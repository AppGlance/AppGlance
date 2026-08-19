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

    /// The clamp has to count in the unit the ingest counts in. It cuts at 200 UTF-16 code units;
    /// counting characters instead keeps 200 emoji, which is 400 units, and the server then
    /// stores a different string from the one the SDK remembers - so every later `identify` with
    /// the same values matches the cache, sends nothing, and the value on the dashboard can never
    /// be corrected by the app repeating it.
    ///
    /// The second value puts the cut on an odd boundary, where it lands inside a surrogate pair -
    /// a round number of emoji never reaches that case. The half has to be dropped rather than
    /// kept: the ingest trims a lone surrogate, so a snapshot that keeps one is a snapshot the
    /// server can never agree with, which is the same silence by another route.
    func testValuesAreClampedInTheUnitsTheServerCounts() async throws {
        let id = "test.traits.utf16"; isolate(id)
        let client = makeClient(appID: id)

        await client.identify([
            UserProperty.name: String(repeating: "😀", count: 150),  // 300 units: the cut falls between pairs
            "headline": "a" + String(repeating: "😀", count: 150),  // 301 units: the cut falls inside one
        ])

        let traits = await client.currentTraits()
        let stored = try XCTUnwrap(traits[UserProperty.name])
        XCTAssertEqual(stored.utf16.count, 200, "200 code units, which is what the ingest keeps")
        XCTAssertEqual(stored.count, 100, "and 100 whole emoji, not 200")

        let split = try XCTUnwrap(traits["headline"])
        XCTAssertEqual(split.utf16.count, 199, "the split pair is dropped, not kept as a half")
        XCTAssertEqual(split.count, 100, "the letter and 99 whole emoji")
        XCTAssertFalse(
            split.unicodeScalars.contains { $0.value == 0xFFFD },
            "and never the replacement character a lone surrogate decodes to, which the ingest trims")
    }

    /// The snapshot names what the server acknowledged, not what was queued. A `user.identify`
    /// the ingest never stored has to leave the next identical call something to send, or the
    /// install's page in the dashboard stays blank for as long as the app keeps passing the same
    /// values - which is what the doc comment tells it to do at every launch.
    func testAnIdentifyThatNeverLandsIsSentAgainByTheNextIdenticalCall() async throws {
        let id = "test.traits.dropped"; isolate(id)
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())

        RecordingProtocol.script([400])  // a permanent 4xx: the slice is dropped, never stored
        await client.identify([UserProperty.email: "ada@example.com"])
        await client.flush()
        let queued = await client.pendingSignals()
        XCTAssertEqual(queued, [], "the batch was dropped, not kept for a retry")
        let delivered = await client.deliveredTraits()
        XCTAssertEqual(delivered, [:], "nothing was acknowledged, so nothing is remembered")

        await client.identify([UserProperty.email: "ada@example.com"])
        let again = await client.pendingSignals()
        XCTAssertEqual(
            again, [Signal.identify],
            "the same values are new again: the event that carried them never reached the server")
    }

    /// A 202 is not by itself proof that the rows were stored. Past the plan's grace ceiling the
    /// ingest answers 202 and drops `user.identify`, saying so in `accepted`; a snapshot committed
    /// on the status code alone would freeze this install's properties for the rest of the month.
    func testAnIdentifyDroppedOverQuotaIsSentAgain() async throws {
        let id = "test.traits.overquota"; isolate(id)
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())

        RecordingProtocol.scriptResponseBody("{\"accepted\":0,\"over_quota_dropped\":1}")
        await client.identify([UserProperty.email: "ada@example.com"])
        await client.flush()
        let delivered = await client.deliveredTraits()
        XCTAssertEqual(delivered, [:], "a batch the server counted short is not an acknowledgement")

        await client.identify([UserProperty.email: "ada@example.com"])
        let again = await client.pendingSignals()
        XCTAssertEqual(again, [Signal.identify], "so the app's next identify has something to send")
    }

    /// The other direction, which is what stops the fix costing the customer an event a launch:
    /// a delivered identify IS remembered, and the launch-time repeat the docs encourage is free.
    func testADeliveredIdentifyIsRememberedSoTheNextIdenticalCallIsFree() async throws {
        let id = "test.traits.delivered"; isolate(id)
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())

        await client.identify([UserProperty.email: "ada@example.com"])
        await client.flush()
        let delivered = await client.deliveredTraits()
        XCTAssertEqual(delivered, [UserProperty.email: "ada@example.com"])

        await client.identify([UserProperty.email: "ada@example.com"])
        let queued = await client.pendingSignals()
        XCTAssertEqual(queued, [], "an acknowledged snapshot still makes a repeat cost nothing")
    }

    /// `reset()` clears the person's properties from disk at once, ahead of delivery. An empty
    /// snapshot suppresses nothing - every later `identify` sends its whole set whatever became of
    /// the reset - while holding `$email` and `$name` in `UserDefaults`, inside the iCloud and the
    /// encrypted backup, until the server acknowledges the sign-out keeps them exactly where the
    /// sign-out asked for them to be gone.
    func testResetClearsThePersonFromDiskWithoutWaitingForTheServer() async throws {
        let id = "test.traits.reset.disk"; isolate(id)
        let key = "app.appglance.traits.\(id)"
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())

        await client.identify([UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])
        await client.flush()
        XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: key), "acknowledged, so it is on disk")

        await client.reset()  // and nothing is flushed: the sign-out has to land on disk by itself

        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: key),
            "an email and a name do not wait on the network to be forgotten")

        // A kill before the `user.reset` lands is the case this is for: the next launch must not
        // read them straight back off disk as the snapshot the server holds.
        let relaunched = Client(config: TestSupport.configuration(appID: id), userID: "u-\(id)")
        let acknowledged = await relaunched.deliveredTraits()
        XCTAssertEqual(acknowledged, [:], "and the sign-out is not silently undone by the next launch")
        await relaunched.shutdown()
    }

    /// Nothing is committed to the snapshot while a newer identify or reset is still owed. What the
    /// server holds now is already superseded, and re-persisting it puts the properties a sign-out
    /// has just cleared back on disk - inside the iCloud and encrypted backups - where they stay
    /// for good if the reset never lands.
    func testAnOlderIdentifyLandingBehindAResetCommitsNothing() async throws {
        let id = "test.traits.stalecommit"; isolate(id)
        let key = "app.appglance.traits.\(id)"
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())
        await client.identify([UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])

        // The identify is accepted; the reset queued behind it while it was on the wire is not, so
        // nothing after this can move the snapshot on the identify's behalf.
        RecordingProtocol.script([202, 503])
        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        let started = await TestSupport.waitUntil { hold.isStarted }
        XCTAssertTrue(started, "the identify is on the wire")
        await client.reset()  // the sign-out happens while it is out there
        hold.proceed()
        await flushing.value

        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: key),
            "the accepted batch is already superseded: committing it would put the sign-out's data back")
        let acknowledged = await client.deliveredTraits()
        XCTAssertEqual(
            acknowledged, [:], "and would mis-free the next identify against a set the server no longer holds")
        let owed = await client.pendingSignals()
        XCTAssertEqual(owed, [Signal.reset], "the reset is still owed, and commits when its own batch lands")
    }

    /// Withdrawing consent has to reach the person's own data. `$email` and `$name` sit in
    /// `UserDefaults`, inside the iCloud and the encrypted backup, and `reset()` cannot clear them
    /// once collection is off - which is the order an app is most likely to use.
    func testWithdrawingConsentClearsTheStoredPropertiesAndAClosedGateDoesNot() async throws {
        let id = "test.traits.withdrawal"; isolate(id)
        let key = "app.appglance.traits.\(id)"
        let client = Client(
            config: TestSupport.configuration(appID: id), userID: "u-\(id)",
            session: TestSupport.recordingSession())
        await client.identify([UserProperty.email: "ada@example.com", UserProperty.name: "Ada"])
        await client.flush()
        XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: key), "acknowledged, so it is on disk")
        await client.shutdown()

        // A Debug build run over an installed App Store copy shares this container. Its closed
        // environment gate is not a withdrawal of consent and must leave the snapshot alone.
        let gated = Client(
            config: TestSupport.configuration(appID: id, enabledEnvironments: []), userID: "u-\(id)")
        XCTAssertNotNil(
            UserDefaults.standard.dictionary(forKey: key), "a closed environment gate is not a withdrawal")
        await gated.shutdown()

        let disabled = Client(config: TestSupport.configuration(appID: id, isEnabled: false), userID: "u-\(id)")
        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: key),
            "an email and a name must not outlive the consent they were collected under")
        let remaining = await disabled.currentTraits()
        XCTAssertEqual(remaining, [:])
        // And `reset()` after the fact is still the no-op it always was, which is the point: the
        // withdrawal itself has to do the clearing.
        await disabled.reset()
        let queued = await disabled.pendingSignals()
        XCTAssertEqual(queued, [])
    }
}
