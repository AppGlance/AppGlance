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

/// Which of a Mac's two keychains an item is asked for. A query gets the file-based login
/// keychain unless it says otherwise, and there `kSecAttrAccessible` is documented as having no
/// effect: the `…ThisDeviceOnly` attribute the install id is written with means nothing, and
/// Migration Assistant and a Time Machine restore copy that keychain onto the next Mac verbatim -
/// two machines in use at once, reporting as one install. The data protection keychain is the one
/// that honours the attribute. Every other Apple platform has only that keychain and ignores the
/// key, so `legacy` is a macOS concept and is asked for nowhere else.
enum KeychainScope {
    case dataProtection
    case legacy
}

/// The Security-framework calls the store makes, behind a seam: a test host has no entitlement for
/// a keychain of either kind, and the migration in `lookup()` is the part that must not be wrong.
protocol KeychainAccess: Sendable {
    func read(service: String, account: String, scope: KeychainScope) -> IdentityLookup
    /// True once the value is stored. False means this build cannot reach that keychain: on macOS
    /// the data protection keychain needs the entitlement that grants a keychain access group,
    /// which an app signed without a provisioning profile does not have.
    func write(_ value: String, service: String, account: String, scope: KeychainScope) -> Bool
    func delete(service: String, account: String, scope: KeychainScope)
}

/// The Keychain itself.
struct SecurityKeychain: KeychainAccess {

    func read(service: String, account: String, scope: KeychainScope) -> IdentityLookup {
        var query = Self.baseQuery(service: service, account: account, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
            let string = String(data: data, encoding: .utf8), !string.isEmpty
        {
            return .found(string)
        }
        // Locked device: the item may well be there, it just cannot be read yet. Any answer
        // invented now would be a second user.
        if status == errSecInteractionNotAllowed { return .unavailable }
        return .absent
    }

    func write(_ value: String, service: String, account: String, scope: KeychainScope) -> Bool {
        SecItemDelete(Self.baseQuery(service: service, account: account, scope: scope) as CFDictionary)
        let insert = Self.insertQuery(value, service: service, account: account, scope: scope)
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// The item as it is stored. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the whole
    /// of the device binding: `ThisDeviceOnly` is what keeps the item out of an encrypted backup
    /// and out of a device-to-device transfer, so a restored or transferred handset finds nothing
    /// and mints an install id of its own rather than reporting as the machine it came from.
    /// Alongside `baseQuery` because it is a fact worth being able to look at, for the same
    /// reason: everything above it is policy, and these two are what the policy stands on.
    static func insertQuery(
        _ value: String, service: String, account: String, scope: KeychainScope
    ) -> [String: Any] {
        var insert = baseQuery(service: service, account: account, scope: scope)
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return insert
    }

    func delete(service: String, account: String, scope: KeychainScope) {
        SecItemDelete(Self.baseQuery(service: service, account: account, scope: scope) as CFDictionary)
    }

    /// The item's address. The keychain is named only where there is a choice of one; elsewhere
    /// the key is ignored and this is the query the SDK has always sent.
    static func baseQuery(service: String, account: String, scope: KeychainScope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = (scope == .dataProtection)
        #endif
        return query
    }
}

/// Keeps the install id in the Keychain, which survives deleting and reinstalling the app - so a
/// returning user is counted once, not twice. The item is `…ThisDeviceOnly`: it is not synced
/// through iCloud Keychain and a backup restored onto another device does not carry it, so a
/// second device mints its own id. The local mirror below is held to the same rule.
struct KeychainIdentityStore: IdentityStoring {
    let service: String
    let account: String
    let keychain: KeychainAccess
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

    init(
        service: String = "app.appglance", account: String = "anonymousUserID",
        keychain: KeychainAccess = SecurityKeychain()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
        self.mirrorURL = Self.defaultMirrorURL(account: account)
    }

    /// Test seam: the mirror at a caller-chosen path and a keychain of the caller's choosing, so
    /// both can be exercised without a real one (the test host has no entitlement for a Keychain).
    init(
        service: String, account: String, mirrorURL: URL?,
        keychain: KeychainAccess = SecurityKeychain()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
        self.mirrorURL = mirrorURL
    }

    func lookup() -> IdentityLookup {
        let stored = keychain.read(service: service, account: account, scope: .dataProtection)
        if case .found(let id) = stored {
            // Also the migration path for an install whose mirror is still the retired
            // preferences one: the Keychain answers, and the copy moves to a place a backup
            // leaves behind.
            writeMirror(id)
            return .found(id)
        }
        #if os(macOS)
        // An install set up by an earlier version of the SDK keeps its id in the login
        // keychain, where the device binding does not hold. The id moves across; it is not
        // re-minted, because this is the same install and a fresh id here would count one Mac
        // as two. The old item goes only once its replacement is written: a build that cannot
        // reach the data protection keychain at all then leaves it exactly where the next
        // launch will find it, and nothing is ever deleted that has not been written
        // somewhere else first.
        if case .found(let carried) = keychain.read(service: service, account: account, scope: .legacy) {
            if keychain.write(carried, service: service, account: account, scope: .dataProtection) {
                keychain.delete(service: service, account: account, scope: .legacy)
            }
            writeMirror(carried)
            return .found(carried)
        }
        #endif
        if let mirrored = readMirror(), !mirrored.isEmpty {
            if case .absent = stored { keychainWrite(mirrored) }  // heal the Keychain from the mirror
            writeMirror(mirrored)  // a no-op for the file itself; clears the retired copy
            return .found(mirrored)
        }
        // Locked device: the item may well be there, it just cannot be read yet. Any answer
        // invented now would be a second user.
        if case .unavailable = stored { return .unavailable }
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
        guard var mirrorURL else { return }
        if readMirror() != value {
            try? Data(value.utf8).write(to: mirrorURL, options: .atomic)
        }
        // Checked on every pass rather than only when the contents change. The exclusion is a
        // separate call from the write and its failure is invisible, and once the file holds the
        // right id nothing would ever look again: the id would sit inside the backup set for the
        // life of the install, travel to a second device, be read there because the Keychain item
        // correctly did not travel, and be written back - the one thing this file exists to stop.
        let excluded = try? mirrorURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        guard excluded != true else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mirrorURL.setResourceValues(values)
    }

    /// Stores the id where the device binding holds. On macOS a build that cannot reach that
    /// keychain falls back to the login one: the binding is inert there, which makes it the weaker
    /// of the two homes and still a durable one, and the alternative is an install whose only copy
    /// is the Caches mirror - a directory the system may reclaim, taking the id and everything the
    /// dashboard knows about that person with it.
    @discardableResult
    private func keychainWrite(_ value: String) -> Bool {
        if keychain.write(value, service: service, account: account, scope: .dataProtection) { return true }
        #if os(macOS)
        return keychain.write(value, service: service, account: account, scope: .legacy)
        #else
        return false
        #endif
    }
}
