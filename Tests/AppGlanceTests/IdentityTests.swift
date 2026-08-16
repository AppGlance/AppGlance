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
