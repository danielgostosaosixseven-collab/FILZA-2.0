import Foundation
import Network

/// Monitora a conexão WiFi durante o handshake de emparelhamento.
/// O Beta 5 usa o mesmo mecanismo: se a rede muda no meio do handshake,
/// o túnel é invalidado e precisa reconectar. Este monitor detecta a mudança
/// e loga para diagnóstico.
final class WiFiConnectionMonitor {
    static let shared = WiFiConnectionMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.filza.wifi.monitor", qos: .utility)
    private var lastPath: NWPath?
    private var onChange: ((NWPath) -> Void)?

    private init() {}

    func start(onChange: @escaping (NWPath) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let previous = self.lastPath
            self.lastPath = path

            // Detecta mudança relevante: satisfiado → não satisfiado, ou vice-versa
            if let prev = previous {
                let wasSatisfied = prev.status == .satisfied
                let isSatisfied = path.status == .satisfied
                if wasSatisfied != isSatisfied {
                    let interface = path.usesInterfaceType(.wifi) ? "wifi" : "other"
                    log("wifi.monitor: path changed \(wasSatisfied ? "up" : "down") → \(isSatisfied ? "up" : "down") interface=\(interface)")
                    self.onChange?(path)
                } else if isSatisfied && prev.usesInterfaceType(.wifi) != path.usesInterfaceType(.wifi) {
                    log("wifi.monitor: interface type changed")
                    self.onChange?(path)
                }
            } else {
                log("wifi.monitor: initial path status=\(path.status) interface=\(path.usesInterfaceType(.wifi) ? "wifi" : "other")")
            }
        }
        monitor.start(queue: queue)
        log("wifi.monitor: started")
    }

    func stop() {
        monitor.cancel()
        onChange = nil
        lastPath = nil
        log("wifi.monitor: stopped")
    }

    /// Verifica se o caminho atual é satisfatório (VPN ou WiFi).
    var isPathSatisfied: Bool {
        lastPath?.status == .satisfied
    }
}
