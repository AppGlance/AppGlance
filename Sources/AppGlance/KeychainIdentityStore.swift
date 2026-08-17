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
/// returning user is counted once, not twice. The item is `…ThisDeviceOnly`: it is not synced
/// through iCloud Keychain and a backup restored onto another device does not carry it, so a
/// second device mints its own id. The local mirror below is held to the same rule.
struct KeychainIdentityStore: IdentityStoring {
    let service: String
    let account: String
    /// A copy of the Keychain item, read only when the Keychain comes up empty, so a momentary
    /// Keychain failure cannot renumber this install as a new user.
    ///
    /// It lives in Caches, explicitly excluded from backup, and deliberately not in
    /// `UserDefaults`: preferences are inside the backup and inside a device-to-device transfer,
    /// so a mirror there travels to a new device, is read when the (correctly device-bound)
    /// Keychain item does not arrive with it, and is written back into the Keychain. The install
    /// id would then be shared by two devices that are both in use, and the `ThisDeviceOnly`
    /// attribute would mean nothing.
    let mirrorURL: URL?
    /// The preferences key an install set up by an earlier version still holds a copy of the id
    /// in. Cleared whenever the mirror is written, which is to say once an id is known for
    /// certain, so that copy stops riding along in backups. Never read: a preferences copy is
    /// exactly what carries the id onto a second device, and the Keychain item it duplicates is
    /// right there.
    private let retiredDefaultsMirrorKey = "app.appglance.anonymousUserID"

    init(service: String = "app.appglance", account: String = "anonymousUserID") {
        self.service = service
        self.account = account
        self.mirrorURL = Self.defaultMirrorURL(account: account)
    }

    /// Test seam: the mirror at a caller-chosen path, so its behaviour can be exercised without
    /// a Keychain (the test host has no entitlement for one).
    init(service: String, account: String, mirrorURL: URL?) {
        self.service = service
        self.account = account
        self.mirrorURL = mirrorURL
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
            // Also the migration path for an install whose mirror is still the retired
            // preferences one: the Keychain answers, and the copy moves to a place a backup
            // leaves behind.
            writeMirror(string)
            return .found(string)
        }
        if let mirrored = readMirror(), !mirrored.isEmpty {
            if status == errSecItemNotFound { keychainWrite(mirrored) }  // heal the Keychain from the mirror
            writeMirror(mirrored)  // a no-op for the file itself; clears the retired copy
            return .found(mirrored)
        }
        // Locked device: the item may well be there, it just cannot be read yet. Any answer
        // invented now would be a second user.
        if status == errSecInteractionNotAllowed { return .unavailable }
        return .absent
    }

    func save(_ value: String) {
        keychainWrite(value)
        writeMirror(value)
    }

    /// Beside the event queue, in Caches: not backed up by iOS, and excluded from backup
    /// explicitly for the platforms where that directory is.
    private static func defaultMirrorURL(account: String) -> URL? {
        let safeAccount = account.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("appglance-\(safeAccount)")
    }

    func readMirror() -> String? {
        guard let mirrorURL, let data = try? Data(contentsOf: mirrorURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeMirror(_ value: String) {
        if UserDefaults.standard.object(forKey: retiredDefaultsMirrorKey) != nil {
            UserDefaults.standard.removeObject(forKey: retiredDefaultsMirrorKey)
        }
        guard var mirrorURL, readMirror() != value else { return }
        try? Data(value.utf8).write(to: mirrorURL, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mirrorURL.setResourceValues(values)
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
