import Foundation
import XCTest

@testable import AppGlance

/// In-memory identity store: no Keychain entitlement on the test host.
final class InMemoryIdentityStore: IdentityStoring, @unchecked Sendable {
    private var value: String?
    private let locked: Bool
    /// A store that answers but keeps nothing: the Keychain refusing the write for want of an
    /// entitlement, with the Caches mirror unwritable too.
    private let refusesWrites: Bool

    init(_ initial: String? = nil, locked: Bool = false, refusesWrites: Bool = false) {
        self.value = initial
        self.locked = locked
        self.refusesWrites = refusesWrites
    }

    func lookup() -> IdentityLookup {
        if locked { return .unavailable }
        if let value, !value.isEmpty { return .found(value) }
        return .absent
    }

    func save(_ newValue: String) {
        guard !refusesWrites else { return }
        value = newValue
    }
}

/// A keychain with one item per scope. The macOS migration has to be provable without a real one:
/// the test host has no entitlement for either keychain, and the ordering of the read, the write
/// and the delete is the part that decides whether an install keeps its id.
final class FakeKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeychainScope: String]
    /// Scopes that answer "cannot be read yet": the Keychain before the first unlock.
    private var lockedScopes: Set<KeychainScope>
    /// Scopes this build cannot write to: on macOS, the data protection keychain without the
    /// entitlement that grants a keychain access group.
    private var unwritableScopes: Set<KeychainScope>
    private var writeLog: [KeychainScope] = []
    private var deleteLog: [KeychainScope] = []

    init(
        _ items: [KeychainScope: String] = [:], locked: Set<KeychainScope> = [],
        unwritable: Set<KeychainScope> = []
    ) {
        self.items = items
        self.lockedScopes = locked
        self.unwritableScopes = unwritable
    }

    func item(_ scope: KeychainScope) -> String? { lock.lock(); defer { lock.unlock() }; return items[scope] }
    func writes() -> [KeychainScope] { lock.lock(); defer { lock.unlock() }; return writeLog }
    func deletes() -> [KeychainScope] { lock.lock(); defer { lock.unlock() }; return deleteLog }

    func read(service: String, account: String, scope: KeychainScope) -> IdentityLookup {
        lock.lock(); defer { lock.unlock() }
        if lockedScopes.contains(scope) { return .unavailable }
        if let value = items[scope], !value.isEmpty { return .found(value) }
        return .absent
    }

    func write(_ value: String, service: String, account: String, scope: KeychainScope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        writeLog.append(scope)
        if unwritableScopes.contains(scope) { return false }
        items[scope] = value
        return true
    }

    func delete(service: String, account: String, scope: KeychainScope) {
        lock.lock(); defer { lock.unlock() }
        deleteLog.append(scope)
        items[scope] = nil
    }
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
    nonisolated(unsafe) private static var responseBody = "{}"  // the body of every answer
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var received: [[Event]] = []  // every batch, accepted or not
    /// When set, the next request is held open (see `RequestHold`) before it is answered.
    nonisolated(unsafe) private static var hold: RequestHold?
    /// When set, the next request is answered with a redirect to this URL instead of a batch
    /// answer. A custom `URLProtocol` has to hand the redirect to the loading system itself; a
    /// `3xx` status alone is not one.
    nonisolated(unsafe) private static var redirectTo: URL?
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        sent = []; batches = []; sessionIDs = []; statuses = []; requests = []; received = []; hold = nil
        redirectTo = nil
        responseHeaders = nil
        responseBody = "{}"
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
    /// The body of every response until the next `reset` (e.g. `{"accepted":1,"heartbeat_interval":240}`).
    static func scriptResponseBody(_ body: String) {
        lock.lock(); responseBody = body; lock.unlock()
    }

    /// Answers the next request with a `302` to `url`, the way a proxy or a hijacked endpoint
    /// host would.
    static func scriptRedirect(to url: URL) {
        lock.lock(); redirectTo = url; lock.unlock()
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

        Self.lock.lock()
        let redirect = Self.redirectTo
        Self.redirectTo = nil
        if let redirect {
            Self.requests.append(request)
            Self.lock.unlock()
            let moved = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": redirect.absoluteString])!
            var followed = request
            followed.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: followed, redirectResponse: moved)
            // If the redirect is followed, the loading system cancels this instance and starts a
            // fresh request; if it is refused, nothing else will ever complete this task, so the
            // `302` is delivered as the answer - which is what a refused redirect looks like to
            // the caller of a real session.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                guard !isStopped else { return }
                client?.urlProtocol(self, didReceive: moved, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        Self.lock.unlock()

        let batch = (try? EventCoding.makeDecoder().decode([Event].self, from: body)) ?? []
        Self.lock.lock()
        let status = Self.statuses.isEmpty ? 202 : Self.statuses.removeFirst()
        let headers = Self.responseHeaders
        let answerBody = Self.responseBody
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
        client?.urlProtocol(self, didLoad: Data(answerBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Set when the loading system cancels this instance, which is what following a redirect
    /// does to the request that produced it.
    private let stoppedLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stoppedLock.lock(); defer { stoppedLock.unlock() }; return stopped }

    override func stopLoading() {
        stoppedLock.lock()
        stopped = true
        stoppedLock.unlock()
    }
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

/// A store answer the test owns. The real one resolves instantly on a test host - a Debug build
/// is a compile-time environment, so `AppEnvironment.storeAnswer` returns before it asks anything
/// - and neither the grace a flush pays for the label nor what overlaps that grace is observable
/// without an ask that waits to be answered.
final class StoreAnswerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    private var value: AppEnvironment?
    private var originValue: InstallOrigin?
    private let gate = DispatchSemaphore(value: 0)

    /// Pass `{ await gate.ask() }` as the client's `storeAnswer`: it records the ask, then waits
    /// for `answer(_:)`.
    func ask() async -> StoreAnswer {
        lock.lock(); asked = true; lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [self] in
                gate.wait()
                continuation.resume()
            }
        }
        lock.lock(); defer { lock.unlock() }
        return StoreAnswer(environment: value, origin: originValue)
    }

    /// Answers the ask. Safe to call again in teardown: a surplus signal leaves nothing blocked.
    func answer(_ environment: AppEnvironment?, origin: InstallOrigin? = nil) {
        lock.lock(); value = environment; originValue = origin; lock.unlock()
        gate.signal()
    }

    /// Resolves once the client has asked, so a test never races the task that asks.
    func waitUntilAsked(timeout: TimeInterval = 5) async -> Bool {
        await TestSupport.waitUntil(timeout: timeout) {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.asked
        }
    }
}

enum TestSupport {
    /// A hosted-mode configuration that only sends on explicit flushes and accepts every environment.
    static func configuration(
        appID: String, sessionTimeout: TimeInterval = 300, maxBatchSize: Int = 1000,
        heartbeatInterval: TimeInterval = 60,
        enabledEnvironments: Set<AppEnvironment> = Set(AppEnvironment.allCases),
        isEnabled: Bool = true, debug: Bool = false
    ) -> AppGlance.Configuration {
        var config = AppGlance.Configuration(
            apiKey: "glance_live_test", appID: appID,
            endpoint: URL(string: "https://ingest.invalid/v1/events")!,
            flushInterval: 3600, maxBatchSize: maxBatchSize, heartbeatInterval: heartbeatInterval,
            sessionTimeout: sessionTimeout,
            isEnabled: isEnabled, enabledEnvironments: enabledEnvironments, debug: debug)
        // Assigned after the initializer, on purpose: a shipped app is held to a 15 s presence
        // floor (and `configure` re-applies it), but a test that drives the presence loop wants
        // it in milliseconds, so it does not spend the interval waiting in real time. Tests that
        // pin the bounds themselves live in `ConfigurationTests`.
        config.heartbeatInterval = heartbeatInterval
        return config
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

    /// Polls until the condition holds, so a test waits for an outcome rather than for a duration.
    static func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await settle(0.02)
        }
        return false
    }

    /// The same wait for a condition only an actor can answer. `waitUntil`'s condition is
    /// synchronous, so a client's own state cannot be read from inside it, and a fixed sleep in
    /// its place is either longer than the test needs or shorter than the machine needs.
    static func waitUntilAsync(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            await settle(0.02)
        }
        return await condition()
    }

    /// Lets a detached task (the heartbeat, a flush) get its turn.
    static func settle(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits until the client has produced `count` heartbeats in total - delivered to the recorder
    /// or still queued - so a test never depends on how quickly the heartbeat task gets scheduled.
    ///
    /// The count is the whole test's, not this client's: the recorder is not cleared between
    /// clients inside a test, and a client built later loads the earlier one's persisted queue.
    /// So a test that relaunches a client and then waits for a ping can be satisfied by a ping
    /// the first process left behind, without the second one ever ticking. Where the tick itself
    /// is the thing under test, assert inside one visit, or read the count before the wait and
    /// require it to grow.
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
