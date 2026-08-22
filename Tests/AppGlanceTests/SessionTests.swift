import XCTest

@testable import AppGlance

/// What the client sends for the lifecycle transitions SwiftUI actually produces - including the
/// doubled ones (`onAppear` + first `scenePhase`, `.inactive` + `.background`) - and how it
/// delivers the queue.
final class SessionTests: XCTestCase {

    private func makeClient(
        appID: String, clock: TestClock, sessionTimeout: TimeInterval = 300, maxBatchSize: Int = 1000,
        heartbeatInterval: TimeInterval = 60, debug: Bool = false,
        storeAnswer: (@Sendable () async -> StoreAnswer)? = nil,
        environmentAnswerGrace: TimeInterval = 3, minHeartbeatRetry: TimeInterval = 15
    ) -> Client {
        Client(
            config: TestSupport.configuration(
                appID: appID, sessionTimeout: sessionTimeout, maxBatchSize: maxBatchSize,
                heartbeatInterval: heartbeatInterval, debug: debug),
            userID: "u-\(appID)", session: TestSupport.recordingSession(), now: { clock.now },
            // A test that supplies an answer is a test that wants the ask path; a test host is a
            // Debug build, where it is otherwise never entered.
            asksTheStore: storeAnswer != nil,
            storeAnswer: storeAnswer ?? { await AppEnvironment.storeAnswer() },
            environmentAnswerGrace: environmentAnswerGrace, minHeartbeatRetry: minHeartbeatRetry)
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

    /// Forgetting `.trackAppLifecycle()` is silent from inside the app: `install` and every
    /// `track` still arrive and still send, but no session ever opens and every event carries the
    /// one pre-minted session id forever. The SDK says so once, in the build where it happens.
    func testAMissingLifecycleSignalIsReportedOnceAndASetActiveSilencesIt() async throws {
        let quiet = "test.session.nolifecycle", wired = "test.session.lifecycle"
        [quiet, wired].forEach(isolate)

        let unwired = makeClient(appID: quiet, clock: TestClock())
        await unwired.armLifecycleCheck(after: 0.05)
        await TestSupport.settle(0.3)
        var reported = await unwired.reportedMissingLifecycleForTesting()
        XCTAssertTrue(reported, "configured, sending, and never told the app came to the front: say so")

        // Armed once: a second arming cannot turn it into a stream of lines.
        await unwired.armLifecycleCheck(after: 0.05)
        await TestSupport.settle(0.2)
        reported = await unwired.reportedMissingLifecycleForTesting()
        XCTAssertTrue(reported)

        let correct = makeClient(appID: wired, clock: TestClock())
        await correct.armLifecycleCheck(after: 0.2)
        await correct.setActive(true)
        await TestSupport.settle(0.4)
        reported = await correct.reportedMissingLifecycleForTesting()
        XCTAssertFalse(reported, "the modifier is attached: nothing to report")
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
    /// `setActive` is idempotent, and the doubled reports are the ones SwiftUI really produces:
    /// `onAppear` then the first `scenePhase` on the way in, `.inactive` then `.background` on the
    /// way out. Acting twice on one departure means two flushes, and - when the two halves are
    /// more than a minute apart, which a slow background transition is - a second closing ping,
    /// which is counted additively on the server and so lengthens the session permanently.
    func testTheSameTransitionReportedTwiceIsActedOnOnce() async throws {
        let id = "test.session.idempotent"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)  // onAppear
        await client.setActive(true)  // and the first scenePhase, the same fact again
        clock.advance(90)  // a minute and a half with nothing sent
        await client.setActive(false)  // .inactive: the closing ping goes with the flush
        clock.advance(70)  // the transition takes its time
        await client.setActive(false)  // .background: the same departure, reported again
        await TestSupport.settle(0.4)

        let starts =
            RecordingProtocol.signals().filter { $0 == Signal.sessionStart }.count
            + (await client.pendingSignals().filter { $0 == Signal.sessionStart }.count)
        XCTAssertEqual(starts, 1, "two reports of arriving are one arrival")
        let pings =
            RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count
            + (await client.pendingSignals().filter { $0 == Signal.heartbeat }.count)
        XCTAssertEqual(pings, 1, "and two reports of leaving close the session once, however far apart they fall")
        XCTAssertEqual(
            RecordingProtocol.requestSizes().count, 1, "one departure, one flush, one process assertion")
    }

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

    /// The server's two deliberate-drop counts reach the developer's console in debug mode. The
    /// response is read by the very loop that is broken, so these lines are how a `track()` call
    /// in a loop, or a plan out of allowance, is noticed from Xcode rather than days later from a
    /// quota email.
    func testAThrottledOrOverQuotaAnswerIsSaidOutLoudInDebug() async throws {
        let id = "test.session.serverdrops"; isolate(id)
        // The capture closure is invoked on the client actor, so the collected lines live behind
        // a lock rather than in a captured local the compiler would rightly refuse.
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
            func clear() { lock.lock(); storage = []; lock.unlock() }
            var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        }
        let captured = Captured()
        Log.captureForTesting = { captured.append($0) }
        addTeardownBlock { Log.captureForTesting = nil }

        let client = makeClient(appID: id, clock: TestClock(), debug: true)
        RecordingProtocol.scriptResponseBody(#"{"accepted":10,"throttled":90,"over_quota_dropped":3}"#)
        await client.track(signal: "a", metadata: nil)
        await client.flush()
        XCTAssertTrue(
            captured.lines.contains { $0.contains("rate limited 90 events from this install") },
            "the throttle count is said with its likely cause: \(captured.lines)")
        XCTAssertTrue(
            captured.lines.contains { $0.contains("3 events not stored") && $0.contains("cap") },
            "the over-quota count is said with the way out: \(captured.lines)")

        // A clean answer stays quiet: these lines exist for the two problems, not for every send.
        captured.clear()
        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"rejected":0}"#)
        await client.track(signal: "b", metadata: nil)
        await client.flush()
        XCTAssertFalse(
            captured.lines.contains { $0.contains("rate limited") || $0.contains("not stored") },
            "nothing was dropped, so nothing is warned about: \(captured.lines)")
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

    /// A visit shorter than one interval leaves no ping stamp behind, so the last thing the
    /// server heard from this install was a real event. Its stamp is persisted too, or the next
    /// process would prove presence again the moment it came up.
    func testAShortVisitDoesNotEarnAPingOnTheNextRelaunch() async throws {
        let id = "test.session.shortvisit"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)  // session.start at t0: a real event, and the only one
        clock.advance(10)
        await first.setActive(false)  // quiet for ten seconds, so no closing ping either
        await first.flush()
        await first.shutdown()

        clock.advance(20)  // reopened at t+30, well inside both the interval and the timeout
        let second = makeClient(appID: id, clock: clock)
        await second.setActive(true)
        await TestSupport.settle(0.3)

        let sent = RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count
        let queued = await second.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(sent + queued, 0, "the event 30 seconds ago is presence; a ping waits for a full interval")
    }

    /// A ping the server never acknowledged must not pace the next one: the install would be
    /// silent for two intervals, which at the sparsest cadence a plan asks for is longer than the
    /// dashboard's presence window. The replacement is owed to the visit that is still running,
    /// so the stretch that lost the ping arms it - it is not left to whatever a later launch
    /// happens to find on disk.
    func testADroppedPingIsReplacedInsideTheSameVisit() async throws {
        let id = "test.session.droppedping"; isolate(id)
        let clock = TestClock()
        // A minute of cadence, so the heartbeat task that has just ticked is asleep for a minute
        // of real time: any ping this test sees came from the re-arm. The retry floor is
        // shortened for the same reason - to be waited out rather than watched for.
        let client = makeClient(appID: id, clock: clock, minHeartbeatRetry: 1)

        await client.setActive(true)  // session.start at t0
        await client.flush()  // and it is acknowledged, so the failing batch below is the ping alone
        clock.advance(61)
        let ticked = await client.heartbeatForTesting()  // the quiet minute has passed
        XCTAssertTrue(ticked, "the ping is due after a quiet minute")

        RecordingProtocol.script([500])
        await client.flush()  // the ping is dropped rather than risk counting it twice
        XCTAssertEqual(
            RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count, 0,
            "the server never saw that ping")
        await TestSupport.settle(0.25)
        var pings = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(pings, 0, "not at once: the dropped ping may have landed after all")

        // Same visit, same client: the replacement is due `minHeartbeatRetry` after the dropped
        // ping, long before the fresh interval the dropped stamp would have bought - without a
        // relaunch to load anything from disk. The clock crosses that moment here; the waited-out
        // retry floor is what lets the loop wake up and see it.
        clock.advance(2)
        let replaced = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(replaced, "the stretch that lost the ping proves presence again itself")
        pings = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertEqual(pings, 1, "one replacement, not a stream of them")
        await client.shutdown()
    }

    /// The roll-back measures the silence that is really outstanding, and it never mints a fresh
    /// interval: a ping an earlier process stamped is proof the server was heard from, and the
    /// stamp goes back toward it - stopping at the replacement floor, so the next ping lands
    /// `minHeartbeatRetry` after the one that was dropped rather than a whole interval later, and
    /// rather than at once.
    func testADroppedPingRollsBackTowardTheStampAnEarlierProcessLeft() async throws {
        let id = "test.session.rollback.persisted"; isolate(id)
        let clock = TestClock()
        let defaults = UserDefaults.standard
        let earlier = clock.now.timeIntervalSince1970 - 600
        // A visit still inside the timeout, so this launch resumes and records no session.start of
        // its own: the ping below is the only thing it sends.
        defaults.set(clock.now.timeIntervalSince1970 - 30, forKey: "app.appglance.lastActive.\(id)")
        defaults.set("22222222-2222-2222-2222-222222222222", forKey: "app.appglance.session.\(id)")
        defaults.set(earlier, forKey: "app.appglance.lastHeartbeat.\(id)")

        // The retry floor (15 s of real time here) outlasts the test, so the replacement ping
        // cannot arrive and move the stamp this is about.
        let client = makeClient(appID: id, clock: clock)
        await client.setActive(true)
        let ticked = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked, "ten minutes of silence: a ping is owed at once")
        let dropped = clock.now.timeIntervalSince1970
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(id)") as? Double,
            dropped, "and queueing it stamps the install")

        RecordingProtocol.script([500])
        await client.flush()  // dropped rather than risk counting it twice

        let restored = try XCTUnwrap(defaults.object(forKey: "app.appglance.lastHeartbeat.\(id)") as? Double)
        XCTAssertEqual(
            restored, dropped + 15 - 60, accuracy: 0.001,
            "back toward the acknowledged ping, stopping where the replacement stays 15 s from the drop")
        await client.shutdown()
    }

    /// The other half of that bound: the roll-back never goes past the newest ping the server
    /// acknowledged. A closing tick fires after a quiet minute whatever the cadence, so at a
    /// sparse one it can be dropped while the acknowledged ping is newer than the replacement
    /// floor - and pacing from the floor would tick again inside the interval that ping already
    /// proved.
    func testARolledBackClosingTickNeverPacesInsideAnAcknowledgedInterval() async throws {
        let id = "test.session.rollback.acked"; isolate(id)
        let clock = TestClock()
        let defaults = UserDefaults.standard
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 240)

        await client.setActive(true)  // session.start at t0
        await client.heartbeatForTesting()  // a ping at t0, sent and acknowledged
        await client.flush()
        let acknowledged = clock.now.timeIntervalSince1970
        XCTAssertEqual(RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count, 1)

        clock.advance(70)
        RecordingProtocol.script([500])
        await client.setActive(false)  // quiet for 70 s: the closing tick goes, and is dropped
        let failed = await TestSupport.waitUntilAsync {
            await client.backoffForTesting().failures == 1
        }
        XCTAssertTrue(failed, "the departure flush failed, so the closing tick was dropped")

        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(id)") as? Double, acknowledged,
            "the acknowledged ping is newer than the replacement floor, so it is what paces the next one")
        await client.shutdown()
    }

    /// The acknowledged stamp is dropped with the others when the clock steps behind them. Left
    /// where it is, it is what the next dropped ping rolls back to, so a stamp from the future
    /// would be written straight back to disk and the ping-storm defence undone for a whole round
    /// trip. With it gone, the roll-back writes the replacement floor paced from the dropped ping
    /// itself: a moment in the past, never the future one it was holding.
    func testTheAcknowledgedPingStampIsDroppedWhenItTooIsAheadOfTheClock() async throws {
        let id = "test.session.rollback.futuredelivered"; isolate(id)
        let clock = TestClock()
        let defaults = UserDefaults.standard
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 0.2, minHeartbeatRetry: 0.1)

        await client.setActive(true)  // session.start at t0
        clock.advance(0.25)
        let ticked = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked, "quiet for an interval: a ping")
        await client.flush()  // accepted, so the server has acknowledged a ping stamped at t0
        XCTAssertEqual(RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count, 1)

        clock.advance(-7200)  // corrected backwards, under both stamps at once
        let again = await TestSupport.waitForHeartbeats(2, from: client)
        XCTAssertTrue(again, "the stamps ahead of the clock are dropped, so presence is owed again")
        let dropped = clock.now.timeIntervalSince1970  // the replacement ping's own stamp

        // Leaving is what carries that ping, and the server drops it. Leaving also stops the loop,
        // so nothing after this can move the stamp the assertion is about.
        RecordingProtocol.script([500])
        await client.setActive(false)
        await TestSupport.settle(0.3)

        let restored = try XCTUnwrap(defaults.object(forKey: "app.appglance.lastHeartbeat.\(id)") as? Double)
        XCTAssertEqual(
            restored, dropped + 0.1 - 0.2, accuracy: 0.001,
            "no acknowledged ping to go back to - the one it held was in the future - so the floor stands")
        XCTAssertLessThanOrEqual(
            restored, clock.now.timeIntervalSince1970,
            "and it is a moment in the past, never the future stamp the defence exists to bury")
        await client.shutdown()
    }

    /// A stamp the clock has not reached yet: written while the device was hours ahead, read back
    /// after the correction. The silence it measures reads as negative, so the next ping is due
    /// hours out, and every relaunch reads the same stamp and owes the same nothing.
    func testAPresenceStampFromTheFutureDoesNotSilenceTheLoop() async throws {
        let id = "test.session.futurestamp"; isolate(id)
        let clock = TestClock()
        let now = clock.now.timeIntervalSince1970
        let defaults = UserDefaults.standard
        // A session that is still resumable, so this launch records no session.start of its own:
        // a ping is then the only thing that can prove the install is in front of someone.
        defaults.set(now - 30, forKey: "app.appglance.lastActive.\(id)")
        defaults.set("11111111-1111-1111-1111-111111111111", forKey: "app.appglance.session.\(id)")
        defaults.set(now - 600, forKey: "app.appglance.lastEvent.\(id)")
        defaults.set(now + 7200, forKey: "app.appglance.lastHeartbeat.\(id)")

        let client = makeClient(appID: id, clock: clock)
        await client.setActive(true)
        let proved = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(proved, "a stamp two hours ahead of the clock is not proof that anyone was here")
        let queued = await client.pendingSignals()
        XCTAssertEqual(
            queued.filter { $0 == Signal.sessionStart }.count, 0,
            "and the session on disk is still the one being lived")
        await client.setActive(false)
        await client.shutdown()
    }

    /// The same fault from inside one visit: a clock corrected backwards leaves the stamps this
    /// process wrote ahead of it. The wait is what paces the whole presence loop, so it is bounded
    /// by one interval however the arithmetic comes out.
    func testAClockThatStepsBackwardsCannotStretchTheWait() async throws {
        let id = "test.session.clockback"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 60)
        await client.setActive(true)  // session.start proves presence at t0
        clock.advance(-7200)  // two hours backwards, mid-visit

        let wait = await client.timeUntilNextHeartbeatForTesting()
        XCTAssertGreaterThanOrEqual(wait, 0)
        XCTAssertLessThanOrEqual(wait, 60, "the next ping is at most one interval out, never the whole offset")
        await client.setActive(false)
        await client.shutdown()
    }

    /// And the ping that answers it has to answer it. A stamp ahead of the clock measures a
    /// silence that never grows, so a ping does not settle it: the loop would ask for another at
    /// once, and again, for as long as the app stayed in front. Presence is counted additively on
    /// the server, so a flood of pings is not a smaller error than a missing one, it is a larger
    /// and a permanent one.
    func testAClockThatStepsBackwardsDoesNotStartAPingStorm() async throws {
        let id = "test.session.clockback.storm"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 60)
        await client.setActive(true)
        clock.advance(-7200)

        await TestSupport.settle(0.5)  // hundreds of pings fit in this, if the loop is not paced
        let pings = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
        XCTAssertLessThanOrEqual(pings, 1, "one ping proves presence again; the interval paces the next")
        let wait = await client.timeUntilNextHeartbeatForTesting()
        XCTAssertEqual(wait, 60, accuracy: 1, "and the loop is measuring from a stamp it can trust again")
        await client.setActive(false)
        await client.shutdown()
    }

    /// The other half of the same fault. A gap measured against a stamp the clock has stepped
    /// behind comes out negative, and a negative gap is not a small one: it is a gap nothing can
    /// measure. Every question the SDK asks of a stamp - resume this session or open a new one,
    /// does leaving deserve a closing tick - is safe when the answer is "a long time" and stuck
    /// when it is "no time at all": one endless session, and no session boundaries, for the life
    /// of the bad stamp.
    func testAGapThatCannotBeMeasuredReadsAsALongOneAndNotAsNone() async throws {
        let id = "test.session.clockback.gap"; isolate(id)
        let clock = TestClock()
        // A minute of cadence, so the presence loop sleeps through the whole test in real time and
        // the stamps it would judge are still there for the two questions below to be asked of.
        let client = makeClient(appID: id, clock: clock, heartbeatInterval: 60)

        await client.setActive(true)  // session.start at t0
        await client.setActive(false)  // straight back out: no silence, so no closing ping
        await TestSupport.settle(0.3)
        clock.advance(-7200)  // the clock is corrected backwards while the app is away

        await client.setActive(true)
        await TestSupport.settle(0.2)
        let starts =
            RecordingProtocol.signals().filter { $0 == Signal.sessionStart }.count
            + (await client.pendingSignals().filter { $0 == Signal.sessionStart }.count)
        XCTAssertEqual(
            starts, 2, "a last-active stamp two hours ahead cannot say this is still the same visit")

        clock.advance(-7200)  // and again, under the stamps this stretch wrote
        await client.setActive(false)
        await TestSupport.settle(0.3)
        let pings =
            RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count
            + (await client.pendingSignals().filter { $0 == Signal.heartbeat }.count)
        XCTAssertEqual(
            pings, 1, "and leaving still closes the session: a silence it cannot measure is a long one")
        await client.shutdown()
    }

    /// The backoff a struggling server asks for is set by the delivery that is finishing, so an
    /// automatic attempt has to read it after joining that delivery, not before. Reading it first
    /// means the timer fires while a request is out, sees no backoff, waits out the request and
    /// then goes straight at the server anyway.
    func testAnAutomaticFlushReadsTheBackoffTheSendInProgressIsAboutToSet() async throws {
        let id = "test.session.backoffrace"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)

        RecordingProtocol.script([503])
        let hold = RecordingProtocol.holdNextRequest()
        let first = Task { await client.flushAutomatically() }
        let started = await TestSupport.waitUntil { hold.isStarted }
        XCTAssertTrue(started, "the first attempt is on the wire, and no backoff is set yet")

        // The flush timer fires while that request is still out: today's window.
        let second = Task { await client.flushAutomatically() }
        hold.proceed()
        await first.value
        await second.value

        let backoff = await client.backoffForTesting()
        XCTAssertEqual(backoff.failures, 1, "one failure, from one attempt")
        XCTAssertNotNil(backoff.nextAttemptAt)
        XCTAssertEqual(
            RecordingProtocol.requestSizes().count, 1,
            "the second attempt saw the backoff the first had just set and waited, rather than retrying inside it")
    }

    /// A permanent 4xx drops the whole slice, pings included, and the ingest rejects a batch like
    /// that before it reads a row - so those pings were never counted. Leaving their stamp in
    /// place spends a whole fresh interval before the install proves presence again, which at the
    /// cadence a free-plan account is asked for is longer than the dashboard's presence window.
    func testAPermanentRejectionDoesNotPaceTheNextPingFromPingsItThrewAway() async throws {
        let id = "test.session.4xxping"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock, minHeartbeatRetry: 1)
        await client.setActive(true)  // session.start at t0
        clock.advance(61)
        let ticked = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked, "the ping is due after a quiet minute")

        RecordingProtocol.script([400])  // rejected before a single row is read
        await client.flush()
        XCTAssertEqual(
            RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count, 0,
            "the server never saw that ping")

        clock.advance(2)  // past the replacement floor, which is paced from the dropped ping
        let replaced = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(replaced, "so presence is still owed, and the replacement arrives on the floor")
        await client.shutdown()
    }

    // MARK: - Delivery

    func testEveryRequestNamesTheSDKAndItsVersion() async throws {
        let id = "test.session.useragent"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        await client.flush()

        let agents = RecordingProtocol.receivedRequests().map { $0.value(forHTTPHeaderField: "User-Agent") }
        XCTAssertEqual(agents, ["AppGlance-Apple/\(AppGlance.version)"])
    }

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

    /// Two flushes that overlap the wait for the store's label. `inFlightBatch` is one slot -
    /// the record `persist()` writes of what is on the wire - so a second drain starting while
    /// the first slice is still out would put its own slice there, and the first slice would be
    /// in neither the queue nor the file the next launch reads. The second flush joins the first.
    func testASecondFlushJoinsTheOneWaitingForTheStoreRatherThanDrainingPastIt() async throws {
        let id = "test.session.doubledrain"; isolate(id)
        let store = StoreAnswerGate()
        addTeardownBlock { store.answer(nil) }  // never leave the injected ask blocked
        let client = makeClient(appID: id, clock: TestClock(), storeAnswer: { await store.ask() })
        for i in 0..<150 { await client.track(signal: "e\(i)", metadata: nil) }

        // The first request is held open, so "a slice is on the wire" is a moment the test can
        // stop in and read the disk.
        let hold = RecordingProtocol.holdNextRequest()
        let first = Task { await client.flush() }
        let asked = await store.waitUntilAsked()
        XCTAssertTrue(asked, "the first flush is waiting for the label")

        let second = Task { await client.flush() }
        await TestSupport.settle(0.3)
        XCTAssertFalse(
            hold.isStarted, "nothing may go on the wire while the label the first flush is waiting for is unsettled")

        store.answer(.testFlight)
        await TestSupport.settle(0.3)  // long enough for a second drain to have claimed a slice
        XCTAssertEqual(
            try TestSupport.persistedSignals(id).count, 150,
            "one slice on the wire and the rest queued: every event is still accounted for on disk")

        hold.proceed()
        await first.value
        await second.value
        XCTAssertEqual(RecordingProtocol.requestSizes(), [100, 50], "one drain in slices, not two drains")
        XCTAssertEqual(RecordingProtocol.signals(), (0..<150).map { "e\($0)" }, "everything, once, in order")
        XCTAssertEqual(try TestSupport.persistedSignals(id), [], "and nothing is owed")
    }

    /// The grace has to bound the wait for the label. Awaiting the ask's task is not a
    /// cancellation point, so a timer racing it inside a task group cannot end the wait: the
    /// group waits for the store however long it takes, and the launch where `AppTransaction` is
    /// slowest - one with no network - is exactly the launch whose first batch must not be held.
    func testAStoreThatNeverAnswersHoldsAFlushForTheGraceAndNoLonger() async throws {
        let id = "test.session.grace"; isolate(id)
        let store = StoreAnswerGate()  // asked, and never answered
        addTeardownBlock { store.answer(nil) }
        let client = makeClient(
            appID: id, clock: TestClock(), storeAnswer: { await store.ask() }, environmentAnswerGrace: 0.3)
        await client.track(signal: "a", metadata: nil)

        let flushing = Task { await client.flush() }
        let sent = await TestSupport.waitUntil(timeout: 3) { RecordingProtocol.signals() == ["a"] }
        XCTAssertTrue(sent, "the grace runs out and the batch leaves with the guessed label")

        store.answer(nil)  // whether or not the grace already released it, leave nothing blocked
        await flushing.value
    }

    /// A redirect on the batch POST is refused, not followed. `URLSession` follows one by default
    /// and re-applies the original headers to the new request, so the write key and whatever a
    /// `user.identify` is carrying would go to whatever host the answer names, and a `2xx` from
    /// there would be read as the batch being delivered - the events gone, and the customer's
    /// key and their user's email in a stranger's log.
    func testARedirectIsRefusedRatherThanFollowedWithTheWriteKey() async throws {
        let id = "test.session.redirect"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.identify([UserProperty.email: "ada@example.com"])

        let elsewhere = URL(string: "https://somewhere-else.invalid/v1/events")!
        RecordingProtocol.scriptRedirect(to: elsewhere)
        await client.flush()

        let hosts = RecordingProtocol.receivedRequests().compactMap { $0.url?.host }
        XCTAssertEqual(
            hosts, ["ingest.invalid"], "the key and the payload went to the configured host and nowhere else")
        XCTAssertEqual(RecordingProtocol.signals(), [], "and nothing was counted as delivered")
        let queued = await client.pendingSignals()
        XCTAssertEqual(queued, [Signal.identify], "the batch is kept for a later attempt, as any other failure is")
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

    /// A delivery that fails and comes back has changed nothing about what is owed: the slice
    /// moved from the queue into the in-flight slot and back, and the file holds the union of the
    /// two. The client skips a write whose bytes match the one it last landed, so those two full
    /// rewrites cost nothing - but only while the file still says what it is supposed to say,
    /// which is what the content assertions here are for.
    func testASliceWithNoPresencePingIsClaimedAndReturnedWithoutRewritingTheFile() async throws {
        let id = "test.session.elide"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        await client.track(signal: "b", metadata: nil)
        let afterTracking = await client.queueFileWritesForTesting()
        XCTAssertEqual(afterTracking, 2, "one write per tracked event, whatever else is elided")

        RecordingProtocol.script([503])
        await client.flush()
        let afterFailure = await client.queueFileWritesForTesting()
        XCTAssertEqual(
            afterFailure, afterTracking,
            "claimed and handed back with no ping in the slice: the file already owed exactly these two")
        XCTAssertEqual(try TestSupport.persistedSignals(id), ["a", "b"], "and it still says so")

        await client.flush()  // 202 this time
        let afterAcknowledgement = await client.queueFileWritesForTesting()
        XCTAssertEqual(afterAcknowledgement, afterTracking + 1, "the acknowledgement is a change, so it is written")
        XCTAssertEqual(try TestSupport.persistedSignals(id), [])
    }

    /// The write the elision must never skip. Claiming a slice that carries a ping takes that
    /// ping off disk, and it has to be gone before the request leaves: the server folds pings
    /// additively and never dedupes, so one recovered by the next launch is counted twice.
    func testClaimingASliceThatCarriesAPingStillRewritesTheFile() async throws {
        let id = "test.session.elide.ping"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: Signal.heartbeat, metadata: nil)
        await client.track(signal: "purchase", metadata: nil)
        let beforeSend = await client.queueFileWritesForTesting()

        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        while !hold.isStarted { await TestSupport.settle(0.02) }
        XCTAssertEqual(
            try TestSupport.persistedSignals(id), ["purchase"], "the ping is off disk before it is on the wire")
        let inFlightWrites = await client.queueFileWritesForTesting()
        XCTAssertGreaterThan(inFlightWrites, beforeSend, "which takes a write, however the bytes compare")

        hold.proceed()
        await flushing.value
        XCTAssertEqual(RecordingProtocol.signals(), [Signal.heartbeat, "purchase"])
        XCTAssertEqual(try TestSupport.persistedSignals(id), [])
    }

    /// The queue file lives in Caches, which the system may reclaim at any moment. A write is
    /// skipped only against a file that is still there, or a client that had just been asked to
    /// write what it wrote last would leave the queue nowhere at all.
    func testAnIdenticalWriteIsNotSkippedWhenTheFileHasBeenReclaimed() async throws {
        let id = "test.session.elide.reclaimed"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        try FileManager.default.removeItem(at: Client.makeStoreURL(appID: id))

        // Claimed and handed straight back, for bytes identical to the ones last written.
        RecordingProtocol.script([503])
        await client.flush()

        XCTAssertEqual(
            try TestSupport.persistedSignals(id), ["a"], "the event is owed, so something on disk has to say so")
    }

    /// The queue file holds what is OWED, which is the queue plus the non-ping half of the slice
    /// that was on the wire, so it can legitimately carry a whole request more than the queue's
    /// own cap. Restoring it whole started the next launch over that cap and left it there until
    /// something else was tracked, so the documented 500-event ceiling was really 600 on exactly
    /// the launch that follows a crash mid-delivery. The Kotlin SDK trims on the same path.
    func testAQueueFileHoldingMoreThanTheCapIsTrimmedOnTheWayIn() async throws {
        let id = "test.session.restore.cap"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        for i in 0..<300 { await client.track(signal: "e\(i)", metadata: nil) }
        let url = Client.makeStoreURL(appID: id)
        let stored = try EventCoding.makeDecoder().decode([Event].self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.count, 300, "nothing is trimmed under the cap")

        // A file carrying 600 owed events: the shape a kill mid-delivery leaves behind.
        try EventCoding.makeEncoder().encode(stored + stored).write(to: url)
        XCTAssertEqual(try TestSupport.persistedSignals(id).count, 600, "the file really does hold 600")

        let restored = await makeClient(appID: id, clock: TestClock()).pendingEvents().count
        XCTAssertEqual(restored, 500, "the launch starts at the cap, not over it")
    }

    /// The elision remembers what LANDED, not what was offered. A store that refuses a write and
    /// says so must not leave the client believing the file holds those bytes, because the write
    /// that follows is very often the identical one: claiming a slice and handing it back both
    /// write the union of the queue and the in-flight batch, which is the same set. Skipping that
    /// one against a file that never received it leaves the disk a whole event behind the client,
    /// and a kill in between loses it - the one way this saving could cost events.
    func testAQueueWriteThatDidNotLandIsNotRememberedAsThoughItHad() async throws {
        let id = "test.session.elide.refused"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        XCTAssertEqual(try TestSupport.persistedSignals(id), ["a"], "the first write is on disk")

        await client.refuseQueueWritesForTesting(true)
        await client.track(signal: "b", metadata: nil)
        XCTAssertEqual(try TestSupport.persistedSignals(id), ["a"], "the refused write left the file as it was")

        // The disk frees up, and the next write carries exactly the bytes the refused one did:
        // claiming a slice with no ping in it and handing it back is the commonest write there is.
        await client.refuseQueueWritesForTesting(false)
        RecordingProtocol.script([503])
        await client.flush()

        XCTAssertEqual(
            try TestSupport.persistedSignals(id), ["a", "b"],
            "the write the elision would have skipped is the one that repairs the file")
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
            RecordingProtocol.requestSizes(), [2],
            "the held slice carried both; a delivery sends what was owed when it began and no more")
        XCTAssertEqual(
            try TestSupport.persistedSignals(id), ["later"],
            "and the event tracked while it was on the wire is still owed, waiting for the next one")

        await client.flush()
        XCTAssertEqual(RecordingProtocol.requestSizes(), [2, 1], "which the next delivery carries")
        XCTAssertEqual(RecordingProtocol.signals(), [Signal.heartbeat, "purchase", "later"])
        XCTAssertEqual(try TestSupport.persistedSignals(id), [], "acknowledged: nothing is owed")
    }

    /// A later `configure` replaces the client. The old one must stop recording and, above all,
    /// stop writing the queue file the replacement now owns.
    /// The queue cap. An install offline for a long stretch keeps recording, and `persist()`
    /// rewrites the whole array on every single `track`, so an uncapped queue costs memory and
    /// battery in proportion to its own square and grows the file in Caches until the write fails
    /// or the system reclaims it, taking everything with it. Five hundred events, and it is the
    /// oldest that go: the newest are the ones still worth sending.
    func testTheQueueIsHardCappedAndTheOldestGoFirst() async throws {
        let id = "test.session.cap"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        // The outage itself. `maxBatchSize` cannot be set above the cap, so a queue at the cap is
        // always one the batch-size trigger has just tried to send; the failure returns the slice
        // and the frozen clock keeps the backoff from letting a second attempt through.
        RecordingProtocol.script(Array(repeating: 503, count: 10))
        for i in 0..<520 { await client.track(signal: "e\(i)", metadata: nil) }
        await TestSupport.settle(0.4)

        let queued = await client.pendingSignals()
        XCTAssertEqual(queued.count, 500, "the cap holds however long the outage lasts")
        XCTAssertEqual(queued.first, "e20", "and it is the oldest twenty that went")
        XCTAssertEqual(queued.last, "e519", "so what is kept is the most recent five hundred")
        XCTAssertEqual(
            try TestSupport.persistedSignals(id).count, 500, "and the file a relaunch reads is capped with it")
    }

    /// A slice that comes back goes in front of everything recorded while it was away, which can
    /// stand the queue over the cap. Only `track` would trim it otherwise: an app that records
    /// rarely but flushes on a timer sits above the cap for as long as the outage lasts, and
    /// `persist()` writes the oversized array to disk every time it is asked to.
    func testARequeuedSliceIsTrimmedBackToTheCap() async throws {
        let id = "test.session.cap.requeue"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        RecordingProtocol.script(Array(repeating: 503, count: 10))
        let hold = RecordingProtocol.holdNextRequest()
        // The batch-size trigger fires as the queue reaches the cap, and the recorder holds that
        // request open while the app keeps recording behind it.
        for i in 0..<500 { await client.track(signal: "e\(i)", metadata: nil) }
        let started = await TestSupport.waitUntil { hold.isStarted }
        XCTAssertTrue(started, "the first hundred are on the wire, four hundred still queued behind them")
        for i in 0..<20 { await client.track(signal: "late\(i)", metadata: nil) }
        hold.proceed()
        await TestSupport.settle(0.4)

        let queued = await client.pendingSignals()
        XCTAssertEqual(
            queued.count, 500, "the slice went back in front of the twenty tracked meanwhile, and the cap held")
        XCTAssertEqual(queued.first, "e20", "the oldest of what came back is what the cap dropped")
        XCTAssertEqual(queued.last, "late19", "and nothing recorded during the outage was lost to make room")
        XCTAssertEqual(try TestSupport.persistedSignals(id).count, 500, "the file was never written oversized")
    }

    /// A burst - a screenful of items, a replayed queue of user actions, anything recorded faster
    /// than one request round trip - has to leave as batches. Every event past `maxBatchSize`
    /// reaches the batch-size trigger again, and the drain is fed by the same queue the app is
    /// writing to: uncoalesced and unbounded, the two together turn a burst into one request per
    /// event, each paying its own round trip and its own full set of headers, and the ingest sees
    /// a rate-limitable storm from one install.
    func testABurstOfEventsLeavesInBatchesAndNotOneRequestPerEvent() async throws {
        let id = "test.session.burst"; isolate(id)
        let client = Client(
            config: TestSupport.configuration(appID: id, maxBatchSize: 20),
            userID: "u-\(id)", session: TestSupport.recordingSession())

        for i in 0..<200 { await client.track(signal: "e\(i)", metadata: nil) }
        await TestSupport.settle(0.2)
        await client.flush()  // the tail, which is otherwise the flush timer's

        let sizes = RecordingProtocol.requestSizes()
        XCTAssertEqual(RecordingProtocol.signals().count, 200, "everything arrives")
        XCTAssertLessThanOrEqual(
            sizes.count, 20, "two hundred events in twenty-event batches is a dozen requests, not two hundred")
        XCTAssertEqual(sizes.filter { $0 == 1 }.count, 0, "and no request carries a single event")
        XCTAssertTrue(
            sizes.dropLast().allSatisfy { $0 >= 20 },
            "every request but the last carries a full batch: what is recorded while one is on the wire rides"
                + " along in the next, rather than each event asking for a delivery of its own")
    }

    /// The flush on the way to the background and every explicit `flush()` run under a process
    /// assertion, and that assertion has a ceiling. A request allowed to outlive it is answered
    /// into a suspended process: the batch is counted as failed and the whole slice is re-uploaded
    /// on the next launch, which is exactly the replay the assertion is held to prevent.
    func testABatchRequestCannotOutliveTheProcessAssertionHeldForIt() async throws {
        let id = "test.session.timeout"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())
        await client.track(signal: "a", metadata: nil)
        await client.flush()

        let request = try XCTUnwrap(RecordingProtocol.receivedRequests().first)
        XCTAssertLessThanOrEqual(
            request.timeoutInterval, ProcessHold.maximumHold,
            "a request the hold cannot outlast is one whose answer arrives at a process that is gone")
        XCTAssertGreaterThanOrEqual(
            request.timeoutInterval, 10, "and not so tight that an ordinary slow connection cannot finish")
    }

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

    /// A batch can come back after a second `configure` has retired the client that sent it, and
    /// its answer can carry the server's cadence floor. The floor key is the install's: the
    /// replacement client read it at its own init and owns it from then on.
    func testAFloorThatLandsAfterTheClientIsRetiredIsNotAdopted() async throws {
        let id = "test.session.retired.floor"; isolate(id)
        let old = makeClient(appID: id, clock: TestClock())
        await old.track(signal: "before", metadata: nil)
        RecordingProtocol.scriptResponseBody(#"{"accepted":1,"heartbeat_interval":240}"#)
        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await old.flush() }
        let started = await TestSupport.waitUntil { hold.isStarted }
        XCTAssertTrue(started, "the batch is on the wire")

        await old.shutdown()  // a second configure replaces the client mid-send
        hold.proceed()  // the 2xx lands afterwards, floor and all
        await flushing.value

        XCTAssertNil(
            UserDefaults.standard.object(forKey: "app.appglance.heartbeatFloor.\(id)"),
            "the floor key is the replacement's to move")
        let interval = await old.heartbeatIntervalForTesting()
        XCTAssertEqual(interval, 60, "and the retired client paces nothing by it")
    }

    /// The 15 s replacement floor lives in the stamp, so it survives the visit ending. The re-arm
    /// that enforces it runs only while the app is in front, and a ping dropped by the flush on
    /// the way to the background used to leave nothing behind but the rolled-back stamp: coming
    /// back seconds later ticked at once, a second ping within seconds of one the server may well
    /// have counted, and a relaunch inside the interval did the same with no live state at all.
    func testADroppedPingsReplacementFloorSurvivesABackgroundBounce() async throws {
        let id = "test.session.hbretry.bounce"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)
        await client.setActive(true)  // session.start proves presence at t0
        await client.flush()  // and is acknowledged, so only the ping is ever owed
        clock.advance(60)
        await client.heartbeatForTesting()  // the visit's one ping, stamped t60
        RecordingProtocol.script([500])
        clock.advance(1)
        await client.setActive(false)  // quiet for 1 s: no closing tick, and the flush fails
        let failed = await TestSupport.waitUntilAsync {
            await client.backoffForTesting().failures == 1
        }
        XCTAssertTrue(failed, "the departure flush failed, so the ping was dropped and rolled back")

        clock.advance(4)
        await client.setActive(true)  // back five seconds after the dropped ping
        let wait = await client.timeUntilNextHeartbeatForTesting()
        XCTAssertEqual(
            wait, 10, accuracy: 0.01,
            "the replacement is due 15 s after the ping it replaces, not the moment the app is back")
        await client.shutdown()
    }

    /// At `maxBatchSize: 1` every track is its own trigger, and one tracked between a delivery's
    /// final look at the queue and the trigger flag clearing has only the refusal to speak for
    /// it. The refusal leaves a timer armed, so the event is delivered without waiting for the
    /// app to do anything else.
    func testATriggerRefusedDuringADeliveryLeavesTheFlushTimerArmed() async throws {
        let id = "test.session.trigger.refused"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock(), maxBatchSize: 1)
        let hold = RecordingProtocol.holdNextRequest()
        await client.track(signal: "one", metadata: nil)  // its own trigger: the delivery starts
        let started = await TestSupport.waitUntil { hold.isStarted }
        XCTAssertTrue(started, "the first event is on the wire")

        await client.track(signal: "two", metadata: nil)  // trigger refused: a delivery is out
        let armed = await client.flushTimerIsArmedForTesting()
        XCTAssertTrue(armed, "the refusal leaves the timer as the event's trigger")

        hold.proceed()
        await client.flush()
        XCTAssertEqual(RecordingProtocol.signals(), ["one", "two"], "and nothing is lost either way")
        await client.shutdown()
    }
}
