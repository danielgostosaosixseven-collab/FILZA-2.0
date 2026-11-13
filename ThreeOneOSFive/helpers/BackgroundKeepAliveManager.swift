import AVFoundation
import Foundation
import UIKit

/// Mantém o processo vivo em segundo plano durante operações de patch,
/// replicando o mecanismo do Free Fire: sessão de áudio ativa (recorder +
/// player silencioso) impede que o iOS suspenda o processo.
///
/// Diferença do AirLiftPairingKeepAlive: este roda durante a INJEÇÃO,
/// não durante o pairing. É ativado pelo DevicePatchService antes de
/// apply()/restore() e desativado quando terminam.
///
/// Funciona em qualquer iOS 16+ / iPhone / iPad — não depende de hardware.
final class BackgroundKeepAliveManager {
    static let shared = BackgroundKeepAliveManager()

    private let queue = DispatchQueue(label: "com.filza.bgkeepalive.patch", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var audioRecorder: AVAudioRecorder?
    private var audioSession: AVAudioSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keepaliveTimer: Timer?
    private var isHolding = false
    private var holdCount = 0  // reference counting: multiple operations can hold simultaneously

    private init() {}

    // MARK: - Public API

    /// Chamar ANTES de iniciar apply() ou restore().
    /// Cada chamada incrementa o hold count; o áudio só para quando todos soltarem.
    func beginHold(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.holdCount += 1
            log("bgkeepalive: beginHold(\(reason)) count=\(self.holdCount)")
            guard !self.isHolding else { return }
            self.isHolding = true
            self.startAudioSession()
            self.startBackgroundTask()
            self.startKeepaliveTimer()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    /// Chamar DEPOIS de terminar apply() ou restore().
    /// Quando o count chega a zero, desliga tudo.
    func endHold(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.holdCount = max(0, self.holdCount - 1)
            log("bgkeepalive: endHold(\(reason)) count=\(self.holdCount)")
            guard self.holdCount == 0, self.isHolding else { return }
            self.isHolding = false
            self.stopKeepaliveTimer()
            self.stopBackgroundTask()
            self.stopAudioSession()
            UIApplication.shared.isIdleTimerDisabled = false
            log("bgkeepalive: all holds released — audio stopped")
        }
    }

    /// Força parada imediata (ex: app voltando pro foreground com erro).
    func forceStop() {
        queue.async { [weak self] in
            guard let self, self.isHolding else { return }
            self.holdCount = 0
            self.isHolding = false
            self.stopKeepaliveTimer()
            self.stopBackgroundTask()
            self.stopAudioSession()
            UIApplication.shared.isIdleTimerDisabled = false
            log("bgkeepalive: forceStop")
        }
    }

    // MARK: - Audio (o coração do sistema)

    private func startAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .recordAndPlay: abre microfone E alto-falante.
            // Enquanto houver input ativo (mic), o iOS NÃO suspende o processo.
            // É exatamente o que o Free Fire faz com o voice chat.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])

            // Player: buffer silencioso em loop (mantém output ativo)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
            if let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410) {
                buffer.frameLength = 4_410
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                engine.prepare()
                try engine.start()
                player.play()
            }

            // Recorder: abre o microfone (mesmo sem gravar nada).
            // O input ativo é o que realmente impede a suspensão.
            let recorderURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bgkeepalive_silent.wav")
            let recorderSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16
            ]
            let recorder = try AVAudioRecorder(url: recorderURL, settings: recorderSettings)
            recorder.isMeteringEnabled = true
            recorder.record()  // mic aberto = processo não suspende

            audioSession = session
            audioEngine = engine
            audioPlayer = player
            audioRecorder = recorder
            log("bgkeepalive: audio session active (recordAndPlay + silent player)")
        } catch {
            // Se o sistema recusar áudio (modo silencioso estrito, perfil, etc.),
            // o background task ainda dá ~30s. Melhor que nada.
            log("bgkeepalive: audio session failed: \(error.localizedDescription)")
        }
    }

    private func stopAudioSession() {
        audioRecorder?.stop()
        audioRecorder = nil
        audioPlayer?.stop()
        audioEngine?.stop()
        try? audioSession?.setActive(false, options: .notifyOthersOnDeactivation)
        audioPlayer = nil
        audioEngine = nil
        audioSession = nil
        // Limpar arquivo temporário
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgkeepalive_silent.wav")
        try? FileManager.default.removeItem(at: tmpFile)
    }

    // MARK: - Background Task

    private func startBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PatchKeepAlive") { [weak self] in
            log("bgkeepalive: background task expired by system")
            self?.stopBackgroundTask()
        }
        log("bgkeepalive: background task started (id=\(backgroundTask.rawValue))")
    }

    private func stopBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Keepalive Timer (renova o background task antes de expirar)

    private func startKeepaliveTimer() {
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self, self.isHolding else { return }
            // Renova o background task: encerra o antigo e começa um novo.
            // Isso estende a janela de ~30s indefinidamente enquanto o hold estiver ativo.
            self.stopBackgroundTask()
            self.startBackgroundTask()
            log("bgkeepalive: timer tick — background task renewed")
        }
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }
}
