import Foundation
import StoreKit
import XCTest

@testable import AppGlance

/// The environment correction: the store's answer maps onto the SDK's vocabulary, queued
/// events are restamped before anything is sent, and the sending gate follows the corrected
/// environment, not the guess.
final class EnvironmentTests: XCTestCase {

    func testStoreEnvironmentMapsOntoSDKVocabulary() {
        XCTAssertEqual(AppEnvironment.refined(from: .sandbox, fallback: .appStore), .testFlight)
        XCTAssertEqual(AppEnvironment.refined(from: .production, fallback: .testFlight), .appStore)
        XCTAssertEqual(AppEnvironment.refined(from: .xcode, fallback: .appStore), .debug)
    }

    func testAdoptRestampsQueueAndSendsCorrectedLabel() async throws {
        let appID = "env.restamp"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)
        await client.track(signal: Signal.heartbeat, metadata: nil)

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingEvents()
        XCTAssertEqual(Set(queued.map(\.environment)), ["testflight"])
        await client.flush()
        let sent = RecordingProtocol.receivedBatches().flatMap { $0 }
        XCTAssertEqual(Set(sent.map(\.environment)), ["testflight"])
    }

    func testAdoptKeepsLabelsFromEarlierRuns() async throws {
        let appID = "env.foreign"
        TestSupport.fresh(appID)
        // An event persisted by an earlier run under a different label; this process cannot
        // vouch for that run's channel, so the correction must not touch it. The label must
        // differ from every test host's guess (macOS guesses debug, an iOS Simulator host
        // guesses simulator), or the restamp would legitimately rewrite it.
        let foreign = Event(
            event_id: "11111111-1111-1111-1111-111111111111", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "purchase", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([foreign])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)
        await client.adoptEnvironment(.testFlight)

        let labels = await client.pendingEvents().map(\.environment).sorted()
        XCTAssertEqual(labels, ["appstore", "testflight"], "the foreign label survives; the guessed one is restamped")
    }

    func testAdoptDropsQueueWhenGateCloses() async throws {
        let appID = "env.gate.closes"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingEvents()
        XCTAssertTrue(queued.isEmpty)
        await client.track(signal: "after", metadata: nil)
        let after = await client.pendingEvents()
        XCTAssertTrue(after.isEmpty)
    }

    func testNilStoreAnswerLeavesGuessAndAllowsRetry() async throws {
        let appID = "env.retry"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "first", metadata: nil)

        await client.adoptStoreAnswer(nil)
        let unchanged = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(unchanged), [AppEnvironment.current.rawValue])

        await client.adoptStoreAnswer(.testFlight)
        let corrected = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(corrected), ["testflight"])
    }

    func testStoreAnswerIsAdoptedOnce() async throws {
        let appID = "env.once"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.adoptStoreAnswer(.testFlight)
        await client.adoptStoreAnswer(.appStore)
        await client.track(signal: "after", metadata: nil)
        let labels = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(labels), ["testflight"])
    }

    /// A build the store can never answer for - a directly downloaded Mac app, an ad hoc or
    /// enterprise build - must not spend a task and a storekitd round trip per flush for the
    /// life of the process. `asksTheStore` is injected because a test host is a Debug build,
    /// whose environment is a compile-time fact, so the ask path is otherwise never entered.
    func testTheStoreIsNotAskedForeverWhenItNeverAnswers() async throws {
        let appID = "env.ceiling"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession(), asksTheStore: true)

        for _ in 0..<10 {
            await client.beginEnvironmentRefinement()
            // The ask resolves to "no answer" at once on this host; let the slot clear, or the
            // next call would be swallowed by the one-ask-at-a-time guard rather than the ceiling.
            let deadline = Date().addingTimeInterval(2)
            while await client.environmentAskIsOpenForTesting(), Date() < deadline {
                await TestSupport.settle(0.01)
            }
        }

        let asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 5, "a few retries for the fresh install that has nothing cached, then the guess stands")
    }

    /// The label only matters for events about to leave, so a flush with nothing to send neither
    /// asks nor waits for an answer.
    func testAnEmptyFlushDoesNotAskTheStore() async throws {
        let appID = "env.emptyflush"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession(), asksTheStore: true)

        await client.flush()
        var asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 0, "nothing queued: no ask, and no wait for one")

        await client.track(signal: "a", metadata: nil)
        await client.flush()
        asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 1, "a flush that has something to label does ask")
        XCTAssertEqual(RecordingProtocol.signals(), ["a"])
    }

    func testAdoptOpensGateForCorrectedEnvironment() async throws {
        let appID = "env.gate.opens"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.testFlight]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "dropped.by.guess", metadata: nil)

        await client.adoptEnvironment(.testFlight)

        await client.track(signal: "collected", metadata: nil)
        let signals = await client.pendingSignals()
        XCTAssertEqual(signals, ["collected"])
    }
}
