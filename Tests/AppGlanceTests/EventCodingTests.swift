import XCTest

@testable import AppGlance

final class EventCodingTests: XCTestCase {

    private func sample(
        country: String? = "US", metadata: [String: String]? = ["k": "v"],
        clientTS: Date = Date(timeIntervalSince1970: 0)
    ) -> Event {
        Event(
            event_id: "0e37e055-7d1c-4b4f-9a54-8f3ac54f8f70",
            session_id: "5b1c8d1e-2b7f-4f36-8b0f-1a2b3c4d5e6f",
            app_id: "com.example.app", user_id: "abc", signal: Signal.heartbeat,
            app_version: "1.0", os_name: "iOS", os_version: "17.0.0",
            environment: AppEnvironment.appStore.rawValue, country: country,
            client_ts: clientTS, metadata: metadata)
    }

    func testEventEncodesSnakeCaseFieldsAndISO8601Timestamps() throws {
        let json = String(data: try EventCoding.makeEncoder().encode(sample()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"app_id\":\"com.example.app\""))
        XCTAssertTrue(json.contains("\"environment\":\"appstore\""))
        XCTAssertTrue(json.contains("\"country\":\"US\""))
        XCTAssertTrue(json.contains("\"client_ts\":\"1970-01-01T00:00:00.000Z\""))
        XCTAssertTrue(json.contains("\"metadata\":{\"k\":\"v\"}"))
        XCTAssertTrue(json.contains("\"event_id\":\"0e37e055-7d1c-4b4f-9a54-8f3ac54f8f70\""))
        XCTAssertTrue(json.contains("\"session_id\":\"5b1c8d1e-2b7f-4f36-8b0f-1a2b3c4d5e6f\""))
    }

    /// Fractional seconds on the way out, so same-second events keep their order; both forms
    /// accepted on the way in.
    func testCoderRoundTripsBothDateForms() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000.25)
        let out = String(data: try EventCoding.makeEncoder().encode(sample(clientTS: t)), encoding: .utf8)!
        XCTAssertTrue(out.contains("\"client_ts\":\"2023-11-14T22:13:20.250Z\""), out)

        let decoder = EventCoding.makeDecoder()
        let back = try decoder.decode(Event.self, from: Data(out.utf8))
        XCTAssertEqual(back.client_ts.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 0.001)
        let wholeSeconds = out.replacingOccurrences(of: "22:13:20.250Z", with: "22:13:20Z")
        let old = try decoder.decode(Event.self, from: Data(wholeSeconds.utf8))
        XCTAssertEqual(old.client_ts.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testNilFieldsAreOmittedRatherThanSentAsNull() throws {
        let json = String(
            data: try EventCoding.makeEncoder().encode(
                Event(
                    event_id: "e", session_id: nil, app_id: "a", user_id: "b", signal: "s", app_version: "1",
                    os_name: "iOS", os_version: "17.0.0", environment: "appstore", country: nil,
                    client_ts: Date(timeIntervalSince1970: 0), metadata: nil)), encoding: .utf8)!
        XCTAssertFalse(json.contains("metadata"))
        XCTAssertFalse(json.contains("session_id"))
        XCTAssertFalse(json.contains("country"))
    }
}
