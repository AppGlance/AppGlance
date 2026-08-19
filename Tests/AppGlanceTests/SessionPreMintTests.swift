import XCTest

@testable import AppGlance

/// The pre-minted session id: whenever a fresh session is inevitable, its id exists from client
/// startup, so `install` and everything recorded before the first foreground carry the id that
/// `session.start` adopts - on the server they all fold into one session. Resumable sessions are
/// untouched.
final class SessionPreMintTests: XCTestCase {

    private func makeClient(
        appID: String, clock: TestClock, isNewInstall: Bool = false, sessionTimeout: TimeInterval = 300
    ) -> Client {
        Client(
            config: TestSupport.configuration(appID: appID, sessionTimeout: sessionTimeout),
            userID: "u-\(appID)", isNewInstall: isNewInstall, installAt: clock.now,
            session: TestSupport.recordingSession(), now: { clock.now })
    }

    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    func testFreshInstallSharesOneSessionIDAcrossInstallAndFirstSession() async throws {
        let id = "test.premint.fresh"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock(), isNewInstall: true)

        await client.recordInstallIfNeeded()
        await client.track(signal: "launch.option", metadata: nil)  // before any foreground
        await client.setActive(true)

        let events = await client.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal).filter { $0 != Signal.heartbeat },
            [Signal.install, "launch.option", Signal.sessionStart],
            "install first, then the pre-foreground event, then the session start")
        let ids = Set(events.map(\.session_id))
        XCTAssertEqual(ids.count, 1, "one session id across everything, heartbeats included")
        XCTAssertNotNil(ids.first ?? nil, "and it is a real id, not nil")
    }

    func testSecondInProcessSessionMintsAFreshID() async throws {
        let id = "test.premint.reuseonce"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)
        let first = await client.currentSessionID()
        await client.setActive(false)  // flushes on the way out
        clock.advance(6 * 60)  // past the session timeout
        await client.setActive(true)
        let second = await client.currentSessionID()
        await client.flush()  // settle every send before reading what the server saw

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "the pre-minted id is adopted exactly once")
        let starts = RecordingProtocol.receivedBatches().flatMap { $0 }.filter { $0.signal == Signal.sessionStart }
        XCTAssertEqual(starts.map(\.session_id), [first, second], "each session.start carries its own id")
    }

    func testDeathBeforeFirstForegroundHandsTheUnadoptedIDToTheNextLaunch() async throws {
        let id = "test.premint.death"; isolate(id)
        let clock = TestClock()

        let dying = makeClient(appID: id, clock: clock, isNewInstall: true)
        await dying.recordInstallIfNeeded()
        let preMinted = await dying.currentSessionID()
        let unadopted = await dying.currentSessionIsUnadopted()
        XCTAssertNotNil(preMinted)
        XCTAssertTrue(unadopted, "no foreground yet: the id is still waiting for its session.start")
        await dying.shutdown()  // the process dies before setActive(true)

        let relaunched = makeClient(appID: id, clock: clock)
        let reused = await relaunched.currentSessionID()
        XCTAssertEqual(reused, preMinted, "the unadopted id is reused, never replaced")
        await relaunched.setActive(true)
        await relaunched.flush()

        let sent = RecordingProtocol.sessions()
        XCTAssertEqual(
            Set(sent.compactMap { $0 }).count, 1,
            "install (from the first run's persisted queue) and session.start share the one session")
        XCTAssertTrue(sent.allSatisfy { $0 == preMinted })
        let stillUnadopted = await relaunched.currentSessionIsUnadopted()
        XCTAssertFalse(stillUnadopted, "adopted now: a later session must mint its own id")
    }

    func testColdRelaunchAfterTimeoutAttachesPreForegroundEventsToTheNewSession() async throws {
        let id = "test.premint.stalegap"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)
        let oldSession = await first.currentSessionID()
        await first.setActive(false)
        await first.flush()
        await first.shutdown()

        clock.advance(20 * 60)  // relaunched well past the timeout
        let second = makeClient(appID: id, clock: clock)
        await second.track(signal: "launch.option", metadata: nil)  // before any foreground
        let preMinted = await second.currentSessionID()
        XCTAssertNotNil(preMinted)
        XCTAssertNotEqual(preMinted, oldSession, "a fresh session is inevitable, so its id is already fresh")
        await second.setActive(true)

        let events = await second.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal).filter { $0 != Signal.heartbeat }, ["launch.option", Signal.sessionStart])
        XCTAssertEqual(
            Set(events.map(\.session_id)), [preMinted],
            "the pre-foreground event and the session.start share the pre-minted id")
    }

    func testColdRelaunchWithinTimeoutResumesExactlyAsBefore() async throws {
        let id = "test.premint.resume"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)
        let session = await first.currentSessionID()
        await first.setActive(false)
        await first.flush()
        await first.shutdown()

        clock.advance(60)  // relaunched inside the timeout
        let second = makeClient(appID: id, clock: clock)
        let restored = await second.currentSessionID()
        XCTAssertEqual(restored, session, "the session is restored, not pre-minted over")
        let unadopted = await second.currentSessionIsUnadopted()
        XCTAssertFalse(unadopted, "a restored session already had its session.start")

        await second.track(signal: "launch.option", metadata: nil)  // before the foreground report
        await second.setActive(true)
        await second.flush()

        let sent = RecordingProtocol.signals()
        XCTAssertEqual(
            sent.filter { $0 == Signal.sessionStart }.count, 1,
            "a relaunch inside the timeout continues the session; no second session.start")
        XCTAssertTrue(
            RecordingProtocol.sessions().allSatisfy { $0 == session },
            "everything, including the pre-foreground event, stays in the resumed session")
    }

    /// A pre-minted id is never a resume candidate: nothing has opened its session yet, so there
    /// is no `session.start` for a resume to continue. The state is ordinary - a recent last-active
    /// stamp with no session key beside it, which is what a sibling build's late gate close leaves
    /// behind - and a resume there means no `session.start` is ever sent for the visit, so the
    /// whole thing files under a session the server never saw begin.
    func testAPreMintedIDIsNotResumedEvenBesideARecentLastActiveStamp() async throws {
        let id = "test.premint.recentstamp"; isolate(id)
        let clock = TestClock()
        // Recent enough to be inside the timeout, and no session id to go with it.
        UserDefaults.standard.set(
            clock.now.timeIntervalSince1970 - 30, forKey: "app.appglance.lastActive.\(id)")

        let client = makeClient(appID: id, clock: clock)
        let mintedID = await client.currentSessionID()
        let preMinted = try XCTUnwrap(mintedID)
        var unadopted = await client.currentSessionIsUnadopted()
        XCTAssertTrue(
            unadopted, "no session to restore, so one is minted here and is still owed its session.start")

        await client.track(signal: "launch.option", metadata: nil)
        await client.setActive(true)

        let events = await client.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal).filter { $0 != Signal.heartbeat }, ["launch.option", Signal.sessionStart],
            "nothing has opened this session yet, so there is nothing for the foreground to resume")
        XCTAssertEqual(Set(events.map(\.session_id)), [preMinted], "and the start adopts the id those events carry")
        unadopted = await client.currentSessionIsUnadopted()
        XCTAssertFalse(unadopted, "once, and only once")
    }

    /// The full facade path: `configure` on a fresh install, launch-time calls, then the first
    /// foreground - one session id end to end, and install still first.
    func testConfigureToFirstForegroundCarriesOneSessionIDThroughTheFacade() async throws {
        let id = "test.premint.facade"
        TestSupport.fresh(id)
        await AppGlance.resetForTesting()
        addTeardownBlock {
            await AppGlance.resetForTesting()
            TestSupport.fresh(id)
        }

        AppGlance.configure(
            TestSupport.configuration(appID: id), identityStore: InMemoryIdentityStore(),
            session: TestSupport.recordingSession())
        AppGlance.track("launch.option")
        AppGlance.setActive(true)

        let live = await AppGlance.currentClientForTesting()
        let client = try XCTUnwrap(live)
        let events = await client.pendingEvents()
        XCTAssertEqual(
            events.map(\.signal).filter { $0 != Signal.heartbeat },
            [Signal.install, "launch.option", Signal.sessionStart])
        XCTAssertEqual(Set(events.map(\.session_id)).count, 1, "one session id from install to session.start")
        XCTAssertNotNil(events.first?.session_id ?? nil)
    }
}
