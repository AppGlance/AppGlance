import XCTest

@testable import AppGlance

/// What the client sends for the lifecycle transitions SwiftUI actually produces - including the
/// doubled ones (`onAppear` + first `scenePhase`, `.inactive` + `.background`) - and how it
/// delivers the queue.
final class SessionTests: XCTestCase {

    private func makeClient(appID: String, clock: TestClock, sessionTimeout: TimeInterval = 300) -> Client {
        Client(
            config: TestSupport.configuration(appID: appID, sessionTimeout: sessionTimeout),
            userID: "u-\(appID)", session: TestSupport.recordingSession(), now: { clock.now })
    }

    /// Clean state before the test and again after it.
    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    // MARK: - Sessions and the heartbeat

    func testLaunchStartsExactlyOneSessionAndOneHeartbeat() async throws {
        let id = "test.session.launch"; isolate(id)
        let client = makeClient(appID: id, clock: TestClock())

        // onAppear, then scenePhase → .active: two reports of the same fact.
        await client.setActive(true)
        await client.setActive(true)
        let ticked1 = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked1, "the heartbeat task got its turn")

        let queued = await client.pendingSignals()
        XCTAssertEqual(
            queued, [Signal.sessionStart, Signal.heartbeat],
            "one session.start then one heartbeat - never two of either")
    }

    func testBriefInterruptionResumesTheSameSession() async throws {
        let id = "test.session.brief"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)
        let ticked1 = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked1, "the heartbeat task got its turn")
        clock.advance(20)
        await client.setActive(false)  // .inactive (a notification banner, say)
        await client.setActive(false)  // .background - must not flush or act twice
        clock.advance(30)
        await client.setActive(true)  // back within the timeout: the next beat is 30 s away
        await client.setActive(false)
        await client.flush()

        let sent = RecordingProtocol.signals()
        XCTAssertEqual(
            sent.filter { $0 == Signal.sessionStart }.count, 1, "50 seconds away is an interruption, not a new session")
        XCTAssertEqual(
            sent.filter { $0 == Signal.heartbeat }.count, 1,
            "resuming inside the heartbeat interval must not tick again at once")
        let left = await client.pendingSignals()
        XCTAssertTrue(left.isEmpty, "a successful flush clears the queue")
    }

    func testReturningAfterTheTimeoutStartsANewSession() async throws {
        let id = "test.session.timeout"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.setActive(true)
        let ticked1 = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked1, "the heartbeat task got its turn")
        await client.setActive(false)
        clock.advance(6 * 60)  // longer than the 5-minute session timeout
        await client.setActive(true)
        let ticked2 = await TestSupport.waitForHeartbeats(2, from: client)
        XCTAssertTrue(ticked2, "the heartbeat task got its turn")
        await client.setActive(false)
        await client.flush()

        XCTAssertEqual(
            RecordingProtocol.signals(),
            [Signal.sessionStart, Signal.heartbeat, Signal.sessionStart, Signal.heartbeat],
            "each return after the gap is a new session with its own first heartbeat")
    }

    func testRelaunchWithinTimeoutContinuesTheSessionAcrossProcesses() async throws {
        let id = "test.session.relaunch"; isolate(id)
        let clock = TestClock()

        let first = makeClient(appID: id, clock: clock)
        await first.setActive(true)
        let ticked1 = await TestSupport.waitForHeartbeats(1, from: first)
        XCTAssertTrue(ticked1, "the heartbeat task got its turn")
        await first.track(signal: "paywall.viewed", metadata: nil)
        let sid = await first.currentSessionID()
        XCTAssertNotNil(sid)
        await first.setActive(false)
        await first.flush()

        clock.advance(60)  // quit and reopened a minute later: same session
        let second = makeClient(appID: id, clock: clock)
        await second.setActive(true)
        let ticked2 = await TestSupport.waitForHeartbeats(2, from: second)
        XCTAssertTrue(ticked2, "the heartbeat task got its turn")
        let sid2 = await second.currentSessionID()
        XCTAssertEqual(sid2, sid, "same session id across a quit-and-relaunch inside the timeout")
        await second.setActive(false)
        await second.flush()

        clock.advance(20 * 60)  // reopened much later: a new session
        let third = makeClient(appID: id, clock: clock)
        await third.setActive(true)
        let ticked3 = await TestSupport.waitForHeartbeats(3, from: third)
        XCTAssertTrue(ticked3, "the heartbeat task got its turn")
        let sid3 = await third.currentSessionID()
        XCTAssertNotEqual(sid3, sid)
        await third.flush()

        let sent = RecordingProtocol.signals()
        XCTAssertEqual(
            sent.filter { $0 == Signal.sessionStart }.count, 2,
            "the dashboard splits sessions on a 5-minute gap; the SDK agrees")
        let ids = RecordingProtocol.sessions()
        XCTAssertTrue(ids.allSatisfy { $0 != nil }, "every event carries its session id")
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 2, "two sessions were lived")
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
