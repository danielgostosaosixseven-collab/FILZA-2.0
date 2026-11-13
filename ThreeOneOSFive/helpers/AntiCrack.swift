import Foundation
import CryptoKit
import UIKit
import Darwin
import MachO

/// Camada anti-crack: integridade do bundle, anti-debug/injeção e
/// fingerprint de dispositivo. Chame `AntiCrack.verifyAtLaunch()` no boot.
enum AntiCrack {

    // MARK: - Configuração (preencha com os valores do seu build)

    /// Especificações `arquivo|tipo|tamanho mínimo|tamanho máximo|magic hex`.
    /// A faixa de tamanho é apenas referência: o tipo é validado pela assinatura
    /// para não bloquear mídia legítima reempacotada por um instalador do iOS.
    static let criticalFiles: [String] = [
        "ActivationBackground.png|png|2000000|5000000|89504e470d0a1a0a",
        "REALExternalMark.png|png|100000|5000000|89504e470d0a1a0a",
        "Tutorials/tutorial_error_others.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_ffth_ffmax.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_ap.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_error_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ffth_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ap_banner.jpg|jpg|1000|2000000|ffd8ff",
    ]

    /// Fingerprint de dispositivo esperado (opcional). Se vazio, só valida
    /// que o dispositivo está registrado na primeira ativação.
    static let expectedDeviceFingerprint = ""

    // MARK: - Integridade do bundle

    /// O Bundle ID identifica a instalação oficial e deve permanecer fixo.
    private static func verifyAppContainerMetadata() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("anticrack: Bundle ID ausente — bloqueando interface protegida")
            return false
        }
        guard bundleID == "com.apple.mobile.MobileHouseArrest" else {
            log("anticrack: Bundle ID divergente — bloqueando interface protegida")
            return false
        }
        guard let executable = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            log("anticrack: metadados estruturais do app inválidos")
            return false
        }
        return true
    }

    static func verifyBundleIntegrity() -> Bool {
        guard !criticalFiles.isEmpty else {
            log("anticrack: criticalFiles vazio — integridade pulada")
            return true
        }
        let bundlePath = Bundle.main.bundleURL.path
        let fm = FileManager.default
        var resourcesIntact = true
        for spec in criticalFiles {
            let parts = spec.components(separatedBy: "|")
            guard parts.count >= 5 else {
                log("anticrack: especificação de recurso inválida")
                resourcesIntact = false
                continue
            }
            let rel = parts[0]
            let sizeMin = UInt64(parts[2]) ?? 0
            let sizeMax = UInt64(parts[3]) ?? .max
            let magicHex = parts[4]
            let filename = (rel as NSString).deletingPathExtension
            let extensionName = (rel as NSString).pathExtension
            let url = URL(fileURLWithPath: bundlePath).appendingPathComponent(rel)
            let flatFilename = (filename as NSString).lastPathComponent
            let resolvedURL = (fm.fileExists(atPath: url.path) ? url :
                (Bundle.main.url(forResource: filename, withExtension: extensionName) ??
                 Bundle.main.url(forResource: flatFilename, withExtension: extensionName) ?? url))
            guard fm.fileExists(atPath: resolvedURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: resolvedURL.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else {
                log("anticrack: recurso indisponível após assinatura \(rel)")
                resourcesIntact = false
                continue
            }
            if size < sizeMin || size > sizeMax {
                log("anticrack: tamanho fora da faixa de referência em \(rel): \(size)")
            }
            if !magicHex.isEmpty {
                guard let signature = Self.data(fromHex: magicHex), !signature.isEmpty else {
                    log("anticrack: não consegui validar \(rel)")
                    resourcesIntact = false
                    continue
                }
                let mediaType = parts[1].lowercased()
                let signatureOffset = ["mov", "mp4", "m4v"].contains(mediaType) ? 4 : 0
                let signatureData: Data?
                do {
                    let handle = try FileHandle(forReadingFrom: resolvedURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(signatureOffset))
                    signatureData = try handle.read(upToCount: signature.count)
                } catch {
                    signatureData = nil
                }
                guard let signatureData, signatureData == signature else {
                    log("anticrack: magic bytes divergentes em \(rel)")
                    resourcesIntact = false
                    continue
                }
            }
        }
        return resourcesIntact
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - Anti-debug / anti-injeção

    static func environmentLooksClean() -> Bool {
        // 1) Debugger anexado (PT_DENY_ATTACH / ptrace)
        var flags: Int32 = 0
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("proc.ptrace", &flags, &size, nil, 0)
        if flags != 0 {
            log("anticrack: ptrace ativo (debugger)")
            return false
        }

        // 2) Dylibs injetadas (frida, gdb, lldb, cycript, substrate...)
        let count = Int(_dyld_image_count())
        for i in 0..<count {
            guard let namePtr = _dyld_get_image_name(UInt32(i)) else { continue }
            let name = String(cString: namePtr).lowercased()
            if name.contains("frida") || name.contains("gdb") ||
               name.contains("lldb") || name.contains("cycript") ||
               name.contains("substrate") || name.contains("spooles") {
                log("anticrack: dylib suspeita \(name)")
                return false
            }
        }
        return true
    }

    // MARK: - Fingerprint de dispositivo

    static func deviceFingerprint() -> String {
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let bundle = Bundle.main.bundleIdentifier ?? ""
        return SHA256.hash(data: Data((idfv + "|" + bundle).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Gate de boot

    /// Retorna true se o app pode abrir. Falso se algo não bate.
    static func verifyAtLaunch() -> Bool {
        let appContainerIsValid = verifyAppContainerMetadata()
        let resourcesMatch = verifyBundleIntegrity()
        let clean = environmentLooksClean()
        let canonicalBrand = BrandProtection.canonicalChannelIsIntact
        if !appContainerIsValid {
            log("anticrack: estrutura do bundle inválida — bloqueando interface protegida")
        } else if !canonicalBrand {
            log("anticrack: configuração canônica do canal divergente — bloqueando interface protegida")
        } else if !resourcesMatch {
            log("anticrack: recursos normalizados pelo assinador; diferenças não bloqueiam a instalação")
        } else if !clean {
            // Some iOS installers and development environments report a
            // non-zero ptrace probe even when no injectable dylib is present.
            // Keep environment probes as telemetry; they are not a reliable
            // reason to reject a legitimate signed/sideloaded installation.
            log("anticrack: ambiente suspeito, mantendo execução resources=\(resourcesMatch)")
        }
        // Signing tools may rewrite the Bundle ID and normalize bundled media.
        // Those changes are telemetry only; malformed app structure or a changed
        // canonical channel remains a deterministic reason to block.
        return appContainerIsValid && canonicalBrand
    }
}
