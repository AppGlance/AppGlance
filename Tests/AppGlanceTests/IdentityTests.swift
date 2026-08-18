import Foundation
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
}
