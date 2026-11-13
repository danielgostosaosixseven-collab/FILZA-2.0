import Foundation

/// Originais de segurança enviados pelo usuário, limitados aos dois jogos FF.
enum FixedGameOriginalStore {
    private static let assets: [String: (bundleID: String, relativePath: String)] = [
        "ff_normal_original": (
            "com.dts.freefireth",
            "Documents/contentcache/Compulsory/ios/gameassetbundles/avatar/assetindexer.U6Zffc4YIR3DslNj3cXvYGAqz58~3D"
        ),
        "ff_max_original": (
            "com.dts.freefiremax",
            "Documents/contentcache/Compulsory/ios/gameassetbundles/avatar/assetindexer.YJ~2FW7EkU5pRkVg51NrKyx4LXid8~3D"
        )
    ]

    static func data(bundleID: String, relativePath: String) -> Data? {
        guard let asset = assets.values.first(where: {
            $0.bundleID == bundleID && relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == $0.relativePath
        }) else { return nil }
        let resourceName = assets.first(where: { $0.value.bundleID == asset.bundleID && $0.value.relativePath == asset.relativePath })?.key
        guard let resourceName,
              let url = Bundle.main.url(forResource: resourceName, withExtension: nil) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static var directEntries: [(bundleID: String, relativePath: String, data: Data)] {
        assets.compactMap { name, asset in
            guard let data = Bundle.main.url(forResource: name, withExtension: nil)
                .flatMap({ try? Data(contentsOf: $0, options: .mappedIfSafe) }),
                  !data.isEmpty else { return nil }
            return (asset.bundleID, asset.relativePath, data)
        }
    }

    static func isSupported(bundleID: String) -> Bool {
        assets.values.contains { $0.bundleID == bundleID }
    }
}
