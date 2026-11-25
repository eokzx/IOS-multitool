import Foundation
import Security

enum Keychain {
    private static let service = "com.multitool.secrets"

    enum Account {
        static func password(_ id: UUID) -> String { "password.\(id.uuidString)" }
        static func privateKey(_ id: UUID) -> String { "key.\(id.uuidString)" }
        static let tailscaleAPIKey = "tailscale.apikey"
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    static func setString(_ value: String?, for account: String) {
        if let value, !value.isEmpty {
            set(Data(value.utf8), for: account)
        } else {
            delete(account)
        }
    }

    static func string(for account: String) -> String? {
        guard let data = data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
