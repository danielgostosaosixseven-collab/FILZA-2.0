import Foundation
import CryptoKit
import Security


enum PatchAtRestCrypto {
    private static let magic = Data("FPENC1\0".utf8)
    private static let service = "com.apple.mobile.MobileHouseArrest.patch-cache-key.v1"
    private static let account = "installation-key"

    private static func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw PatchPackageError.keychainFailed }
        // The read query contains return/match options that are invalid for
        // SecItemAdd. Build a clean write query so a fresh installation can
        // create the cache key instead of dropping every downloaded package.
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess || add == errSecDuplicateItem else { throw PatchPackageError.keychainFailed }
        return SymmetricKey(data: data)
    }

    static func seal(_ data: Data, filename: String) throws -> Data {
        let box = try AES.GCM.seal(data, using: try key(), authenticating: Data(filename.utf8))
        guard let combined = box.combined else { throw PatchPackageError.invalidProject }
        var result = magic
        result.append(combined)
        return result
    }

    static func open(_ data: Data, filename: String) throws -> Data {
        guard data.starts(with: magic) else { return data }
        let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count)))
        return try AES.GCM.open(box, using: try key(), authenticating: Data(filename.utf8))
    }
}

struct PatchLibraryItem: Identifiable {
    let summary: PatchPackageSummary
    var project: PatchProject?
    var contentKey: Data?
    var packageURL: URL

    var id: UUID { summary.packageID }
    var isLocked: Bool { project == nil }
    var displayName: String {
        let filename = packageURL.lastPathComponent
        // Try direct catalog match first
        if let catalogName = PatchCatalog.displayName(forBundledFile: filename) {
            return catalogName
        }
        if let project, !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return project.name
        }
        let base = packageURL.deletingPathExtension().lastPathComponent
        let visibleBase = base.split(separator: "__", maxSplits: 1).last.map(String.init) ?? base
        return visibleBase.replacingOccurrences(of: "-", with: " ")
    }
}

struct PatchPasswordRequest: Identifiable {
    let summary: PatchPackageSummary
    var id: UUID { summary.packageID }
}

enum PatchProjectLibrary {
    static func packageRootURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let session = support.appendingPathComponent(".fp-session", isDirectory: true)
        let root = session.appendingPathComponent(".packages", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [session, root] {
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isHidden = true
            values.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(values)
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
        }

        // Migrate the prior encrypted cache without decrypting it; filenames (and
        // therefore AES-GCM AAD) remain unchanged. Copy first so a failed move
        // can still fall back to the intact legacy cache.
        let legacy = fileManager.temporaryDirectory
            .appendingPathComponent(".fp-session", isDirectory: true)
            .appendingPathComponent(".packages", isDirectory: true)
        if legacy.path != root.path,
           let children = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            do {
                for child in children {
                    let destination = root.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
                    if !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.copyItem(at: child, to: destination)
                    }
                }
                try? fileManager.removeItem(at: legacy)
                let legacyParent = legacy.deletingLastPathComponent()
                if (try? fileManager.contentsOfDirectory(atPath: legacyParent.path).isEmpty) == true {
                    try? fileManager.removeItem(at: legacyParent)
                }
            } catch {
                log("patch: kept legacy encrypted cache after incomplete migration")
                return legacy
            }
        }
        return root
    }
    static func backupRootURL(fileManager: FileManager = .default) throws -> URL {
        let root = try packageRootURL(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Once, removes artifacts created by releases that embedded patches locally.
    /// Downloaded `.r7v` packages stay encrypted in hidden Application Support;
    /// stale plaintext workspace directories from older releases are removed.
    static func purgeLegacyBundledArtifacts(fileManager: FileManager = .default) {
        // Remove old persistent patch locations from earlier releases.
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fileManager.removeItem(at: support.appendingPathComponent("PatchProjects", isDirectory: true))
        try? fileManager.removeItem(at: documents.appendingPathComponent("Patches", isDirectory: true))
        try? fileManager.removeItem(at: documents.appendingPathComponent("FilzaFiles", isDirectory: true))
        PatchWorkspaceService.clearWorkspaceArtifacts(fileManager: fileManager)

        let migrationKey = "onlineCatalogLegacyPatchMigration.v2"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        let legacyNames = (1...12).map { "p\(String(format: "%02d", $0)).dat" } + ["p15.dat", "p16.dat"]
        let patchRoot = support.appendingPathComponent("PatchProjects", isDirectory: true)
        for name in legacyNames {
            try? fileManager.removeItem(at: patchRoot.appendingPathComponent(name))
        }
        if let urls = try? fileManager.contentsOfDirectory(at: patchRoot, includingPropertiesForKeys: nil) {
            for url in urls where ["3105", "r7v"].contains(url.pathExtension.lowercased()) {
                try? fileManager.removeItem(at: url)
            }
        }

        // Older builds downloaded into Documents/FilzaFiles instead of the
        // authenticated PatchProjects directory.
        let legacyDownloads = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilzaFiles", isDirectory: true)
        try? fileManager.removeItem(at: legacyDownloads)
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    static func load(fileManager: FileManager = .default) -> [PatchLibraryItem] {
        guard let root = try? packageRootURL(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
              ) else { return [] }

        var byFilename: [String: PatchLibraryItem] = [:]
        for rawURL in urls where ["3105", "r7v"].contains(rawURL.pathExtension.lowercased()) {
            let url = migrateOpaqueCatalogURLIfNeeded(from: rawURL, fileManager: fileManager)
            do {
                try ensureProtectedAtRest(at: url, fileManager: fileManager)
                let data = try readPackage(at: url)
                let summary = try PatchPackageCodec.inspect(data)
                let decoded: DecodedPatchPackage?
                if let contentKey = try PatchKeyStore.load(for: summary) {
                    decoded = try PatchPackageCodec.decode(data, contentKey: contentKey)
                } else if summary.isPasswordProtected {
                    // Online packages remain locked until the user supplies the password.
                    decoded = nil
                } else {
                    decoded = try PatchPackageCodec.decode(data, password: nil)
                }
                let item = PatchLibraryItem(
                    summary: summary,
                    project: decoded?.project,
                    contentKey: decoded?.contentKey,
                    packageURL: url
                )
                // Keep decrypted replacement data in memory only while the
                // library is loaded; routine scans must not unpack every .r7v.
                byFilename[url.lastPathComponent] = item
            } catch {
                if !isProtectedAtRest(at: url) {
                    try? fileManager.removeItem(at: url)
                    log("patch: removed unprotected local package \(url.lastPathComponent)")
                } else {
                    log("patch: skipped invalid protected package \(url.lastPathComponent)")
                }
            }
        }
        return byFilename.values.sorted {
            ($0.project?.updatedAt ?? .distantPast) > ($1.project?.updatedAt ?? .distantPast)
        }
    }

    private static func migrateOpaqueCatalogURLIfNeeded(
        from url: URL,
        fileManager: FileManager
    ) -> URL {
        let oldFilename = url.lastPathComponent
        guard url.pathExtension.lowercased() == "r7v",
              let separator = oldFilename.range(of: "__") else { return url }
        let catalogID = String(oldFilename[..<separator.lowerBound])
        let remoteFilename = String(oldFilename[separator.upperBound...])
        guard !catalogID.isEmpty, !remoteFilename.isEmpty else { return url }

        let newFilename = FilzaLicense.CatalogItem.cacheFilename(
            catalogID: catalogID,
            remoteFilename: remoteFilename
        )
        let destination = url.deletingLastPathComponent().appendingPathComponent(newFilename)
        do {
            let data = try readPackage(at: url)
            _ = try save(
                data: data,
                projectName: newFilename,
                existingURL: destination,
                fileManager: fileManager
            )
            try? fileManager.removeItem(at: url)
            return destination
        } catch {
            log("patch: could not migrate opaque cache filename for \(catalogID)")
            return url
        }
    }

    static func readPackage(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw PatchPackageError.invalidProject
        }
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        return try PatchAtRestCrypto.open(raw, filename: url.lastPathComponent)
    }

    static func isProtectedAtRest(at url: URL) -> Bool {
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return raw.starts(with: Data("FPENC1\0".utf8))
    }

    /// Migrates older plaintext local files to AES-GCM before they can be used.
    /// If sealing fails, the caller must remove the still-unprotected source.
    static func ensureProtectedAtRest(at url: URL, fileManager: FileManager = .default) throws {
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !raw.starts(with: Data("FPENC1\0".utf8)) else { return }
        let packageData = try PatchAtRestCrypto.open(raw, filename: url.lastPathComponent)
        _ = try save(
            data: packageData,
            projectName: url.deletingPathExtension().lastPathComponent,
            existingURL: url,
            fileManager: fileManager
        )
        guard isProtectedAtRest(at: url) else { throw PatchPackageError.invalidProject }
    }

    static func save(
        data: Data,
        projectName: String,
        existingURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination: URL
        if let existingURL {
            destination = existingURL
        } else {
            let root = try packageRootURL(fileManager: fileManager)
            let baseName = sanitizedFilename(projectName)
            var candidate = root.appendingPathComponent(baseName).appendingPathExtension("OGIOS")
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = root.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("OGIOS")
                suffix += 1
            }
            destination = candidate
        }
        let protectedData = try PatchAtRestCrypto.seal(data, filename: destination.lastPathComponent)
        try protectedData.write(to: destination, options: [.atomic, .completeFileProtection])
        return destination
    }

    static func installImportedPackage(
        data: Data,
        decoded: DecodedPatchPackage,
        summary: PatchPackageSummary,
        existingURL: URL?,
        fileManager: FileManager = .default
    ) throws {
        let previousData = try existingURL.map { try readPackage(at: $0) }
        var savedURL: URL?
        do {
            savedURL = try save(
                data: data,
                projectName: decoded.project.name,
                existingURL: existingURL,
                fileManager: fileManager
            )
        } catch {
            if let previousData, let existingURL {
                _ = try? save(
                    data: previousData,
                    projectName: existingURL.deletingPathExtension().lastPathComponent,
                    existingURL: existingURL,
                    fileManager: fileManager
                )
            } else if let savedURL, fileManager.fileExists(atPath: savedURL.path) {
                try? fileManager.removeItem(at: savedURL)
            }
            throw error
        }
    }

    static func delete(_ item: PatchLibraryItem, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: item.packageURL.path) {
            try fileManager.removeItem(at: item.packageURL)
        }
        try? PatchKeyStore.delete(for: item.summary)
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = rawName.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
        return result.isEmpty ? "Patch" : String(result)
    }
}

// MARK: - Unique ID per file (deterministic hash of filename)
extension PatchLibraryItem {
    var uniqueID: UUID {
        let filename = packageURL.lastPathComponent
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in filename.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        let s1 = String(padded.prefix(8))
        let s2 = String(padded.dropFirst(8).prefix(4))
        let s3 = String(padded.dropFirst(12).prefix(4))
        let s4 = "0000"
        let s5 = "000000000000"
        return UUID(uuidString: "\(s1)-\(s2)-\(s3)-\(s4)-\(s5)")!
    }
}
