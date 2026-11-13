// AirLiftPairingController.swift
// Orquestra LocalDevVPN e o fluxo iOS 27+ de device-initiated RemotePairing.
// O app anuncia um pairable host; Ajustes do iOS inicia o pairing e o app mostra o PIN recebido.

import Foundation
import Network
import Combine
import UIKit
import BackgroundTasks
import UserNotifications

final class AirLiftPairingController: ObservableObject {
    static let shared = AirLiftPairingController()

    enum Step: Int, CaseIterable, Equatable {
        case wifiRequired = 0
        case downloadVPN
        case tunnelRequired
        case testing
        case tunnelReady
        case pairingRequired
        case directPairing
        case pairingCompleted
        case readyToUse
        case failed
    }

    @Published var step: Step = .wifiRequired
    @Published var statusMessage: String = ""
    @Published var pin: String = ""
    @Published var isWorking: Bool = false
    @Published var errorMessage: String?

    private static let continuedProcessingTaskIdentifier = "com.apple.mobile.MobileHouseArrest.airlift.pairing"
    private static let pinNotificationIdentifier = "airlift-pairing-pin"
    private let transport = AirLiftTransport.shared
    private var pairingHost: AirLiftPairingHost?
    private var continuedProcessingTask: AnyObject?
    private var didRegisterContinuedProcessingTask = false
    private var fallbackBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var manualPairingRequested = false

    private init() {}

    var isLocalDevVPNInstalled: Bool {
        guard let url = URL(string: "localdevvpn://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    var pairingHostDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Conexão do dispositivo"
    }

    func prepareForManualPairing() {
        pairingHost?.cancel()
        pairingHost = nil
        clearPairingPINNotification()
        finishBackgroundWork(success: false)
        pin = ""
        errorMessage = nil
        isWorking = false
        manualPairingRequested = true
        step = .pairingRequired
        statusMessage = "Ative primeiro o LocalDevVPN. Depois emparelhe e confirme este iPhone."
    }

    // MARK: - Step-by-step flow

    func advance() {
        guard !isWorking else { return }
        switch step {
        case .wifiRequired:
            checkWiFi()
        case .downloadVPN:
            openLocalDevVPN()
        case .tunnelRequired, .testing:
            verifyTunnel()
        case .tunnelReady:
            step = .pairingRequired
            statusMessage = "Túnel pronto. Inicie o pareamento neste iPhone."
        case .pairingRequired:
            startOnDevicePairing()
        case .directPairing:
            break
        case .pairingCompleted:
            step = .readyToUse
            statusMessage = "Pronto! Conexão estabelecida."
        case .readyToUse:
            break
        case .failed:
            errorMessage = nil
            step = AirLiftPairingStore.shared.hasPairingFile ? .tunnelRequired : .pairingRequired
        }
    }

    private func checkWiFi() {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var hasNetwork = false

        monitor.pathUpdateHandler = { path in
            hasNetwork = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.cellular) || path.usesInterfaceType(.wiredEthernet))
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue.global())
        _ = semaphore.wait(timeout: .now() + 2.0)
        monitor.cancel()

        if hasNetwork {
            step = .pairingRequired
            statusMessage = "Rede disponível. A conexão direta ou o túnel seguro será usado automaticamente."
            errorMessage = nil
        } else {
            errorMessage = "Conecte-se ao Wi‑Fi ou ative os dados móveis com um túnel seguro."
            step = .failed
        }
    }

    func openLocalDevVPN() {
        errorMessage = nil
        guard isLocalDevVPNInstalled else {
            let storeURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
            UIApplication.shared.open(storeURL)
            statusMessage = "Instale e ative o LocalDevVPN; depois volte para emparelhar."
            return
        }

        let connectURL = URL(string: "localdevvpn://enable?scheme=airliftreturn")!
        statusMessage = "Abrindo o LocalDevVPN. Aguarde a ativação e retorne ao app…"
        UIApplication.shared.open(connectURL, options: [:]) { [weak self] opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorMessage = "Não foi possível abrir o túnel seguro."
                self.statusMessage = "Confira se o túnel seguro está instalado e tente novamente."
            }
        }
    }

    func verifyTunnel() {
        guard !isWorking, step != .directPairing else { return }
        guard AirLiftTransport.detectVPNInterface() != nil else {
            errorMessage = "Ative primeiro o LocalDevVPN e volte para confirmar a conexão."
            step = .tunnelRequired
            return
        }
        errorMessage = nil
        step = .testing
        statusMessage = "Confirmando a conexão pelo LocalDevVPN…"
        isWorking = true
        testTunnel()
    }

    func localDevVPNDidReturn() {
        statusMessage = "Túnel seguro retornou. Verificando a conexão…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyTunnel()
        }
    }

    private func connectSavedPairingWithRecovery() -> Bool {
        log("airlift.connection_diagnostic stage=pairing_file result=checking")
        guard AirLiftPairingStore.shared.hasPairingFile else {
            log("airlift.connection_diagnostic stage=pairing_file result=failed attribution=pairing_file_unreadable tcp=not_tested")
            return false
        }
        log("airlift.connection_diagnostic stage=pairing_file result=ok")
        let ok = transport.connectWithRecovery(pin: nil, attempts: 10) { [weak self] attempt, total, message in
            log("airlift.tunnel id=reconnect stage=connect attempt=\(attempt)/\(total) detail=\(message)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = "Aguardando o serviço do dispositivo; tentativa \(attempt) de \(total)…"
            }
        }
        if ok {
            log("airlift.connection_diagnostic stage=service_probe result=connected route=tunnel atc=ready zip=ready")
        } else {
            let err = transport.error ?? "unknown"
            let attribution: String
            let lower = err.lowercased()
            if lower.contains("refused") || lower.contains("refused") { attribution = "hosts_refused" }
            else if lower.contains("timed out") || lower.contains("timeout") { attribution = "timeout" }
            else if lower.contains("handshake") || lower.contains("tls") { attribution = "tls_handshake" }
            else if lower.contains("rsd") { attribution = "rsd_unreachable" }
            else { attribution = "native_classification" }
            log("airlift.connection_diagnostic stage=multihost_tunnel result=failed reason=\(err) attribution=\(attribution)")
        }
        return ok
    }

    /// Antes do primeiro pairing, a porta RPPairing ainda não está pronta.
    /// A VPN é opcional: o transporte tenta primeiro o endpoint local direto.
    private func testTunnel() {
        if manualPairingRequested {
            manualPairingRequested = false
            isWorking = false
            errorMessage = nil
            statusMessage = "LocalDevVPN pronto. Inicie o emparelhamento neste iPhone."
            step = .pairingRequired
            return
        }

        guard AirLiftPairingStore.shared.hasPairingFile else {
            isWorking = false
            errorMessage = nil
            statusMessage = "Nenhum pairing file salvo. LocalDevVPN pronto. Inicie o emparelhamento neste iPhone."
            step = .pairingRequired
            return
        }

        statusMessage = "Emparelhamento salvo. Conectando ao serviço…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let connected = self.connectSavedPairingWithRecovery()
            DispatchQueue.main.async {
                self.isWorking = false
                if connected {
                    AirLiftPairingStore.shared.markConnectionConfirmedForThisInstallation()
                    self.step = .readyToUse
                    self.statusMessage = "Conexão ativa."
                    self.errorMessage = nil
                } else {
                    self.step = .tunnelRequired
                    self.statusMessage = "Emparelhamento salvo, mas a rede direta não alcançou o dispositivo. Ative o túnel seguro e tente novamente."
                    self.errorMessage = self.transport.error
                }
            }
        }
    }

    func startPairingFromSettings() {
        guard !isWorking, step != .directPairing else { return }
        guard AirLiftTransport.detectVPNInterface() != nil else {
            errorMessage = "Ative primeiro o LocalDevVPN e volte para emparelhar."
            step = .tunnelRequired
            return
        }
        prepareForManualPairing()
        manualPairingRequested = false
        startOnDevicePairing()
    }

    private func startOnDevicePairing() {
        errorMessage = nil
        pin = ""
        isWorking = true
        step = .directPairing
        statusMessage = "Preparando o serviço de pareamento deste iPhone…"

        requestPairingNotificationAuthorization { [weak self] in
            self?.startPairingWithBackgroundTask()
        }
    }

    private func requestPairingNotificationAuthorization(completion: @escaping () -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log("airlift: notification permission request failed: \(error.localizedDescription)")
            }
            if !granted {
                log("airlift: PIN notifications disabled; user can return to the app to read the PIN")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func startPairingWithBackgroundTask() {
        if #available(iOS 26.0, *) {
            if registerContinuedProcessingTask() {
                let request = BGContinuedProcessingTaskRequest(
                    identifier: Self.continuedProcessingTaskIdentifier,
                    title: "Pareamento do dispositivo",
                    subtitle: "Mantendo o serviço ativo enquanto os Ajustes estão abertos"
                )
                request.strategy = .fail
                do {
                    try BGTaskScheduler.shared.submit(request)
                    beginLegacyBackgroundTask()
                    startPairingHost()
                    return
                } catch {
                    log("airlift: continued-processing submit failed: \(error.localizedDescription)")
                    statusMessage = "O iOS não autorizou a execução prolongada; mantenha esta tela aberta durante o pairing."
                }
            } else {
                log("airlift: continued-processing handler registration failed")
                statusMessage = "O iOS não manteve o app em segundo plano; mantenha esta tela aberta durante o pairing."
            }
        }

        beginLegacyBackgroundTask()
        startPairingHost()
    }

    private func startPairingHost() {
        guard pairingHost == nil else { return }
        let host = AirLiftPairingHost(
            hostName: pairingHostDisplayName,
            onStatus: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusMessage = message
                    self.isWorking = false
                    if message.contains("Serviço anunciado") {
                        if #available(iOS 26.0, *) {
                            self.updateContinuedProcessingTask(progress: 20, subtitle: "Aguardando o iPhone iniciar o pairing")
                        }
                    } else if message.contains("Conexão recebida do iPhone") {
                        if #available(iOS 26.0, *) {
                            self.updateContinuedProcessingTask(progress: 45, subtitle: "Solicitando o PIN de pareamento")
                        }
                    }
                }
            },
            onPIN: { [weak self] value in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pin = value
                    self.statusMessage = "PIN recebido. Digite-o na tela de pareamento do Modo do Desenvolvedor."
                    self.isWorking = false
                    self.schedulePairingPINNotification(value)
                    if #available(iOS 26.0, *) {
                        self.updateContinuedProcessingTask(progress: 70, subtitle: "PIN: \(value) - digite nos Ajustes")
                    }
                }
            },
            onPairingFile: { [weak self] data, hostAltIRK in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if #available(iOS 26.0, *) {
                        self.updateContinuedProcessingTask(progress: 90, subtitle: "Pareamento concluído; salvando credenciais")
                    }
                    self.finishOnDevicePairing(with: data, hostAltIRK: hostAltIRK)
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pairingHost = nil
                    self.isWorking = false
                    self.errorMessage = message
                    self.step = .failed
                    self.finishBackgroundWork(success: false)
                }
            }
        )
        pairingHost = host
        host.start()
    }

    private func schedulePairingPINNotification(_ value: String) {
        let center = UNUserNotificationCenter.current()
        clearPairingPINNotification()
        let content = UNMutableNotificationContent()
        content.title = "Código de pareamento do dispositivo"
        content.body = "PIN: \(value). Digite-o na tela do Modo do Desenvolvedor em Ajustes."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.pinNotificationIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                log("airlift: PIN notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearPairingPINNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pinNotificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.pinNotificationIdentifier])
    }

    @available(iOS 26.0, *)
    private func registerContinuedProcessingTask() -> Bool {
        if didRegisterContinuedProcessingTask { return true }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedProcessingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let self else {
                continuedTask.setTaskCompleted(success: false)
                return
            }
            DispatchQueue.main.async {
                self.continuedProcessingTask = continuedTask
                continuedTask.progress.totalUnitCount = 100
                continuedTask.progress.completedUnitCount = 10
                continuedTask.updateTitle(
                    "Pareamento do dispositivo",
                    subtitle: "Mantendo o serviço de pairing ativo"
                )
                continuedTask.expirationHandler = { [weak self] in
                    DispatchQueue.main.async { self?.handleContinuedTaskExpiration() }
                }
                self.endLegacyBackgroundTask()
                self.startPairingHost()
            }
        }
        didRegisterContinuedProcessingTask = registered
        return registered
    }

    @available(iOS 26.0, *)
    private func updateContinuedProcessingTask(progress: Int64, subtitle: String) {
        guard let task = continuedProcessingTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = progress
        task.updateTitle("Pareamento do dispositivo", subtitle: subtitle)
    }

    @available(iOS 26.0, *)
    private func handleContinuedTaskExpiration() {
        guard continuedProcessingTask != nil else { return }
        pairingHost?.cancel()
        pairingHost = nil
        isWorking = false
        errorMessage = "O iOS encerrou a execução em segundo plano. Abra Emparelhar dispositivo nos Ajustes e tente novamente."
        step = .failed
        finishBackgroundWork(success: false)
    }

    private func beginLegacyBackgroundTask() {
        guard fallbackBackgroundTask == .invalid else { return }
        fallbackBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DevicePairing") { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if #available(iOS 26.0, *), self.continuedProcessingTask != nil {
                    self.endLegacyBackgroundTask()
                    return
                }
                self.pairingHost?.cancel()
                self.pairingHost = nil
                self.isWorking = false
                self.errorMessage = "O iOS encerrou a execução em segundo plano. Mantenha o app aberto e tente novamente."
                self.step = .failed
                self.finishBackgroundWork(success: false)
            }
        }
    }

    private func endLegacyBackgroundTask() {
        guard fallbackBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fallbackBackgroundTask)
        fallbackBackgroundTask = .invalid
    }

    private func finishBackgroundWork(success: Bool) {
        if #available(iOS 26.0, *), let task = continuedProcessingTask as? BGContinuedProcessingTask {
            continuedProcessingTask = nil
            task.expirationHandler = nil
            if success { task.progress.completedUnitCount = 100 }
            task.setTaskCompleted(success: success)
        }
        endLegacyBackgroundTask()
    }

    private func finishOnDevicePairing(with data: Data, hostAltIRK: Data) {
        pairingHost = nil
        guard AirLiftPairingStore.shared.savePairingFile(data, hostAltIRK: hostAltIRK) else {
            isWorking = false
            errorMessage = "O pareamento terminou, mas não foi possível salvar o pairing file no Keychain."
            step = .failed
            finishBackgroundWork(success: false)
            return
        }

        clearPairingPINNotification()
        isWorking = true
        statusMessage = "Emparelhamento concluído. Abrindo a conexão…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let connected = self.connectSavedPairingWithRecovery()
            DispatchQueue.main.async {
                self.isWorking = false
                if connected {
                    AirLiftPairingStore.shared.markConnectionConfirmedForThisInstallation()
                    self.step = .pairingCompleted
                    self.statusMessage = "Emparelhamento e conexão concluídos."
                    self.errorMessage = nil
                } else {
                    // O pairing file fica salvo para permitir uma nova tentativa sem repetir o PIN.
                    self.step = .tunnelRequired
                    self.statusMessage = "Emparelhamento salvo, mas a rede direta não alcançou o dispositivo. Ative o túnel seguro e tente novamente."
                    self.errorMessage = self.transport.error
                }
                self.finishBackgroundWork(success: true)
            }
        }
    }

    func cancelPairing() {
        pairingHost?.cancel()
        pairingHost = nil
        clearPairingPINNotification()
        finishBackgroundWork(success: false)
        isWorking = false
        pin = ""
        errorMessage = nil
        statusMessage = "Pareamento cancelado."
        step = .pairingRequired
    }

    @discardableResult
    func tryReconnect() -> Bool {
        guard AirLiftPairingStore.shared.hasPairingFile else {
            log("airlift: no saved pairing file — need first-time setup")
            return false
        }
        log("airlift: attempting reconnect with saved pairing…")
        return connectSavedPairingWithRecovery()
    }

    func reset() {
        pairingHost?.cancel()
        pairingHost = nil
        clearPairingPINNotification()
        finishBackgroundWork(success: false)
        transport.disconnect()
        AirLiftPairingStore.shared.deletePairingFile()
        AirLiftPairingStore.shared.clearConnectionConfirmationForThisInstallation()
        step = .wifiRequired
        statusMessage = ""
        errorMessage = nil
        pin = ""
        isWorking = false
    }
}

// MARK: - Device-initiated RPPairing host

/// Announces a pairable host for iOS Settings, accepts the iOS-initiated TCP socket,
/// surfaces the generated PIN, and returns the resulting RPPairing file.
private final class AirLiftPairingHost: NSObject, NetServiceDelegate {
    private enum HostError: LocalizedError {
        case socket(String)
        case ffi(String)
        case invalidTXTRecord
        case missingHandle
        case cancelled

        var errorDescription: String? {
            switch self {
            case .socket(let message), .ffi(let message): return message
            case .invalidTXTRecord: return "A biblioteca não retornou registros Bonjour válidos."
            case .missingHandle: return "A biblioteca não retornou o identificador do host de pareamento."
            case .cancelled: return "Pareamento cancelado."
            }
        }
    }

    private let hostName: String
    private let onStatus: (String) -> Void
    private let onPIN: (String) -> Void
    private let onPairingFile: (Data, Data) -> Void
    private let onError: (String) -> Void
    private let queue = DispatchQueue(label: "airlift.pairing-host", qos: .userInitiated)
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var acceptedFD: Int32 = -1
    private var cancelled = false
    private var netService: NetService?

    init(
        hostName: String,
        onStatus: @escaping (String) -> Void,
        onPIN: @escaping (String) -> Void,
        onPairingFile: @escaping (Data, Data) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.hostName = hostName
        self.onStatus = onStatus
        self.onPIN = onPIN
        self.onPairingFile = onPairingFile
        self.onError = onError
        super.init()
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let listener = listenerFD
        let client = acceptedFD
        listenerFD = -1
        acceptedFD = -1
        lock.unlock()

        if listener >= 0 { _ = Darwin.shutdown(listener, SHUT_RDWR) }
        if client >= 0 { _ = Darwin.shutdown(client, SHUT_RDWR) }
        DispatchQueue.main.async { [weak self] in
            self?.netService?.stop()
            self?.netService = nil
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        onStatus("Serviço anunciado. Abra Ajustes > Privacidade e Segurança > Modo do Desenvolvedor e escolha Pair with \(hostName).")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        let message = errorDict[NetService.errorDomain]?.stringValue ?? "Falha ao anunciar o serviço Bonjour"
        onError("\(message) (\(code)). Verifique a permissão de Rede Local e tente novamente.")
        cancel()
    }

    private static let pinCallback: PairableHostPinCb = { pin, context in
        guard let pin, let context else { return }
        let host = Unmanaged<AirLiftPairingHost>.fromOpaque(context).takeUnretainedValue()
        host.onPIN(String(cString: pin))
    }

    private func run() {
        var listener: Int32 = -1
        var client: Int32 = -1
        var hostHandle: OpaquePointer?
        var pairingFile: OpaquePointer?

        defer {
            stopAdvertising()
            if let pairingFile { rp_pairing_file_free(pairingFile) }
            if let hostHandle { pairable_host_free(hostHandle) }
            releaseDescriptor(&client, listener: false)
            releaseDescriptor(&listener, listener: true)
        }

        do {
            guard !isCancelled else { throw HostError.cancelled }
            let preparedSocket = try Self.makeListener()
            listener = preparedSocket.fd
            guard registerDescriptor(listener, isListener: true) else { throw HostError.cancelled }

            var serviceIDPointer: UnsafeMutablePointer<CChar>?
            var txtPointer: UnsafeMutablePointer<UInt8>?
            var txtLength: UInt = 0
            var hostAltIRKBytes = [UInt8](repeating: 0, count: 16)
            let prepareError = hostName.withCString { name in
                "Mac17,7".withCString { model in
                    hostAltIRKBytes.withUnsafeMutableBufferPointer { irkBuffer in
                        pairable_host_prepare(
                            name,
                            model,
                            false,
                            &hostHandle,
                            &serviceIDPointer,
                            &txtPointer,
                            &txtLength,
                            irkBuffer.baseAddress
                        )
                    }
                }
            }
            if let prepareError {
                throw HostError.ffi(Self.consumeError(prepareError, fallback: "Falha ao preparar pairable host."))
            }
            guard let hostHandle else { throw HostError.missingHandle }
            guard let serviceIDPointer, let txtPointer else { throw HostError.invalidTXTRecord }
            defer {
                idevice_string_free(serviceIDPointer)
                idevice_data_free(txtPointer, txtLength)
            }

            let serviceName = String(cString: serviceIDPointer)
            let plistData = Data(bytes: txtPointer, count: Int(txtLength))
            let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
            let txtRecords: [String: Data]
            if let strings = plist as? [String: String] {
                txtRecords = strings.mapValues { Data($0.utf8) }
            } else if let dataRecords = plist as? [String: Data] {
                txtRecords = dataRecords
            } else {
                throw HostError.invalidTXTRecord
            }

            DispatchQueue.main.async { [weak self] in
                self?.publish(serviceName: serviceName, port: preparedSocket.port, txtRecords: txtRecords)
            }
            onStatus("Preparando o anúncio local para o Modo do Desenvolvedor…")

            guard !isCancelled else { throw HostError.cancelled }
            let accepted = Darwin.accept(listener, nil, nil)
            guard accepted >= 0 else {
                if isCancelled { throw HostError.cancelled }
                throw HostError.socket("Falha ao aceitar a conexão do iPhone: \(String(cString: strerror(errno)))")
            }
            client = accepted
            guard registerDescriptor(client, isListener: false) else { throw HostError.cancelled }
            guard !isCancelled else { throw HostError.cancelled }

            onStatus("Conexão recebida do iPhone. Negociando o PIN de pareamento…")
            let pinContext = Unmanaged.passUnretained(self).toOpaque()
            let handshakeError = pairable_host_accept_fd(
                hostHandle,
                client,
                Self.pinCallback,
                pinContext,
                nil,
                &pairingFile
            )
            if let handshakeError {
                throw HostError.ffi(Self.consumeError(handshakeError, fallback: "Falha no handshake RemotePairing."))
            }
            guard let pairingFile else { throw HostError.missingHandle }

            var pairingDataPointer: UnsafeMutablePointer<UInt8>?
            var pairingDataLength: UInt = 0
            let serializeError = rp_pairing_file_to_bytes(pairingFile, &pairingDataPointer, &pairingDataLength)
            if let serializeError {
                throw HostError.ffi(Self.consumeError(serializeError, fallback: "Não foi possível serializar o pairing file."))
            }
            guard let pairingDataPointer else { throw HostError.missingHandle }
            let pairingData = Data(bytes: pairingDataPointer, count: Int(pairingDataLength))
            idevice_data_free(pairingDataPointer, pairingDataLength)

            stopAdvertising()
            onPairingFile(pairingData, Data(hostAltIRKBytes))
        } catch {
            if !isCancelled {
                stopAdvertising()
                onError(error.localizedDescription)
            }
        }
    }

    private func publish(serviceName: String, port: UInt16, txtRecords: [String: Data]) {
        guard !isCancelled else { return }
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txtRecords))
        netService = service
        service.publish()
    }

    private func stopAdvertising() {
        DispatchQueue.main.async { [weak self] in
            self?.netService?.stop()
            self?.netService = nil
        }
    }

    private func registerDescriptor(_ descriptor: Int32, isListener: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        if isListener { listenerFD = descriptor } else { acceptedFD = descriptor }
        return true
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func releaseDescriptor(_ descriptor: inout Int32, listener isListener: Bool) {
        let value = descriptor
        descriptor = -1
        guard value >= 0 else { return }
        lock.lock()
        if isListener, listenerFD == value { listenerFD = -1 }
        if !isListener, acceptedFD == value { acceptedFD = -1 }
        lock.unlock()
        _ = Darwin.close(value)
    }

    private static func makeListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw HostError.socket("Não foi possível criar o socket: \(String(cString: strerror(errno)))")
        }

        var reuseAddress: Int32 = 1
        _ = withUnsafePointer(to: &reuseAddress) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_ANY))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            _ = Darwin.close(fd)
            throw HostError.socket("Falha ao abrir a porta local: \(message)")
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            _ = Darwin.close(fd)
            throw HostError.socket("Falha ao iniciar o listener local: \(message)")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            let message = String(cString: strerror(errno))
            _ = Darwin.close(fd)
            throw HostError.socket("Falha ao obter a porta do listener: \(message)")
        }

        return (fd, UInt16(bigEndian: boundAddress.sin_port))
    }

    private static func consumeError(_ error: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        defer { idevice_error_free(error) }
        guard let message = error.pointee.message else { return fallback }
        return String(cString: message)
    }
}
