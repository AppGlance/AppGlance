import Foundation
import Security

/// What an identity store found.
enum IdentityLookup: Equatable {
    case found(String)
    /// Nothing stored: a fresh install. Mint an id.
    case absent
    /// The store exists but cannot be read at this moment (the Keychain before the first unlock
    /// after a reboot). Do not mint - try again later.
    case unavailable
}

/// Where the install id is kept. A protocol so tests can inject an in-memory store.
protocol IdentityStoring: Sendable {
    func lookup() -> IdentityLookup
    func save(_ value: String)
}

/// Keeps the install id in the Keychain, which survives deleting and reinstalling the app - so a
/// returning user is counted once, not twice. The item is `…ThisDeviceOnly`: never synced through
/// iCloud Keychain, never restored to another device.
struct KeychainIdentityStore: IdentityStoring {
    let service: String
    let account: String
    /// A `UserDefaults` copy of the Keychain item, read only when the Keychain comes up empty, so
    /// a momentary Keychain failure cannot renumber this install as a new user.
    private let defaultsMirrorKey = "app.appglance.anonymousUserID"

    init(service: String = "app.appglance", account: String = "anonymousUserID") {
        self.service = service
        self.account = account
    }

    func lookup() -> IdentityLookup {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
            let string = String(data: data, encoding: .utf8), !string.isEmpty
        {
            return .found(string)
        }
        if let mirrored = UserDefaults.standard.string(forKey: defaultsMirrorKey), !mirrored.isEmpty {
            if status == errSecItemNotFound { keychainWrite(mirrored) }  // heal the Keychain from the mirror
            return .found(mirrored)
        }
        // Locked device: the item may well be there, it just cannot be read yet. Any answer
        // invented now would be a second user.
        if status == errSecInteractionNotAllowed { return .unavailable }
        return .absent
    }

    func save(_ value: String) {
        keychainWrite(value)
        UserDefaults.standard.set(value, forKey: defaultsMirrorKey)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainWrite(_ value: String) {
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }
}
