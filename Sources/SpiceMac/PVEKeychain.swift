// SPDX-License-Identifier: MIT
import Foundation
import Security

/// Keychain storage for Proxmox secrets (API token secrets and passwords).
///
/// Secrets never go into `UserDefaults` — only the non-secret half of a profile does.
/// Items are stored per server+account so several clusters, or several tokens on one
/// cluster, can coexist.
enum PVEKeychain {
    private static let service = "SpiceMac.ProxmoxVE"

    /// Stable per-credential key: `host:port|user@realm[!token]`.
    static func account(host: String, port: Int, user: String) -> String {
        "\(host):\(port)|\(user)"
    }

    @discardableResult
    static func save(secret: String, account: String) -> Bool {
        guard secret.isEmpty == false else { return delete(account: account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            // Available after first unlock so a reconnect works without re-prompting,
            // but never synced to iCloud or included in a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func secret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
