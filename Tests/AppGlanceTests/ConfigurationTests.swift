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
