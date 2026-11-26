import Foundation
#if canImport(Security)
import Security
#endif

/// Stores the Apple ID password in the login Keychain, so it never sits in a file or in UserDefaults.
/// The app and the command-line tool share the same item. On platforms without a Keychain it stores nothing.
public enum Keychain {
    public static let service = "ICloudPhotos.AppleID"
    /// The item the Immich API key is kept under.
    public static let immichService = "ICloudPhotos.Immich"

    public static func password(for account: String, service: String = Keychain.service) -> String? {
        #if canImport(Security)
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
        #else
        return nil
        #endif
    }

    public static func save(_ password: String, for account: String, service: String = Keychain.service) {
        #if canImport(Security)
        delete(account, service: service)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
        #endif
    }

    public static func delete(_ account: String, service: String = Keychain.service) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
