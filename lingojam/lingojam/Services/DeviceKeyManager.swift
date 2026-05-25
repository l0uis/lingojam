import Foundation
import Security

/// Generates and persists a stable per-install device ID in the iOS
/// Keychain. The walrus proxy uses it as an anti-abuse identifier — no
/// user accounts, no PII, just a UUID that survives app updates and
/// reinstalls (until the user deletes the app and reinstalls AND
/// chooses not to restore from backup).
enum DeviceKeyManager {
    private static let service = "lingojam.walrus.proxy"
    private static let account = "device-id"

    /// Returns the existing device ID, or generates and stores a new one
    /// on first call. Idempotent.
    static func deviceID() -> String {
        if let existing = readKeychain() {
            return existing
        }
        let id = UUID().uuidString
        _ = writeKeychain(id)
        return id
    }

    private static func readKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    private static func writeKeychain(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery()
        query[kSecValueData as String] = data
        // Available after first unlock, persists across backups within
        // the same device (kSecAttrAccessibleAfterFirstUnlock).
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        // Try add; if it already exists update instead.
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            let updateQuery = baseQuery() as CFDictionary
            let updates: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(updateQuery, updates as CFDictionary)
            return updateStatus == errSecSuccess
        }
        return false
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
