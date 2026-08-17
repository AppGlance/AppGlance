import XCTest

@testable import AppGlance

final class ConfigurationTests: XCTestCase {

    func testHostedDefaults() throws {
        let config = AppGlance.Configuration(apiKey: "glance_live_abc", appID: "com.example.app")
        guard case .hosted(let endpoint, let apiKey) = config.backend else {
            return XCTFail("the apiKey initializer selects the hosted backend")
        }
        XCTAssertEqual(apiKey, "glance_live_abc")
        XCTAssertEqual(endpoint, AppGlance.Configuration.defaultEndpoint)
        XCTAssertEqual(config.flushInterval, 10)
        XCTAssertEqual(config.maxBatchSize, 20)
        XCTAssertEqual(config.heartbeatInterval, 60)
        XCTAssertEqual(config.sessionTimeout, 300)
        XCTAssertTrue(config.isEnabled)
        XCTAssertTrue(config.collectsCountry)
        XCTAssertFalse(config.debug, "debug mode is opt-in")
        XCTAssertEqual(
            config.enabledEnvironments, [.appStore, .testFlight],
            "App Store and TestFlight send (tagged apart); Simulator and Debug builds do not")
    }

    func testSupabaseInitializers() throws {
        let config = try XCTUnwrap(
            AppGlance.Configuration(
                supabaseURLString: "https://abcd1234.supabase.co", publishableKey: "sb_publishable_x",
                appID: "com.example.app"))
        guard case .supabase(let url, let key) = config.backend else {
            return XCTFail("the supabase initializer selects the supabase backend")
        }
        XCTAssertEqual(url.host, "abcd1234.supabase.co")
        XCTAssertEqual(key, "sb_publishable_x")
        XCTAssertEqual(config.enabledEnvironments, [.appStore, .testFlight])

        XCTAssertNil(AppGlance.Configuration(supabaseURLString: "not a url", publishableKey: "k", appID: "a"))
        XCTAssertNil(
            AppGlance.Configuration(supabaseURLString: "my-ref.supabase.co", publishableKey: "k", appID: "a"),
            "a missing scheme is rejected, not silently accepted")
        XCTAssertNil(AppGlance.Configuration(supabaseURLString: "", publishableKey: "k", appID: "a"))
    }

    /// Debug mode is how a developer sees themselves on the dashboard from Xcode: it lifts the
    /// environment gate, and only that gate. An empty `enabledEnvironments` excludes whatever
    /// environment the test host is, so the assertions do not depend on it.
    func testDebugModeLiftsTheEnvironmentGateButNotTheOffSwitch() async {
        let ids = ["test.debugmode.gated", "test.debugmode.on", "test.debugmode.off"]
        ids.forEach(TestSupport.fresh)
        addTeardownBlock { ids.forEach(TestSupport.fresh) }
        func client(_ appID: String, debug: Bool, isEnabled: Bool = true) -> Client {
            Client(
                config: TestSupport.configuration(
                    appID: appID, enabledEnvironments: [], isEnabled: isEnabled, debug: debug),
                userID: "u1")
        }

        let gated = client(ids[0], debug: false)
        await gated.track(signal: "paywall.viewed", metadata: nil)
        let dropped = await gated.pendingSignals()
        XCTAssertEqual(dropped, [], "environment excluded, debug off: nothing is recorded")

        let debugging = client(ids[1], debug: true)
        await debugging.track(signal: "paywall.viewed", metadata: ["source": "test"])
        await debugging.identify(["plan": "pro"])
        let recorded = await debugging.pendingEvents()
        XCTAssertEqual(
            recorded.map(\.signal), ["paywall.viewed", Signal.identify],
            "debug on: the same build records events and properties")
        XCTAssertEqual(
            recorded.first?.environment, AppEnvironment.current.rawValue,
            "the tag stays truthful, so Live stays clean")

        let off = client(ids[2], debug: true, isEnabled: false)
        await off.track(signal: "paywall.viewed", metadata: nil)
        let stillOff = await off.pendingSignals()
        XCTAssertEqual(stillOff, [], "isEnabled = false wins over debug mode")
    }

    /// The intervals reach `Task.sleep` and the presence loop, where a value the SDK cannot mean
    /// is a crash or a spin inside the customer's shipped app. They are clamped, never rejected.
    func testIntervalsAreClampedToWhatTheSDKCanHonour() {
        let floored = AppGlance.Configuration(
            apiKey: "k", flushInterval: -5, maxBatchSize: 0, heartbeatInterval: 0, sessionTimeout: 0)
        XCTAssertEqual(floored.flushInterval, 1)
        XCTAssertEqual(floored.maxBatchSize, 1)
        XCTAssertEqual(floored.heartbeatInterval, 15, "there is no way to switch presence off by asking for zero")
        XCTAssertEqual(floored.sessionTimeout, 1)

        let capped = AppGlance.Configuration(
            apiKey: "k", flushInterval: 99_999, maxBatchSize: 10_000, heartbeatInterval: 99_999,
            sessionTimeout: 99_999_999)
        XCTAssertEqual(capped.flushInterval, 3600)
        XCTAssertEqual(capped.maxBatchSize, 500, "the largest batch the ingest API accepts")
        XCTAssertEqual(capped.heartbeatInterval, 3600)
        XCTAssertEqual(capped.sessionTimeout, 86_400)

        let nonsense = AppGlance.Configuration(
            apiKey: "k", flushInterval: .infinity, heartbeatInterval: .nan, sessionTimeout: -.infinity)
        XCTAssertEqual(nonsense.flushInterval, 10, "a value with no meaning falls back to the default")
        XCTAssertEqual(nonsense.heartbeatInterval, 60)
        XCTAssertEqual(nonsense.sessionTimeout, 300)
    }

    /// The properties are `var`s, so the initializer is not the only way in; `configure` applies
    /// the same bounds to whatever it is handed.
    func testValuesAssignedAfterTheInitializerAreBoundedAgain() {
        var config = AppGlance.Configuration(apiKey: "k", appID: "com.example.app")
        config.heartbeatInterval = 0
        config.flushInterval = .infinity
        config.maxBatchSize = -1
        let bounded = config.withinBounds()
        XCTAssertEqual(bounded.heartbeatInterval, 15)
        XCTAssertEqual(bounded.flushInterval, 10)
        XCTAssertEqual(bounded.maxBatchSize, 1)
        XCTAssertEqual(bounded.appID, "com.example.app", "everything else survives the pass unchanged")
        guard case .hosted(_, let apiKey) = bounded.backend else { return XCTFail("the backend survives too") }
        XCTAssertEqual(apiKey, "k")
    }

    /// Defence in depth for the same numbers: a flush timer armed from an unbounded value must
    /// not trap on the `UInt64` conversion, because `try?` does not catch a trap and the crash
    /// would be inside somebody else's app.
    func testAnUnboundedFlushIntervalDoesNotTrapTheFlushTimer() async {
        let id = "test.config.trap"
        TestSupport.fresh(id)
        addTeardownBlock { TestSupport.fresh(id) }
        var config = TestSupport.configuration(appID: id)
        config.flushInterval = .infinity
        let client = Client(config: config, userID: "u1", session: TestSupport.recordingSession())

        await client.track(signal: "a", metadata: nil)  // arms the timer
        await TestSupport.settle(0.2)
        await client.flush()  // joins whatever the timer started

        XCTAssertEqual(
            RecordingProtocol.signals(), ["a"], "the event survives, and the process is still here to say so")
    }

    /// `isEnabled: false` is how an app honours a consent withdrawal, and it has to apply to what
    /// is already on disk: the events recorded before the switch was flipped are exactly the ones
    /// consent was withdrawn for.
    func testTurningCollectionOffDiscardsWhatWasAlreadyQueued() async throws {
        let id = "test.config.consent"
        TestSupport.fresh(id)
        addTeardownBlock { TestSupport.fresh(id) }
        let session = TestSupport.recordingSession()

        let collecting = Client(config: TestSupport.configuration(appID: id), userID: "u1", session: session)
        await collecting.track(signal: "before.the.switch", metadata: nil)
        await collecting.identify(["$email": "ada@example.com"])
        XCTAssertEqual(try TestSupport.persistedSignals(id).count, 2, "both are on disk")
        await collecting.shutdown()

        // The app calls configure again with the switch off; the replacement client owns the file.
        let off = Client(
            config: TestSupport.configuration(appID: id, isEnabled: false), userID: "u1", session: session)
        let queued = await off.pendingSignals()
        XCTAssertEqual(queued, [], "the backlog is not inherited")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: Client.makeStoreURL(appID: id).path),
            "nor left on disk to be resurrected by turning the switch back on")

        await off.flush()
        XCTAssertEqual(RecordingProtocol.signals(), [], "an explicit flush after withdrawal sends nothing")
    }

    /// Both backends receive the same JSON array with a client-minted event id per event, and
    /// both ignore a replayed id: the hosted ingest by design, Supabase through PostgREST's
    /// `on_conflict` + `ignore-duplicates` over the schema's unique index.
    func testBothBackendsSendEventIDsAndSupabaseAsksForIdempotentInserts() async throws {
        let hostedID = "test.backend.hosted", supabaseID = "test.backend.supabase"
        [hostedID, supabaseID].forEach(TestSupport.fresh)
        addTeardownBlock { [hostedID, supabaseID].forEach(TestSupport.fresh) }
        let session = TestSupport.recordingSession()

        let hosted = Client(config: TestSupport.configuration(appID: hostedID), userID: "u1", session: session)
        await hosted.track(signal: "a", metadata: nil)
        await hosted.flush()
        let hostedRequest = try XCTUnwrap(RecordingProtocol.receivedRequests().last)
        XCTAssertEqual(hostedRequest.url?.absoluteString, "https://ingest.invalid/v1/events")
        XCTAssertEqual(hostedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer glance_live_test")
        XCTAssertEqual(hostedRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let supabase = Client(
            config: AppGlance.Configuration(
                supabaseURL: URL(string: "https://ref.supabase.co")!, publishableKey: "sb_k",
                appID: supabaseID, flushInterval: 3600, maxBatchSize: 1000,
                enabledEnvironments: Set(AppEnvironment.allCases)),
            userID: "u1", session: session)
        await supabase.track(signal: "a", metadata: nil)
        await supabase.track(signal: "b", metadata: nil)
        await supabase.flush()
        let supabaseRequest = try XCTUnwrap(RecordingProtocol.receivedRequests().last)
        XCTAssertEqual(
            supabaseRequest.url?.absoluteString, "https://ref.supabase.co/rest/v1/events?on_conflict=app_id,event_id")
        XCTAssertEqual(supabaseRequest.value(forHTTPHeaderField: "apikey"), "sb_k")
        XCTAssertEqual(supabaseRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sb_k")
        XCTAssertEqual(
            supabaseRequest.value(forHTTPHeaderField: "Prefer"), "return=minimal, resolution=ignore-duplicates")

        let sent = try XCTUnwrap(RecordingProtocol.receivedBatches().last)
        XCTAssertEqual(sent.map(\.signal), ["a", "b"])
        XCTAssertEqual(Set(sent.map(\.event_id)).count, 2, "every event carries its own dedupe id")
    }
}
