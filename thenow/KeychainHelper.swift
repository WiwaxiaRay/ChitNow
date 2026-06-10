import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.wangyang.thenow"

    static var brokerURL:       String? { read(key: "brokerURL") }
    static var apiKey:          String? { read(key: "apiKey") }
    static var certFingerprint: String? { read(key: "certFingerprint") }

    static func save(brokerURL: String, apiKey: String, certFingerprint: String) {
        set(key: "brokerURL",       value: brokerURL)
        set(key: "apiKey",          value: apiKey)
        set(key: "certFingerprint", value: certFingerprint)
    }

    static func clear() {
        delete(key: "brokerURL")
        delete(key: "apiKey")
        delete(key: "certFingerprint")
    }

    static var isConfigured: Bool {
        brokerURL != nil && apiKey != nil && certFingerprint != nil
    }

    private static func set(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func read(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
