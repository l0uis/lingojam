import Foundation
import Security

/// Generates and persists a stable per-user device ID in the iOS Keychain.
/// The walrus proxy uses it as an anti-abuse identifier and as the key for the
/// per-device word backup — no user accounts, no PII, just a UUID.
///
/// The item is stored **iCloud-synchronizable**, so the ID follows the user's
/// Apple ID across devices (via iCloud Keychain). That means a new phone gets
/// the same ID and the user's backed-up words restore there; it also survives
/// app update / delete / reinstall on the same device. When iCloud Keychain is
/// off the item is simply kept locally instead.
enum DeviceKeyManager {
    private static let service = "wordrus.walrus.proxy"
    private static let account = "device-id"

    /// Returns the existing device ID, or generates and stores a new one on
    /// first call. Idempotent.
    static func deviceID() -> String {
        // Prefer the iCloud-synced item so the ID follows the user to new
        // devices and the server word-backup restores there.
        if let synced = readKeychain(synced: true) {
            return synced
        }
        // Migrate a legacy device-local ID into the synced keychain so existing
        // users keep their ID — and therefore their backed-up words.
        if let legacy = readKeychain(synced: false) {
            _ = writeKeychain(legacy, synced: true)
            return legacy
        }
        let id = UUID().uuidString
        _ = writeKeychain(id, synced: true)
        return id
    }

    private static func readKeychain(synced: Bool) -> String? {
        var query = baseQuery(synced: synced)
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
    private static func writeKeychain(_ value: String, synced: Bool) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery(synced: synced)
        query[kSecValueData as String] = data
        // AfterFirstUnlock (not a "ThisDeviceOnly" variant) is required for an
        // item to be eligible for iCloud Keychain sync.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            let updates: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(synced: synced) as CFDictionary, updates as CFDictionary)
            return updateStatus == errSecSuccess
        }
        return false
    }

    private static func baseQuery(synced: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synced,
        ]
    }
}
