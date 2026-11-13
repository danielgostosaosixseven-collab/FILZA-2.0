import Combine
import Foundation
import Security

@MainActor
final class LicenseManager: ObservableObject {

    @Published private(set) var expirationDate: Date?
    @Published private(set) var isLifetime = false
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var contactOwner: String?
    @Published private(set) var isLocked = false
    @Published private(set) var lockMessage: String?
    @Published private(set) var globalMessage: String?
    @Published private(set) var activeKeysCount: Int?
    @Published var rememberKey = true

    private let service = "com.apple.mobile.MobileHouseArrest.activation"
    private let keyAccount = "license-key"
    private let validKeyAccount = "license-key-valid"
    private let expirationAccount = "license-key-expiration"
    private let lifetimeAccount = "license-key-lifetime"
    private var lastAttemptAt: Date?

    init() {
        isActive = hasRememberedValidKey
        if let storedExpiration = string(for: expirationAccount) {
            expirationDate = Self.parseDate(storedExpiration)
        }
        isLifetime = string(for: lifetimeAccount) == "true"
    }

    /// True only if a previously validated key is stored AND marked valid.
    var hasRememberedValidKey: Bool {
        string(for: validKeyAccount) == "true"
    }

    func beginLaunchSession() {
        // Re-validate on every launch; don't trust stale local state alone.
        isActive = hasRememberedValidKey
        if isActive {
            message = "Ready to use"
            // Background re-check so we catch revoked keys
            Task { await revalidateStoredKey() }
        } else {
            message = "Key required — enter your access key"
        }
        // Remote kill-switch + global announcement (non-blocking)
        Task { await refreshRemoteState() }
        Task { await refreshActiveCount() }
    }

    func activate(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < 1 {
            message = "Please wait a moment before trying again"
            return
        }
        lastAttemptAt = Date()
        isBusy = true
        message = "Checking access key…"

        Task {
            let result = await FilzaLicense.validate(key: trimmed)
            await MainActor.run {
                self.isBusy = false
                if result.isTransientFailure {
                    // A captive portal, Wi-Fi transition, or temporary DNS/API
                    // outage is not a license revocation. Keep an already valid
                    // Keychain-backed session usable and do not overwrite it.
                    if self.isActive || self.hasRememberedValidKey {
                        self.isActive = true
                        self.message = "Conexión no disponible. La clave guardada fue mantenida."
                    } else {
                        self.message = result.message ?? "Conexión no disponible. Intenta nuevamente."
                    }
                } else if result.valid {
                    self.isActive = true
                    self.message = "Activated successfully"
                    if self.rememberKey {
                        self.save(trimmed, for: self.keyAccount)
                        self.save("true", for: self.validKeyAccount)
                    }
                    let explicitLifetime = result.lifetime == true || result.type?.lowercased() == "lifetime"
                    self.isLifetime = explicitLifetime
                    self.save(explicitLifetime ? "true" : "false", for: self.lifetimeAccount)
                    if let exp = result.expiresAt ?? result.expiration,
                       let date = Self.parseDate(exp), date > Date() {
                        self.expirationDate = date
                        self.isLifetime = false
                        self.save("false", for: self.lifetimeAccount)
                        self.save(exp, for: self.expirationAccount)
                    } else if explicitLifetime {
                        self.expirationDate = nil
                        self.delete(self.expirationAccount)
                    } else {
                        // A temporary key without a parseable expiration is not lifetime.
                        self.expirationDate = nil
                        self.isLifetime = false
                        self.save("false", for: self.lifetimeAccount)
                        self.delete(self.expirationAccount)
                    }
                } else {
                    self.isActive = false
                    self.expirationDate = nil
                    let msg = result.detail ?? result.message ?? "Invalid access key"
                    self.message = msg
                }
            }
        }
    }

    /// Re-validate the stored key in the background.
    private func revalidateStoredKey() async {
        guard let stored = string(for: keyAccount) else { return }
        let result = await FilzaLicense.validate(key: stored)
        await MainActor.run {
            if result.isTransientFailure {
                // Never delete a valid credential because Wi-Fi/DNS/API was
                // temporarily unavailable during the background re-check.
                if self.hasRememberedValidKey {
                    self.isActive = true
                    self.message = "Conexión no disponible. La clave guardada fue mantenida."
                }
            } else if !result.valid {
                // A definitive response means the server revoked/rejected the
                // key. Clear local activation so it cannot stay unlocked.
                self.deactivate()
                self.message = result.message ?? "Key revogada — insira uma nova key"
            } else {
                let explicitLifetime = result.lifetime == true || result.type?.lowercased() == "lifetime"
                if let exp = result.expiresAt ?? result.expiration,
                   let date = Self.parseDate(exp), date > Date() {
                    self.expirationDate = date
                    self.isLifetime = false
                    self.save("false", for: self.lifetimeAccount)
                    self.save(exp, for: self.expirationAccount)
                } else if explicitLifetime {
                    self.expirationDate = nil
                    self.isLifetime = true
                    self.save("true", for: self.lifetimeAccount)
                    self.delete(self.expirationAccount)
                } else {
                    self.expirationDate = nil
                    self.isLifetime = false
                    self.save("false", for: self.lifetimeAccount)
                    self.delete(self.expirationAccount)
                }
            }
        }
    }

    func rememberedKey() -> String? { string(for: keyAccount) }

    func refresh() {
        isActive = hasRememberedValidKey
        message = isActive ? "Ready to use" : "Key required — enter your access key"
    }

    func dismissGlobalMessage() {
        globalMessage = nil
    }

    func deactivate() {
        delete(keyAccount)
        delete(validKeyAccount)
        delete(expirationAccount)
        delete(lifetimeAccount)
        isActive = false
        expirationDate = nil
        isLifetime = false
        message = "Activation removed from this device"
    }

    /// Fetches the remote IPA lock and global message.
    func refreshRemoteState() async {
        async let lock = FilzaLicense.checkIpaLock()
        async let msg  = FilzaLicense.checkGlobalMessage()
        let (l, m) = await (lock, msg)
        await MainActor.run {
            if let l {
                self.isLocked = l.active
                self.lockMessage = l.message
            }
            if let m, m.msgId > 0 {
                self.globalMessage = m.message
            }
        }
    }

    /// Fetches the live count of active keys from the backend.
    func refreshActiveCount() async {
        if let key = rememberedKey(), !key.isEmpty {
            await FilzaLicense.sendOnlineHeartbeat(key: key)
        }
        guard let count = await FilzaLicense.fetchActiveKeysCount() else { return }
        await MainActor.run { self.activeKeysCount = count }
    }

    // MARK: - Keychain helpers

    private func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func parseDate(_ s: String) -> Date? {
        // Try ISO 8601 first, then a few common formats
        if let epoch = Double(s) {
            let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
            return Date(timeIntervalSince1970: seconds)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd"] {
            fmt.dateFormat = format
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }
}
