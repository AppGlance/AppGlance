import Foundation
import Security
import XCTest

@testable import AppGlance

final class IdentityTests: XCTestCase {

    func testAnonymousIdentityIsStableAndNewExactlyOnce() throws {
        let store = InMemoryIdentityStore()
        let first = try XCTUnwrap(AnonymousIdentity.current(store: store))
        let second = try XCTUnwrap(AnonymousIdentity.current(store: store))
        XCTAssertEqual(first.id, second.id, "the id must be stable for an install")
        XCTAssertFalse(first.id.isEmpty)
        XCTAssertTrue(first.isNew, "the minting call is the install moment")
        XCTAssertFalse(second.isNew, "only the minting call may report a new install")
    }

    /// A store that answers "nothing here" and then keeps nothing: an unentitled Mac build whose
    /// Caches mirror cannot be written either. Every launch mints, and if every launch also
    /// reported a new install the dashboard would show one device as an unbounded stream of
    /// users, each with its own `install` and its own id - nothing the server can collapse.
    func testAnIDTheStoreDidNotKeepIsNotReportedAsANewInstall() throws {
        let refusing = InMemoryIdentityStore(refusesWrites: true)
        let first = try XCTUnwrap(AnonymousIdentity.current(store: refusing))
        XCTAssertFalse(first.id.isEmpty, "the run still has an id to stamp its events with")
        XCTAssertFalse(first.isNew, "but it is not an install, because nothing kept it")

        let second = try XCTUnwrap(AnonymousIdentity.current(store: refusing))
        XCTAssertFalse(second.isNew, "and the next launch does not record one either")
    }

    func testDifferentStoresMintDifferentIDs() {
        XCTAssertNotEqual(
            AnonymousIdentity.current(store: InMemoryIdentityStore())?.id,
            AnonymousIdentity.current(store: InMemoryIdentityStore())?.id)
    }

    func testPersistedIDIsReusedAndAReinstallIsNotANewInstall() throws {
        let store = InMemoryIdentityStore("EXISTING-ID")
        let identity = try XCTUnwrap(AnonymousIdentity.current(store: store))
        XCTAssertEqual(identity.id, "EXISTING-ID")
        XCTAssertFalse(identity.isNew, "a reinstall must not look like a new install")
    }

    /// The Keychain item is `…ThisDeviceOnly`, so the copy that backs it up has to be too: a
    /// mirror inside the app's preferences travels with an iCloud restore or a device-to-device
    /// transfer, is read on the new device because the Keychain item correctly did not travel,
    /// and is written back - two devices, one install id. The mirror therefore lives in a file
    /// that is marked excluded from backup, and the preferences key it used to occupy is cleared
    /// on the way past, so an existing install stops carrying a copy of its id in backups.
    func testTheInstallIDMirrorIsKeptOutOfBackupsAndOutOfUserDefaults() throws {
        let mirrorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("appglance-mirror-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: mirrorURL) }
        let retiredKey = "app.appglance.anonymousUserID"
        UserDefaults.standard.set("ID-FROM-AN-OLDER-SDK", forKey: retiredKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: retiredKey) }

        let store = KeychainIdentityStore(service: "app.appglance.test", account: "test", mirrorURL: mirrorURL)
        store.writeMirror("INSTALL-ID")

        XCTAssertEqual(store.readMirror(), "INSTALL-ID", "the fallback is still there for a Keychain that hiccups")
        let excluded = try mirrorURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "a backup must not carry the install id to a second device")
        XCTAssertNil(
            UserDefaults.standard.string(forKey: retiredKey),
            "and the copy an older SDK left in preferences, which backups do carry, is cleared")
    }

    /// Marking the mirror is a separate call from writing it, and its failure is silent. If the
    /// exclusion were only attempted when the contents change, one failure would be permanent:
    /// every later write finds the same id already there and returns, so the file sits inside the
    /// backup set for the life of the install and carries the id to the next device.
    func testTheMirrorIsPutBackOutOfBackupsEvenWhenItsContentsHaveNotChanged() throws {
        let mirrorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("appglance-mirror-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: mirrorURL) }
        let store = KeychainIdentityStore(service: "app.appglance.test", account: "test", mirrorURL: mirrorURL)
        store.writeMirror("INSTALL-ID")

        // The state a failed `setResourceValues` leaves: the right id, in the backup.
        var cleared = URLResourceValues()
        cleared.isExcludedFromBackup = false
        var mutable = mirrorURL
        try mutable.setResourceValues(cleared)
        XCTAssertEqual(
            try mirrorURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)

        store.writeMirror("INSTALL-ID")  // the same id: nothing to write, something to fix

        XCTAssertEqual(
            try mirrorURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
            "the id must not be left riding along in backups because the file already held it")
    }

    /// The one line that decides which keychain macOS uses. Everything above it is policy; this is
    /// the fact the policy stands on, and on every other platform there is no choice to make.
    func testTheKeychainQueryNamesTheKeychainOnMacAndIsUntouchedElsewhere() {
        let bound = SecurityKeychain.baseQuery(service: "s", account: "a", scope: .dataProtection)
        #if os(macOS)
        let login = SecurityKeychain.baseQuery(service: "s", account: "a", scope: .legacy)
        XCTAssertEqual(
            bound[kSecUseDataProtectionKeychain as String] as? Bool, true,
            "the login keychain ignores kSecAttrAccessible, so the device binding lives in the other one")
        XCTAssertEqual(login[kSecUseDataProtectionKeychain as String] as? Bool, false)
        #else
        XCTAssertNil(
            bound[kSecUseDataProtectionKeychain as String],
            "one keychain, and it ignores the key: the query is the one this SDK has always sent")
        XCTAssertEqual(bound.count, 3, "class, service, account, and nothing else")
        #endif
    }

    /// The one attribute the whole device-binding design rests on, and the other half of the fact
    /// the policy above stands on. Without `ThisDeviceOnly` the item is carried by an encrypted
    /// backup and by device-to-device transfer, so a restored or transferred handset reads the
    /// original device's install id: two devices in use at once reporting as one install, with
    /// their user properties landing on the same page.
    func testTheInstallIDIsStoredWithTheAttributeThatKeepsItOnThisDevice() {
        let insert = SecurityKeychain.insertQuery("INSTALL-ID", service: "s", account: "a", scope: .dataProtection)

        XCTAssertEqual(
            insert[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "a backup or a transfer must find nothing here, so the next device mints an id of its own")
        XCTAssertNotEqual(
            insert[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String,
            "the same item without the device binding is one that travels")
        XCTAssertEqual(insert[kSecValueData as String] as? Data, Data("INSTALL-ID".utf8))
    }

    /// A new install's id goes where the device binding holds. The login keychain is somewhere the
    /// SDK reads, never somewhere it chooses.
    func testANewInstallIDIsWrittenToTheKeychainThatHonoursTheDeviceBinding() {
        let keychain = FakeKeychain()
        let store = KeychainIdentityStore(
            service: "app.appglance.test", account: "test", mirrorURL: nil, keychain: keychain)

        store.save("MINTED-ID")

        XCTAssertEqual(keychain.item(.dataProtection), "MINTED-ID")
        XCTAssertNil(keychain.item(.legacy))
    }

    #if os(macOS)
    /// An install set up by an earlier version of the SDK keeps its id in the login keychain,
    /// which Migration Assistant and a Time Machine restore copy onto the next Mac verbatim.
    /// Naming the other keychain would hide that id, and a hidden id is a second install for a
    /// Mac that already had one: it has to move across, and it has to leave nothing behind.
    func testTheMacInstallIDMovesToTheKeychainThatHonoursTheDeviceBinding() {
        let keychain = FakeKeychain([.legacy: "INSTALL-ID"])
        let store = KeychainIdentityStore(
            service: "app.appglance.test", account: "test", mirrorURL: nil, keychain: keychain)

        XCTAssertEqual(store.lookup(), .found("INSTALL-ID"), "the same install, not a new one")
        XCTAssertEqual(keychain.item(.dataProtection), "INSTALL-ID", "now where the binding holds")
        XCTAssertNil(keychain.item(.legacy), "and gone from the keychain a migration would copy")
        XCTAssertEqual(store.lookup(), .found("INSTALL-ID"), "and the same again on every launch after")
    }

    /// The migration's failure: a build that cannot reach the data protection keychain at all,
    /// an app signed without the entitlement that grants a keychain access group. The id must
    /// survive unchanged, and the only copy of it that exists must stay where the next launch
    /// will find it.
    func testAFailedMigrationKeepsTheLegacyItemAndTheSameID() {
        let keychain = FakeKeychain([.legacy: "INSTALL-ID"], unwritable: [.dataProtection])
        let store = KeychainIdentityStore(
            service: "app.appglance.test", account: "test", mirrorURL: nil, keychain: keychain)

        XCTAssertEqual(store.lookup(), .found("INSTALL-ID"), "a failed move is not a new install")
        XCTAssertEqual(keychain.item(.legacy), "INSTALL-ID", "the only copy there is stays where it is")
        XCTAssertNil(keychain.item(.dataProtection))
        XCTAssertTrue(keychain.deletes().isEmpty, "nothing is removed before its replacement exists")
    }

    /// The same build minting an id instead of carrying one over: no entitlement, so the write to
    /// the data protection keychain fails. The id has to land in the login keychain anyway. The
    /// device binding is inert there, which makes it the weaker of the two homes and still a
    /// durable one, and the alternative is an install whose only copy is the Caches mirror - a
    /// directory the system may reclaim, renumbering the install and taking everything the
    /// dashboard knows about that person with it.
    func testAMacBuildThatCannotReachTheBoundKeychainStillKeepsTheNewID() {
        let keychain = FakeKeychain(unwritable: [.dataProtection])
        let store = KeychainIdentityStore(
            service: "app.appglance.test", account: "test", mirrorURL: nil, keychain: keychain)

        store.save("MINTED-ID")

        XCTAssertEqual(keychain.item(.legacy), "MINTED-ID", "somewhere the next launch will find it")
        XCTAssertNil(keychain.item(.dataProtection))
        XCTAssertEqual(
            keychain.writes(), [.dataProtection, .legacy],
            "and in that order: the login keychain is where the id falls back to, never where it is aimed")
    }
    #endif

    /// The id is device-bound - a `ThisDeviceOnly` Keychain item, mirrored outside the backup -
    /// but the session, the presence stamps and the user properties beside it are in
    /// `UserDefaults`, which an iCloud or encrypted backup and a device-to-device transfer all
    /// carry. The restored handset correctly mints its own id; it must not then read the old
    /// device's state as its own, or it opens no session of its own and never sends the
    /// properties its install page is waiting for.
    func testANewInstallIDDoesNotInheritTheStateATransferCarriedOver() async throws {
        let id = "test.identity.restore"
        TestSupport.fresh(id)
        addTeardownBlock { TestSupport.fresh(id) }
        let session = TestSupport.recordingSession()
        let clock = TestClock()

        let a = Client(
            config: TestSupport.configuration(appID: id), userID: "install-A", session: session,
            now: { clock.now })
        await a.setActive(true)
        await a.identify([UserProperty.email: "ada@example.com"])
        await a.flush()
        let sessionA = await a.currentSessionID()
        await a.shutdown()

        // The queue file is not part of this: it lives in Caches, which is not backed up, so it
        // never arrives on the second device. `UserDefaults` does. The transfer lands and the app
        // is opened a minute later - inside the session timeout, so the old device's session would
        // still look resumable.
        RecordingProtocol.reset()
        clock.advance(60)
        let b = Client(
            config: TestSupport.configuration(appID: id), userID: "install-B", isNewInstall: true,
            session: session, now: { clock.now })
        await b.recordInstallIfNeeded()
        let traits = await b.currentTraits()
        XCTAssertEqual(traits, [:], "the new install starts with no properties of its own")
        let sessionB = await b.currentSessionID()
        XCTAssertNotEqual(sessionB, sessionA, "and does not continue the old device's session")

        await b.setActive(true)
        await b.identify([UserProperty.email: "ada@example.com"])
        await b.flush()
        XCTAssertEqual(
            RecordingProtocol.signals(), [Signal.install, Signal.sessionStart, Signal.identify],
            "so its first visit is a session of its own, and its properties reach the server")
    }

    /// The Keychain is unreadable before the first unlock after a reboot - exactly when a
    /// background launch can happen. Minting there would create a phantom second user.
    func testLockedStoreDoesNotMintAnIdentity() throws {
        let locked = InMemoryIdentityStore("REAL-ID", locked: true)
        XCTAssertNil(AnonymousIdentity.current(store: locked), "no answer beats a wrong one")
        let unlocked = InMemoryIdentityStore("REAL-ID")
        XCTAssertEqual(AnonymousIdentity.current(store: unlocked)?.id, "REAL-ID")
        XCTAssertEqual(AnonymousIdentity.current(store: unlocked)?.isNew, false)
    }

    /// The environment gate excludes Debug and the Simulator by default, and an app waiting for
    /// consent configures with `isEnabled: false`, so the launch that mints the install id is very
    /// often one that can record nothing. `isNewInstall` is true on that launch only, so the debt
    /// has to outlive it: otherwise every later launch finds the stored id, records nothing, and
    /// the install never appears in the dashboard at all.
    func testAGatedFirstLaunchStillRecordsTheInstallOnTheFirstLaunchThatCollects() async throws {
        let appID = "install.gated.first.launch"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let session = TestSupport.recordingSession()

        let gated = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: []),
            userID: "install-1", isNewInstall: true, session: session)
        await gated.recordInstallIfNeeded()
        let whileGated = await gated.pendingSignals()
        XCTAssertEqual(whileGated, [], "a gated client records nothing")
        await gated.shutdown()

        // The next launch is the App Store build: the id is already stored, so `isNewInstall` is
        // false, and only the note left on disk can say that an install is still owed.
        let sending = Client(
            config: TestSupport.configuration(appID: appID), userID: "install-1", session: session)
        await sending.recordInstallIfNeeded()
        let recorded = await sending.pendingSignals()
        XCTAssertEqual(recorded, [Signal.install], "the install the gated launch could not record")
        await sending.flush()
        await sending.shutdown()

        // And exactly once: the debt is paid, so a third launch owes nothing.
        let later = Client(
            config: TestSupport.configuration(appID: appID), userID: "install-1", session: session)
        await later.recordInstallIfNeeded()
        let afterwards = await later.pendingSignals()
        XCTAssertEqual(afterwards, [], "and never a second time")
    }
}
