import Foundation

/// One event, shaped as the ingest API and the events table see it - hence the snake_case
/// names. `id` and `created_at` are assigned server-side.
struct Event: Codable, Sendable {
    /// Client-minted UUID. The server ignores a replay of the same `(app_id, event_id)`, which
    /// is what makes retrying a batch safe.
    let event_id: String
    /// The session this event belongs to. The id exists from client startup on: pre-minted
    /// whenever a fresh session is inevitable (a first launch, or a relaunch after
    /// `sessionTimeout`), so `install` and everything recorded before the first foreground
    /// carry the same id the `session.start` adopts; a resumable session keeps its restored id,
    /// and later in-process sessions mint theirs at each `session.start`. nil only for events
    /// replayed from a queue persisted by an SDK build that predates pre-minting.
    let session_id: String?
    let app_id: String
    let user_id: String
    let signal: String
    let app_version: String
    let os_name: String
    let os_version: String
    let environment: String
    let country: String?
    let client_ts: Date
    let metadata: [String: String]?

    /// The same event under a corrected environment label (see `Client.adoptEnvironment`).
    func relabeled(environment: String) -> Event {
        Event(
            event_id: event_id, session_id: session_id, app_id: app_id, user_id: user_id,
            signal: signal, app_version: app_version, os_name: os_name, os_version: os_version,
            environment: environment, country: country, client_ts: client_ts, metadata: metadata)
    }
}

/// The one JSON dialect the SDK speaks, on the wire and on disk. Timestamps are ISO-8601 UTC
/// with fractional seconds when writing (events fired within the same second keep their order),
/// and either form when reading.
enum EventCoding {
    // ISO8601DateFormatter is documented thread-safe; the compiler cannot see that.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractional.date(from: raw) ?? whole.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO-8601 date: \(raw)")
        }
        return decoder
    }
}

/// Minimal, non-identifying device context attached to every event.
enum DeviceInfo {
    static let osName: String = {
        #if os(iOS)
        return "iOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }()

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The device's region setting as an ISO 3166-1 alpha-2 code (e.g. "US") - not GPS, no
    /// permission prompt, no IP. Only real two-letter codes are sent: locales such as `en_150`
    /// (Europe) or `001` (world) carry a numeric region that means nothing on a map.
    static var country: String? {
        guard let code = Locale.current.region?.identifier, code.count == 2,
            code.allSatisfy(\.isLetter)
        else { return nil }
        return code.uppercased()
    }
}
