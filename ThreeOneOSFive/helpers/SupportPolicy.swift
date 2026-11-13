import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS16Range = "16.0–16.6.16"
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.6.1"
    static let verifiedIOS26ExtendedRange = "26.6.2–26.7.2"
    static let verifiedIOS27Range = "27.0–27.2"
    static let verifiedIOS27ExtendedRange = "27.2–27.3"

    // Eligibility for the new backend is separate from permission to a game's
    // files. The selected game's temporary-file probe must still succeed.
    static func prefersWorseQuery(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }
        if major == 26 {
            return (minor == 6 && patch >= 2) || (minor == 7 && patch <= 2)
        }
        if major == 27 {
            if minor < 2 { return true }
            if minor == 2 { return patch <= 1 }
            return isIOS273Beta1(major: major, minor: minor, patch: patch, build: build)
        }
        return false
    }

    static func isIOS273Beta1(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        major == 27 && minor == 3 && patch == 0 && build == "24C5037i"
    }

    static let gameBundleIDs = ["com.dts.freefireth", "com.dts.freefiremax"]

    static func normalizedAccessPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let normalized = path.hasPrefix("/private/var/") ? String(path.dropFirst(8)) : path
        return URL(fileURLWithPath: normalized).standardizedFileURL.path
    }

    static func applicationContainerRoot(for path: String) -> String? {
        guard let normalized = normalizedAccessPath(path) else { return nil }
        let prefix = "/var/mobile/Containers/Data/Application/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let suffix = normalized.dropFirst(prefix.count)
        guard let uuid = suffix.split(separator: "/").first,
              UUID(uuidString: String(uuid)) != nil else { return nil }
        return prefix + String(uuid)
    }

    static func allowsIOS273GameGrant(build: String, bundleID: String?, path: String) -> Bool {
        guard build == "24C5037i", let bundleID, gameBundleIDs.contains(bundleID),
              let normalized = normalizedAccessPath(path),
              let root = applicationContainerRoot(for: normalized) else { return false }
        return root == normalized
    }

    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355c"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f")
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Builds.first { $0.build == build }?.publicBeta
    }

    static func requiresAirLift(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        !isSupported(major: major, minor: minor, patch: patch, build: build)
    }

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 9)
        }

        return false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if prefersWorseQuery(major: major, minor: minor, patch: patch, build: build) { return true }
        guard minor >= 0, patch >= 0 else { return false }

        if major == 16 {
            return minor <= 7
        }

        if supportsKernelExploit(major: major, minor: minor, patch: patch) {
            return true
        }

        if major == 26 {
            return minor < 6 || (minor == 6 && patch <= 2)
        }

        // Em iOS 27, somente builds beta explicitamente listados são suportados diretamente.
        if major == 27 {
            return minor == 0 && patch == 0 && iOS27BetaNumber(for: build) != nil
        }

        // Versões não listadas ficam não suportadas até uma conexão AirLift bem-sucedida.
        return false
    }
}
