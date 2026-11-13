import Foundation
import Security

/// Uses the App Groups in this app's live signature. No other app's group,
/// API endpoint, license, or release identity is used here.
enum WorseQueryAccess {
    private static let queryLock = NSLock()
    private static let stateLock = NSLock()
    private static var prepared = false
    private static var knownGames: [String: String] = [:]
    private static var browserLeases: [String: Int64] = [:]

    static var isRequired: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ExploitSupportPolicy.prefersWorseQuery(
            major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion, build: AppInfo.osBuild
        )
    }

    static var isIOS273: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ExploitSupportPolicy.isIOS273Beta1(
            major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion, build: AppInfo.osBuild
        )
    }

    static var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return prepared
    }

    static var signedGroups: [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ) as? [String] else { return [] }
        return Array(Set(groups.filter { $0.hasPrefix("group.") })).sorted()
    }

    struct AccessFailure: LocalizedError {
        let codes: [Int64]
        var errorDescription: String? {
            if codes.contains(-100) {
                return "File access needs a usable App Group authorized in this app's signature and provisioning profile. Sign with this app's own App Group, then reopen the app."
            }
            return "Game file access was not granted (codes: \(codes)). The current operation was stopped."
        }
    }

    /// Prepares the backend with a new app-owned directory. Game access is
    /// verified separately on every paste/restore, never inferred from this.
    static func activate() -> Bool {
        guard isRequired else { return false }
        if isReady { return true }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("3105-wq-" + UUID().uuidString)
        do {
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            let attempt = performGrant(path: temporary.path)
            guard let handle = attempt.handle else {
                log("worse_query: preparation failed codes=\(attempt.codes)")
                return false
            }
            defer { worse_query_release(handle) }
            stateLock.lock()
            prepared = true
            stateLock.unlock()
            log("worse_query: backend prepared; selected game access still requires verification")
            return true
        } catch {
            log("worse_query: local preparation failed: \(error.localizedDescription)")
            return false
        }
    }

    static func rememberGameContainer(path: String, bundleID: String) {
        guard ExploitSupportPolicy.gameBundleIDs.contains(bundleID),
              let root = ExploitSupportPolicy.applicationContainerRoot(for: path),
              root == ExploitSupportPolicy.normalizedAccessPath(path) else { return }
        stateLock.lock()
        knownGames[root] = bundleID
        stateLock.unlock()
    }

    static func knownGameBundleID(for path: String) -> String? {
        guard let root = ExploitSupportPolicy.applicationContainerRoot(for: path) else { return nil }
        stateLock.lock()
        defer { stateLock.unlock() }
        return knownGames[root]
    }

    static func grantWithDiagnostics(path: String, bundleID: String? = nil) -> (handle: Int64?, codes: [Int64]) {
        guard isRequired, let canonical = ExploitSupportPolicy.normalizedAccessPath(path) else {
            return (nil, [-101])
        }
        if isIOS273 && !ExploitSupportPolicy.allowsIOS273GameGrant(
            build: AppInfo.osBuild, bundleID: bundleID, path: canonical
        ) {
            return (nil, [-101])
        }
        return performGrant(path: canonical)
    }

    private static func performGrant(path: String) -> (handle: Int64?, codes: [Int64]) {
        let groups = signedGroups
        guard !groups.isEmpty else { return (nil, [-100]) }
        queryLock.lock()
        defer { queryLock.unlock() }
        var codes: [Int64] = []
        for group in groups {
            guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
                codes.append(-1)
                continue
            }
            // The imported implementation refuses populated/redirected caches.
            let flags = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                ? [true, false] : [false]
            for alternateFlags in flags {
                let handle = worse_query(path, group, alternateFlags, false)
                if handle >= 0 { return (handle, codes) }
                codes.append(handle)
                // Changing query flags cannot repair a protected cache, missing
                // group or missing symbol. Never alter existing cache contents.
                if [-1, -2, -3, -4, -7, -255].contains(handle) { break }
            }
        }
        return (nil, codes)
    }

    /// The file browser keeps a grant while its later copy/paste actions run.
    /// Renewals replace the previous lease for that container.
    static func retainBrowserGrant(_ handle: Int64, path: String) {
        guard handle >= 0 else { return }
        let key = ExploitSupportPolicy.applicationContainerRoot(for: path) ?? path
        stateLock.lock()
        let previous = browserLeases.updateValue(handle, forKey: key)
        stateLock.unlock()
        if let previous, previous != handle { worse_query_release(previous) }
    }
}

enum GameFileAccessProbe {
    enum Failure: LocalizedError {
        case documentsUnavailable, readMismatch, replaceMismatch, restoreMismatch, filenameCollision
        var errorDescription: String? {
            switch self {
            case .documentsUnavailable: return "The selected game's Documents folder is unavailable."
            case .readMismatch: return "Temporary file read/backup verification failed."
            case .replaceMismatch: return "Temporary file paste verification failed."
            case .restoreMismatch: return "Temporary file restore verification failed."
            case .filenameCollision: return "The temporary test filename already exists."
            }
        }
    }

    // Exercise existing replacement code on a disposable file before touching
    // any game asset. The caller must hold the container grant throughout.
    static func verify(containerRoot: URL) throws {
        let manager = FileManager.default
        let documents = containerRoot.appendingPathComponent("Documents", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: documents.path, isDirectory: &isDirectory), isDirectory.boolValue,
              try documents.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure.documentsUnavailable
        }
        let id = UUID().uuidString
        let test = documents.appendingPathComponent(".3105-access-probe-" + id)
        let working = manager.temporaryDirectory.appendingPathComponent("3105-probe-" + id)
        let backup = working.appendingPathComponent("original")
        let replacement = working.appendingPathComponent("replacement")
        let originalBytes = Data(("3105-ORIGINAL-" + id).utf8)
        let replacementBytes = Data(("3105-REPLACEMENT-" + id).utf8)
        var created = false
        try manager.createDirectory(at: working, withIntermediateDirectories: true)
        defer {
            if created { try? manager.removeItem(at: test) }
            try? manager.removeItem(at: working)
        }
        guard !manager.fileExists(atPath: test.path) else { throw Failure.filenameCollision }
        try originalBytes.write(to: test, options: .withoutOverwriting)
        created = true
        guard try Data(contentsOf: test) == originalBytes else { throw Failure.readMismatch }
        try manager.copyItem(at: test, to: backup)
        guard try Data(contentsOf: backup) == originalBytes else { throw Failure.readMismatch }
        try replacementBytes.write(to: replacement, options: .atomic)
        _ = try FileReplacementService.replace(target: test, with: replacement)
        guard try Data(contentsOf: test) == replacementBytes else { throw Failure.replaceMismatch }
        _ = try FileReplacementService.replace(target: test, with: backup)
        guard try Data(contentsOf: test) == originalBytes else { throw Failure.restoreMismatch }
    }
}
