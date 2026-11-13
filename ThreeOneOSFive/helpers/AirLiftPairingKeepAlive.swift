import AVFoundation
import Foundation
import Network

/// Mantém a sessão de pairing viva sem iniciar handshakes concorrentes.
/// A referência usa uma sessão de áudio silenciosa, monitoramento de rota e
/// pulsos periódicos; esta classe concentra apenas esse ciclo de vida.
final class AirLiftPairingKeepAlive {
    static let shared = AirLiftPairingKeepAlive()

    private let queue = DispatchQueue(label: "com.filza.airlift.keepalive", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var pulse: (() -> Void)?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var audioSession: AVAudioSession?
    private var isRunning = false

    private init() {}

    func start(pulse: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pulse = pulse
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startSilentAudio()
            self.startPathMonitor()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 8, repeating: 12, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                self?.pulse?()
            }
            self.timer = timer
            timer.resume()
            log("airlift.keepalive: started")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.pulse = nil
            self.stopSilentAudio()
            if self.isRunning { log("airlift.keepalive: stopped") }
            self.isRunning = false
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied {
                log("airlift.keepalive: network path satisfied (expensive=\(path.isExpensive))")
            } else {
                log("airlift.keepalive: network path unavailable")
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func startSilentAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
            guard let format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410) else {
                log("airlift.keepalive: could not create silent audio buffer")
                return
            }
            buffer.frameLength = 4_410
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            engine.prepare()
            try engine.start()
            player.play()
            audioSession = session
            audioEngine = engine
            audioPlayer = player
            log("airlift.keepalive: silent audio session active")
        } catch {
            // O pairing continua funcional mesmo quando o sistema recusa áudio
            // em uma instalação específica; o timer e o monitor permanecem ativos.
            log("airlift.keepalive: audio session unavailable: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioEngine?.stop()
        try? audioSession?.setActive(false, options: .notifyOthersOnDeactivation)
        audioPlayer = nil
        audioEngine = nil
        audioSession = nil
    }
}
