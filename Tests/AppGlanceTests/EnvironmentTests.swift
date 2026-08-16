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
        // vouch for that run's channel, so the correction must not touch it.
        let foreign = Event(
            event_id: "11111111-1111-1111-1111-111111111111", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "purchase", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "simulator", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([foreign])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)
        await client.adoptEnvironment(.testFlight)

        let labels = await client.pendingEvents().map(\.environment).sorted()
        XCTAssertEqual(labels, ["simulator", "testflight"])
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
