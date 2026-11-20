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
        let text = SecCopyErrorMessageString(status, nil) as String? ?? Words.t("error {0}", status)
        return Words.t("The keychain refused: {0}.", text)
    }
}

/// The login keychain, one generic password per account.
public struct Keychain: SecretStorePort {
    let service: String

    public init(service: String = "com.webpty.squeaky") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The accounts kept under this service, by name: no secret is read.
    public func accounts() -> [String] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let list = out as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
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
        var change: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        // Readable once the phone has been unlocked after starting: Squeaky woken
        // with the phone locked hands the next photos to the buffer server (0.30.0).
        change[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemUpdate(query(account) as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(change) { $1 }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}
