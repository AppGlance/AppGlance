import XCTest

@testable import AppGlance

/// What the client sends for the lifecycle transitions SwiftUI actually produces - including the
/// doubled ones (`onAppear` + first `scenePhase`, `.inactive` + `.background`) - and how it
/// delivers the queue.
final class SessionTests: XCTestCase {

    private func makeClient(
        appID: String, clock: TestClock, sessionTimeout: TimeInterval = 300, heartbeatInterval: TimeInterval = 60
    ) -> Client {
        Client(
            config: TestSupport.configuration(
                appID: appID, sessionTimeout: sessionTimeout, heartbeatInterval: heartbeatInterval),
            userID: "u-\(appID)", session: TestSupport.recordingSession(), now: { clock.now })
    }

    /// Clean state before the test and again after it.
    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    // MARK: - Sessions and the heartbeat

    func testLaunchStartsExactlyOneSessionAndNoPingUntilAMinuteOfSilence() async throws {
        let id = "test.session.launch"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())

        // onAppear, then scenePhase → .active: two reports of the same fact.
        await client.setActive(true)
        await client.setActive(true)
        await TestSupport.settle(0.3)

        let queued = await client.pendingSignals()
        XCTAssertEqual(
            queued, [Signal.sessionStart],
            "one session.start and nothing else: the start is presence enough, a ping waits for a minute of silence")
    }

    /// The heartbeat measures silence, not time: any real event resets it, so an install that is
    /// sending events never pings, and one that goes quiet pings once per interval of quiet.
    func testPingsOnlyAfterAnIntervalOfSilence() async throws {
        let id = "test.session.silence"; isolate(id)
        let clock = TestClock()
        // A short interval so the task's real-time waits stay short; the clock still decides
        // when silence has elapsed.
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 0.2)

        await client.setActive(true)  // session.start at t0
        await TestSupport.settle(0.4)
        var pings = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(pings, 0, "the clock has not moved: no silence has elapsed yet")

        clock.advance(0.25)  // a full interval of quiet since session.start
        let ticked = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked, "quiet for an interval: one ping")

        clock.advance(0.15)
        await client.track(signal: "tap", metadata: nil)  // presence proved 0.15 s after the ping
        clock.advance(0.15)  // 0.30 s since the ping, but only 0.15 s since the event
        await TestSupport.settle(0.4)
        pings = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(pings, 1, "the event reset the silence: no second ping yet")

        clock.advance(0.1)  // 0.25 s since the event
        let tickedAgain = await TestSupport.waitForHeartbeats(2, from: client)
        XCTAssertTrue(tickedAgain, "quiet again for an interval after the event: a second ping")
        let queued = await client.pendingSignals()
        XCTAssertEqual(queued, [Signal.sessionStart, Signal.heartbeat, "tap", Signal.heartbeat])
    }

    func testBriefInterruptionResumesTheSameSession() async throws {
        let id = "test.session.brief"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)
        clock.advance(20)
        await client.setActive(false)  // .inactive (a notification banner, say)
        await client.setActive(false)  // .background - must not flush or act twice
        clock.advance(30)
        await client.setActive(true)  // back within the timeout: the next beat is 10 s away
        await TestSupport.settle(0.3)
        await client.setActive(false)
        await client.flush()

        let sent = RecordingProtocol.signals()
        XCTAssertEqual(
            sent.filter { $0 == Signal.sessionStart }.count, 1, "50 seconds away is an interruption, not a new session")
        XCTAssertEqual(
            sent.filter { $0 == Signal.heartbeat }.count, 0,
            "resuming inside the interval since session.start must not tick, and 20 s of quiet earns no closing ping")
        let left = await client.pendingSignals()
        XCTAssertTrue(left.isEmpty, "a successful flush clears the queue")
    }

    func testReturningAfterTheTimeoutStartsANewSession() async throws {
        let id = "test.session.timeout"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)
        await client.setActive(false)
        clock.advance(6 * 60)  // longer than the 5-minute session timeout
        await client.setActive(true)
        await TestSupport.settle(0.3)
        await client.setActive(false)
        await client.flush()

        XCTAssertEqual(
            RecordingProtocol.signals(),
            [Signal.sessionStart, Signal.sessionStart],
            "each return after the gap is a new session; its start is its first proof of presence")
    }

    /// Leaving the foreground after more than a minute of silence sends one closing ping, so
    /// the session's length ends where the visit ended; leaving sooner sends nothing extra.
    func testLeavingAfterAQuietMinuteSendsAClosingPing() async throws {
        let id = "test.session.closing"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 3600)  // no periodic ping in this test

        await client.setActive(true)  // session.start at t0
        clock.advance(30)
        await client.setActive(false)  // 30 s of quiet: nothing to add
        await client.flush()
        XCTAssertEqual(RecordingProtocol.signals(), [Signal.sessionStart])

        clock.advance(10)
        await client.setActive(true)  // resumed
        clock.advance(90)  // a quiet minute and a half
        await client.setActive(false)
        await client.flush()
        XCTAssertEqual(
            RecordingProtocol.signals(), [Signal.sessionStart, Signal.heartbeat],
            "quiet for over a minute: the goodbye is one ping, stamped at the moment of leaving")

        clock.advance(10)
        await client.setActive(true)
        clock.advance(20)
        await client.track(signal: "tap", metadata: nil)
        clock.advance(20)
        await client.setActive(false)  // 20 s since the tap: the server already knows
        await client.flush()
        XCTAssertEqual(
            RecordingProtocol.signals(), [Signal.sessionStart, Signal.heartbeat, "tap"],
            "a recent event is presence enough: no closing ping")
    }

    /// The server may raise the cadence for the account's plan through the ingest response;
    /// the SDK obeys it as a floor, remembers it across launches, and ignores nonsense.
    func testServerHeartbeatFloorIsHonouredRememberedAndBounded() async throws {
        let id = "test.session.floor"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        var interval = await first.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 60, "the configured interval until the server says otherwise")

        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"rejected":0,"heartbeat_interval":240}"#)
        await first.track(signal: "a", metadata: nil)
        await first.flush()
        interval = await first.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 240, "the plan asks for a ping every four minutes at most")

        // Remembered: the next launch paces itself before its first response arrives.
        let second = makeClient(appID: id, clock: clock)
        interval = await second.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 240)

        // A floor, not a ceiling: an app that configured 300 keeps 300 when the server says 240.
        let wide = makeClient(appID: id, clock: clock, heartbeatInterval: 300)
        interval = await wide.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 300)

        // Nonsense is ignored: too tight to mean anything, or not a presence cadence at all.
        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"heartbeat_interval":5}"#)
        await second.track(signal: "b", metadata: nil)
        await second.flush()
        interval = await second.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 240, "5 s is below the sane floor: kept the last good value")
        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"heartbeat_interval":86400}"#)
        await second.track(signal: "c", metadata: nil)
        await second.flush()
        interval = await second.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 240, "a day is not a presence cadence: kept the last good value")
        // And back down when the plan changes.
        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"heartbeat_interval":60}"#)
        await second.track(signal: "d", metadata: nil)
        await second.flush()
        interval = await second.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 60)
        // A response with no hint changes nothing.
        RecordingProtocol.scriptResponseBody(#"{"accepted":1}"#)
        await second.track(signal: "e", metadata: nil)
        await second.flush()
        interval = await second.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 60)
    }

    func testRelaunchWithinTimeoutContinuesTheSessionAcrossProcesses() async throws {
        let id = "test.session.relaunch"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)
        await first.track(signal: "paywall.viewed", metadata: nil)
        let sid = await first.currentSessionID()
        XCTAssertNotNil(sid)
        await first.setActive(false)
        await first.flush()

        clock.advance(60)  // quit and reopened a minute later: same session
        let second = makeClient(appID: id, clock: clock)
        await second.setActive(true)
        // A resume sends no session.start, and the last thing the server heard was a minute
        // ago: the resumed process proves its presence with a ping at once.
        let ticked = await TestSupport.waitForHeartbeats(1, from: second)
        XCTAssertTrue(ticked, "a resume after an interval of silence pings at once")
        let sid2 = await second.currentSessionID()
        XCTAssertEqual(sid2, sid, "same session id across a quit-and-relaunch inside the timeout")
        await second.setActive(false)
        await second.flush()

        clock.advance(20 * 60)  // reopened much later: a new session
        let third = makeClient(appID: id, clock: clock)
        await third.setActive(true)
        await TestSupport.settle(0.3)
        let sid3 = await third.currentSessionID()
        XCTAssertNotEqual(sid3, sid)
        await third.flush()

        let sent = RecordingProtocol.signals()
        XCTAssertEqual(
            sent.filter { $0 == Signal.sessionStart }.count, 2,
            "the dashboard splits sessions on a 5-minute gap; the SDK agrees")
        XCTAssertEqual(sent.filter { $0 == Signal.heartbeat }.count, 1, "the resume's ping, and no other")
        let ids = RecordingProtocol.sessions()
        XCTAssertTrue(ids.allSatisfy { $0 != nil }, "every event carries its session id")
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 2, "two sessions were lived")
    }

    /// The last-heartbeat stamp is persisted: the interval is a wall-clock promise that holds
    /// across a quit-and-relaunch, so presence rollups are not inflated by relaunching.
    func testHeartbeatTimingSurvivesARelaunch() async throws {
        let id = "test.session.hbrelaunch"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)  // session.start at t0
        clock.advance(61)  // a quiet minute: the periodic ping is due
        let ticked = await TestSupport.waitForHeartbeats(1, from: first)
        XCTAssertTrue(ticked, "the heartbeat task got its turn")
        clock.advance(30)
        await first.setActive(false)
        await first.flush()
        await first.shutdown()

        // Relaunched inside the heartbeat interval: the persisted stamp says a beat happened 30
        // seconds ago, so resuming must not tick again at once.
        let second = makeClient(appID: id, clock: clock)
        await second.setActive(true)
        await TestSupport.settle(0.3)
        let sentEarly = RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count
        let queuedEarly = await second.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(sentEarly + queuedEarly, 1, "a relaunch inside the interval does not beat immediately")
        await second.setActive(false)
        await second.flush()
        await second.shutdown()

        // Relaunched once the interval has genuinely passed (70 seconds since the beat, still
        // inside the session timeout): the next beat is due at once.
        clock.advance(40)
        let third = makeClient(appID: id, clock: clock)
        await third.setActive(true)
        let tickedAgain = await TestSupport.waitForHeartbeats(2, from: third)
        XCTAssertTrue(tickedAgain, "a relaunch past the interval beats at once")
        await third.setActive(false)
        await third.flush()
        XCTAssertEqual(
            RecordingProtocol.signals().filter { $0 == Signal.sessionStart }.count, 1,
            "one session throughout; only its first foreground started it")
    }

    // MARK: - Delivery

    func testFlushSendsEachEventOnce() async throws {
        let id = "test.session.once"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        await client.track(signal: "b", metadata: nil)
        // Two overlapping flushes - the shape of `.inactive` + `.background` - send one batch.
        async let f1: Void = client.flush()
        async let f2: Void = client.flushHoldingProcess()
        _ = await (f1, f2)
        XCTAssertEqual(RecordingProtocol.signals(), ["a", "b"])
        XCTAssertEqual(RecordingProtocol.requestSizes(), [2], "one request, not two")
    }

    func testLongQueueDrainsInSlicesAndKeepsOrder() async throws {
        let id = "test.session.slices"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        for i in 0..<230 { await client.track(signal: "e\(i)", metadata: nil) }
        await client.flush()
        XCTAssertEqual(RecordingProtocol.requestSizes(), [100, 100, 30])
        XCTAssertEqual(RecordingProtocol.signals(), (0..<230).map { "e\($0)" })
        let left = await client.pendingSignals()
        XCTAssertTrue(left.isEmpty)
    }

    func testPermanentRejectionDropsOnlyThatSliceAndTransientKeepsIt() async throws {
        let id = "test.session.4xx"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        // 429: keep and stop - nothing is lost, nothing else is attempted this round.
        RecordingProtocol.script([429])
        await client.flush()
        var left = await client.pendingSignals()
        XCTAssertEqual(left, ["a"], "rate-limited: the batch waits for the next attempt")
        // 401 (an unknown key): dropping beats a queue that can never drain again.
        RecordingProtocol.script([401])
        await client.flush()
        left = await client.pendingSignals()
        XCTAssertTrue(left.isEmpty, "a permanent 4xx must not be retried forever")
        XCTAssertEqual(RecordingProtocol.signals(), [], "and nothing was recorded as delivered")
    }

    func testOversizedBatchIsSplitUntilItFits() async throws {
        let id = "test.session.413"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        for i in 0..<8 { await client.track(signal: "e\(i)", metadata: nil) }
        RecordingProtocol.script([413, 413])  // the first two attempts are "too big"; halves get through
        await client.flush()
        XCTAssertEqual(RecordingProtocol.requestSizes().first, 8)
        XCTAssertEqual(RecordingProtocol.signals(), (0..<8).map { "e\($0)" }, "everything arrives, in order")
        XCTAssertTrue(RecordingProtocol.requestSizes().dropFirst(2).allSatisfy { $0 <= 2 })
    }

    func testEventsArePersistedAsTheyAreTrackedAndClearedOnceAcknowledged() async throws {
        let id = "test.session.persist"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "x", metadata: nil)
        XCTAssertEqual(try TestSupport.persistedSignals(id), ["x"], "on disk before any flush - a crash cannot lose it")
        await client.flush()
        XCTAssertEqual(try TestSupport.persistedSignals(id), [], "and gone from disk once acknowledged")
    }

    // MARK: - Presence pings are never risked twice
    //
    // Every other signal carries an event id the server dedupes on, so retrying it is free.
    // Heartbeats are folded into rollups on arrival and a re-sent one counts twice, so they are
    // retried only when the server definitely did not process the batch.

    func testTransientFailureRetriesRealEventsButDropsPresencePings() async throws {
        let id = "test.session.hbretry"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: Signal.heartbeat, metadata: nil)
        await client.track(signal: "purchase", metadata: nil)

        RecordingProtocol.script([503])
        await client.flush()

        let left = await client.pendingSignals()
        XCTAssertEqual(
            left, ["purchase"], "the server answered, so it may have applied the ping; the real event is safe to retry")
        await client.flush()  // 202 this time
        XCTAssertEqual(RecordingProtocol.signals(), ["purchase"], "no heartbeat reaches the wire a second time")
    }

    func testOversizedBatchKeepsPresencePingsBecauseNothingWasApplied() async throws {
        let id = "test.session.hb413"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: Signal.heartbeat, metadata: nil)
        await client.track(signal: "purchase", metadata: nil)

        // 413 rejects the body before processing it, so the ping is re-sent in the smaller slices.
        RecordingProtocol.script([413])
        await client.flush()

        XCTAssertTrue(RecordingProtocol.signals().contains(Signal.heartbeat), "the ping is re-sent after a 413")
        let left = await client.pendingSignals()
        XCTAssertTrue(left.isEmpty)
    }

    func testBeingOfflineKeepsPresencePingsBecauseNothingLeftTheDevice() async throws {
        let id = "test.session.hboffline"; isolate(id)
        // Port 9 (discard) on the loopback: the connection is refused, so nothing was ever sent.
        let client = Client(
            config: AppGlance.Configuration(
                apiKey: "glance_live_test", appID: id,
                endpoint: URL(string: "http://127.0.0.1:9/v1/events")!,
                flushInterval: 3600, maxBatchSize: 1000,
                enabledEnvironments: Set(AppEnvironment.allCases)),
            userID: "u1")
        await client.track(signal: Signal.heartbeat, metadata: nil)
        await client.track(signal: "purchase", metadata: nil)
        await client.flush()
        let left = await client.pendingSignals()
        XCTAssertEqual(
            left, [Signal.heartbeat, "purchase"],
            "an unreachable network is not an ambiguous outcome - the ping is kept")
    }

    /// The on-disk queue is what a relaunch sends. While a slice is on the wire, the disk shows
    /// its real events as still owed and its heartbeats as gone - so a process killed before the
    /// response arrives replays the events (deduplicated by id) and never the pings.
    func testQueueOnDiskNeverContainsAnInFlightHeartbeat() async throws {
        let id = "test.session.inflight"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: Signal.heartbeat, metadata: nil)
        await client.track(signal: "purchase", metadata: nil)
        XCTAssertEqual(
            try TestSupport.persistedSignals(id), [Signal.heartbeat, "purchase"], "queued, not yet sent: both are owed")

        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        while !hold.isStarted { await TestSupport.settle(0.02) }
        await client.track(signal: "later", metadata: nil)  // tracked while the slice is in flight

        XCTAssertEqual(
            try TestSupport.persistedSignals(id), ["purchase", "later"],
            "in flight: the real event stays owed, the ping is not risked, the new event queues behind")

        hold.proceed()
        await flushing.value
        XCTAssertEqual(
            RecordingProtocol.requestSizes(), [2, 1], "the held slice carried both; the later event followed")
        XCTAssertEqual(RecordingProtocol.signals(), [Signal.heartbeat, "purchase", "later"])
        XCTAssertEqual(try TestSupport.persistedSignals(id), [], "acknowledged: nothing is owed")
    }

    /// A later `configure` replaces the client. The old one must stop recording and, above all,
    /// stop writing the queue file the replacement now owns.
    func testRetiredClientRecordsNothingAndLeavesTheQueueFileAlone() async throws {
        let id = "test.session.retired"; isolate(id)
        let old = makeClient(appID: id, clock: TestClock())
        await old.track(signal: "before", metadata: nil)
        await old.shutdown()

        let replacement = makeClient(appID: id, clock: TestClock())
        let inherited = await replacement.pendingSignals()
        XCTAssertEqual(inherited, ["before"], "the replacement picks up what was persisted")

        await old.track(signal: "stray", metadata: nil)
        await old.setActive(true)
        await old.flush()
        let oldQueue = await old.pendingSignals()
        XCTAssertTrue(oldQueue.isEmpty, "retired: nothing is recorded")
        XCTAssertEqual(RecordingProtocol.signals(), [], "retired: nothing is sent")
        XCTAssertEqual(try TestSupport.persistedSignals(id), ["before"], "the file is untouched")
    }
}
