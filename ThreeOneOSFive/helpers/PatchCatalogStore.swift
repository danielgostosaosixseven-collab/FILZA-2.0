import Foundation
import SwiftUI

/// Downloads and applies patch packages from the online catalog.
///
/// The IPA ships with NO embedded patches. Every `.3105` package is fetched
/// from the backend catalog (`/v1/catalog`) and kept only in the protected session directory.
/// Toggling a card on/off applies or restores the corresponding project.
@MainActor
final class PatchCatalogStore: ObservableObject {
    static let shared = PatchCatalogStore()
    @Published var items: [FilzaLicense.CatalogItem] = []
    @Published var downloadError: String? = nil
    @Published var activeID: String?
    @Published private(set) var isRefreshing = false
    private var enabledIDs: Set<String> = []

    private let cacheDir: URL
    private var refreshInFlight = false
    private var readyFilenames: Set<String> = []
    private var inFlightDownloads: [String: Task<URL?, Never>] = [:]

    init() {
        cacheDir = (try? PatchProjectLibrary.packageRootURL())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(".fp-session", isDirectory: true)
                .appendingPathComponent(".packages", isDirectory: true)
    }

    // MARK: - Load catalog + prefetch all files in small batches

    /// Publishes catalog metadata immediately, then prefetches missing packages
    /// two at a time. The UI must remain usable for the whole prefetch.
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        isRefreshing = true
        downloadError = nil
        defer {
            refreshInFlight = false
            isRefreshing = false
        }

        let response = await FilzaLicense.fetchCatalog()
        guard let catalog = response.catalog else {
            downloadError = response.failureMessage
                ?? (items.isEmpty
                    ? "Não foi possível carregar as opções. Verifique sua conexão e tente novamente."
                    : "Não foi possível atualizar; mantendo as opções já carregadas.")
            return
        }

        let incoming = catalog.items
        publishCatalogIfChanged(incoming)

        // Skip packages already verified in this process, but re-check their
        // path in case the cache was removed while the app was open.
        let knownReady = readyFilenames
        let candidates = incoming.filter { item in
            let filename = self.filename(for: item)
            guard knownReady.contains(filename) else { return true }
            return !FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent(filename).path)
        }

        guard !candidates.isEmpty else {
            PatchProjectStore.shared.reload()
            return
        }

        var failedDownloads = 0
        let batchSize = 2
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            await withTaskGroup(of: (String, Bool).self) { group in
                for item in batch {
                    let expectedFilename = filename(for: item)
                    let store = self
                    group.addTask {
                        (expectedFilename, await store.ensureDownloaded(item) != nil)
                    }
                }
                for await (expectedFilename, downloaded) in group {
                    if downloaded {
                        readyFilenames.insert(expectedFilename)
                    } else {
                        failedDownloads += 1
                    }
                }
            }
        }

        PatchProjectStore.shared.reload()
        if failedDownloads > 0 {
            downloadError = "Não foi possível carregar \(failedDownloads) opção(ões). Elas continuam visíveis; toque para tentar novamente."
        }
    }

    private func publishCatalogIfChanged(_ incoming: [FilzaLicense.CatalogItem]) {
        let oldSignature = items.map { "\($0.id)|\($0.file)|\($0.cat ?? "")" }
        let newSignature = incoming.map { "\($0.id)|\($0.file)|\($0.cat ?? "")" }
        if oldSignature != newSignature { items = incoming }
    }

    private func filename(for item: FilzaLicense.CatalogItem) -> String {
        item.localFilename
    }

    /// Reuses a prefetch task when the user taps an item that is already being
    /// downloaded. Cache decryption and validation run away from the UI thread.
    private func ensureDownloaded(_ item: FilzaLicense.CatalogItem) async -> URL? {
        let filename = filename(for: item)
        let destination = cacheDir.appendingPathComponent(filename)

        if let existing = inFlightDownloads[item.id] {
            return await existing.value
        }

        let validCache = await Task.detached(priority: .utility) {
            Self.isValidCachedPackage(at: destination)
        }.value
        if validCache {
            readyFilenames.insert(filename)
            return destination
        }

        // Re-check after the asynchronous disk validation: another caller may
        // have started or completed the download while this task was suspended.
        if let existing = inFlightDownloads[item.id] {
            return await existing.value
        }

        let task = Task.detached(priority: .userInitiated) {
            await FilzaLicense.downloadItem(item)
        }
        inFlightDownloads[item.id] = task
        let result = await task.value
        inFlightDownloads[item.id] = nil
        if result != nil {
            readyFilenames.insert(filename)
        }
        return result
    }

    private nonisolated static func isValidCachedPackage(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            // Migrate legacy plaintext cache entries, then verify encryption,
            // authentication, and package structure before treating them as ready.
            try PatchProjectLibrary.ensureProtectedAtRest(at: url)
            let data = try PatchProjectLibrary.readPackage(at: url)
            _ = try PatchPackageCodec.inspect(data)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    private static func normalizedCategory(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !raw.isEmpty else {
            return nil
        }
        let aliases = [
            "HOLOGRAMA": "HOLOGRAMAS",
            "TEXTURA": "TEXTURAS",
            "OUTRO": "OUTROS",
            "PATCH": "OUTROS",
            "PATCHS": "OUTROS"
        ]
        return aliases[raw] ?? raw
    }

    // MARK: - Enabled state (persisted per item id)

    func isEnabled(_ item: FilzaLicense.CatalogItem) -> Bool {
        enabledIDs.contains(item.id)
    }

    /// Clears the in-memory catalog state immediately after a full reset.
    /// The journals are already restored on disk; without this explicit clear,
    /// the old card could remain visually marked as active until a later sync.
    func clearEnabledStates() {
        activeID = nil
        enabledIDs.removeAll()
    }

    func syncEnabledStates() {
        let catalog = items
        Task { [weak self] in
            let ids = await Task.detached(priority: .utility) {
                let libraries = PatchProjectLibrary.load()
                let pending = Set(DevicePatchService.pendingReceipts().map(\.projectID))
                return Set(catalog.compactMap { item -> String? in
                    guard let library = libraries.first(where: { $0.packageURL.lastPathComponent == item.localFilename }),
                          pending.contains(library.uniqueID) || pending.contains(library.id) else { return nil }
                    return item.id
                })
            }.value
            self?.enabledIDs = ids
        }
    }

    // MARK: - Download only (automatic selection)

    func downloadOnly(_ item: FilzaLicense.CatalogItem, onMain: @escaping (String, UUID?) -> Void) {
        guard activeID == nil else {
            onMain("Aguarde o patch atual terminar.", nil)
            return
        }
        activeID = item.id

        Task { [weak self] in
            guard let self else { return }
            var message = "PATCH BAIXADO — PRONTO PARA SELECIONAR"
            var selectedID: UUID?

            if await self.ensureDownloaded(item) == nil {
                message = "ERRO — NÃO FOI POSSÍVEL VALIDAR O DOWNLOAD. TENTE NOVAMENTE."
            } else {
                selectedID = await Task.detached(priority: .userInitiated) {
                    PatchProjectLibrary.load()
                        .first(where: { $0.packageURL.lastPathComponent == item.localFilename && $0.project != nil })?.uniqueID
                }.value
                if selectedID == nil {
                    message = "ERRO — PATCH BAIXADO, MAS AINDA NÃO ESTÁ PRONTO."
                }
            }

            self.activeID = nil
            onMain(message, selectedID)
        }
    }

    // MARK: - Toggle apply / restore

    func toggle(_ item: FilzaLicense.CatalogItem, onMain: @escaping (String) -> Void) {
        guard activeID == nil else {
            onMain("Aguarde o patch atual terminar.")
            return
        }
        let wasOn = isEnabled(item)
        activeID = item.id
        let filename = item.localFilename
        let itemID = item.id
        let categoryKey = Self.normalizedCategory(item.cat)
        let sameCategoryPeers = categoryKey.map { selectedCategory in
            items.filter { candidate in
                candidate.id != item.id && Self.normalizedCategory(candidate.cat) == selectedCategory
            }
        } ?? []

        Task { [weak self] in
            guard let self else { return }
            var message: String
            var resultOn = wasOn
            var restoredPeerIDs = Set<String>()
            var packageReady = wasOn
            if !wasOn {
                packageReady = await self.ensureDownloaded(item) != nil
            }

            if !packageReady {
                message = "ERRO — NÃO FOI POSSÍVEL VALIDAR O DOWNLOAD. TENTE NOVAMENTE."
            } else {
                let result = await Task.detached(priority: .userInitiated) { () -> (String, Bool, Set<String>) in
                    var restored = Set<String>()
                    do {
                        if wasOn {
                            if let lib = PatchProjectLibrary.load().first(where: { $0.packageURL.lastPathComponent == filename }),
                               let receipt = DevicePatchService.latestReceipt(projectID: lib.uniqueID) {
                                try DevicePatchService.restore(receipt: receipt, allowModifiedPatchedFiles: true)
                                return ("CONCLUÍDO", false, restored)
                            }
                            return ("DESATIVADO — NENHUM PATCH ATIVO", false, restored)
                        }

                        let libraries = PatchProjectLibrary.load()
                        let peerProjectIDs = Set(sameCategoryPeers.compactMap { peer in
                            libraries.first(where: { $0.packageURL.lastPathComponent == peer.localFilename })?.uniqueID
                        })
                        if !peerProjectIDs.isEmpty {
                            let recovery = DevicePatchService.restorePendingOriginals(
                                reconnect: true,
                                projectIDs: peerProjectIDs
                            )
                            guard recovery.failures.isEmpty, recovery.remainingIDs.isEmpty else {
                                throw PatchPackageError.restoreFailed
                            }
                            restored.formUnion(sameCategoryPeers.map(\.id))
                        }

                        guard let library = PatchProjectLibrary.load()
                            .first(where: { $0.packageURL.lastPathComponent == filename }),
                              var project = library.project else {
                            return ("ERRO — O PATCH AINDA NÃO ESTÁ PRONTO. TENTE NOVAMENTE.", false, restored)
                        }
                        project.id = library.uniqueID
                        _ = try DevicePatchService.apply(project: project)
                        return ("CONCLUÍDO", true, restored)
                    } catch {
                        return ("ERRO — \(error.localizedDescription)", wasOn, restored)
                    }
                }.value
                message = result.0
                resultOn = result.1
                restoredPeerIDs = result.2
            }

            for peerID in restoredPeerIDs { self.enabledIDs.remove(peerID) }
            if resultOn { self.enabledIDs.insert(itemID) }
            else { self.enabledIDs.remove(itemID) }
            self.activeID = nil
            onMain(message)
        }
    }

    // MARK: - AFC Fallback Accessors
    // Used by KernelExploit.run() when falling back to AFC on iOS 27+.

    func currentPatchData() -> Data? {
        guard let item = items.first(where: { readyFilenames.contains($0.localFilename) }) ?? items.first else { return nil }
        let localURL = cacheDir.appendingPathComponent(item.localFilename)
        return try? PatchProjectLibrary.readPackage(at: localURL)
    }

    func currentPatchName() -> String? {
        guard let item = items.first(where: { readyFilenames.contains($0.localFilename) }) ?? items.first else { return nil }
        return item.name
    }
}
