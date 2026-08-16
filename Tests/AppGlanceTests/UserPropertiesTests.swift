import XCTest

@testable import AppGlance

/// `identify` / `setUserProperties` / `reset`: labels on the install id, sent only when they
/// change, remembered across launches, forgotten on sign-out.
final class UserPropertiesTests: XCTestCase {

    private func makeClient(appID: String) -> Client {
        Client(config: TestSupport.configuration(appID: appID), userID: "u-\(appID)")
    }

    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    func testIdentifySendsOnceAndMergesLater() async throws {
        let id = "test.traits.merge"; isolate(id)
        let client = makeClient(appID: id)

        await client.identify([UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])
        await client.identify([UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])  // same again: free
        var queued = await client.pendingEvents()
        XCTAssertEqual(queued.map(\.signal), [Signal.identify], "identical values must not cost a second event")
        XCTAssertEqual(queued[0].metadata, [UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])

        await client.identify(["plan": "pro"])  // a new property merges with the old ones
        queued = await client.pendingEvents()
        XCTAssertEqual(queued.map(\.signal), [Signal.identify, Signal.identify])
        XCTAssertEqual(
            queued[1].metadata, [UserProperty.email: "ada@example.com", UserProperty.name: "Ada", "plan": "pro"],
            "each identify carries the whole merged set, so the server can store it as-is")

        await client.identify(["plan": ""])  // an empty string removes a key
        let traits = await client.currentTraits()
        XCTAssertEqual(traits, [UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])
    }

    func testTraitsSurviveARelaunchSoTheUsualLaunchTimeIdentifyIsFree() async throws {
        let id = "test.traits.relaunch"; isolate(id)
        let first = makeClient(appID: id)
        await first.identify([UserProperty.id: "acct_42"])
        let afterFirst = await first.pendingSignals()
        XCTAssertEqual(afterFirst, [Signal.identify])

        let second = makeClient(appID: id)  // the app relaunches and identifies again
        await second.identify([UserProperty.id: "acct_42"])
        let queued = await second.pendingSignals()
        XCTAssertEqual(
            queued, [Signal.identify],
            "the queue on disk holds the one event from the first launch; the relaunch added nothing")
    }

    func testResetForgetsAndReidentifyResendsEverything() async throws {
        let id = "test.traits.reset"; isolate(id)
        let client = makeClient(appID: id)
        await client.reset()  // nothing to forget yet: silent
        let silent = await client.pendingSignals()
        XCTAssertEqual(silent, [])

        await client.identify([UserProperty.email: "ada@example.com"])
        await client.reset()
        let afterReset = await client.pendingSignals()
        XCTAssertEqual(afterReset, [Signal.identify, Signal.reset])
        let traitsAfterReset = await client.currentTraits()
        XCTAssertEqual(traitsAfterReset, [:])

        await client.identify([UserProperty.email: "ada@example.com"])  // signs back in
        let queued = await client.pendingEvents()
        XCTAssertEqual(queued.map(\.signal), [Signal.identify, Signal.reset, Signal.identify])
        XCTAssertEqual(
            queued[2].metadata, [UserProperty.email: "ada@example.com"], "after a reset the same values are new again")
    }

    func testAtMostTwentyPropertiesReservedOnesFirst() async throws {
        let id = "test.traits.cap"; isolate(id)
        let client = makeClient(appID: id)
        var many: [String: String] = [UserProperty.email: "ada@example.com"]
        for i in 0..<30 { many["k\(String(format: "%02d", i))"] = "v" }
        await client.identify(many)
        let traits = await client.currentTraits()
        XCTAssertEqual(traits.count, 20, "the ingest API keeps 20 metadata keys; the SDK must not pretend otherwise")
        XCTAssertEqual(traits[UserProperty.email], "ada@example.com", "reserved keys are kept ahead of custom ones")
    }

    func testKeysAndValuesAreTrimmedAndClamped() async throws {
        let id = "test.traits.clamp"; isolate(id)
        let client = makeClient(appID: id)
        await client.identify([
            "  plan  ": "  " + String(repeating: "x", count: 300),
            String(repeating: "k", count: 60): "v",
            "   ": "ignored",
        ])
        let traits = await client.currentTraits()
        XCTAssertEqual(Set(traits.keys), ["plan", String(repeating: "k", count: 40)])
        XCTAssertEqual(traits["plan"]?.count, 200)
    }
}
