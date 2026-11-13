// AirLiftPairingStore.swift
// Persistência do arquivo de emparelhamento (pairing) no Keychain.
// O arquivo .mobiledevicepairing vem da conclusão do pairable-host ou da
// importação manual e é persistido para reutilizar nas sessões seguintes.

import Foundation
import Security

final class AirLiftPairingStore {
    static let shared = AirLiftPairingStore()

    private let service = "com.apple.mobile.MobileHouseArrest.airlift"
    private let pairingKey = "airlift.pairing.file"
    private let pinKey = "airlift.pairing.pin"
    private let hostAltIRKKey = "airlift.pairing.host_alt_irk"

    private init() {}

    // MARK: - Pairing file (binary plist / .mobiledevicepairing)

    func savePairingFile(_ data: Data, hostAltIRK: Data? = nil) -> Bool {
        if let hostAltIRK, hostAltIRK.count != 16 {
            log("airlift: rejected host altIRK with unexpected length \(hostAltIRK.count)")
            return false
        }
        let status = upsert(data, account: pairingKey)
        if status != errSecSuccess {
            log("airlift: Keychain save pairing file failed: \(status)")
            return false
        }
        if let hostAltIRK {
            let irkStatus = upsert(hostAltIRK, account: hostAltIRKKey)
            if irkStatus != errSecSuccess {
                log("airlift: Keychain save host altIRK failed: \(irkStatus)")
                return false
            }
        }
        log("airlift: pairing file saved to Keychain (\(data.count) bytes)")
        return true
    }

    private func upsert(_ data: Data, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        return addStatus
    }

    func loadPairingFile() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pairingKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            log("airlift: no pairing file in Keychain (status=\(status))")
            return nil
        }
        log("airlift: pairing file loaded from Keychain (\(data.count) bytes)")
        return data
    }

    func deletePairingFile() {
        for account in [pairingKey, hostAltIRKKey] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
        log("airlift: pairing file and host altIRK deleted from Keychain")
    }

    func loadHostAltIRK() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostAltIRKKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 16 else { return nil }
        return data
    }

    var hasPairingFile: Bool {
        loadPairingFile() != nil
    }

    // Pairing bytes intentionally survive app reinstalls. This marker does not:
    // it makes recovery UI appear only after this installation confirmed a connection.
    private let confirmedConnectionKey = "pairing.confirmed.connection.this.installation"
    private let pairingRecoveryKey = "pairing.reset.recovery.available.after.pairing"

    var hasConfirmedConnectionForThisInstallation: Bool {
        UserDefaults.standard.bool(forKey: confirmedConnectionKey)
    }

    /// Once a device that was natively unsupported has paired successfully,
    /// keep the reset control available after the pairing is cleared.
    var hasPersistentResetRecoveryAfterPairing: Bool {
        UserDefaults.standard.bool(forKey: pairingRecoveryKey) ||
        UserDefaults.standard.bool(forKey: "pairing.reset.recovery.available.ios27")
    }

    func markConnectionConfirmedForThisInstallation() {
        UserDefaults.standard.set(true, forKey: confirmedConnectionKey)
        let v = AppInfo.versionTuple
        if !ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        ) {
            UserDefaults.standard.set(true, forKey: pairingRecoveryKey)
        }
    }

    func clearConnectionConfirmationForThisInstallation() {
        UserDefaults.standard.removeObject(forKey: confirmedConnectionKey)
        // Do not clear iOS27RecoveryKey: the reset control must remain visible.
    }

    // MARK: - PIN (optional, for re-pairing reference)

    func savePIN(_ pin: String) {
        let data = Data(pin.utf8)
        let status = upsert(data, account: pinKey)
        if status != errSecSuccess {
            log("airlift: Keychain save PIN failed: \(status)")
        }
    }

    func loadPIN() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pinKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Temp file for FFI (rp_pairing_file_read expects a path)

    /// Writes the pairing data to a temp file and returns the path.
    /// The caller is responsible for deleting it after use.
    func tempFilePath(for data: Data) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "airlift_pairing_\(UUID().uuidString).mobiledevicepairing"
        let path = tempDir.appendingPathComponent(fileName).path
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            log("airlift: failed to write temp pairing file: \(error)")
            return nil
        }
    }
}
