import Foundation

struct PatchTransactionReceipt {
    let id: UUID
    let projectID: UUID
    let createdAt: Date
    let backend: Backend
    enum Backend { case airTraffic, airLift, local }
}
struct PatchProject { var id = UUID(); var allBundleIdentifiers: [String] = [] }
enum PatchPackageError: Error { case restoreFailed; case targetAppUnavailable(String) }
enum AirLiftTransportError: Error { case tunnelUnavailable }
enum AppInfo { static let versionTuple = (major: 27, minor: 0, patch: 0); static let osBuild = "test" }
enum ExploitSupportPolicy { static let gameBundleIDs = ["com.dts.freefireth", "com.dts.freefiremax"]; static func requiresAirLift(major: Int, minor: Int, patch: Int, build: String) -> Bool { true } }
final class AirLiftPairingStore { static let shared = AirLiftPairingStore(); var hasPairingFile = true }
final class AirLiftTransport {
    static let shared = AirLiftTransport()
    enum State { case idle, connected }
    var state: State = .connected
    var canConnect = true
    func connectWithRecovery(pin: String?, attempts: Int) -> Bool { state = canConnect ? .connected : .idle; return canConnect }
    func ensureConnectionForOperation(attempts: Int) -> Bool { canConnect }
}
enum ContainerStore {
    static func resolveAppContainerPath(bundleID: String) -> String? { "/tmp/test" }
    static func isApplicationContainerPath(_ path: String) -> Bool { true }
}
enum WorseQueryAccess {
    static var isRequired = false
    struct AccessFailure: Error { let codes: [Int64] }
    static func grantWithDiagnostics(path: String, bundleID: String?) -> (handle: Int64?, codes: [Int64]) { (1, []) }
}
func worse_query_release(_ handle: Int64) {}
enum GameFileAccessProbe { static func verify(containerRoot: URL) throws {} }
enum FixedGameOriginalStore {
    static var directEntries: [(bundleID: String, relativePath: String, data: Data)] { [] }
}
enum FileReplacementService { static func replace(target: URL, with source: URL) throws -> Bool { true } }
enum PatchPathValidator {
    static func resolveContainedTargetURL(relativePath: String, containerRoot: URL) throws -> URL { containerRoot.appendingPathComponent(relativePath) }
 static func canonicalFileURL(_ url: URL) -> URL { url } }
enum PatchProjectLibrary {
    static var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static func backupRootURL() throws -> URL { root }
}
func log(_ text: String) { print(text) }
enum Mock {
    static var receipts: [PatchTransactionReceipt] = []
    static var failIDs: Set<UUID> = []
    static var restored: [UUID] = []
    static func latest(_ id: UUID, backend: PatchTransactionReceipt.Backend) -> PatchTransactionReceipt? {
        receipts.filter { $0.projectID == id && $0.backend == backend }.max { $0.createdAt < $1.createdAt }
    }
    static func restore(_ receipt: PatchTransactionReceipt) throws {
        if failIDs.contains(receipt.id) { throw PatchPackageError.restoreFailed }
        restored.append(receipt.id)
        receipts.removeAll { $0.id == receipt.id }
    }
}
enum AirTrafficPatchTransaction {
    static func forceFixedGameOriginal(bundleID: String) throws {}
    static func restoreFixedGameOriginalsDirectly() throws { throw AirLiftTransportError.tunnelUnavailable }
    static func verifyWriteChannel(project: PatchProject) throws { }
    static func latestReceipt(projectID: UUID, backupRoot: URL) -> PatchTransactionReceipt? { Mock.latest(projectID, backend: .airTraffic) }
    static func restore(receipt: PatchTransactionReceipt, allowModifiedPatchedFiles: Bool) throws { try Mock.restore(receipt) }
    static func apply(project: PatchProject, backupRoot: URL) throws -> PatchTransactionReceipt { fatalError() }
}
enum AirLiftPatchTransaction {
    static func latestReceipt(projectID: UUID, backupRoot: URL) -> PatchTransactionReceipt? { Mock.latest(projectID, backend: .airLift) }
    static func restore(receipt: PatchTransactionReceipt, allowModifiedPatchedFiles: Bool) throws { try Mock.restore(receipt) }
}
enum PatchTransaction {
    static func latestReceipt(projectID: UUID, backupRoot: URL) -> PatchTransactionReceipt? { Mock.latest(projectID, backend: .local) }
    static func restore(receipt: PatchTransactionReceipt, containerResolver: (String) throws -> URL, allowModifiedPatchedFiles: Bool) throws { try Mock.restore(receipt) }
    static func requiredBundleIdentifiers(for receipt: PatchTransactionReceipt) throws -> [String] { [] }
    static func apply(project: PatchProject, backupRoot: URL, containerResolver: (String) throws -> URL) throws -> PatchTransactionReceipt { fatalError() }
}

// PRODUCTION_SOURCE

func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
    print("PASS: " + message)
}
func receipt(project: UUID, age: Double, backend: PatchTransactionReceipt.Backend = .airTraffic) -> PatchTransactionReceipt {
    try! FileManager.default.createDirectory(at: PatchProjectLibrary.root.appendingPathComponent(project.uuidString), withIntermediateDirectories: true)
    return PatchTransactionReceipt(id: UUID(), projectID: project, createdAt: Date(timeIntervalSince1970: age), backend: backend)
}
try FileManager.default.createDirectory(at: PatchProjectLibrary.root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: PatchProjectLibrary.root) }
let a = UUID(), b = UUID()
let old = receipt(project: a, age: 1), new = receipt(project: a, age: 3), other = receipt(project: b, age: 2)
Mock.receipts = [old, new, other]
let all = DevicePatchService.restorePendingOriginals(reconnect: true)
check(all.failures.isEmpty && all.remainingIDs.isEmpty && all.restoredTransactions == 3, "all journals restored including older same-project transactions")
check(Mock.restored == [new.id, other.id, old.id], "newest first across projects; older journals exposed without false failure")
Mock.restored = []; Mock.receipts = [old, new, other]; Mock.failIDs = [other.id]
let partial = DevicePatchService.restorePendingOriginals(reconnect: true)
check(!partial.failures.isEmpty && partial.remainingIDs == Set([a,b]), "failed restoration remains pending; no blanket reset")
check(Mock.restored == [new.id] && Mock.receipts.contains { $0.id == old.id }, "stop before older writes after a failed overlapping restore")
Mock.failIDs = []; AirLiftTransport.shared.canConnect = false
let disconnected = DevicePatchService.restorePendingOriginals(reconnect: true)
check(!disconnected.failures.isEmpty && Mock.receipts.count == 2, "no writes or journal deletion on reconnect failure")
AirLiftTransport.shared.canConnect = true
Mock.receipts = [old,other]; Mock.restored = []
let subset = DevicePatchService.restorePendingOriginals(reconnect: false, projectIDs: Set([a]))
check(subset.failures.isEmpty && Mock.restored == [old.id] && Mock.receipts.count == 1, "scoped FF restore leaves unrelated category intact")
Mock.receipts = []
let empty = DevicePatchService.restorePendingOriginals(reconnect: true)
check(empty.failures.isEmpty && empty.restoredTransactions == 0, "reconnect without active journals is valid and does not invent writes")
print("All recovery regression tests passed.")
