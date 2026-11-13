import Foundation

@main
enum WorseQueryPolicyTests {
    static func main() {
        func route(_ major: Int, _ minor: Int, _ patch: Int, _ build: String = "") -> Bool {
            ExploitSupportPolicy.prefersWorseQuery(major: major, minor: minor, patch: patch, build: build)
        }
        func launch(_ major: Int, _ minor: Int, _ patch: Int, _ build: String = "") -> Bool {
            ExploitSupportPolicy.isSupported(major: major, minor: minor, patch: patch, build: build)
        }
        // Existing routes stay on their original backend.
        precondition(launch(17, 7, 1) && !route(17, 7, 1))
        precondition(launch(18, 7, 1) && !route(18, 7, 1))
        precondition(launch(18, 7, 2) && launch(18, 7, 9))
        precondition(!launch(18, 7, 10))
        precondition(launch(16, 7, 0))
        precondition(launch(26, 6, 1) && !route(26, 6, 1))
        precondition(route(26, 6, 2) && route(26, 7, 2))
        precondition(!route(26, 7, 3) && !launch(26, 7, 3))
        precondition(!route(26, 8, 0))
        precondition(route(27, 0, 0, "24A437"))
        precondition(route(27, 0, 1, "24A446"))
        precondition(route(27, 1, 0) && route(27, 2, 1))
        precondition(!route(27, 2, 2))
        precondition(route(27, 3, 0, "24C5037i") && launch(27, 3, 0, "24C5037i"))
        precondition(!route(27, 3, 0, "24C5049f"))
        precondition(!launch(27, 3, 0, "24C5049f"))
        precondition(!route(27, 3, 1, "24C5037i"))
        precondition(!route(28, 0, 0))
        precondition(!route(27, -1, 0) && !route(27, 0, -1))

        let root = "/var/mobile/Containers/Data/Application/12345678-1234-1234-1234-123456789ABC"
        let ff = "com.dts.freefireth"
        let max = "com.dts.freefiremax"
        func grant(_ path: String, _ bundleID: String?, _ build: String = "24C5037i") -> Bool {
            ExploitSupportPolicy.allowsIOS273GameGrant(build: build, bundleID: bundleID, path: path)
        }
        precondition(grant(root, ff) && grant(root, max))
        precondition(grant("/private" + root, ff))
        precondition(grant(root + "/", ff))
        precondition(!grant(root, nil) && !grant(root, "com.apple.mobilesafari"))
        precondition(!grant(root, ff, "24C5049f"))
        precondition(!grant(root + "/Documents", ff))
        precondition(!grant(root + "/../", ff))
        precondition(!grant(root + "/./", ff))
        precondition(!grant("/var/mobile/Containers/Data/Application", ff))
        precondition(!grant("/var/mobile/Containers/Data/Application/not-a-uuid", ff))
        precondition(!grant("/var/mobile/Containers/Shared/AppGroup/12345678-1234-1234-1234-123456789ABC", ff))
        precondition(!grant(root + "\u{0}", ff))
        precondition(ExploitSupportPolicy.applicationContainerRoot(for: root + "/Documents/file") == root)
        precondition(ExploitSupportPolicy.applicationContainerRoot(for: "/private" + root + "/Documents") == root)
        precondition(ExploitSupportPolicy.applicationContainerRoot(for: root + "/../Documents") == nil)
        print("PASS: version boundaries, exact beta gate, FF/MAX scope, aliases, path rejection")
    }
}
