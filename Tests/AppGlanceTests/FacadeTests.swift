import XCTest

@testable import AppGlance

/// The public `AppGlance` facade: calls apply in call order, `install` comes first, calls made
/// before `configure` are held and replayed, and a second `configure` replaces the client cleanly.
final class FacadeTests: XCTestCase {

    private func configure(_ appID: String, store: InMemoryIdentityStore) {
        AppGlance.configure(
            TestSupport.configuration(appID: appID), identityStore: store,
            session: TestSupport.recordingSession())
    }

    /// Clean state before the test, and again after it - synchronously with the test's
    /// lifecycle, so a cleanup cannot race the next test's configure.
    private func isolate(_ appID: String) async {
        TestSupport.fresh(appID)
        await AppGlance.resetForTesting()
        addTeardownBlock {
            await AppGlance.resetForTesting()
            TestSupport.fresh(appID)
        }
    }

    /// The live client once every command issued so far has been applied.
    private func liveClient(file: StaticString = #filePath, line: UInt = #line) async throws -> Client {
        let client = await AppGlance.currentClientForTesting()
        return try XCTUnwrap(client, "no live client", file: file, line: line)
    }

    /// An app extension is a separate process with its own container and its own Keychain access
    /// group, so it cannot share the app's install id: `configure` there records nothing.
    func testAnAppExtensionBundleIsRecognised() throws {
        XCTAssertFalse(AppGlance.isAppExtension(.main), "the test host is an app, not an extension")

        let appex = FileManager.default.temporaryDirectory.appendingPathComponent("Probe.appex", isDirectory: true)
        try? FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: appex) }
        let bundle = try XCTUnwrap(Bundle(url: appex))
        XCTAssertTrue(AppGlance.isAppExtension(bundle))
    }

    func testCallsApplyInOrderAndInstallIsFirst() async throws {
        let id = "test.facade.order"; await isolate(id)
        configure(id, store: InMemoryIdentityStore())  // a fresh install
        for i in 0..<40 { AppGlance.track("e\(i)") }

        let client = try await liveClient()
        let events = await client.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal), [Signal.install] + (0..<40).map { "e\($0)" },
            "strict call order, install ahead of everything")
        let stamps = events.map(\.client_ts)
        XCTAssertEqual(stamps, stamps.sorted(), "client timestamps are taken at call time, in order")
    }

    func testCallsBeforeConfigureAreHeldAndReplayed() async throws {
        let id = "test.facade.early"; await isolate(id)
        AppGlance.track("early")  // nothing is configured yet
        AppGlance.identify(email: "ada@example.com")
        configure(id, store: InMemoryIdentityStore("EXISTING"))  // a reinstall: no `install`
        AppGlance.track("late")

        let client = try await liveClient()
        let signals = await client.pendingSignals()
        XCTAssertEqual(
            signals, ["early", Signal.identify, "late"],
            "nothing tracked before configure is lost, and order is preserved")
    }

    func testCallsWaitWhileTheInstallIDIsUnreadable() async throws {
        let id = "test.facade.locked"; await isolate(id)
        // The Keychain before the first unlock: configure ran, but no id can be read yet.
        configure(id, store: InMemoryIdentityStore("REAL", locked: true))
        AppGlance.track("held")
        let none = await AppGlance.currentClientForTesting()
        XCTAssertNil(none, "no client until the id can be read - minting now would invent a second user")

        // Unlocked: a fresh configure with the readable store, and the held call goes out.
        configure(id, store: InMemoryIdentityStore("REAL"))
        let client = try await liveClient()
        let signals = await client.pendingSignals()
        XCTAssertEqual(signals, ["held"])
    }

    func testRapidInactiveActiveEndsActiveWithOneSession() async throws {
        let id = "test.facade.active"; await isolate(id)
        configure(id, store: InMemoryIdentityStore("EXISTING"))
        AppGlance.setActive(true)  // onAppear
        AppGlance.setActive(true)  // first scenePhase
        AppGlance.setActive(false)  // a banner pulled down…
        AppGlance.setActive(true)  // …and dismissed, all within a moment
        let client = try await liveClient()
        await TestSupport.settle(0.3)
        await client.flush()  // the moment away flushed too; wait for every send to land

        let signals = RecordingProtocol.signals() + (await client.pendingSignals())
        XCTAssertEqual(signals.filter { $0 == Signal.sessionStart }.count, 1, "one visit, one session")
        XCTAssertEqual(
            signals.filter { $0 == Signal.heartbeat }.count, 0,
            "and no heartbeat: session.start proved presence and nothing has been quiet for a minute")
    }

    func testFlushBeforeConfigureIsHarmless() async throws {
        let id = "test.facade.flush"; await isolate(id)
        AppGlance.flush()  // releases its process hold, drops nothing
        await AppGlance.drain()
        configure(id, store: InMemoryIdentityStore("EXISTING"))
        AppGlance.track("after")
        let client = try await liveClient()
        let signals = await client.pendingSignals()
        XCTAssertEqual(signals, ["after"])
    }

    func testSecondConfigureReplacesTheClientWithoutLosingOrDoublingAnything() async throws {
        let id = "test.facade.reconfigure"; await isolate(id)
        configure(id, store: InMemoryIdentityStore())
        AppGlance.track("first")
        let first = try await liveClient()

        configure(id, store: InMemoryIdentityStore("EXISTING"))
        AppGlance.track("second")
        let second = try await liveClient()
        XCTAssertFalse(first === second, "a new client for the new configuration")

        let signals = await second.pendingSignals()
        XCTAssertEqual(
            signals, [Signal.install, "first", "second"],
            "the replacement inherits the persisted queue; the reinstall adds no second install")
        let retired = await first.pendingSignals()
        XCTAssertTrue(retired.isEmpty, "the retired client holds nothing")
    }
}
