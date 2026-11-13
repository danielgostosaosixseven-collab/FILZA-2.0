// AirLiftTransport.swift
// Caminho alternativo de acesso ao filesystem: LocalDevVPN + RPPairing + RSD + AFC.
// Usado quando o kexploit_opa334 não é aplicável (iOS 27+) ou como fallback.

import CryptoKit
import Foundation
import AirliftFFI
import Network
import Combine
import Darwin

final class AirLiftTransport: ObservableObject {
    static let shared = AirLiftTransport()

    enum State: Equatable {
        case idle
        case detectingVPN
        case connecting
        case paired
        case connected
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var error: String?
    @Published var rsdPort: UInt16?
    @Published var deviceUUID: String?

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var afcClient: OpaquePointer?
    private var installProxy: OpaquePointer?
    private var appContainerClients: [String: OpaquePointer] = [:]
    private let fileOperationLock = NSRecursiveLock()
    /// Impede que o reconnect silencioso concorra com aplicação/restauração.
    private let connectionOperationLock = NSRecursiveLock()
    /// O caminho AirTraffic pode invalidar a sessão RSD/AFC existente.
    private let airTrafficOperationLock = NSRecursiveLock()
    private var tunnelReady = false
    private var heartbeatClient: OpaquePointer?
    private let heartbeatLock = NSRecursiveLock()

    private init() {}

    // MARK: - VPN detection

    /// Detecta a interface utun criada pelo LocalDevVPN.
    /// Retorna (localIP, remoteIP) ou nil se não houver VPN ativa.
    static let defaultTunnelInterfaceIP = "10.7.1.1"
    static let defaultTunnelPeerIP = "10.7.0.1"
    static let defaultRemotePairingPort: UInt16 = 49152
    private static let defaultTunnelPeerCandidates = ["10.7.0.1", "10.7.0.2", "10.7.0.3"]
    private static var pairingHostName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Conexão do dispositivo"
    }

    static func detectVPNInterface() -> (local: String, remote: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            log("airlift: getifaddrs failed — VPN state cannot be verified")
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var localIP: String?
        var ptr = ifaddr

        while let iface = ptr {
            let name = String(cString: iface.pointee.ifa_name)
            let isVPN = name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            if isVPN, let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(MemoryLayout<sockaddr>.size),
                            &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                log("airlift: VPN interface \(name) → \(ip)")

                if ip.hasPrefix("10.7.") && ip != defaultTunnelPeerIP {
                    localIP = ip
                    break
                }
            }
            ptr = iface.pointee.ifa_next
        }

        guard let localIP else {
            log("airlift: no active LocalDevVPN interface found")
            return nil
        }
        log("airlift: LocalDevVPN detected — local=\(localIP) peer=\(defaultTunnelPeerIP)")
        return (local: localIP, remote: defaultTunnelPeerIP)
    }

    /// Resolve the device's Wi-Fi IPv4 address for a direct RSD attempt when
    /// LocalDevVPN is not active or its tunnel endpoint is unavailable.
    static func detectWiFiIPv4Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            log("airlift: getifaddrs failed — Wi-Fi target IP cannot be discovered")
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var addresses: [String] = []
        var ptr = ifaddr
        while let iface = ptr {
            let name = String(cString: iface.pointee.ifa_name)
            if name == "en0", let addr = iface.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    addr,
                    socklen_t(MemoryLayout<sockaddr>.size),
                    &host,
                    socklen_t(NI_MAXHOST),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    let ip = String(cString: host)
                    if ip != "0.0.0.0", !ip.hasPrefix("127."), !ip.hasPrefix("169.254."),
                       !addresses.contains(ip) {
                        addresses.append(ip)
                        log("airlift: Wi-Fi interface en0 → \(ip)")
                    }
                }
            }
            ptr = iface.pointee.ifa_next
        }
        return addresses
    }

    // MARK: - PIN callback (C function pointer for FFI)

    private let pinCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { context in
        guard let context else { return nil }
        return UnsafePointer(context.assumingMemoryBound(to: CChar.self))
    }

    // MARK: - Connect

    /// Conecta ao front door RemotePairing; o túnel fornece depois o endpoint RSD dinâmico.
    /// - Parameter pin: PIN de emparelhamento (nil para reconectar com pairing file salvo)
    /// - Returns: true se a conexão foi estabelecida
    @discardableResult
    func connect(pin: String?) -> Bool {
        disconnect()
        error = nil
        state = .detectingVPN

        let vpn = Self.detectVPNInterface()
        var targetHosts: [String] = []
        if let vpn { targetHosts.append(vpn.remote) }
        targetHosts.append(contentsOf: Self.detectWiFiIPv4Addresses().filter { !targetHosts.contains($0) })
        guard !targetHosts.isEmpty else {
            let message = "Nenhum endpoint de rede local foi encontrado. Conecte-se ao Wi‑Fi ou ative os dados móveis com um túnel seguro."
            state = .failed(message)
            error = message
            return false
        }
        state = .connecting
        log("airlift: trying RemotePairing hosts in order: \(targetHosts.joined(separator: ", "))")

        if pin == nil && !AirLiftPairingStore.shared.hasPairingFile {
            state = .failed("Nenhum PIN fornecido e nenhum pairing file salvo.")
            error = "Primeiro emparelhamento requer PIN."
            return false
        }

        var pairingFile: OpaquePointer?
        var pairingTempPath: String?
        if let savedData = AirLiftPairingStore.shared.loadPairingFile() {
            guard let path = AirLiftPairingStore.shared.tempFilePath(for: savedData) else {
                state = .failed("Não foi possível preparar o arquivo de emparelhamento.")
                error = "Falha ao preparar pairing file."
                return false
            }
            pairingTempPath = path
            let pairingError = rp_pairing_file_read(path, &pairingFile)
            if let pairingError {
                let message = Self.consumeError(pairingError, fallback: "Falha ao ler pairing file.")
                try? FileManager.default.removeItem(atPath: path)
                state = .failed(message)
                error = message
                return false
            }
        } else {
            let pairingError = Self.pairingHostName.withCString { hostName in
                rp_pairing_file_generate(hostName, &pairingFile)
            }
            if let pairingError {
                let message = Self.consumeError(pairingError, fallback: "Falha ao criar pairing file.")
                state = .failed(message)
                error = message
                return false
            }
        }
        defer {
            if let pairingTempPath {
                try? FileManager.default.removeItem(atPath: pairingTempPath)
            }
            if let pairingFile { rp_pairing_file_free(pairingFile) }
        }
        guard let pairingFile else {
            state = .failed("A biblioteca não retornou um pairing file.")
            error = "Pairing file indisponível."
            return false
        }

        var pinCString: UnsafeMutablePointer<CChar>? = pin?.withCString { strdup($0) }
        if pin != nil && pinCString == nil {
            state = .failed("Não foi possível preparar o PIN.")
            error = "Falha ao preparar PIN."
            return false
        }
        defer {
            if let pinCString { free(UnsafeMutableRawPointer(pinCString)) }
        }

        var outAdapter: OpaquePointer?
        var outHandshake: OpaquePointer?
        var connectionErrors: [String] = []
        var connectionRoute = ""
        for targetHost in targetHosts {
            let extraTunnelHosts = (vpn?.remote == targetHost)
                ? [targetHost] + Self.defaultTunnelPeerCandidates.filter { $0 != targetHost }
                : [targetHost]
            let hostStatus = targetHost.withCString { al_set_target_host($0) }
            guard hostStatus == 0 else {
                connectionErrors.append("Host \(targetHost): configuração FFI falhou (\(hostStatus))")
                continue
            }

            var allocatedHostStrings: [UnsafeMutablePointer<CChar>] = []
            for candidate in extraTunnelHosts {
                guard let hostString = candidate.withCString({ strdup($0) }) else {
                    allocatedHostStrings.forEach { free(UnsafeMutableRawPointer($0)) }
                    let message = "Não foi possível preparar os hosts candidatos do túnel."
                    state = .failed(message)
                    error = message
                    return false
                }
                allocatedHostStrings.append(hostString)
            }
            defer { allocatedHostStrings.forEach { free(UnsafeMutableRawPointer($0)) } }
            let extraHostPointers: [UnsafePointer<CChar>?] = allocatedHostStrings.map {
                UnsafePointer<CChar>($0) as UnsafePointer<CChar>?
            }

            var addr = idevice_sockaddr()
            addr.sa_family = sa_family_t(AF_INET)
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = in_port_t(Self.defaultRemotePairingPort).bigEndian
            let parsedHost = targetHost.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
            guard parsedHost == 1 else {
                connectionErrors.append("Host RemotePairing inválido: \(targetHost)")
                continue
            }
            withUnsafeBytes(of: sin) { source in
                withUnsafeMutableBytes(of: &addr) { destination in
                    destination.copyMemory(from: source)
                }
            }

            let routeName = (vpn?.remote == targetHost) ? "LocalDevVPN" : "Wi-Fi direto"
            log("airlift: trying RemotePairing at \(targetHost):\(Self.defaultRemotePairingPort) via \(routeName); tunnel listener candidates: \(extraTunnelHosts.joined(separator: ", "))")
            var pairingFailureKind: Int32 = 0
            // Prefer the reference-client route: RSD -> RemoteXPC -> RPPairing -> TLS-PSK.
            let pairingError = extraHostPointers.withUnsafeBufferPointer { extraHostBuffer in
                Self.pairingHostName.withCString { hostName in
                    withUnsafeMutablePointer(to: &pairingFailureKind) { failureKindPointer in
                        tunnel_create_remotexpc_multihost(
                            &addr,
                            idevice_socklen_t(MemoryLayout<sockaddr>.size),
                            hostName,
                            pairingFile,
                            pinCallback,
                            pinCString.map { UnsafeMutableRawPointer($0) },
                            extraHostBuffer.baseAddress,
                            uintptr_t(extraHostBuffer.count),
                            failureKindPointer,
                            &outAdapter,
                            &outHandshake
                        )
                    }
                }
            }

            if let pairingError {
                let message = Self.consumeError(pairingError, fallback: "Falha desconhecida no RemoteXPC.")
                let kind = Self.tunnelFailureKindDescription(pairingFailureKind)
                connectionErrors.append("RemoteXPC [\(kind)] host=\(targetHost):\(Self.defaultRemotePairingPort): \(message)")
                log("airlift: RemoteXPC at \(targetHost) failed [\(kind)]: \(message)")
                outAdapter = nil
                outHandshake = nil
                let rawError = extraHostPointers.withUnsafeBufferPointer { extraHostBuffer in
                    Self.pairingHostName.withCString { hostName in
                        withUnsafeMutablePointer(to: &pairingFailureKind) { failureKindPointer in
                            tunnel_create_rppairing_multihost(
                                &addr,
                                idevice_socklen_t(MemoryLayout<sockaddr>.size),
                                hostName,
                                pairingFile,
                                pinCallback,
                                pinCString.map { UnsafeMutableRawPointer($0) },
                                extraHostBuffer.baseAddress,
                                uintptr_t(extraHostBuffer.count),
                                failureKindPointer,
                                &outAdapter,
                                &outHandshake
                            )
                        }
                    }
                }
                if let rawError {
                    let rawMessage = Self.consumeError(rawError, fallback: "Falha desconhecida no RPPairing.")
                    let rawKind = Self.tunnelFailureKindDescription(pairingFailureKind)
                    connectionErrors.append("RPPairing [\(rawKind)] host=\(targetHost):\(Self.defaultRemotePairingPort): \(rawMessage)")
                    log("airlift: raw RPPairing at \(targetHost) failed [\(rawKind)]: \(rawMessage)")
                } else if outAdapter != nil && outHandshake != nil {
                    connectionRoute = "RPPairing fallback (\(targetHost))"
                    break
                }
            } else if outAdapter != nil && outHandshake != nil {
                connectionRoute = "RemoteXPC (\(targetHost))"
                break
            } else {
                connectionErrors.append("RemoteXPC em \(targetHost) não retornou os handles do túnel.")
            }
            outAdapter = nil
            outHandshake = nil
        }
        guard let adapterPtr = outAdapter, let handshakePtr = outHandshake else {
            let details = connectionErrors.isEmpty
                ? "A biblioteca não retornou os handles do túnel."
                : connectionErrors.joined(separator: " | ")
            log("airlift: all tunnel routes failed: \(details)")
            state = .failed("Falha no handshake: \(details)")
            error = details
            return false
        }

        log("airlift: tunnel established via \(connectionRoute)")
        adapter = adapterPtr
        handshake = handshakePtr
        state = .paired
        log("airlift: pairing OK")

        var services: UnsafeMutablePointer<CRsdServiceArray>?
        let rsdError = rsd_get_services(handshakePtr, &services)
        if let rsdError {
            let message = Self.consumeError(rsdError, fallback: "RSD failed.")
            state = .failed("RSD failed: \(message)")
            error = message
            return false
        }
        guard let serviceArray = services else {
            state = .failed("RSD não retornou serviços.")
            error = "RSD não retornou serviços."
            return false
        }
        defer { rsd_free_services(serviceArray) }

        let discoveredServices: [(name: String, port: UInt16)] = (0..<Int(serviceArray.pointee.count)).map { index in
            let service = serviceArray.pointee.services[index]
            return (String(cString: service.name), service.port)
        }
        let afcService = discoveredServices.first { $0.name == "com.apple.afc.shim.remote" }
            ?? discoveredServices.first { $0.name == "com.apple.afc" }
        guard let afcService, afcService.port != 0 else {
            let names = discoveredServices.map { $0.name }.sorted().prefix(12).joined(separator: ", ")
            let message = "RSD não anunciou com.apple.afc.shim.remote nem com.apple.afc. Serviços: \(names.isEmpty ? "nenhum" : names)"
            state = .failed(message)
            error = message
            return false
        }
        let afcPort = afcService.port
        rsdPort = afcPort
        log("airlift: AFC RSD service=\(afcService.name) port=\(afcPort)")

        var outAfc: OpaquePointer?
        let afcError = afc_client_connect_rsd(adapterPtr, handshakePtr, &outAfc)
        if let afcError {
            let message = Self.consumeError(afcError, fallback: "AFC connect failed.")
            state = .failed("AFC connect failed: \(message)")
            error = message
            return false
        }
        guard let afcPtr = outAfc else {
            state = .failed("AFC não retornou um client.")
            error = "AFC indisponível."
            return false
        }

        afcClient = afcPtr
        fileOperationLock.lock()
        tunnelReady = true
        fileOperationLock.unlock()
        // Reuse the exact persisted blob on credential-only reconnects. A
        // reserialization can change its hash and invalidate existing journals.
        let pairingAlreadyPersisted = pin == nil && AirLiftPairingStore.shared.hasPairingFile
        guard pairingAlreadyPersisted || savePairingFile(pairingFile) else {
            disconnect()
            let message = "Túnel seguro conectado, mas o emparelhamento não pôde ser salvo; ativação remota indisponível."
            error = message
            state = .failed(message)
            return false
        }
        state = .connected
        startHeartbeatAndKeepAlive()
        log("airlift: AFC connected, heartbeat and keepalive active")
        return true
    }

    /// Reintenta fallos transitorios de red/handshake, igual que la recuperación de túnel del cliente de referencia.
    @discardableResult
    func connectWithRecovery(
        pin: String?,
        attempts: Int = 5,
        onRetry: ((Int, Int, String) -> Void)? = nil
    ) -> Bool {
        connectionOperationLock.lock()
        defer { connectionOperationLock.unlock() }
        let maxAttempts = max(1, attempts)
        for attempt in 1...maxAttempts {
            if connect(pin: pin) {
                if attempt > 1 {
                    log("airlift: tunnel recovered on attempt \(attempt)/\(maxAttempts)")
                }
                return true
            }

            let message = error ?? "Falha desconhecida ao conectar."
            log("airlift: tunnel attempt \(attempt)/\(maxAttempts) failed: \(message)")
            guard attempt < maxAttempts, Self.isTransientTunnelError(message) else { return false }

            disconnect()
            onRetry?(attempt + 1, maxAttempts, message)
            Thread.sleep(forTimeInterval: min(5.0, pow(2.0, Double(attempt - 1))))
        }
        return false
    }

    private static func isTransientTunnelError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let markers = [
            "connectionreset", "connection reset", "connectionrefused", "connection refused",
            "timedout", "timed out", "network is unreachable", "network unreachable",
            "broken pipe", "socket(", "rsd failed", "handshake", "afc connect failed",
            "temporarily unavailable"
        ]
        return markers.contains { normalized.contains($0) }
    }

    /// Executa a escrita AirTraffic sem derrubar preventivamente a sessão.
    /// Só reconstrói o túnel se uma consulta real ao AFC confirmar que o socket
    /// foi encerrado durante a escrita.
    func withExclusiveAirTrafficWrite<T>(_ operation: () throws -> T) throws -> T {
        connectionOperationLock.lock()
        defer { connectionOperationLock.unlock() }
        airTrafficOperationLock.lock()
        defer { airTrafficOperationLock.unlock() }

        fileOperationLock.lock()
        let shouldReconnect = tunnelReady || adapter != nil || handshake != nil
        fileOperationLock.unlock()

        do {
            let result = try operation()
            if shouldReconnect && !sessionIsHealthy() {
                if !connectWithRecovery(pin: nil, attempts: 4) {
                    log("airlift: AirTraffic write completed, but session recovery failed")
                }
            }
            return result
        } catch {
            if shouldReconnect && !sessionIsHealthy() {
                _ = connectWithRecovery(pin: nil, attempts: 4)
            }
            throw error
        }
    }

    /// Consulta o AFC para não confiar apenas no estado publicado pela UI.
    private func sessionIsHealthy() -> Bool {
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }
        guard tunnelReady, let client = afcClient else { return false }
        var info = AfcFileInfo()
        let result = "/".withCString { afc_get_file_info(client, $0, &info) }
        if result == nil {
            afc_file_info_free(&info)
            return true
        }
        idevice_error_free(result)
        return false
    }

    /// Garante que a sessão responde antes de iniciar uma operação remota.
    @discardableResult
    func ensureConnectionForOperation(attempts: Int = 4) -> Bool {
        connectionOperationLock.lock()
        let alreadyHealthy = sessionIsHealthy()
        connectionOperationLock.unlock()
        if alreadyHealthy { return true }
        guard connectWithRecovery(pin: nil, attempts: attempts) else { return false }

        // Em aparelhos mais lentos, o handshake pode terminar antes de o AFC
        // aceitar a primeira consulta. Aguarde a sessão realmente responder,
        // sem recriar o pairing nem iniciar outro handshake em paralelo.
        for _ in 0..<4 {
            if sessionIsHealthy() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("airlift: tunnel connected but AFC was not ready after warm-up")
        return false
    }

    fileprivate static func consumeError(_ error: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        defer { idevice_error_free(error) }
        guard let message = error.pointee.message else { return fallback }
        return String(cString: message)
    }

    private static func tunnelFailureKindDescription(_ kind: Int32) -> String {
        switch kind {
        case 0: return "none"
        case 1: return "RSD unreachable"
        case 2: return "RemotePairing handshake failed"
        case 3: return "tunnel hosts refused"
        case 4: return "tunnel timed out"
        case 5: return "TLS/CDTunnel handshake failed"
        case 6: return "other tunnel failure"
        default: return "unknown kind (\(kind))"
        }
    }

    /// Reabre silenciosamente um túnel que caiu, usando o pairing salvo.
    /// Não solicita PIN e não altera o pairing persistido.
    @discardableResult
    func reconnectSavedPairingIfNeeded() -> Bool {
        guard AirLiftPairingStore.shared.hasPairingFile else { return false }
        guard AirLiftConnectionCheckGate.shared.checkBeforeReconnect(operation: "reconnect") else { return false }
        return ensureConnectionForOperation(attempts: 5)
    }
    // MARK: - Save pairing file

    private func savePairingFile(_ pairingFile: OpaquePointer) -> Bool {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift_pairing_\(UUID().uuidString).mobiledevicepairing").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        if let writeError = rp_pairing_file_write(pairingFile, path) {
            let message = Self.consumeError(writeError, fallback: "Falha ao persistir pairing file.")
            log("airlift: failed to save pairing file: \(message)")
            return false
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            log("airlift: failed to read temporary pairing file")
            return false
        }
        if !AirLiftPairingStore.shared.savePairingFile(data) {
            log("airlift: failed to store pairing file in Keychain")
            return false
        }
        return true
    }

    // MARK: - AFC operations

    /// Lista diretórios via AFC.
    func listDirectory(path: String) -> [String] {
        guard let client = afcClient else { return [] }
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        let result = afc_list_directory(client, path, &entries, &count)
        if let result {
            _ = Self.consumeError(result, fallback: "Falha ao listar diretório.")
            return []
        }
        guard let entries else { return [] }

        var names: [String] = []
        for index in 0..<count {
            if let entry = entries[index] { names.append(String(cString: entry)) }
        }
        return names
    }

    /// Lê arquivo via AFC.
    func readFile(path: String) -> Data? {
        guard let client = afcClient else { return nil }
        var fileHandle: OpaquePointer?
        if let openError = afc_file_open(client, path, AfcRdOnly, &fileHandle) {
            _ = Self.consumeError(openError, fallback: "Falha ao abrir arquivo AFC.")
            return nil
        }
        guard let fileHandle else { return nil }
        defer { _ = afc_file_close(fileHandle) }

        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        if let readError = afc_file_read_entire(fileHandle, &bytes, &length) {
            _ = Self.consumeError(readError, fallback: "Falha ao ler arquivo AFC.")
            return nil
        }
        guard let bytes else { return nil }
        defer { afc_file_read_data_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    /// Escreve arquivo via AFC.
    func writeFile(path: String, data: Data) -> Bool {
        guard let client = afcClient else { return false }
        var fileHandle: OpaquePointer?
        if let openError = afc_file_open(client, path, AfcWrOnly, &fileHandle) {
            _ = Self.consumeError(openError, fallback: "Falha ao abrir arquivo para escrita AFC.")
            return false
        }
        guard let fileHandle else { return false }
        defer { _ = afc_file_close(fileHandle) }

        let writeError: UnsafeMutablePointer<IdeviceFfiError>? = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return afc_file_write(fileHandle, baseAddress.assumingMemoryBound(to: UInt8.self), data.count)
        }
        guard let writeError else { return data.isEmpty }
        _ = Self.consumeError(writeError, fallback: "Falha ao escrever arquivo AFC.")
        return false
    }

    /// Executa uma operação com o AFC vendado pelo House Arrest para o container
    /// de dados de um bundle ID. O lock mantém as chamadas FFI sequenciais.
    func withAppContainer<T>(
        bundleID: String,
        operation: (AirLiftAFCFileSystem) throws -> T
    ) throws -> T {
        guard AirLiftPairingStore.shared.hasPairingFile,
              ensureConnectionForOperation(attempts: 5) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }

        guard tunnelReady, let adapter, let handshake else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        let canonicalBundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleID)

        let client: OpaquePointer
        if let cached = appContainerClients[canonicalBundleID] {
            client = cached
        } else {
            var houseArrestClient: OpaquePointer?
            if let connectError = house_arrest_client_connect_rsd(adapter, handshake, &houseArrestClient) {
                let reason = Self.consumeError(connectError, fallback: "House Arrest indisponível.")
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, reason)
            }
            guard let houseArrestClient else {
                throw AirLiftTransportError.appContainerUnavailable(
                    canonicalBundleID,
                    "a biblioteca não retornou um cliente House Arrest"
                )
            }

            var vendClient: OpaquePointer?
            let vendError = canonicalBundleID.withCString {
                house_arrest_vend_container(houseArrestClient, $0, &vendClient)
            }
            if let vendError {
                let reason = Self.consumeError(vendError, fallback: "Falha ao abrir o container do app.")
                // house_arrest_vend_container consome o HouseArrestClient, inclusive em erro.
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, reason)
            }
            guard let vendClient else {
                throw AirLiftTransportError.appContainerUnavailable(
                    canonicalBundleID,
                    "a biblioteca não retornou um cliente AFC"
                )
            }
            appContainerClients[canonicalBundleID] = vendClient
            client = vendClient
        }

        return try operation(AirLiftAFCFileSystem(client: client, bundleID: canonicalBundleID))
    }

    /// Abre especificamente a pasta Documents via House Arrest.
    /// Esta é a mesma rota vend_documents usada pela referência.
    func withAppDocuments<T>(
        bundleID: String,
        operation: (AirLiftAFCFileSystem) throws -> T
    ) throws -> T {
        guard AirLiftPairingStore.shared.hasPairingFile,
              ensureConnectionForOperation(attempts: 5) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }
        guard tunnelReady, let adapter, let handshake else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        let canonicalBundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleID)
        let cacheKey = "documents:\(canonicalBundleID)"
        let client: OpaquePointer
        if let cached = appContainerClients[cacheKey] {
            client = cached
        } else {
            var houseArrestClient: OpaquePointer?
            if let connectError = house_arrest_client_connect_rsd(adapter, handshake, &houseArrestClient) {
                let reason = Self.consumeError(connectError, fallback: "House Arrest indisponível.")
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, reason)
            }
            guard let houseArrestClient else {
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, "cliente House Arrest indisponível")
            }
            var vendClient: OpaquePointer?
            let vendError = canonicalBundleID.withCString {
                house_arrest_vend_documents(houseArrestClient, $0, &vendClient)
            }
            if let vendError {
                let reason = Self.consumeError(vendError, fallback: "Falha ao abrir Documents do app.")
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, reason)
            }
            guard let vendClient else {
                throw AirLiftTransportError.appContainerUnavailable(canonicalBundleID, "AFC Documents indisponível")
            }
            appContainerClients[cacheKey] = vendClient
            client = vendClient
        }
        return try operation(AirLiftAFCFileSystem(client: client, bundleID: canonicalBundleID))
    }

    /// Usa o AFC principal diretamente quando House Arrest falha.
    func withRootAFC<T>(containerPath: String? = nil, operation: (AirLiftAFCFileSystem) throws -> T) throws -> T {
        guard AirLiftPairingStore.shared.hasPairingFile,
              ensureConnectionForOperation(attempts: 5) else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        do {
            return try withRootAFCOnce(containerPath: containerPath, operation: operation)
        } catch let error as AirLiftTransportError {
            guard case .fileOperation(_, _, let reason) = error,
                  reason.localizedCaseInsensitiveContains("not connected") ||
                  reason.localizedCaseInsensitiveContains("connection reset") ||
                  reason.localizedCaseInsensitiveContains("socket") else {
                throw error
            }
            log("airlift: AFC socket is stale; reconnecting before retry")
            guard connectWithRecovery(pin: nil, attempts: 2) else { throw error }
            return try withRootAFCOnce(containerPath: containerPath, operation: operation)
        }
    }

    private func withRootAFCOnce<T>(containerPath: String?, operation: (AirLiftAFCFileSystem) throws -> T) throws -> T {
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }
        guard tunnelReady, let client = afcClient else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        return try operation(AirLiftAFCFileSystem(client: client, bundleID: "root", pathPrefix: containerPath))
    }

    /// Abre FileService no domínio AppDataContainer para leitura e backup remoto.
    /// O handle e o lock vivem apenas durante a operação; o canal de dados é
    /// descoberto no mesmo RSD já emparelhado.
    func withFileService<T>(
        bundleID: String,
        operation: (AirLiftFileServiceClient) throws -> T
    ) throws -> T {
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }

        guard tunnelReady, let adapter, let handshake else {
            throw AirLiftTransportError.tunnelUnavailable
        }
        let canonicalBundleID = try PatchPathValidator.canonicalBundleIdentifier(bundleID)

        var services: UnsafeMutablePointer<CRsdServiceArray>?
        if let result = rsd_get_services(handshake, &services) {
            let reason = Self.consumeError(result, fallback: "RSD não listou serviços do FileService.")
            throw AirLiftTransportError.fileServiceUnavailable(canonicalBundleID, reason)
        }
        guard let serviceArray = services else {
            throw AirLiftTransportError.fileServiceUnavailable(
                canonicalBundleID,
                "RSD não retornou a lista de serviços."
            )
        }
        defer { rsd_free_services(serviceArray) }

        let discovered = (0..<Int(serviceArray.pointee.count)).map { index in
            let service = serviceArray.pointee.services[index]
            return (name: String(cString: service.name), port: service.port)
        }
        let dataService = discovered.first { $0.name == "com.apple.coredevice.fileservice.data" }
            ?? discovered.first { $0.name.hasPrefix("com.apple.coredevice.fileservice.data.") }
        // Alguns iOS expõem o canal de controle do FileService no RSD, mas
        // omitem o serviço de dados até a primeira transferência. Nesse caso
        // mantemos a sessão de controle e deixamos a operação de download
        // decidir se o canal de dados está realmente disponível.
        let dataPort = dataService?.port ?? 0

        var handle: OpaquePointer?
        if let result = file_service_connect_rsd(adapter, handshake, &handle) {
            let reason = Self.consumeError(result, fallback: "FileService connect falhou.")
            throw AirLiftTransportError.fileServiceUnavailable(canonicalBundleID, reason)
        }
        guard let handle else {
            throw AirLiftTransportError.fileServiceUnavailable(
                canonicalBundleID,
                "a biblioteca não retornou um cliente FileService"
            )
        }
        defer { file_service_free(handle) }

        if let result = canonicalBundleID.withCString({
            file_service_create_session(
                handle,
                IdeviceFileServiceDomainAppDataContainer,
                $0,
                nil
            )
        }) {
            let reason = Self.consumeError(result, fallback: "Não foi possível abrir AppDataContainer.")
            throw AirLiftTransportError.fileServiceUnavailable(canonicalBundleID, reason)
        }

        return try operation(AirLiftFileServiceClient(
            handle: handle,
            adapter: adapter,
            dataPort: dataPort,
            bundleID: canonicalBundleID
        ))
    }

    // MARK: - Installation Proxy

    /// Lista apps instalados via InstallationProxy.
    func installedApps() -> [(bundleID: String, name: String)] {
        guard installProxy != nil else { return [] }
        // A consulta de apps não é usada pelo fluxo atual.
        return []
    }

    // MARK: - Heartbeat / keepalive

    private func startHeartbeatAndKeepAlive() {
        WiFiConnectionMonitor.shared.start { [weak self] path in
            if path.status != .satisfied {
                log("airlift: network path lost during session; tunnel may be stale")
            }
        }
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        if heartbeatClient == nil, let adapter, let handshake {
            var client: OpaquePointer?
            if let result = heartbeat_connect_rsd(adapter, handshake, &client) {
                let message = Self.consumeError(result, fallback: "Heartbeat indisponível.")
                log("airlift: heartbeat setup unavailable: \(message)")
            } else {
                heartbeatClient = client
                log("airlift: RSD heartbeat connected")
            }
        }
        AirLiftPairingKeepAlive.shared.start { [weak self] in
            self?.sendHeartbeatPulse()
        }
    }

    private func sendHeartbeatPulse() {
        guard AirLiftConnectionCheckGate.shared.checkBeforeReconnect(operation: "heartbeat") else { return }
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        guard let client = heartbeatClient else { return }
        if let result = heartbeat_send_polo(client) {
            let message = Self.consumeError(result, fallback: "Heartbeat falhou.")
            log("airlift: heartbeat pulse failed: \(message)")
        } else {
            log("airlift: heartbeat pulse OK")
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        fileOperationLock.lock()
        defer { fileOperationLock.unlock() }
        disconnectLocked()
    }

    /// Deve ser chamado somente com fileOperationLock já adquirido.
    private func disconnectLocked() {
        WiFiConnectionMonitor.shared.stop()
        AirLiftPairingKeepAlive.shared.stop()
        heartbeatLock.lock()
        if let client = heartbeatClient {
            heartbeat_client_free(client)
            heartbeatClient = nil
        }
        heartbeatLock.unlock()
        tunnelReady = false
        for client in appContainerClients.values {
            afc_client_free(client)
        }
        appContainerClients.removeAll()
        if let client = afcClient {
            afc_client_free(client)
            afcClient = nil
        }
        if let proxy = installProxy {
            installation_proxy_client_free(proxy)
            installProxy = nil
        }
        if let hs = handshake {
            rsd_handshake_free(hs)
            handshake = nil
        }
        if let ad = adapter {
            adapter_free(ad)
            adapter = nil
        }
        state = .idle
        log("airlift: disconnected")
    }
}


enum AirLiftTransportError: LocalizedError {
    case tunnelUnavailable
    case appContainerUnavailable(String, String)
    case fileServiceUnavailable(String, String)
    case fileServiceOperation(String, String, String)
    case fileOperation(String, String, String)

    var errorDescription: String? {
        switch self {
        case .tunnelUnavailable:
            return "Conecte o túnel seguro e conclua o emparelhamento antes de ativar o patch."
        case .appContainerUnavailable(let bundleID, let reason):
            return "House Arrest não abriu o container de \(bundleID): \(reason)"
        case .fileServiceUnavailable(let bundleID, let reason):
            return "FileService não abriu o container de \(bundleID): \(reason)"
        case .fileServiceOperation(let operation, let path, let reason):
            return "Serviço de arquivos falhou ao \(operation) \(path): \(reason)"
        case .fileOperation(let operation, let path, let reason):
            return "Acesso de arquivos falhou ao \(operation) \(path): \(reason)"
        }
    }
}

/// AFC já limitado pelo House Arrest ao container de um único app.
/// Todas as chamadas são feitas dentro de AirLiftTransport.withAppContainer,
/// que mantém o lock enquanto a transação está em curso.
final class AirLiftAFCFileSystem {
    enum EntryKind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    struct Entry {
        let kind: EntryKind
        let size: UInt64
        let creationTime: Int64
    }

    private static let chunkSize = 1_048_576
    private let client: OpaquePointer
    private let bundleID: String
    private let pathPrefix: String?

    fileprivate init(client: OpaquePointer, bundleID: String, pathPrefix: String? = nil) {
        self.client = client
        self.bundleID = bundleID
        self.pathPrefix = pathPrefix
    }

    func info(path: String) throws -> Entry? {
        var raw = AfcFileInfo()
        let remotePath = devicePath(path)
        let result = remotePath.withCString { afc_get_file_info(client, $0, &raw) }
        if let result {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao consultar metadados")
            if Self.isNotFound(reason) { return nil }
            throw operationError("consultar", path, reason)
        }
        defer { afc_file_info_free(&raw) }

        let format = raw.st_ifmt.map { String(cString: $0) } ?? ""
        let isLink = format.contains("LNK") || raw.st_link_target != nil
        let kind: EntryKind
        if isLink {
            kind = .symbolicLink
        } else if format.contains("DIR") {
            kind = .directory
        } else if format.contains("REG") {
            kind = .regularFile
        } else {
            kind = .other
        }
        return Entry(kind: kind, size: UInt64(raw.size), creationTime: raw.creation)
    }

    func rootCreationTime() throws -> Int64 {
        guard let root = try info(path: "/"), root.kind == .directory else {
            throw operationError("consultar", "/", "o container remoto não expôs um diretório raiz")
        }
        return root.creationTime
    }

    func digestFile(path: String) throws -> Data? {
        guard let entry = try info(path: path) else { return nil }
        guard entry.kind == .regularFile else {
            throw operationError("ler", path, "o destino não é um arquivo comum")
        }
        return try streamFile(path: path) { _ in }
    }

    /// Faz backup em blocos para evitar carregar arquivos grandes na memória.
    func copyFileToLocal(path: String, destination: URL) throws -> Data? {
        guard let entry = try info(path: path) else { return nil }
        guard entry.kind == .regularFile else {
            throw operationError("salvar backup de", path, "o destino não é um arquivo comum")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw operationError("criar backup de", path, "não foi possível criar o arquivo local")
        }
        let output = try FileHandle(forWritingTo: destination)
        do {
            let digest = try streamFile(path: path) { chunk in
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
            return digest
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func makeDirectory(path: String) throws {
        let remotePath = devicePath(path)
        if let result = remotePath.withCString({ afc_make_directory(client, $0) }) {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao criar diretório")
            throw operationError("criar diretório", path, reason)
        }
    }

    func removePath(path: String) throws {
        guard try info(path: path) != nil else { return }
        let remotePath = devicePath(path)
        if let result = remotePath.withCString({ afc_remove_path(client, $0) }) {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao remover caminho")
            throw operationError("remover", path, reason)
        }
    }

    func renamePath(from source: String, to destination: String) throws {
        let remoteSource = devicePath(source)
        let remoteDestination = devicePath(destination)
        let result = remoteSource.withCString { sourcePath in
            remoteDestination.withCString { destinationPath in
                afc_rename_path(client, sourcePath, destinationPath)
            }
        }
        if let result {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao renomear caminho")
            throw operationError("renomear", source, reason)
        }
    }

    func writeAtomically(data: Data, to path: String) throws {
        try writeAtomically(to: path) { file in
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let length = min(Self.chunkSize, buffer.count - offset)
                    guard let base = buffer.baseAddress?.advanced(by: offset) else {
                        throw operationError("escrever", path, "buffer de dados vazio inesperado")
                    }
                    if let result = afc_file_write(
                        file,
                        base.assumingMemoryBound(to: UInt8.self),
                        length
                    ) {
                        let reason = AirLiftTransport.consumeError(result, fallback: "falha ao gravar dados")
                        throw operationError("escrever", path, reason)
                    }
                    offset += length
                }
            }
        }
    }

    func writeAtomically(from source: URL, to path: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try writeAtomically(to: path) { file in
            while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                if let result = chunk.withUnsafeBytes({ buffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    guard let base = buffer.baseAddress else { return nil }
                    return afc_file_write(file, base.assumingMemoryBound(to: UInt8.self), buffer.count)
                }) {
                    let reason = AirLiftTransport.consumeError(result, fallback: "falha ao restaurar backup")
                    throw operationError("restaurar", path, reason)
                }
            }
        }
    }

    private func writeAtomically(to path: String, writer: (OpaquePointer) throws -> Void) throws {
        if let existing = try info(path: path), existing.kind != .regularFile {
            throw operationError("substituir", path, "o destino não é um arquivo comum")
        }

        let parent = Self.parentPath(of: path)
        let staging = Self.join(parent, ".airlift-stage-\(UUID().uuidString)")
        let previous = Self.join(parent, ".airlift-previous-\(UUID().uuidString)")
        defer { try? removePath(path: staging) }
        try writeRemoteFile(path: staging, writer: writer)

        var movedOriginal = false
        if try info(path: path) != nil {
            try renamePath(from: path, to: previous)
            movedOriginal = true
        }
        do {
            try renamePath(from: staging, to: path)
        } catch {
            if movedOriginal { try? renamePath(from: previous, to: path) }
            throw error
        }
        if movedOriginal {
            do {
                try removePath(path: previous)
            } catch {
                log("airlift: temporary previous file cleanup failed for \(previous): \(error.localizedDescription)")
            }
        }
    }

    private func writeRemoteFile(path: String, writer: (OpaquePointer) throws -> Void) throws {
        var opened: OpaquePointer?
        let remotePath = devicePath(path)
        if let result = remotePath.withCString({ afc_file_open(client, $0, AfcWrOnly, &opened) }) {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao abrir para escrita")
            throw operationError("abrir para escrita", path, reason)
        }
        guard let file = opened else {
            throw operationError("abrir para escrita", path, "a biblioteca não retornou um handle")
        }
        defer { if let opened { _ = afc_file_close(opened) } }
        try writer(file)
        if let closeError = afc_file_close(file) {
            opened = nil
            let reason = AirLiftTransport.consumeError(closeError, fallback: "falha ao fechar arquivo")
            throw operationError("fechar", path, reason)
        }
        opened = nil
    }

    private func streamFile(path: String, sink: (Data) throws -> Void) throws -> Data {
        var opened: OpaquePointer?
        let remotePath = devicePath(path)
        if let result = remotePath.withCString({ afc_file_open(client, $0, AfcRdOnly, &opened) }) {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao abrir para leitura")
            throw operationError("abrir para leitura", path, reason)
        }
        guard let file = opened else {
            throw operationError("abrir para leitura", path, "a biblioteca não retornou um handle")
        }
        defer { _ = afc_file_close(file) }

        var hasher = SHA256()
        while true {
            var bytes: UnsafeMutablePointer<UInt8>?
            var bytesRead = 0
            if let result = afc_file_read(file, &bytes, UInt(Self.chunkSize), &bytesRead) {
                let reason = AirLiftTransport.consumeError(result, fallback: "falha ao ler bloco")
                throw operationError("ler", path, reason)
            }
            guard let bytes else {
                if bytesRead == 0 { break }
                throw operationError("ler", path, "resposta AFC sem buffer de dados")
            }
            let chunk = Data(bytes: bytes, count: bytesRead)
            afc_file_read_data_free(bytes, bytesRead)
            guard bytesRead > 0 else { break }
            hasher.update(data: chunk)
            try sink(chunk)
        }
        return Data(hasher.finalize())
    }

    private func operationError(_ operation: String, _ path: String, _ reason: String) -> AirLiftTransportError {
        .fileOperation("\(operation) [\(bundleID)]", path, reason)
    }

    private static func isNotFound(_ reason: String) -> Bool {
        let value = reason.lowercased().replacingOccurrences(of: " ", with: "")
        return value.contains("notfound") || value.contains("nosuchfile") || value.contains("enoent")
            || value.contains("doesnotexist")
    }

    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private func devicePath(_ path: String) -> String {
        guard let pathPrefix, !path.hasPrefix("/") else {
            guard !path.isEmpty else { return "/" }
            return path.hasPrefix("/") ? path : "/" + path
        }
        let prefix = pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
        let relative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? prefix : prefix + "/" + relative
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }
}

/// Leitor FileService limitado à sessão AppDataContainer de um bundle.
final class AirLiftFileServiceClient {
    private static let maximumReadBytes = 256 * 1_048_576
    private let handle: OpaquePointer
    private let adapter: OpaquePointer
    private let dataPort: UInt16
    private let bundleID: String

    fileprivate init(handle: OpaquePointer, adapter: OpaquePointer, dataPort: UInt16, bundleID: String) {
        self.handle = handle
        self.adapter = adapter
        self.dataPort = dataPort
        self.bundleID = bundleID
    }

    func readFile(path: String) throws -> Data {
        guard dataPort != 0 else {
            throw AirLiftTransportError.fileServiceOperation(
                "baixar [\(bundleID)]", path, "canal de dados FileService não anunciado pelo RSD"
            )
        }
        let canonicalPath = try PatchPathValidator.canonicalRelativePath(path)
        guard canonicalPath == path else {
            throw AirLiftTransportError.fileServiceOperation("validar", path, "caminho não canônico")
        }

        var buffer: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        let result = canonicalPath.withCString {
            file_service_retrieve_file(handle, $0, adapter, dataPort, &buffer, &length)
        }
        defer {
            if let buffer { idevice_data_free(buffer, length) }
        }
        if let result {
            let reason = AirLiftTransport.consumeError(result, fallback: "falha ao baixar arquivo")
            throw AirLiftTransportError.fileServiceOperation("baixar [\(bundleID)]", path, reason)
        }

        guard let byteCount = Int(exactly: length), byteCount <= Self.maximumReadBytes else {
            throw AirLiftTransportError.fileServiceOperation(
                "baixar [\(bundleID)]",
                path,
                "o arquivo excede o limite de 256 MiB"
            )
        }
        guard let buffer else {
            guard byteCount == 0 else {
                throw AirLiftTransportError.fileServiceOperation(
                    "baixar [\(bundleID)]",
                    path,
                    "resposta FileService sem buffer"
                )
            }
            return Data()
        }
        return Data(bytes: buffer, count: byteCount)
    }
    func readFileIfPresent(path: String) throws -> Data? {
        guard dataPort != 0 else { return nil }
        do {
            return try readFile(path: path)
        } catch let error as AirLiftTransportError {
            if case .fileServiceOperation(_, _, let reason) = error,
               reason.lowercased().contains("notfound") || reason.lowercased().contains("no such") {
                return nil
            }
            throw error
        }
    }
    func digestFile(path: String) throws -> Data? {
        guard let data = try readFileIfPresent(path: path) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
