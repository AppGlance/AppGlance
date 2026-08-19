import XCTest

@testable import AppGlance

/// The public `AppGlance` facade: calls apply in call order, `install` comes first, calls made
/// before `configure` are held and replayed, and a second `configure` replaces the client cleanly.
final class FacadeTests: XCTestCase {

    /// No periodic ping in this suite. These tests assert on exact signal lists while the app is
    /// in front, and the presence loop is armed by wall clock, not by the test clock: at the
    /// default interval a machine slow enough to spend a minute between `setActive(true)` and the
    /// assertion folds a `heartbeat` into the list and fails a test that is not about presence.
    /// The guard against a ping that fires when it should not still holds, because the tests that
    /// check for one measure in fractions of a second.
    private func configure(_ appID: String, store: InMemoryIdentityStore) {
        AppGlance.configure(
            TestSupport.configuration(appID: appID, heartbeatInterval: 3600), identityStore: store,
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

    /// `install` is queued first, and it has to be first in time as well. Calls made before
    /// `configure` are held and replayed, and they carry the moment the app made them; stamping
    /// `install` with `configure` would put it after events that provably preceded it, and the
    /// platform's first-seen rollup takes the smallest timestamp an install ever sends.
    func testInstallIsNotStampedLaterThanTheCallsHeldBeforeConfigure() async throws {
        let id = "test.facade.installstamp"; await isolate(id)
        AppGlance.track("before.configure")  // an initializer that runs ahead of configure
        await TestSupport.settle(0.05)
        configure(id, store: InMemoryIdentityStore())  // a fresh install

        let client = try await liveClient()
        let events = await client.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal), [Signal.install, "before.configure"], "install is still queued first")
        let stamps = events.map(\.client_ts)
        XCTAssertEqual(stamps, stamps.sorted(), "and it is first in time too, not only in the queue")
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

    /// A `configure` in the middle of a visit is the documented way to apply a consent change,
    /// and it is the one moment SwiftUI reports nothing: `onAppear` has already fired and the
    /// scene phase is not changing. The replacement is handed where the app is instead, so it
    /// rejoins the running session rather than sitting inactive for the rest of the visit.
    func testAConfigureWhileTheAppIsInFrontLeavesTheReplacementActive() async throws {
        let id = "test.facade.reconfigure.front"; await isolate(id)
        configure(id, store: InMemoryIdentityStore("EXISTING"))
        AppGlance.setActive(true)
        let first = try await liveClient()
        let opened = await first.pendingSignals()
        XCTAssertEqual(opened, [Signal.sessionStart], "the first client is in front, with a session open")

        configure(id, store: InMemoryIdentityStore("EXISTING"))  // a consent change, say
        AppGlance.track("after.reconfigure")
        let second = try await liveClient()
        XCTAssertFalse(first === second, "a new client for the new configuration")

        let active = await second.isActiveForTesting()
        XCTAssertTrue(
            active,
            "the replacement knows the app is in front: without it there is no presence ping and no flush on the way out"
        )
        let signals = await second.pendingSignals()
        XCTAssertEqual(
            signals, [Signal.sessionStart, "after.reconfigure"],
            "and it resumed the running session rather than opening a second one")
        let sawSignal = await second.sawLifecycleSignalForTesting()
        XCTAssertTrue(sawSignal, "this app reports its lifecycle, so the replacement must not say it forgot to")
    }

    /// The other half: a `configure` made while the app is genuinely away must not invent a
    /// foreground for it. The replacement still inherits the fact that this app reports its
    /// lifecycle, so nothing accuses it of forgetting the modifier.
    func testAConfigureWhileTheAppIsAwayHandsTheReplacementNoSession() async throws {
        let id = "test.facade.reconfigure.away"; await isolate(id)
        configure(id, store: InMemoryIdentityStore("EXISTING"))
        AppGlance.setActive(true)
        AppGlance.setActive(false)
        let first = try await liveClient()
        await TestSupport.settle(0.3)
        await first.flush()  // join the flush that leaving the foreground started
        let owed = await first.pendingSignals()

        configure(id, store: InMemoryIdentityStore("EXISTING"))
        let second = try await liveClient()
        let signals = await second.pendingSignals()
        XCTAssertEqual(signals, owed, "nothing is invented for an app that is not on screen")
        let active = await second.isActiveForTesting()
        XCTAssertFalse(active, "no session and no presence loop until it comes forward")
        let sawSignal = await second.sawLifecycleSignalForTesting()
        XCTAssertTrue(sawSignal, "the app does report its lifecycle: the replacement must not claim otherwise")
    }

    /// The reconfigure an app actually makes: it configured with `isEnabled: false` while it
    /// waited for consent, and turns collection on once the person agrees. The outgoing client
    /// never became active - its own `setActive` returned at the collecting guard - so its state
    /// cannot be what is handed over. What the app reported can, and that is the difference
    /// between a visit that opens a session and one that is never recorded at all.
    func testAConsentGrantMidVisitLeavesTheReplacementActive() async throws {
        let id = "test.facade.reconfigure.consent"; await isolate(id)
        AppGlance.configure(
            TestSupport.configuration(appID: id, isEnabled: false), identityStore: InMemoryIdentityStore("EXISTING"),
            session: TestSupport.recordingSession())
        AppGlance.setActive(true)  // onAppear, while the app is still waiting for an answer
        let waiting = try await liveClient()
        let recorded = await waiting.pendingSignals()
        XCTAssertEqual(recorded, [], "a client that is not collecting records nothing")
        let wasActive = await waiting.isActiveForTesting()
        XCTAssertFalse(wasActive, "and never became active, so its own state is not what the app said")

        configure(id, store: InMemoryIdentityStore("EXISTING"))  // consent granted
        AppGlance.track("after.consent")
        let second = try await liveClient()
        let active = await second.isActiveForTesting()
        XCTAssertTrue(active, "the app is in front and said so; the replacement is the one that can act on it")
        let signals = await second.pendingSignals()
        XCTAssertEqual(signals, [Signal.sessionStart, "after.consent"], "so the visit finally opens a session")
    }
}
