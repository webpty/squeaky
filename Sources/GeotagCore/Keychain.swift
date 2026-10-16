import Foundation
import Security

/// Where secrets live. The app's only one so far is the track service key.
public protocol SecretStorePort: Sendable {
    func read(_ account: String) -> String?
    func write(_ account: String, _ value: String) throws
}

public struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The keychain refused: \(text)."
    }
}

/// The login keychain, one generic password per account.
public struct Keychain: SecretStorePort {
    let service: String

    public init(service: String = "com.webpty.geotag") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the value in place, so the item is never removed.
    public func write(_ account: String, _ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}
