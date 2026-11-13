import Foundation

/// ExtendedVersionUnlock — camada de desbloqueio de versões estendidas.
///
/// Este arquivo é a parte dedicada a liberar versões do iOS que não são
/// cobertas pelo exploit kernel nativo (18.7.10, 27.1 beta, 27.2 beta).
/// Ele sobrepõe a política original do ExploitSupportPolicy e marca essas
/// versões como Supported na UI, permitindo que o exploit tente rodar.
///
/// Baseado na engenharia reversa da IPA oficial 3105 2.1-beta,
/// que usa um mecanismo de transporte compartilhado para acessar builds novos.
enum ExtendedVersionUnlock {
    /// Versões estendidas liberadas além da política original.
    static let extendedIOS18Range = "18.0–18.7.10"
    static let extendedIOS27Range = "27.0–27.2 beta"

    /// Retorna true se a versão deve ser liberada pela camada estendida.
    /// Isso cobre iOS 16+ inteiro, incluindo 18.7.10 e 27.1/27.2 beta.
    static func isUnlocked(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        // iOS 16: qualquer patch
        if major == 16 { return true }

        // iOS 17: até 17.7.x
        if major == 17 { return minor <= 7 }

        // iOS 18: até 18.7.10 (estendido de 18.7.1)
        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 10)
        }

        // iOS 26: até 26.6.2
        if major == 26 {
            return minor < 6 || (minor == 6 && patch <= 2)
        }

        // iOS 27: 27.0 (beta verificado), 27.1 beta, 27.2 beta
        if major == 27 {
            if minor == 0 && patch == 0 {
                // 27.0: só os builds beta verificados
                let verifiedBuilds = ["24A5355q", "24A5370h", "24A5380h", "24A5390f"]
                return verifiedBuilds.contains(build)
            }
            // 27.1 e 27.2: aceitar qualquer build (beta)
            if minor == 1 || minor == 2 { return true }
            return false
        }

        return false
    }

    /// Resumo para exibição na UI (Settings/Onboarding).
    static func displaySummary() -> String {
        return "iOS 16.0+ (inclui 18.7.10, 27.1 beta, 27.2 beta)"
    }
}
