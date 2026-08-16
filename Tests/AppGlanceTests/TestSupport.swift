import Foundation
import XCTest

@testable import AppGlance

/// In-memory identity store: no Keychain entitlement on the test host.
final class InMemoryIdentityStore: IdentityStoring, @unchecked Sendable {
    private var value: String?
    private let locked: Bool

    init(_ initial: String? = nil, locked: Bool = false) {
        self.value = initial
        self.locked = locked
    }

    func lookup() -> IdentityLookup {
        if locked { return .unavailable }
        if let value, !value.isEmpty { return .found(value) }
        return .absent
    }

    func save(_ newValue: String) { value = newValue }
}

/// A settable clock: the session timeout and heartbeat spacing are wall-clock rules, so tests
/// move time instead of sleeping through it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return t
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        t = t.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Answers 202 to everything (unless scripted) and records what it received, in order - the
/// server's view of what the client did.
final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) private static var sent: [String] = []  // signals of accepted (2xx) batches
    nonisolated(unsafe) private static var batches: [Int] = []  // events per request
    nonisolated(unsafe) private static var sessionIDs: [String?] = []  // per accepted event
    nonisolated(unsafe) private static var statuses: [Int] = []  // scripted answers; 202 once exhausted
    nonisolated(unsafe) private static var responseHeaders: [String: String]?  // attached to every answer
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var received: [[Event]] = []  // every batch, accepted or not
    /// When set, the next request is held open (see `RequestHold`) before it is answered.
    nonisolated(unsafe) private static var hold: RequestHold?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        sent = []; batches = []; sessionIDs = []; statuses = []; requests = []; received = []; hold = nil
        responseHeaders = nil
    }
    static func signals() -> [String] { lock.lock(); defer { lock.unlock() }; return sent }
    static func requestSizes() -> [Int] { lock.lock(); defer { lock.unlock() }; return batches }
    static func sessions() -> [String?] { lock.lock(); defer { lock.unlock() }; return sessionIDs }
    static func receivedRequests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func receivedBatches() -> [[Event]] { lock.lock(); defer { lock.unlock() }; return received }
    static func script(_ answers: [Int]) { lock.lock(); statuses = answers; lock.unlock() }
    /// Headers attached to every response until the next `reset` (e.g. `["Retry-After": "45"]`).
    static func scriptResponseHeaders(_ headers: [String: String]?) {
        lock.lock(); responseHeaders = headers; lock.unlock()
    }

    /// Holds the next request open until `proceed()` is called; `isStarted` turns true once it is in flight.
    static func holdNextRequest() -> RequestHold {
        let next = RequestHold()
        lock.lock(); hold = next; lock.unlock()
        return next
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body =
            request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                return data
            } ?? Data()

        Self.lock.lock()
        let held = Self.hold
        Self.hold = nil
        Self.lock.unlock()
        if let held {
            held.markStarted()
            held.waitToProceed()
        }

        let batch = (try? EventCoding.makeDecoder().decode([Event].self, from: body)) ?? []
        Self.lock.lock()
        let status = Self.statuses.isEmpty ? 202 : Self.statuses.removeFirst()
        let headers = Self.responseHeaders
        if (200..<300).contains(status) {
            Self.sent.append(contentsOf: batch.map(\.signal))
            Self.sessionIDs.append(contentsOf: batch.map(\.session_id))
        }
        Self.batches.append(batch.count)
        Self.requests.append(request)
        Self.received.append(batch)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A request the recorder is holding open, so a test can observe the client mid-flight.
final class RequestHold: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let gate = DispatchSemaphore(value: 0)

    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func markStarted() { lock.lock(); started = true; lock.unlock() }
    func waitToProceed() { gate.wait() }
    func proceed() { gate.signal() }
}

enum TestSupport {
    /// A hosted-mode configuration that only sends on explicit flushes and accepts every environment.
    static func configuration(
        appID: String, sessionTimeout: TimeInterval = 300, maxBatchSize: Int = 1000,
        enabledEnvironments: Set<AppEnvironment> = Set(AppEnvironment.allCases),
        isEnabled: Bool = true, debug: Bool = false
    ) -> AppGlance.Configuration {
        AppGlance.Configuration(
            apiKey: "glance_live_test", appID: appID,
            endpoint: URL(string: "https://ingest.invalid/v1/events")!,
            flushInterval: 3600, maxBatchSize: maxBatchSize, sessionTimeout: sessionTimeout,
            isEnabled: isEnabled, enabledEnvironments: enabledEnvironments, debug: debug)
    }

    /// A URLSession that routes every request through `RecordingProtocol`.
    static func recordingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Wipes the on-disk queue and persisted session state for an app id, and the recorder.
    static func fresh(_ appID: String) {
        try? FileManager.default.removeItem(at: Client.makeStoreURL(appID: appID))
        Client.resetSessionState(appID: appID)
        RecordingProtocol.reset()
    }

    /// The events currently persisted for an app id - what a relaunch would load.
    static func persistedSignals(_ appID: String) throws -> [String] {
        let data = try Data(contentsOf: Client.makeStoreURL(appID: appID))
        return try EventCoding.makeDecoder().decode([Event].self, from: data).map(\.signal)
    }

    /// Lets a detached task (the heartbeat, a flush) get its turn.
    static func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits until the client has produced `count` heartbeats in total - delivered to the recorder
    /// or still queued - so a test never depends on how quickly the heartbeat task gets scheduled.
    static func waitForHeartbeats(_ count: Int, from client: Client, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let delivered = RecordingProtocol.signals().filter { $0 == Signal.heartbeat }.count
            let queued = await client.pendingSignals().filter { $0 == Signal.heartbeat }.count
            if delivered + queued >= count { return true }
            await settle(0.02)
        }
        return false
    }
}
