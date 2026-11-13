import Foundation

/// Gate global que impede que reconexão silenciosa ou heartbeat concorra com
/// aplicação/restauração de patch. O Beta 5 usa a mesma ideia: enquanto um patch
/// está em andamento, qualquer tentativa de reconectar é *deferida* em vez de
/// competir pela conexão e invalidar a sessão AFC no meio da escrita.
///
/// Thread-safe: a flag é lida do keepalive (utility queue), do reconnect
/// (global queue) e escrita pelo DevicePatchService (operation queue).
final class AirLiftConnectionCheckGate {
    static let shared = AirLiftConnectionCheckGate()

    private let lock = NSLock()
    private var _patchBusy = false
    private var _exploitBusy = false

    private init() {}

    // MARK: - Patch

    var isPatchBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return _patchBusy
    }

    func setPatchBusy(_ busy: Bool) {
        lock.lock()
        let changed = _patchBusy != busy
        _patchBusy = busy
        lock.unlock()
        if changed {
            log("airlift.connection_check patch_busy=\(busy)")
        }
    }

    /// RAII: seta busy no init, limpa no dealloc. Uso:
    ///   let gate = AirLiftConnectionCheckGate.patchScope()  // busy = true
    ///   ... operação ...
    ///   gate.clear()                                        // busy = false
    final class PatchScope {
        private var active = true
        func clear() {
            guard active else { return }
            active = false
            AirLiftConnectionCheckGate.shared.setPatchBusy(false)
        }
        deinit { clear() }
    }

    static func patchScope() -> PatchScope {
        shared.setPatchBusy(true)
        return PatchScope()
    }

    // MARK: - Exploit

    var isExploitBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return _exploitBusy
    }

    func setExploitBusy(_ busy: Bool) {
        lock.lock()
        let changed = _exploitBusy != busy
        _exploitBusy = busy
        lock.unlock()
        if changed {
            log("airlift.connection_check exploit_busy=\(busy)")
        }
    }

    // MARK: - Consulta

    /// Consulta antes de reconectar ou pulsar. Retorna true se pode seguir.
    /// Se estiver ocupado, loga o defer igual ao Beta 5.
    @discardableResult
    func checkBeforeReconnect(operation: String) -> Bool {
        lock.lock()
        let busy = _patchBusy || _exploitBusy
        lock.unlock()
        if busy {
            let reason = _patchBusy ? "patch_busy" : "exploit_busy"
            log("airlift.connection_check id=\(operation) result=deferred reason=\(reason)")
            return false
        }
        return true
    }
}
