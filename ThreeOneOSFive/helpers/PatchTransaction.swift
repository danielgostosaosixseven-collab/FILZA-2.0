import CryptoKit
import Darwin
import Foundation
import AirliftFFI

enum PatchTransactionBackend: String, Equatable {
    case local
    case airLift
    case airTraffic
}

struct PatchTransactionReceipt: Equatable, Identifiable {
    let id: UUID
    let projectID: UUID
    let journalURL: URL
    let backend: PatchTransactionBackend
    let createdAt: Date
}

enum PatchTransaction {
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let originalExisted: Bool
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        let createdDirectories: [DirectoryRecord]?
    }

    private struct ResolvedRule {
        let rule: PatchRule
        let containerRoot: URL
        let target: URL
    }

    private struct ResolvedDirectory {
        let bundleID: String
        let relativePath: String
        let containerRoot: URL
        let target: URL
    }

    private static let schemaVersion = 1
    private static let journalFilename = "journal.plist"

    static func apply(
        project: PatchProject,
        backupRoot: URL,
        containerResolver: (String) throws -> URL,
        beforeWrite: ((Int) throws -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> PatchTransactionReceipt {
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }

        var roots: [String: URL] = [:]
        var resolvedRules: [ResolvedRule] = []
        var resolvedDirectories: [ResolvedDirectory] = []
        var targetKeys = Set<String>()

        func resolvedRoot(for bundleID: String) throws -> URL {
            if let cached = roots[bundleID] { return cached }
            let root = PatchPathValidator.canonicalFileURL(try containerResolver(bundleID))
            roots[bundleID] = root
            return root
        }

        var requestedDirectories = Set<String>()
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            guard bundleID == directory.bundleID else { throw PatchPackageError.invalidProject }
            requestedDirectories.insert(bundleID + "\0" + directory.relativePath)
        }
        for rule in project.rules {
            let components = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
                .split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                requestedDirectories.insert(
                    rule.bundleID + "\0" + components.prefix(count).joined(separator: "/")
                )
            }
        }

        for key in requestedDirectories.sorted(by: directoryKeySort) {
            let parts = key.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw PatchPackageError.invalidProject }
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(String(parts[0]))
            let relativePath = try PatchPathValidator.canonicalRelativePath(String(parts[1]))
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: relativePath,
                containerRoot: root
            )
            try validateDirectoryTarget(
                target,
                relativePath: relativePath,
                containerRoot: root,
                fileManager: fileManager
            )
            resolvedDirectories.append(ResolvedDirectory(
                bundleID: bundleID,
                relativePath: relativePath,
                containerRoot: root,
                target: target
            ))
        }

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            guard bundleID == rule.bundleID else { throw PatchPackageError.invalidProject }
            let root = try resolvedRoot(for: bundleID)
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: rule.relativePath,
                containerRoot: root
            )
            let targetKey = target.path
            guard targetKeys.insert(targetKey).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            try validateFileTarget(
                target,
                relativePath: rule.relativePath,
                containerRoot: root,
                allowMissingParents: true,
                fileManager: fileManager
            )
            resolvedRules.append(ResolvedRule(rule: rule, containerRoot: root, target: target))
        }

        let transactionID = UUID()
        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        } catch {
            throw PatchPackageError.applyFailed
        }

        var records: [Record] = []
        let createdDirectories = resolvedDirectories.compactMap { resolved -> DirectoryRecord? in
            guard !fileManager.fileExists(atPath: resolved.target.path) else { return nil }
            return DirectoryRecord(
                bundleID: resolved.bundleID,
                relativePath: resolved.relativePath,
                containerFingerprint: containerFingerprint(resolved.containerRoot)
            )
        }
        do {
            for resolved in resolvedRules {
                let existed = fileManager.fileExists(atPath: resolved.target.path)
                let backupFilename = existed ? "\(resolved.rule.id.uuidString).original" : nil
                var originalDigest: Data?
                if let backupFilename {
                    let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                    try fileManager.copyItem(at: resolved.target, to: backupURL)
                    originalDigest = try digestFile(backupURL)
                }
                records.append(Record(
                    ruleID: resolved.rule.id,
                    bundleID: resolved.rule.bundleID,
                    relativePath: resolved.rule.relativePath,
                    containerFingerprint: containerFingerprint(resolved.containerRoot),
                    originalExisted: existed,
                    backupFilename: backupFilename,
                    originalDigest: originalDigest,
                    replacementDigest: digest(resolved.rule.replacementData)
                ))
            }
        } catch let error as PatchPackageError {
            throw error
        } catch {
            throw PatchPackageError.applyFailed
        }

        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        var journal = Journal(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: createdDirectories
        )
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            throw PatchPackageError.applyFailed
        }

        do {
            for resolved in resolvedDirectories where !fileManager.fileExists(atPath: resolved.target.path) {
                try fileManager.createDirectory(
                    at: resolved.target,
                    withIntermediateDirectories: false
                )
            }
            for (index, resolved) in resolvedRules.enumerated() {
                try beforeWrite?(index)
                try atomicWrite(
                    resolved.rule.replacementData,
                    to: resolved.target,
                    preservingExistingAttributes: true,
                    fileManager: fileManager
                )
                guard try digestFile(resolved.target) == records[index].replacementDigest else {
                    throw PatchPackageError.applyFailed
                }
            }
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL,
                backend: .local,
                createdAt: journal.createdAt
            )
        } catch {
            do {
                try restoreRecords(
                    records,
                    transactionDirectory: transactionDirectory,
                    roots: roots,
                    requirePatchedDigest: false,
                    createdDirectories: createdDirectories,
                    fileManager: fileManager
                )
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
            } catch {
                // Preserve the prepared journal and backups for explicit recovery.
            }
            throw PatchPackageError.applyFailed
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        containerResolver: (String) throws -> URL,
        allowModifiedPatchedFiles: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        guard receipt.backend == .local else { throw PatchPackageError.restoreFailed }
        var journal: Journal
        do {
            journal = try readJournal(receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
        guard journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared
        else {
            throw PatchPackageError.restoreFailed
        }

        var roots: [String: URL] = [:]
        do {
            for record in journal.records where roots[record.bundleID] == nil {
                let root = PatchPathValidator.canonicalFileURL(try containerResolver(record.bundleID))
                guard containerFingerprint(root) == record.containerFingerprint else {
                    throw PatchPackageError.restoreFailed
                }
                roots[record.bundleID] = root
            }
            try restoreRecords(
                journal.records,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                roots: roots,
                // The target may have been touched by the app or by a partial
                // interrupted restore. The journal backup is authoritative.
                requirePatchedDigest: journal.status == .applied && !allowModifiedPatchedFiles,
                createdDirectories: journal.createdDirectories ?? [],
                fileManager: fileManager
            )
            journal.status = .restored
            try writeJournal(journal, to: receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
    }

    static func latestReceipt(
        projectID: UUID,
        backupRoot: URL,
        fileManager: FileManager = .default
    ) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url),
                  journal.status == .applied else { return nil }
            return (journal, url)
        }
        .sorted { $0.0.createdAt > $1.0.createdAt }
        .first
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1,
                backend: .local,
                createdAt: $0.0.createdAt
            )
        }
    }

    static func requiredBundleIdentifiers(for receipt: PatchTransactionReceipt) throws -> [String] {
        guard receipt.backend == .local else { throw PatchPackageError.restoreFailed }
        let journal = try readJournal(receipt.journalURL)
        guard journal.schemaVersion == schemaVersion,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID else {
            throw PatchPackageError.restoreFailed
        }
        var seen = Set<String>()
        return (journal.records.map(\.bundleID)
            + (journal.createdDirectories ?? []).map(\.bundleID)).compactMap { bundleID in
                seen.insert(bundleID).inserted ? bundleID : nil
            }
    }

    private static func restoreRecords(
        _ records: [Record],
        transactionDirectory: URL,
        roots: [String: URL],
        requirePatchedDigest: Bool,
        createdDirectories: [DirectoryRecord],
        fileManager: FileManager
    ) throws {
        var resolvedTargets: [(Record, URL)] = []
        for record in records {
            guard let root = roots[record.bundleID],
                  containerFingerprint(root) == record.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: record.relativePath,
                containerRoot: root
            )
            try validateFileTarget(
                target,
                relativePath: record.relativePath,
                containerRoot: root,
                allowMissingParents: !requirePatchedDigest,
                fileManager: fileManager
            )

            if requirePatchedDigest {
                guard fileManager.fileExists(atPath: target.path),
                      try digestFile(target) == record.replacementDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            if record.originalExisted {
                guard let backupFilename = record.backupFilename,
                      let expectedDigest = record.originalDigest else {
                    throw PatchPackageError.restoreFailed
                }
                let backup = transactionDirectory.appendingPathComponent(backupFilename)
                guard fileManager.fileExists(atPath: backup.path),
                      try digestFile(backup) == expectedDigest else {
                    throw PatchPackageError.restoreFailed
                }
            }
            resolvedTargets.append((record, target))
        }

        for (record, target) in resolvedTargets.reversed() {
            if record.originalExisted {
                let backup = transactionDirectory.appendingPathComponent(record.backupFilename!)
                try atomicCopy(backup, to: target, fileManager: fileManager)
            } else if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }

        for directory in createdDirectories.reversed() {
            guard let root = roots[directory.bundleID],
                  containerFingerprint(root) == directory.containerFingerprint else {
                throw PatchPackageError.restoreFailed
            }
            let target = try PatchPathValidator.resolveContainedTargetURL(
                relativePath: directory.relativePath,
                containerRoot: root
            )
            guard fileManager.fileExists(atPath: target.path) else { continue }
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.restoreFailed
            }
            let contents = try fileManager.contentsOfDirectory(atPath: target.path)
            if contents.isEmpty {
                try fileManager.removeItem(at: target)
            }
        }
    }

    private static func validateFileTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        allowMissingParents: Bool,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/")
            .map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else {
                if allowMissingParents { break }
                throw PatchPackageError.applyFailed
            }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory != true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func validateDirectoryTarget(
        _ target: URL,
        relativePath: String,
        containerRoot: URL,
        fileManager: FileManager
    ) throws {
        let components = try PatchPathValidator.canonicalRelativePath(relativePath)
            .split(separator: "/").map(String.init)
        var cursor = PatchPathValidator.canonicalFileURL(containerRoot)
        for component in components {
            cursor.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: cursor.path) else { break }
            let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatchPackageError.symbolicLinkUnsupported
            }
            guard values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw PatchPackageError.applyFailed
            }
        }
    }

    private static func directoryKeySort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func atomicWrite(
        _ data: Data,
        to target: URL,
        preservingExistingAttributes: Bool,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-patch-\(UUID().uuidString)")
        var attributes: [FileAttributeKey: Any] = [:]
        if preservingExistingAttributes,
           let current = try? fileManager.attributesOfItem(atPath: target.path) {
            if let permissions = current[.posixPermissions] { attributes[.posixPermissions] = permissions }
            if let protection = current[.protectionKey] { attributes[.protectionKey] = protection }
        }
        guard fileManager.createFile(atPath: staging.path, contents: data, attributes: attributes) else {
            throw PatchPackageError.applyFailed
        }
        defer { try? fileManager.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.applyFailed
        }
    }

    private static func atomicCopy(
        _ source: URL,
        to target: URL,
        fileManager: FileManager
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".3105-restore-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        let handle = try FileHandle(forWritingTo: staging)
        try handle.synchronize()
        try handle.close()
        guard rename(staging.path, target.path) == 0 else {
            throw PatchPackageError.restoreFailed
        }
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func containerFingerprint(_ url: URL) -> Data {
        digest(Data(PatchPathValidator.canonicalFileURL(url).path.utf8))
    }
}


/// Transação equivalente à local, mas operando dentro do container AFC vendado
/// pelo House Arrest. Backups e journal permanecem locais ao app controlador.
enum AirLiftPatchTransaction {
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        let originalExisted: Bool
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let backend: String
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        let createdDirectories: [DirectoryRecord]
    }

    private struct RuleSpec {
        let rule: PatchRule
        let bundleID: String
        let relativePath: String
    }

    private static let schemaVersion = 1
    private static let backendTag = "airlift-house-arrest"
    private static let journalFilename = "airlift-journal.plist"

    static func apply(project: PatchProject, backupRoot: URL) throws -> PatchTransactionReceipt {
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }

        var normalizedRules: [RuleSpec] = []
        var ruleIDs = Set<UUID>()
        var targetKeys = Set<String>()
        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let path = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            guard bundleID == rule.bundleID, path == rule.relativePath,
                  ruleIDs.insert(rule.id).inserted else {
                throw PatchPackageError.invalidProject
            }
            guard targetKeys.insert(bundleID + "\0" + path).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            normalizedRules.append(RuleSpec(rule: rule, bundleID: bundleID, relativePath: path))
        }

        var directoryPaths: [String: Set<String>] = [:]
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            let path = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
            guard bundleID == directory.bundleID, path == directory.relativePath else {
                throw PatchPackageError.invalidProject
            }
            directoryPaths[bundleID, default: []].insert(path)
        }
        for bundleID in Array(directoryPaths.keys) {
            for path in Array(directoryPaths[bundleID] ?? []) {
                let components = path.split(separator: "/").map(String.init)
                if components.count > 1 {
                    for count in 1..<components.count {
                        directoryPaths[bundleID, default: []]
                            .insert(components.prefix(count).joined(separator: "/"))
                    }
                }
            }
        }
        for spec in normalizedRules {
            let components = spec.relativePath.split(separator: "/").map(String.init)
            if components.count > 1 {
                for count in 1..<components.count {
                    directoryPaths[spec.bundleID, default: []]
                        .insert(components.prefix(count).joined(separator: "/"))
                }
            }
        }

        let relevantBundleIDs = Set(normalizedRules.map(\.bundleID)).union(directoryPaths.keys)
        let orderedBundleIDs = relevantBundleIDs.sorted()
        guard !orderedBundleIDs.isEmpty else { throw PatchPackageError.invalidProject }
        let rulesByBundle = Dictionary(grouping: normalizedRules, by: \.bundleID)
        let orderedDirectories = directoryPaths.mapValues { paths in
            paths.sorted(by: pathSort)
        }

        let transactionID = UUID()
        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        } catch {
            throw PatchPackageError.applyFailed
        }

        var recordsByRuleID: [UUID: Record] = [:]
        var createdDirectories: [DirectoryRecord] = []
        do {
            for bundleID in orderedBundleIDs {
                try AirLiftTransport.shared.withAppContainer(bundleID: bundleID) { fileSystem in
                    let fingerprint = try containerFingerprint(bundleID: bundleID, fileSystem: fileSystem)
                    for path in orderedDirectories[bundleID] ?? [] {
                        try validateDirectory(path: path, fileSystem: fileSystem)
                        if try fileSystem.info(path: path) == nil {
                            createdDirectories.append(DirectoryRecord(
                                bundleID: bundleID,
                                relativePath: path,
                                containerFingerprint: fingerprint
                            ))
                        }
                    }

                    for spec in rulesByBundle[bundleID] ?? [] {
                        try validateFileTarget(path: spec.relativePath, fileSystem: fileSystem)
                        let existing = try fileSystem.info(path: spec.relativePath)
                        let backupFilename = existing == nil ? nil : "\(spec.rule.id.uuidString).original"
                        var originalDigest: Data?
                        if let backupFilename {
                            let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                            guard let digest = try fileSystem.copyFileToLocal(
                                path: spec.relativePath,
                                destination: backupURL
                            ) else {
                                throw AirLiftTransportError.fileOperation(
                                    "salvar backup [\(bundleID)]",
                                    spec.relativePath,
                                    "o arquivo desapareceu durante a leitura"
                                )
                            }
                            originalDigest = digest
                        }
                        recordsByRuleID[spec.rule.id] = Record(
                            ruleID: spec.rule.id,
                            bundleID: bundleID,
                            relativePath: spec.relativePath,
                            containerFingerprint: fingerprint,
                            originalExisted: existing != nil,
                            backupFilename: backupFilename,
                            originalDigest: originalDigest,
                            replacementDigest: digest(spec.rule.replacementData)
                        )
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw error
        }

        let records = normalizedRules.compactMap { recordsByRuleID[$0.rule.id] }
        guard records.count == normalizedRules.count else {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw PatchPackageError.applyFailed
        }
        var journal = Journal(
            schemaVersion: schemaVersion,
            backend: backendTag,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: createdDirectories
        )
        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw PatchPackageError.applyFailed
        }

        do {
            for bundleID in orderedBundleIDs {
                try AirLiftTransport.shared.withAppContainer(bundleID: bundleID) { fileSystem in
                    for path in orderedDirectories[bundleID] ?? [] {
                        if try fileSystem.info(path: path) == nil {
                            do {
                                try fileSystem.makeDirectory(path: path)
                            } catch {
                                guard try fileSystem.info(path: path)?.kind == .directory else { throw error }
                            }
                        }
                    }
                    for spec in rulesByBundle[bundleID] ?? [] {
                        try fileSystem.writeAtomically(data: spec.rule.replacementData, to: spec.relativePath)
                        guard try fileSystem.digestFile(path: spec.relativePath)
                                == recordsByRuleID[spec.rule.id]?.replacementDigest else {
                            throw PatchPackageError.applyFailed
                        }
                    }
                }
            }
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL,
                backend: .airLift,
                createdAt: journal.createdAt
            )
        } catch {
            do {
                try restoreContents(
                    journal,
                    transactionDirectory: transactionDirectory,
                    requirePatchedDigest: false
                )
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
            } catch {
                log("airlift patch: rollback incomplete; preserving prepared journal: \(error.localizedDescription)")
            }
            throw error
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowModifiedPatchedFiles: Bool = false
    ) throws {
        guard receipt.backend == .airLift else { throw PatchPackageError.restoreFailed }
        var journal: Journal
        do {
            journal = try readJournal(receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
        guard journal.schemaVersion == schemaVersion,
              journal.backend == backendTag,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared else {
            throw PatchPackageError.restoreFailed
        }

        do {
            try restoreContents(
                journal,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                requirePatchedDigest: journal.status == .applied && !allowModifiedPatchedFiles
            )
            journal.status = .restored
            try writeJournal(journal, to: receipt.journalURL)
        } catch {
            throw error
        }
    }

    static func latestReceipt(projectID: UUID, backupRoot: URL) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url),
                  journal.schemaVersion == schemaVersion,
                  journal.backend == backendTag,
                  journal.status == .applied || journal.status == .prepared else { return nil }
            return (journal, url)
        }
        .max { $0.0.createdAt < $1.0.createdAt }
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1,
                backend: .airLift,
                createdAt: $0.0.createdAt
            )
        }
    }

    private static func fixedOriginalData(for record: Record) -> Data? {
        return FixedGameOriginalStore.data(bundleID: record.bundleID, relativePath: record.relativePath)
    }

    private static func restoreContents(
        _ journal: Journal,
        transactionDirectory: URL,
        requirePatchedDigest: Bool
    ) throws {
        let bundleIDs = Array(Set(
            journal.records.map(\.bundleID) + journal.createdDirectories.map(\.bundleID)
        )).sorted()
        var expectedFingerprints: [String: Data] = [:]
        for record in journal.records {
            guard expectedFingerprints[record.bundleID] == nil else { continue }
            expectedFingerprints[record.bundleID] = record.containerFingerprint
        }
        for directory in journal.createdDirectories where expectedFingerprints[directory.bundleID] == nil {
            expectedFingerprints[directory.bundleID] = directory.containerFingerprint
        }

        // Pré-validar todos os containers, destinos e backups antes de alterar qualquer arquivo.
        for bundleID in bundleIDs {
            try withRestoreFileSystem(bundleID: bundleID) { fileSystem in
                let currentFingerprint = try containerFingerprint(bundleID: bundleID, fileSystem: fileSystem)
                let hasFixedOriginalForBundle = journal.records.contains {
                    $0.bundleID == bundleID && fixedOriginalData(for: $0) != nil
                }
                guard hasFixedOriginalForBundle || currentFingerprint == expectedFingerprints[bundleID] else {
                    throw PatchPackageError.restoreFailed
                }
                for record in journal.records where record.bundleID == bundleID {
                    guard fixedOriginalData(for: record) != nil || record.containerFingerprint == currentFingerprint else {
                        throw PatchPackageError.restoreFailed
                    }
                    try validateFileTarget(path: record.relativePath, fileSystem: fileSystem)
                    if requirePatchedDigest {
                        guard try fileSystem.digestFile(path: record.relativePath) == record.replacementDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                    }
                    if record.originalExisted {
                        guard let backupFilename = record.backupFilename,
                              backupFilename == "\(record.ruleID.uuidString).original",
                              let expectedDigest = record.originalDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                        let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                        guard FileManager.default.fileExists(atPath: backupURL.path),
                              try digestFile(at: backupURL) == expectedDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                    }
                }
            }
        }

        // Recriar somente os diretórios registrados como criados pela transação.
        for bundleID in bundleIDs {
            try withRestoreFileSystem(bundleID: bundleID) { fileSystem in
                for directory in journal.createdDirectories
                    .filter({ $0.bundleID == bundleID })
                    .sorted(by: { pathSort($0.relativePath, $1.relativePath) }) {
                    if try fileSystem.info(path: directory.relativePath) == nil {
                        do {
                            try fileSystem.makeDirectory(path: directory.relativePath)
                        } catch {
                            guard try fileSystem.info(path: directory.relativePath)?.kind == .directory else {
                                throw error
                            }
                        }
                    }
                }
            }
        }

        for bundleID in bundleIDs {
            try withRestoreFileSystem(bundleID: bundleID) { fileSystem in
                for record in journal.records.filter({ $0.bundleID == bundleID }).reversed() {
                    if let fixedOriginal = fixedOriginalData(for: record) {
                        try fileSystem.writeAtomically(data: fixedOriginal, to: record.relativePath)
                    } else if record.originalExisted {
                        guard let backupFilename = record.backupFilename else {
                            throw PatchPackageError.restoreFailed
                        }
                        let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                        try fileSystem.writeAtomically(from: backupURL, to: record.relativePath)
                    } else {
                        try fileSystem.removePath(path: record.relativePath)
                    }
                    let expectedDigest = fixedOriginalData(for: record).map { Data(SHA256.hash(data: $0)) } ?? record.originalDigest
                    if let expectedDigest {
                        guard try fileSystem.digestFile(path: record.relativePath) == expectedDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                    }
                }
                for directory in journal.createdDirectories
                    .filter({ $0.bundleID == bundleID })
                    .sorted(by: { pathSort($1.relativePath, $0.relativePath) }) {
                    do {
                        try fileSystem.removePath(path: directory.relativePath)
                    } catch {
                        // AFC remove is non-recursive here; leave a directory if the app populated it.
                        log("airlift patch: kept non-empty directory \(directory.relativePath)")
                    }
                }
            }
        }
    }

    private static func withRestoreFileSystem<T>(
        bundleID: String,
        operation: (AirLiftAFCFileSystem) throws -> T
    ) throws -> T {
        do {
            // A IPA Airlift de referência restaura pela sessão Documents.
            // Priorize essa mesma rota; o container completo permanece como
            // fallback para dispositivos que não expõem vend_documents.
            return try AirLiftTransport.shared.withAppDocuments(
                bundleID: bundleID,
                operation: operation
            )
        } catch {
            log("airlift restore: vend_documents falhou; tentando vend_container: \(error.localizedDescription)")
            return try AirLiftTransport.shared.withAppContainer(
                bundleID: bundleID,
                operation: operation
            )
        }
    }

    private static func validateDirectory(path: String, fileSystem: AirLiftAFCFileSystem) throws {
        let components = try PatchPathValidator.canonicalRelativePath(path).split(separator: "/")
        var cursor: [Substring] = []
        for component in components {
            cursor.append(component)
            let currentPath = cursor.joined(separator: "/")
            guard let entry = try fileSystem.info(path: currentPath) else { break }
            guard entry.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard entry.kind == .directory else { throw PatchPackageError.applyFailed }
        }
    }

    private static func validateFileTarget(path: String, fileSystem: AirLiftAFCFileSystem) throws {
        let canonicalPath = try PatchPathValidator.canonicalRelativePath(path)
        let components = canonicalPath.split(separator: "/")
        var cursor: [Substring] = []
        for component in components.dropLast() {
            cursor.append(component)
            let currentPath = cursor.joined(separator: "/")
            guard let entry = try fileSystem.info(path: currentPath) else { break }
            guard entry.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard entry.kind == .directory else { throw PatchPackageError.applyFailed }
        }
        if let target = try fileSystem.info(path: canonicalPath) {
            guard target.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard target.kind == .regularFile else { throw PatchPackageError.applyFailed }
        }
    }

    private static func containerFingerprint(
        bundleID: String,
        fileSystem: AirLiftAFCFileSystem
    ) throws -> Data {
        let pairingData = AirLiftPairingStore.shared.loadPairingFile() ?? Data()
        var identity = Data(bundleID.utf8)
        identity.append(0)
        identity.append(Data(SHA256.hash(data: pairingData)))
        var creationTime = try fileSystem.rootCreationTime()
        withUnsafeBytes(of: &creationTime) { identity.append(contentsOf: $0) }
        return Data(SHA256.hash(data: identity))
    }

    private static func pathSort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }
}


/// Transação remota para sistemas que exigem AirLift. House Arrest/AFC fornece
/// metadados, backups e verificação do app container; a escrita usa AirTraffic
/// (streaming ZIP + ATC), que é o mecanismo observado na IPA de referência.
enum AirTrafficPatchTransaction {
    private enum Status: String, Codable {
        case prepared
        case applied
        case rolledBack
        case restored
    }

    private struct Record: Codable {
        let ruleID: UUID
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
        // Optional fields preserve decoding of schemaVersion 1 journals created by older builds.
        let originalExisted: Bool?
        let backupFilename: String?
        let originalDigest: Data?
        let replacementDigest: Data
    }

    private struct DirectoryRecord: Codable {
        let bundleID: String
        let relativePath: String
        let containerFingerprint: Data
    }

    private struct Journal: Codable {
        let schemaVersion: Int
        let backend: String
        let transactionID: UUID
        let projectID: UUID
        let createdAt: Date
        var status: Status
        let records: [Record]
        let createdDirectories: [DirectoryRecord]?
    }

    private struct RuleSpec {
        let rule: PatchRule
        let bundleID: String
        let relativePath: String
        let components: [String]

        var parentPath: String { components.dropLast().joined(separator: "/") }
        var leaf: String { components.last ?? "" }
    }

    private struct GroupKey: Hashable {
        let bundleID: String
        let parentPath: String
    }

    private struct StagedFile {
        let relativePath: String
        let data: Data
    }

    private static let schemaVersion = 1
    private static let backendTag = "airtraffic-coredevice-write-dir"
    private static let journalFilename = "airtraffic-journal.plist"

    /// Verifica o canal AFC e o alvo exato sem modificar arquivos.
    static func verifyWriteChannel(project: PatchProject) throws {
        let specs = try normalizedRules(project.rules)
        guard !specs.isEmpty else { throw PatchPackageError.invalidProject }
        guard let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }
        let bundleIDs = Array(Set(specs.map(\.bundleID))).sorted()
        for bundleID in bundleIDs {
            let containerPath = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
            try AirLiftTransport.shared.withRootAFC(containerPath: containerPath) { fileSystem in
                for spec in specs where spec.bundleID == bundleID {
                    guard let entry = try fileSystem.info(path: spec.relativePath),
                          entry.kind == .regularFile else {
                        throw AirLiftTransportError.fileOperation(
                            "verificar o alvo",
                            spec.relativePath,
                            "o arquivo não está disponível no container emparelhado"
                        )
                    }
                }
            }
        }
        log("airtraffic preflight: canal AFC e alvos reais confirmados")
    }

    /// Verifica um arquivo real dentro do container emparelhado, sem escrever nada.
    static func verifyFileAccess(bundleID: String, relativePath: String) throws {
        guard let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }
        let containerPath = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
        try AirLiftTransport.shared.withRootAFC(containerPath: containerPath) { fileSystem in
            guard let entry = try fileSystem.info(path: relativePath), entry.kind == .regularFile else {
                throw AirLiftTransportError.fileOperation(
                    "verificar o acesso",
                    relativePath,
                    "o arquivo não está disponível no container emparelhado"
                )
            }
        }
        log("airtraffic access check: container e arquivo confirmados para \(bundleID)")
    }

    static func apply(project: PatchProject, backupRoot: URL) throws -> PatchTransactionReceipt {
        guard !project.rules.isEmpty || !project.directories.isEmpty else {
            throw PatchPackageError.invalidProject
        }
        guard AirLiftTransport.shared.state == .connected else {
            throw AirLiftTransportError.tunnelUnavailable
        }

        let specs = try normalizedRules(project.rules)
        var directoryPaths: [String: Set<String>] = [:]
        for directory in project.directories {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(directory.bundleID)
            let path = try PatchPathValidator.canonicalRelativePath(directory.relativePath)
            guard bundleID == directory.bundleID, path == directory.relativePath else {
                throw PatchPackageError.invalidProject
            }
            directoryPaths[bundleID, default: []].insert(path)
        }
        for bundleID in Array(directoryPaths.keys) {
            for path in Array(directoryPaths[bundleID] ?? []) {
                let components = path.split(separator: "/").map(String.init)
                if components.count > 1 {
                    for count in 1..<components.count {
                        directoryPaths[bundleID, default: []]
                            .insert(components.prefix(count).joined(separator: "/"))
                    }
                }
            }
        }
        for spec in specs {
            if spec.components.count > 1 {
                for count in 1..<spec.components.count {
                    directoryPaths[spec.bundleID, default: []]
                        .insert(spec.components.prefix(count).joined(separator: "/"))
                }
            }
        }
        for spec in specs where directoryPaths[spec.bundleID]?.contains(spec.relativePath) == true {
            throw PatchPackageError.invalidProject
        }

        let bundleIDs = Array(Set(specs.map(\.bundleID)).union(directoryPaths.keys)).sorted()
        guard !bundleIDs.isEmpty else { throw PatchPackageError.invalidProject }
        let orderedDirectories = directoryPaths.mapValues { paths in
            paths.sorted(by: pathSort)
        }
        let groups = Dictionary(grouping: specs) { GroupKey(bundleID: $0.bundleID, parentPath: $0.parentPath) }
        let groupKeys = sortedGroupKeys(Array(groups.keys))
        let transactionID = UUID()
        let transactionDirectory = backupRoot
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        guard let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }

        var containerPaths: [String: String] = [:]
        var fingerprints: [String: Data] = [:]
        var recordsByRuleID: [UUID: Record] = [:]
        var createdDirectories: [DirectoryRecord] = []
        do {
            for bundleID in bundleIDs {
                let containerPath = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
                containerPaths[bundleID] = containerPath
                fingerprints[bundleID] = containerFingerprint(
                    bundleID: bundleID,
                    containerPath: containerPath,
                    pairingData: pairingData
                )

                do {
                    try AirLiftTransport.shared.withFileService(bundleID: bundleID) { fileSystem in
                    for path in orderedDirectories[bundleID] ?? [] {
                        // FileService does not expose AFC metadata; AirTraffic
                        // creates the parent directories while applying the archive.
                        createdDirectories.append(DirectoryRecord(
                            bundleID: bundleID,
                            relativePath: path,
                            containerFingerprint: fingerprints[bundleID]!
                        ))
                    }
                    for spec in specs where spec.bundleID == bundleID {
                        let original = try fileSystem.readFileIfPresent(path: spec.relativePath)
                        let backupFilename = original == nil ? nil : "\(spec.rule.id.uuidString).original"
                        var originalDigest: Data?
                        if let backupFilename {
                            let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                            guard let original else {
                                throw AirLiftTransportError.fileServiceOperation(
                                    "salvar backup [\(bundleID)]",
                                    spec.relativePath,
                                    "o arquivo desapareceu durante a leitura"
                                )
                            }
                            try original.write(to: backupURL, options: .atomic)
                            originalDigest = Data(SHA256.hash(data: original))
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: backupURL.path
                            )
                        }
                        guard let fingerprint = fingerprints[bundleID] else {
                            throw PatchPackageError.applyFailed
                        }
                        recordsByRuleID[spec.rule.id] = Record(
                            ruleID: spec.rule.id,
                            bundleID: bundleID,
                            relativePath: spec.relativePath,
                            containerFingerprint: fingerprint,
                            originalExisted: original != nil,
                            backupFilename: backupFilename,
                            originalDigest: originalDigest,
                            replacementDigest: digest(spec.rule.replacementData)
                        )
                    }
                    }
                } catch let error as AirLiftTransportError {
                    guard case .fileServiceUnavailable(_, let reason) = error,
                          reason.lowercased().contains("servicenotfound") else {
                        throw error
                    }
                    // FileService é opcional, mas backup não é. O AirTraffic
                    // pode escrever sem esse serviço; a leitura dos originais
                    // continua sendo feita pelo AFC raiz. Nunca marcar
                    // tudo como "original inexistente": isso faria a escrita
                    // funcionar e tornaria a restauração impossível.
                    let containerPath = containerPaths[bundleID]!
                    try AirLiftTransport.shared.withRootAFC { fileSystem in
                        let fingerprint = fingerprints[bundleID]!
                        for path in orderedDirectories[bundleID] ?? [] {
                            let absolutePath = containerPath + "/" + path
                            if try fileSystem.info(path: absolutePath) == nil {
                                createdDirectories.append(DirectoryRecord(
                                    bundleID: bundleID,
                                    relativePath: path,
                                    containerFingerprint: fingerprint
                                ))
                            }
                        }
                        for spec in specs where spec.bundleID == bundleID {
                            let absolutePath = containerPath + "/" + spec.relativePath
                            let existing = try fileSystem.info(path: absolutePath)
                            let backupFilename = existing == nil ? nil : "\(spec.rule.id.uuidString).original"
                            var originalDigest: Data?
                            if let backupFilename {
                                let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                                guard let copiedDigest = try fileSystem.copyFileToLocal(
                                    path: absolutePath,
                                    destination: backupURL
                                ) else {
                                    throw AirLiftTransportError.fileOperation(
                                        "salvar backup [\(bundleID)]",
                                        spec.relativePath,
                                        "o arquivo desapareceu durante a leitura AFC"
                                    )
                                }
                                originalDigest = copiedDigest
                            }
                            recordsByRuleID[spec.rule.id] = Record(
                                ruleID: spec.rule.id,
                                bundleID: bundleID,
                                relativePath: spec.relativePath,
                                containerFingerprint: fingerprint,
                                originalExisted: existing != nil,
                                backupFilename: backupFilename,
                                originalDigest: originalDigest,
                                replacementDigest: digest(spec.rule.replacementData)
                            )
                        }
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: transactionDirectory)
            log("airtraffic patch preflight failed: \(error.localizedDescription)")
            throw error
        }

        let records = specs.compactMap { recordsByRuleID[$0.rule.id] }
        guard records.count == specs.count else {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw PatchPackageError.applyFailed
        }

        let journalURL = transactionDirectory.appendingPathComponent(journalFilename)
        var journal = Journal(
            schemaVersion: schemaVersion,
            backend: backendTag,
            transactionID: transactionID,
            projectID: project.id,
            createdAt: Date(),
            status: .prepared,
            records: records,
            createdDirectories: createdDirectories
        )
        do {
            try writeJournal(journal, to: journalURL)
        } catch {
            try? FileManager.default.removeItem(at: transactionDirectory)
            throw PatchPackageError.applyFailed
        }

        do {
            for key in groupKeys {
                guard let root = containerPaths[key.bundleID], let group = groups[key] else {
                    throw PatchPackageError.applyFailed
                }
                let stagedFiles = group.map { StagedFile(relativePath: $0.relativePath, data: $0.rule.replacementData) }
                try writeGroup(
                    pairingPath: pairingPath,
                    containerRoot: root,
                    parentPath: key.parentPath,
                    files: stagedFiles
                )
                do {
                    try verifyReplacementGroup(containerPath: root, files: stagedFiles)
                } catch {
                    log("airtraffic: confirmação falhou; repetindo pelo AFC raiz: \(error.localizedDescription)")
                    try writeGroupViaRootAFC(containerRoot: root, files: stagedFiles)
                    try verifyReplacementGroup(containerPath: root, files: stagedFiles)
                }
                log("airtraffic: grupo injetado e confirmado pelo digest")
            }
            journal.status = .applied
            try writeJournal(journal, to: journalURL)
            return PatchTransactionReceipt(
                id: transactionID,
                projectID: project.id,
                journalURL: journalURL,
                backend: .airTraffic,
                createdAt: journal.createdAt
            )
        } catch {
            log("airtraffic patch write failed; restoring originals: \(error.localizedDescription)")
            do {
                try restoreContents(
                    journal,
                    transactionDirectory: transactionDirectory,
                    pairingPath: pairingPath,
                    pairingData: pairingData,
                    requirePatchedDigest: false
                )
                journal.status = .rolledBack
                try writeJournal(journal, to: journalURL)
            } catch {
            log("airtraffic patch rollback incomplete; prepared journal preserved: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// Escreve os originais fornecidos diretamente nos dois containers do pairing.
    static func restoreFixedGameOriginalsDirectly() throws {
        guard AirLiftTransport.shared.state == .connected,
              let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }
        let entries = FixedGameOriginalStore.directEntries
        guard !entries.isEmpty else { throw PatchPackageError.restoreFailed }
        for bundleID in Set(entries.map { $0.bundleID }) {
            let root = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
            let files = entries.filter { $0.bundleID == bundleID }.map {
                StagedFile(relativePath: $0.relativePath, data: $0.data)
            }
            try writeGroupViaRootAFC(containerRoot: root, files: files)
            try verifyReplacementGroup(containerPath: root, files: files)
        }
        log("airtraffic restore: originais fornecidos escritos e confirmados por digest")
    }

    /// Força somente o arquivo do jogo selecionado e só retorna após confirmar o digest.
    static func forceFixedGameOriginal(bundleID: String) throws {
        guard AirLiftTransport.shared.state == .connected,
              let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }
        guard let entry = FixedGameOriginalStore.directEntries.first(where: { $0.bundleID == bundleID }) else {
            throw PatchPackageError.restoreFailed
        }
        let root = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
        let file = StagedFile(relativePath: entry.relativePath, data: entry.data)
        let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        // A versão funcional escreve primeiro pelo AirTraffic emparelhado;
        // writeGroup usa AFC somente como fallback interno.
        try writeGroup(
            pairingPath: pairingPath,
            containerRoot: root,
            parentPath: String(parentPath),
            files: [file]
        )
        try verifyReplacementGroup(containerPath: root, files: [file])
        log("airtraffic force restore: \(bundleID) escrito e confirmado por digest")
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowModifiedPatchedFiles: Bool = false
    ) throws {
        guard receipt.backend == .airTraffic else { throw PatchPackageError.restoreFailed }
        var journal: Journal
        do {
            journal = try readJournal(receipt.journalURL)
        } catch {
            throw PatchPackageError.restoreFailed
        }
        guard journal.schemaVersion == schemaVersion,
              journal.backend == backendTag,
              journal.transactionID == receipt.id,
              journal.projectID == receipt.projectID,
              journal.status == .applied || journal.status == .prepared else {
            throw PatchPackageError.restoreFailed
        }
        guard AirLiftTransport.shared.state == .connected,
              let pairingData = AirLiftPairingStore.shared.loadPairingFile(),
              let pairingPath = AirLiftPairingStore.shared.tempFilePath(for: pairingData) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        defer { try? FileManager.default.removeItem(atPath: pairingPath) }

        do {
            try restoreContents(
                journal,
                transactionDirectory: receipt.journalURL.deletingLastPathComponent(),
                pairingPath: pairingPath,
                pairingData: pairingData,
                requirePatchedDigest: journal.status == .applied && !allowModifiedPatchedFiles
            )
            journal.status = .restored
            try writeJournal(journal, to: receipt.journalURL)
        } catch {
            log("airtraffic patch restore failed: \(error.localizedDescription)")
            throw error
        }
    }

    static func latestReceipt(projectID: UUID, backupRoot: URL) -> PatchTransactionReceipt? {
        let projectDirectory = backupRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return directories.compactMap { directory -> (Journal, URL)? in
            let url = directory.appendingPathComponent(journalFilename)
            guard let journal = try? readJournal(url),
                  journal.schemaVersion == schemaVersion,
                  journal.backend == backendTag,
                  journal.status == .applied || journal.status == .prepared else { return nil }
            return (journal, url)
        }
        .max { $0.0.createdAt < $1.0.createdAt }
        .map {
            PatchTransactionReceipt(
                id: $0.0.transactionID,
                projectID: $0.0.projectID,
                journalURL: $0.1,
                backend: .airTraffic,
                createdAt: $0.0.createdAt
            )
        }
    }

    private static func normalizedRules(_ rules: [PatchRule]) throws -> [RuleSpec] {
        var ruleIDs = Set<UUID>()
        var targets = Set<String>()
        return try rules.map { rule in
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let path = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            let components = path.split(separator: "/").map(String.init)
            guard bundleID == rule.bundleID,
                  path == rule.relativePath,
                  !components.isEmpty,
                  let leaf = components.last,
                  !leaf.hasPrefix("."),
                  ruleIDs.insert(rule.id).inserted else {
                throw PatchPackageError.invalidProject
            }
            guard targets.insert(bundleID + "\0" + path).inserted else {
                throw PatchPackageError.duplicateTarget
            }
            return RuleSpec(rule: rule, bundleID: bundleID, relativePath: path, components: components)
        }
    }

    private static func fixedOriginalData(for record: Record) -> Data? {
        return FixedGameOriginalStore.data(bundleID: record.bundleID, relativePath: record.relativePath)
    }

    private static func restoreContents(
        _ journal: Journal,
        transactionDirectory: URL,
        pairingPath: String,
        pairingData: Data,
        requirePatchedDigest: Bool
    ) throws {
        let createdDirectories = journal.createdDirectories ?? []
        let bundleIDs = Array(Set(
            journal.records.map(\.bundleID) + createdDirectories.map(\.bundleID)
        )).sorted()
        var containerPaths: [String: String] = [:]
        var expectedFingerprints: [String: Data] = [:]
        for record in journal.records where expectedFingerprints[record.bundleID] == nil {
            expectedFingerprints[record.bundleID] = record.containerFingerprint
        }
        for directory in createdDirectories where expectedFingerprints[directory.bundleID] == nil {
            expectedFingerprints[directory.bundleID] = directory.containerFingerprint
        }
        for bundleID in bundleIDs {
            let containerPath = try resolveContainerPath(pairingPath: pairingPath, bundleID: bundleID)
            containerPaths[bundleID] = containerPath
            let fingerprint = containerFingerprint(
                bundleID: bundleID,
                containerPath: containerPath,
                pairingData: pairingData
            )
            let hasFixedOriginalForBundle = journal.records.contains {
                $0.bundleID == bundleID && fixedOriginalData(for: $0) != nil
            }
            // A reinstall/update of the game can recreate the data container and
            // change its creation fingerprint. For the two user-supplied fixed
            // originals, the exact bundle/path plus post-write SHA-256 is the
            // stronger identity; do not block those safe factory restores only
            // because an old container fingerprint is stale.
            guard hasFixedOriginalForBundle || expectedFingerprints[bundleID] == fingerprint else {
                throw PatchPackageError.restoreFailed
            }
        }

        for bundleID in bundleIDs {
            guard let expectedFingerprint = expectedFingerprints[bundleID] else {
                throw PatchPackageError.restoreFailed
            }
            try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[bundleID]) { fileSystem in
                for record in journal.records where record.bundleID == bundleID {
                    guard fixedOriginalData(for: record) != nil || record.containerFingerprint == expectedFingerprint else {
                        throw PatchPackageError.restoreFailed
                    }
                    try validateFileTarget(path: record.relativePath, fileSystem: fileSystem)
                    if let fixedOriginal = fixedOriginalData(for: record) {
                        guard !fixedOriginal.isEmpty else { throw PatchPackageError.restoreFailed }
                    } else if record.originalExisted ?? true {
                        guard let backupFilename = record.backupFilename,
                              backupFilename == "\(record.ruleID.uuidString).original",
                              let originalDigest = record.originalDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                        let backupURL = transactionDirectory.appendingPathComponent(backupFilename)
                        guard FileManager.default.fileExists(atPath: backupURL.path),
                              try digestFile(at: backupURL) == originalDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                    } else if let fixedOriginal = fixedOriginalData(for: record) {
                        guard !fixedOriginal.isEmpty else { throw PatchPackageError.restoreFailed }
                    } else if record.backupFilename != nil || record.originalDigest != nil {
                        throw PatchPackageError.restoreFailed
                    }
                }
                for directory in createdDirectories where directory.bundleID == bundleID {
                    guard directory.containerFingerprint == expectedFingerprint else {
                        throw PatchPackageError.restoreFailed
                    }
                    try validateDirectory(path: directory.relativePath, fileSystem: fileSystem)
                }
            }
        }

        if requirePatchedDigest {
            for bundleID in bundleIDs {
                try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[bundleID]) { fileSystem in
                    for record in journal.records where record.bundleID == bundleID {
                        guard try fileSystem.digestFile(path: record.relativePath) == record.replacementDigest else {
                            throw PatchPackageError.restoreFailed
                        }
                    }
                }
            }
        }

        for bundleID in bundleIDs {
            let directories = createdDirectories
                .filter { $0.bundleID == bundleID }
                .sorted { pathSort($0.relativePath, $1.relativePath) }
            guard !directories.isEmpty else { continue }
            try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[bundleID]) { fileSystem in
                for directory in directories {
                    if try fileSystem.info(path: directory.relativePath) == nil {
                        do {
                            try fileSystem.makeDirectory(path: directory.relativePath)
                        } catch {
                            guard try fileSystem.info(path: directory.relativePath)?.kind == .directory else {
                                throw error
                            }
                        }
                    }
                }
            }
        }

        let originalRecords = journal.records.filter {
            ($0.originalExisted ?? true) || fixedOriginalData(for: $0) != nil
        }
        let grouped = Dictionary(grouping: originalRecords) {
            let parts = $0.relativePath.split(separator: "/").map(String.init)
            return GroupKey(bundleID: $0.bundleID, parentPath: parts.dropLast().joined(separator: "/"))
        }
        for key in sortedGroupKeys(Array(grouped.keys)) {
            guard let root = containerPaths[key.bundleID], let records = grouped[key] else {
                throw PatchPackageError.restoreFailed
            }
            let files = try records.map { record -> StagedFile in
                if let fixedOriginal = fixedOriginalData(for: record) {
                    return StagedFile(relativePath: record.relativePath, data: fixedOriginal)
                } else if record.originalExisted ?? true, let backupFilename = record.backupFilename {
                    return StagedFile(
                        relativePath: record.relativePath,
                        data: try Data(contentsOf: transactionDirectory.appendingPathComponent(backupFilename))
                    )
                } else {
                    throw PatchPackageError.restoreFailed
                }
            }
            var restoredAndVerified = false
            var lastRestoreError: Error?
            for attempt in 1...3 {
                do {
                    if attempt > 1 {
                        guard AirLiftTransport.shared.ensureConnectionForOperation(attempts: 5) else {
                            throw AirLiftTransportError.tunnelUnavailable
                        }
                        log("airtraffic restore: retrying group \(key.parentPath) after verification failure")
                    }
                    do {
                        // Restauração determinística pelo AFC raiz emparelhado.
                        // O AirTraffic pode rejeitar um diretório existente como
                        // "unverified target" mesmo após o preflight; não deixe
                        // essa proteção impedir a devolução do original.
                        try writeGroupViaRootAFC(
                            containerRoot: root,
                            files: files
                        )
                    } catch {
                        // Último recurso: o transporte AirTraffic, ainda dentro
                        // da mesma sessão persistente e seguido de SHA-256.
                        log("root AFC restore failed; trying AirTraffic: \(error.localizedDescription)")
                        try writeGroup(
                            pairingPath: pairingPath,
                            containerRoot: root,
                            parentPath: key.parentPath,
                            files: files
                        )
                    }
                    try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[key.bundleID]) { fileSystem in
                        for record in records {
                            let expectedDigest = fixedOriginalData(for: record).map { Data(SHA256.hash(data: $0)) } ?? record.originalDigest
                            guard let expectedDigest,
                                  try fileSystem.digestFile(path: record.relativePath) == expectedDigest else {
                                throw PatchPackageError.restoreFailed
                            }
                        }
                    }
                    restoredAndVerified = true
                    break
                } catch {
                    lastRestoreError = error
                    log("airtraffic restore: group verification attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
            guard restoredAndVerified else {
                throw lastRestoreError ?? PatchPackageError.restoreFailed
            }
        }

        for record in journal.records where !(record.originalExisted ?? true) && fixedOriginalData(for: record) == nil {
            try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[record.bundleID]) { fileSystem in
                try fileSystem.removePath(path: record.relativePath)
            }
        }

        for bundleID in bundleIDs {
            let directories = createdDirectories
                .filter { $0.bundleID == bundleID }
                .sorted { pathSort($1.relativePath, $0.relativePath) }
            guard !directories.isEmpty else { continue }
            try AirLiftTransport.shared.withRootAFC(containerPath: containerPaths[bundleID]) { fileSystem in
                for directory in directories {
                    do {
                        try fileSystem.removePath(path: directory.relativePath)
                    } catch {
                        log("airtraffic patch: kept non-empty directory \(directory.relativePath)")
                    }
                }
            }
        }
    }

    private static func writeGroup(
        pairingPath: String,
        containerRoot: String,
        parentPath: String,
        files: [StagedFile]
    ) throws {
        guard !files.isEmpty else { return }
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtraffic-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        for file in files {
            guard let leaf = file.relativePath.split(separator: "/").last.map(String.init),
                  !leaf.isEmpty,
                  !leaf.hasPrefix(".") else {
                throw PatchPackageError.invalidProject
            }
            let localURL = stagingDirectory.appendingPathComponent(leaf)
            try file.data.write(to: localURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path)
        }

        let targetDirectory = parentPath.isEmpty ? containerRoot : containerRoot + "/" + parentPath
        var rawError: UnsafeMutablePointer<CChar>?
        let status = try AirLiftTransport.shared.withExclusiveAirTrafficWrite {
            pairingPath.withCString { pairingCString in
                stagingDirectory.path.withCString { sourceCString in
                    targetDirectory.withCString { targetCString in
                        al_exploit_write_dir(
                            pairingCString,
                            sourceCString,
                            targetCString,
                            nil,
                            nil,
                            &rawError
                        )
                    }
                }
            }
        }
        let reason = rawError.map { String(cString: $0) }
        if let rawError { al_string_free(rawError) }
        if status != 0 {
            log("airtraffic apply failed for \(targetDirectory); trying scoped AFC fallback: \(reason ?? "unknown")")
            try writeGroupViaRootAFC(containerRoot: containerRoot, files: files)
        }
    }

    private static func writeGroupViaRootAFC(
        containerRoot: String,
        files: [StagedFile]
    ) throws {
        // Use the same AFC container prefix as validation and digest checks.
        // An unscoped root session is not equivalent on every iOS 27 AFC implementation.
        try AirLiftTransport.shared.withRootAFC(containerPath: containerRoot) { fileSystem in
            for file in files {
                let target = file.relativePath
                if let entry = try fileSystem.info(path: target), entry.kind != .regularFile {
                    throw PatchPackageError.restoreFailed
                }
                try fileSystem.writeAtomically(data: file.data, to: target)
            }
        }
    }

    private static func verifyReplacementGroup(
        containerPath: String,
        files: [StagedFile]
    ) throws {
        try AirLiftTransport.shared.withRootAFC(containerPath: containerPath) { fileSystem in
            for file in files {
                let expected = Data(SHA256.hash(data: file.data))
                guard try fileSystem.digestFile(path: file.relativePath) == expected else {
                    throw PatchPackageError.applyFailed
                }
            }
        }
    }

    private static func resolveContainerPath(pairingPath: String, bundleID: String) throws -> String {
        var rawContainer: UnsafeMutablePointer<CChar>?
        var rawError: UnsafeMutablePointer<CChar>?
        let status = pairingPath.withCString { pairingCString in
            bundleID.withCString { bundleCString in
                al_find_app_container(
                    pairingCString,
                    bundleCString,
                    nil,
                    nil,
                    &rawContainer,
                    &rawError
                )
            }
        }
        defer {
            if let rawContainer { al_string_free(rawContainer) }
            if let rawError { al_string_free(rawError) }
        }
        guard status == 0, let rawContainer else {
            let reason = rawError.map { String(cString: $0) } ?? "container do app não foi resolvido"
            throw AirTrafficWriteError.target(target: bundleID, reason: reason)
        }

        var rawPath = String(cString: rawContainer)
        if rawPath.hasPrefix("/private/var/mobile/") {
            rawPath.removeFirst("/private".count)
        }
        let canonical = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL.path
        let prefix = "/var/mobile/Containers/Data/Application/"
        guard canonical.hasPrefix(prefix) else {
            throw AirTrafficWriteError.target(target: bundleID, reason: "InstallationProxy retornou um container fora de Application")
        }
        let identifier = String(canonical.dropFirst(prefix.count))
        guard UUID(uuidString: identifier) != nil else {
            throw AirTrafficWriteError.target(target: bundleID, reason: "caminho de container não canônico")
        }
        return canonical
    }

    private static func containerFingerprint(bundleID: String, containerPath: String, pairingData: Data) -> Data {
        var identity = Data(bundleID.utf8)
        identity.append(0)
        identity.append(Data(containerPath.utf8))
        identity.append(0)
        identity.append(Data(SHA256.hash(data: pairingData)))
        return digest(identity)
    }

    private static func sortedGroupKeys(_ keys: [GroupKey]) -> [GroupKey] {
        keys.sorted {
            if $0.bundleID != $1.bundleID { return $0.bundleID < $1.bundleID }
            return $0.parentPath < $1.parentPath
        }
    }

    private static func withRestoreFileSystem<T>(
        bundleID: String,
        operation: (AirLiftAFCFileSystem) throws -> T
    ) throws -> T {
        do {
            // A IPA Airlift de referência restaura pela sessão Documents.
            // Priorize essa mesma rota; o container completo permanece como
            // fallback para dispositivos que não expõem vend_documents.
            return try AirLiftTransport.shared.withAppDocuments(
                bundleID: bundleID,
                operation: operation
            )
        } catch {
            log("airlift restore: vend_documents falhou; tentando vend_container: \(error.localizedDescription)")
            return try AirLiftTransport.shared.withAppContainer(
                bundleID: bundleID,
                operation: operation
            )
        }
    }

    private static func validateDirectory(path: String, fileSystem: AirLiftAFCFileSystem) throws {
        let components = try PatchPathValidator.canonicalRelativePath(path).split(separator: "/")
        var cursor: [Substring] = []
        for component in components {
            cursor.append(component)
            let currentPath = cursor.joined(separator: "/")
            guard let entry = try fileSystem.info(path: currentPath) else { break }
            guard entry.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard entry.kind == .directory else { throw PatchPackageError.applyFailed }
        }
    }

    private static func validateFileTarget(path: String, fileSystem: AirLiftAFCFileSystem) throws {
        let canonicalPath = try PatchPathValidator.canonicalRelativePath(path)
        let components = canonicalPath.split(separator: "/")
        var cursor: [Substring] = []
        for component in components.dropLast() {
            cursor.append(component)
            let currentPath = cursor.joined(separator: "/")
            guard let entry = try fileSystem.info(path: currentPath) else { break }
            guard entry.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard entry.kind == .directory else { throw PatchPackageError.applyFailed }
        }
        if let target = try fileSystem.info(path: canonicalPath) {
            guard target.kind != .symbolicLink else { throw PatchPackageError.symbolicLinkUnsupported }
            guard target.kind == .regularFile else { throw PatchPackageError.applyFailed }
        }
    }

    private static func pathSort(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.filter { $0 == "/" }.count
        let rightDepth = rhs.filter { $0 == "/" }.count
        return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func digestFile(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private enum AirTrafficWriteError: LocalizedError {
        case target(target: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .target(let target, let reason):
                return "AirTraffic falhou em \(target): \(reason)"
            }
        }
    }
}
