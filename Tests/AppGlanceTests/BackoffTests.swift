import XCTest

@testable import AppGlance

/// The retry backoff: a retryable failure delays the next automatic attempt (exponentially,
/// capped, jittered, floored by a numeric Retry-After on 429), a success resets it, and an
/// explicit `flush()` never waits. The backoff only delays attempts; what a retry may carry is
/// pinned by the heartbeat tests in `SessionTests`.
final class BackoffTests: XCTestCase {

    private func makeClient(appID: String, clock: TestClock, maxBatchSize: Int = 1000) -> Client {
        Client(
            config: TestSupport.configuration(appID: appID, maxBatchSize: maxBatchSize),
            userID: "u-\(appID)", session: TestSupport.recordingSession(), now: { clock.now })
    }

    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    /// Waits until the recorder has seen `count` requests, so a test never races a detached send.
    private func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if RecordingProtocol.requestSizes().count >= count { return true }
            await TestSupport.settle(0.02)
        }
        return false
    }

    func testRetryableFailureSchedulesADelayAndAutomaticTriggersRespectIt() async throws {
        let id = "test.backoff.waits"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock, maxBatchSize: 2)

        await client.track(signal: "a", metadata: nil)
        RecordingProtocol.script([503])
        await client.flush()

        let failed = await client.backoffForTesting()
        XCTAssertEqual(failed.failures, 1)
        let delay = try XCTUnwrap(failed.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertGreaterThan(delay, 0, "a retryable failure schedules a wait")
        XCTAssertLessThanOrEqual(delay, 60, "and the wait is capped")

        // Reaching maxBatchSize is an automatic trigger: inside the backoff it must not send.
        await client.track(signal: "b", metadata: nil)
        await TestSupport.settle(0.3)
        XCTAssertEqual(
            RecordingProtocol.requestSizes().count, 1,
            "the batch-size trigger waited instead of hammering a struggling server")

        // An explicit flush is the developer's own decision: it attempts at once, and the
        // success resets the backoff.
        await client.flush()
        XCTAssertEqual(RecordingProtocol.requestSizes().count, 2, "flush() ignores the backoff window")
        XCTAssertEqual(RecordingProtocol.signals(), ["a", "b"], "nothing was lost while backing off")
        let reset = await client.backoffForTesting()
        XCTAssertEqual(reset.failures, 0)
        XCTAssertNil(reset.nextAttemptAt)

        // With the backoff gone, the automatic trigger sends again.
        await client.track(signal: "c", metadata: nil)
        await client.track(signal: "d", metadata: nil)
        let sent = await waitForRequests(3)
        XCTAssertTrue(sent, "the batch-size trigger flushes as usual once the backoff is reset")
    }

    func testConsecutiveFailuresGrowTheDelayExponentially() async throws {
        let id = "test.backoff.grows"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.track(signal: "a", metadata: nil)
        RecordingProtocol.script([503, 503])
        await client.flush()
        await client.flush()

        let state = await client.backoffForTesting()
        XCTAssertEqual(state.failures, 2, "each retryable failure counts")
        let delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertGreaterThanOrEqual(delay, 2, "two failures wait at least 2 to the power of 2 halved")
        XCTAssertLessThanOrEqual(delay, 4, "and at most 2 to the power of 2")
    }

    func testNumericRetryAfterOn429IsTheFloor() async throws {
        let id = "test.backoff.retryafter"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.track(signal: "a", metadata: nil)
        RecordingProtocol.script([429])
        RecordingProtocol.scriptResponseHeaders(["Retry-After": "45"])
        await client.flush()

        let state = await client.backoffForTesting()
        XCTAssertEqual(state.failures, 1)
        let delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertEqual(delay, 45, accuracy: 0.5, "the server's stated wait is honored, not shortened")
        let left = await client.pendingSignals()
        XCTAssertEqual(left, ["a"], "rate-limited: the batch is kept for the delayed attempt")
    }

    /// A failed delivery arms its own retry. The batch-size trigger asks for one delivery at a
    /// time, so everything recorded behind a failing one has already been folded into it: left to
    /// the next `track`, an app that goes quiet after a burst would sit on a full queue until
    /// something else happened to it.
    func testAFailedDeliveryArmsItsOwnRetryWithoutWaitingForAnotherEvent() async throws {
        let id = "test.backoff.selfretry"; isolate(id)
        // The real clock here, not a settable one: the wait this is about is a real wait, and the
        // point is that it elapses without anything else prompting the client.
        let client = Client(
            config: TestSupport.configuration(appID: id, maxBatchSize: 2),
            userID: "u-\(id)", session: TestSupport.recordingSession())

        RecordingProtocol.script([503])
        await client.track(signal: "a", metadata: nil)
        await client.track(signal: "b", metadata: nil)  // the batch-size trigger
        let attempted = await waitForRequests(1)
        XCTAssertTrue(attempted, "the trigger sent, and the server said later")

        let retried = await waitForRequests(2, timeout: 10)
        XCTAssertTrue(retried, "and the retry arrives on its own, with no further event to prompt it")
        XCTAssertEqual(RecordingProtocol.signals(), ["a", "b"], "in order, and nothing lost on the way")
    }

    /// `Retry-After` is how a maintenance window or a load shed says how long to stay away, and
    /// 503 is the status those answer with: 429 is the narrower case where this one install is
    /// being throttled. Ignoring the header on the wider one means every install keeps hitting the
    /// origin every half minute for the length of the window, which is the case it exists for.
    func testNumericRetryAfterIsHonouredOnAnAnsweredFailureAndNotOnly429() async throws {
        let id = "test.backoff.retryafter.503"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.track(signal: "a", metadata: nil)
        RecordingProtocol.script([503])
        RecordingProtocol.scriptResponseHeaders(["Retry-After": "600"])
        await client.flush()

        let state = await client.backoffForTesting()
        XCTAssertEqual(state.failures, 1)
        let delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertEqual(delay, 600, accuracy: 0.5, "the window the server named is waited out, not a jittered second")
    }

    /// The ceiling widens once an outage has outlasted the cadence meant for a server that is
    /// briefly unwell. Held at a minute, a foregrounded install re-uploads the same head slice
    /// every 30 to 60 s for the length of the outage - megabytes of cellular upload for data that
    /// never lands, and a herd that never thins in front of an ingest that is already failing.
    /// Nothing is lost by waiting: the queue is on disk, and `flush()` and the flush on the way to
    /// the background both ignore the backoff entirely.
    func testASustainedOutageWidensTheCeilingRatherThanRetryingEveryMinute() async throws {
        let id = "test.backoff.sustained"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)
        await client.track(signal: "a", metadata: nil)

        // flush() is the developer's own decision and never waits out the backoff, so each of
        // these really attempts.
        RecordingProtocol.script(Array(repeating: 503, count: 10))
        for _ in 0..<10 { await client.flush() }

        var state = await client.backoffForTesting()
        XCTAssertEqual(state.failures, 10)
        var delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertGreaterThanOrEqual(delay, 30)
        XCTAssertLessThanOrEqual(delay, 60, "ten failures is still a server that may be about to come back")

        RecordingProtocol.script([503])
        await client.flush()

        state = await client.backoffForTesting()
        XCTAssertEqual(state.failures, 11)
        delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertGreaterThan(
            delay, 60, "past that it is an outage, and re-uploading the head every minute buys nothing")
        XCTAssertLessThanOrEqual(delay, 300, "and the wider ceiling is a ceiling too")
        let left = await client.pendingSignals()
        XCTAssertEqual(left, ["a"], "waiting longer costs nothing: the queue is kept, and it is on disk")
    }

    /// `Retry-After` is a number from the server, and `TimeInterval(_: String)` parses "inf" and
    /// eleven digits alike. It is obeyed like the presence cadence the server asks for: finite,
    /// positive, and capped - past a quarter of an hour it is an outage, not rate limiting, and
    /// an unbounded value would reach the sleep conversion, where it is a crash in the host app.
    func testAbsurdRetryAfterIsCappedRatherThanObeyed() async throws {
        let id = "test.backoff.retryafter.absurd"; isolate(id)
        let clock = TestClock()
        let client = makeClient(appID: id, clock: clock)

        await client.track(signal: "a", metadata: nil)
        RecordingProtocol.script([429, 429])
        RecordingProtocol.scriptResponseHeaders(["Retry-After": "86400"])
        await client.flush()

        var state = await client.backoffForTesting()
        var delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertEqual(delay, 900, accuracy: 0.5, "a day is not a rate limit: capped at the longest wait obeyed")

        RecordingProtocol.scriptResponseHeaders(["Retry-After": "inf"])
        await client.flush()
        state = await client.backoffForTesting()
        delay = try XCTUnwrap(state.nextAttemptAt).timeIntervalSince(clock.now)
        XCTAssertLessThanOrEqual(delay, 60, "a value with no meaning is ignored; the exponential wait stands")
        XCTAssertGreaterThan(delay, 0)

        // The remaining wait is armed as a real timer, so the conversion to nanoseconds happens
        // for real: it must not trap, and the automatic trigger must still hold its fire.
        await client.track(signal: "b", metadata: nil)
        await client.flushAutomatically()
        await TestSupport.settle(0.1)
        XCTAssertEqual(RecordingProtocol.requestSizes().count, 2, "inside the backoff, no third attempt")
        let left = await client.pendingSignals()
        XCTAssertEqual(left, ["a", "b"], "both kept for the delayed attempt, and the process is still here")
    }
}
