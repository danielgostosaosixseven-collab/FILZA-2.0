import Foundation

enum DevicePatchService {
    static let operationQueue = DispatchQueue(label: "device.patch.operations", qos: .userInitiated)
    private static let transactionLock = NSRecursiveLock()

    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let connectionGate = AirLiftConnectionCheckGate.patchScope()
        defer { connectionGate.clear() }

        if requiresAirLiftForCurrentDevice {
            // O modo manual aplica imediatamente e não pode depender de o
            // túnel ainda estar conectado após uma oscilação da VPN.
            if !AirLiftTransport.shared.ensureConnectionForOperation(attempts: 5) {
                log("patch activation: recuperando conexão antes do AirTraffic")
                throw AirLiftTransportError.tunnelUnavailable
            }
            // Não pré-validar o arquivo individual: em iOS 17–27 alguns
            // alvos são baixados/criados pelo jogo somente durante o apply.
            // O próprio AirTraffic faz a escrita e a confirmação transacional.
            log("patch activation: routing through AirTraffic over the túnel seguro")
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    return try AirTrafficPatchTransaction.apply(
                        project: project,
                        backupRoot: try PatchProjectLibrary.backupRootURL()
                    )
                } catch {
                    lastError = error
                    let text = error.localizedDescription.lowercased()
                    let transient = ["socket", "not connected", "connection", "timed out", "rsd", "afc", "tunnel"].contains { text.contains($0) }
                    guard attempt == 1, transient else { throw error }
                    log("patch activation: falha transitória; aquecendo a sessão e tentando novamente")
                    guard AirLiftTransport.shared.ensureConnectionForOperation(attempts: 5) else { throw error }
                    Thread.sleep(forTimeInterval: 0.7)
                }
            }
            throw lastError ?? AirLiftTransportError.tunnelUnavailable
        }

        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowModifiedPatchedFiles: Bool = false
    ) throws {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let connectionGate = AirLiftConnectionCheckGate.patchScope()
        defer { connectionGate.clear() }

        if receipt.backend == .airTraffic {
            // A restauração pelo pairing usa a sessão AirTraffic já estabelecida.
            // Não bloqueie por uma sondagem AFC adicional: em alguns iOS ela
            // falha mesmo quando o canal AirTraffic continua apto a restaurar.
            if AirLiftTransport.shared.state != .connected {
                guard AirLiftTransport.shared.connectWithRecovery(pin: nil, attempts: 8) else {
                    log("patch restore: recuperando conexão antes do AirTraffic")
                    throw AirLiftTransportError.tunnelUnavailable
                }
            }
            try AirTrafficPatchTransaction.restore(
                receipt: receipt,
                allowModifiedPatchedFiles: allowModifiedPatchedFiles
            )
            // Restaurar este journal com sucesso não é erro só porque existe
            // um journal mais antigo: a recuperação percorre esses journals
            // separadamente e não pode bloquear a próxima operação.
            return
        }
        if receipt.backend == .airLift {
            guard AirLiftTransport.shared.ensureConnectionForOperation(attempts: 8) else {
                throw AirLiftTransportError.tunnelUnavailable
            }
            try AirLiftPatchTransaction.restore(
                receipt: receipt,
                allowModifiedPatchedFiles: allowModifiedPatchedFiles
            )
            return
        }

        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                },
                allowModifiedPatchedFiles: allowModifiedPatchedFiles
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }

        return [
            PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot),
            AirLiftPatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot),
            AirTrafficPatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
        ]
        .compactMap { $0 }
        .max { $0.createdAt < $1.createdAt }
    }

    struct RecoveryResult {
        var restoredIDs: Set<UUID> = []
        var remainingIDs: Set<UUID> = []
        var failures: [String] = []
        var restoredTransactions = 0
    }

    /// Discover every pending journal, including patches removed from the current catalog.
    static func pendingReceipts() -> [PatchTransactionReceipt] {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let root = try? PatchProjectLibrary.backupRootURL(),
              let projects = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        var receipts: [PatchTransactionReceipt] = []
        for directory in projects {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            receipts.append(contentsOf: [
                PatchTransaction.latestReceipt(projectID: id, backupRoot: root),
                AirLiftPatchTransaction.latestReceipt(projectID: id, backupRoot: root),
                AirTrafficPatchTransaction.latestReceipt(projectID: id, backupRoot: root)
            ].compactMap { $0 })
        }
        return receipts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Remove journals and backups only after every pending original was restored.
    /// Used by the explicit "Resetar do zero" recovery action.
    static func discardResolvedJournals() {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let root = try? PatchProjectLibrary.backupRootURL() else { return }
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
            log("recovery: resolved journals discarded by full reset")
        } catch {
            log("recovery: could not discard resolved journals: \(error.localizedDescription)")
        }
    }

    /// Keep pairing credentials and journals intact. Never clear a failed restore.
    static func restorePendingOriginals(reconnect: Bool, projectIDs: Set<UUID>? = nil) -> RecoveryResult {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        let connectionGate = AirLiftConnectionCheckGate.patchScope()
        defer { connectionGate.clear() }
        var result = RecoveryResult()
        if reconnect && requiresAirLiftForCurrentDevice {
            guard AirLiftPairingStore.shared.hasPairingFile,
                  AirLiftTransport.shared.connectWithRecovery(pin: nil, attempts: 8) else {
                result.remainingIDs = Set(pendingReceipts().map(\.projectID))
                result.failures = ["Não foi possível reconectar. Ative o LocalDevVPN e tente novamente."]
                return result
            }
        }
        if reconnect && requiresAirLiftForCurrentDevice {
            do {
                try AirTrafficPatchTransaction.restoreFixedGameOriginalsDirectly()
                result.restoredTransactions += 1
                log("recovery: originais FF restaurados diretamente pelos caminhos fornecidos")
            } catch {
                // O journal continua sendo a alternativa para projetos antigos
                // ou instalações que não tenham os dois recursos embutidos.
                log("recovery: restauração direta indisponível; usando journals: \(error.localizedDescription)")
            }
        }
        var blockedProjects: Set<UUID> = []
        var processedTransactions: Set<UUID> = []
        while true {
            let candidates = pendingReceipts().filter {
                (projectIDs == nil || projectIDs!.contains($0.projectID)) &&
                !blockedProjects.contains($0.projectID) && !processedTransactions.contains($0.id)
            }
            guard let receipt = candidates.first else { break }
            processedTransactions.insert(receipt.id)
            do {
                try restore(receipt: receipt, allowModifiedPatchedFiles: true)
                result.restoredTransactions += 1
                result.restoredIDs.insert(receipt.projectID)
            } catch {
                blockedProjects.insert(receipt.projectID)
                result.failures.append(error.localizedDescription)
                log("recovery: preserving failed journal \(receipt.id): \(error.localizedDescription)")
                break
            }
        }
        result.remainingIDs = Set(pendingReceipts().filter {
            projectIDs == nil || projectIDs!.contains($0.projectID)
        }.map(\.projectID))
        result.restoredIDs.subtract(result.remainingIDs)
        return result
    }

    static func forceOriginalForCurrentBackend(bundleID: String) throws {
        if !WorseQueryAccess.isRequired {
            guard AirLiftTransport.shared.connectWithRecovery(pin: nil, attempts: 5) else {
                throw AirLiftTransportError.tunnelUnavailable
            }
            try AirTrafficPatchTransaction.forceFixedGameOriginal(bundleID: bundleID)
            return
        }
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let entry = FixedGameOriginalStore.directEntries.first(where: { $0.bundleID == bundleID }) else {
            throw PatchPackageError.restoreFailed
        }
        try withResolvedContainers(bundleIDs: [bundleID]) { roots in
            guard let root = roots[bundleID] else { throw PatchPackageError.restoreFailed }
            let target = try PatchPathValidator.resolveContainedTargetURL(relativePath: entry.relativePath, containerRoot: root)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try entry.data.write(to: staging, options: .atomic)
            _ = try FileReplacementService.replace(target: target, with: staging)
            guard try Data(contentsOf: target) == entry.data else { throw PatchPackageError.restoreFailed }
        }
    }

    static func verifyDirectFileAccess(bundleID: String) throws {
        guard WorseQueryAccess.isRequired else { throw PatchPackageError.targetAppUnavailable(bundleID) }
        try withResolvedContainers(bundleIDs: [bundleID]) { _ in () }
    }

    private static var requiresAirLiftForCurrentDevice: Bool {
        let version = AppInfo.versionTuple
        return ExploitSupportPolicy.requiresAirLift(
            major: version.major,
            minor: version.minor,
            patch: version.patch,
            build: AppInfo.osBuild
        )
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        var leases: [Int64] = []
        defer { leases.forEach { worse_query_release($0) } }

        for bundleID in bundleIDs {
            if WorseQueryAccess.isRequired && !ExploitSupportPolicy.gameBundleIDs.contains(bundleID) {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
            if WorseQueryAccess.isRequired {
                let attempt = WorseQueryAccess.grantWithDiagnostics(path: path, bundleID: bundleID)
                guard let lease = attempt.handle else {
                    throw WorseQueryAccess.AccessFailure(codes: attempt.codes)
                }
                leases.append(lease)
                try GameFileAccessProbe.verify(containerRoot: roots[bundleID]!)
            }
        }
        return try operation(roots)
    }
}
