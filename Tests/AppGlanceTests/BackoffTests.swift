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
