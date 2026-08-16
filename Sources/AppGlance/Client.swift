import Foundation

/// Owns the event queue, batching and delivery, offline persistence, sessions, the foreground
/// heartbeat and the user-properties snapshot. An actor, so every access is serialized.
actor Client {

    private let config: AppGlance.Configuration
    private let session: URLSession
    private let userID: String
    private let endpoint: URL
    private let headers: [String: String]
    private let storeURL: URL
    private let encoder: JSONEncoder
    private var environment: AppEnvironment
    private var collecting: Bool
    private let now: @Sendable () -> Date

    /// Hard cap on the queue, so repeated failures cannot grow it without bound. Oldest first.
    private let maxQueuedEvents = 500
    /// Events per request. The ingest API accepts up to 500 events / 256 KB per batch; a
    /// long-offline queue drains in slices this size rather than as one oversized POST.
    private let maxEventsPerRequest = 100
    private let maxTraits = 20
    private let maxTraitKeyLength = 40
    private let maxTraitValueLength = 200

    private var queue: [Event]
    /// The slice currently on the wire. See `persist()`.
    private var inFlightBatch: [Event] = []
    private var inFlight: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// The in-flight ask for the store's environment answer; each flush waits briefly for it.
    /// See `adoptStoreAnswer`.
    private var refineTask: Task<Void, Never>?
    /// True once the store has answered (or the environment is a compile-time fact). Until
    /// then every flush asks again: a fresh install's first ask can find nothing cached.
    private var environmentAnswered = false
    /// How long a flush waits for the store's answer before sending with the guessed label -
    /// a slow or offline first launch must not hold batches hostage; later flushes correct
    /// what follows.
    private let environmentAnswerGrace: TimeInterval = 3
    /// Set by `shutdown()` once a later `configure` has replaced this client.
    private var retired = false

    // Session state. A session is "the app is in front of the user"; it survives short
    // interruptions and ends only after `sessionTimeout` of absence - the same gap the dashboard
    // uses, so the two agree on what a session is. Persisted so a quit-and-relaunch inside the
    // timeout continues the session and a relaunch after it starts a new one.
    private var isActive = false
    private var lastActiveAt: Date?
    private var lastHeartbeatAt: Date?
    private var sessionID: String?
    private let lastActiveKey: String
    private let sessionKey: String

    // User properties. The last snapshot the server has is mirrored here, so `identify` with the
    // same values on every launch sends nothing; only a change costs an event.
    private var traits: [String: String]
    private let traitsKey: String

    /// True exactly once per install: the launch that minted the install id.
    private let isNewInstall: Bool
    private let installAt: Date
    private var installRecorded = false

    init(
        config: AppGlance.Configuration, userID: String, isNewInstall: Bool = false, installAt: Date = Date(),
        session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.session = session
        self.userID = userID
        self.isNewInstall = isNewInstall
        self.installAt = installAt
        self.now = now

        // On-disk keys are part of the SDK's contract with existing installs; see CONTRIBUTING.
        self.lastActiveKey = "app.appglance.lastActive.\(config.appID)"
        self.sessionKey = "app.appglance.session.\(config.appID)"
        self.traitsKey = "app.appglance.traits.\(config.appID)"
        if let stamp = UserDefaults.standard.object(forKey: lastActiveKey) as? Double {
            self.lastActiveAt = Date(timeIntervalSince1970: stamp)
            self.sessionID = UserDefaults.standard.string(forKey: sessionKey)
        }
        self.traits = (UserDefaults.standard.dictionary(forKey: traitsKey) as? [String: String]) ?? [:]

        // Both backends take the same JSON array of events; they differ in where it goes and how it
        // authenticates. Both ignore a replayed `(app_id, event_id)` - the hosted ingest by design,
        // Supabase through PostgREST's `on_conflict` + `ignore-duplicates` over the schema's unique index.
        switch config.backend {
        case .hosted(let endpoint, let apiKey):
            self.endpoint = endpoint
            self.headers = [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)",
            ]
        case .supabase(let url, let publishableKey):
            let table = url.appendingPathComponent("rest/v1/events")
            var components = URLComponents(url: table, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "on_conflict", value: "app_id,event_id")]
            self.endpoint = components?.url ?? table
            self.headers = [
                "Content-Type": "application/json",
                "apikey": publishableKey,
                "Authorization": "Bearer \(publishableKey)",
                "Prefer": "return=minimal, resolution=ignore-duplicates",
            ]
        }

        let storeURL = Self.makeStoreURL(appID: config.appID)
        let environment = AppEnvironment.current
        // Debug mode lifts the environment gate and nothing else; the developer's own off-switch wins.
        let collecting = config.isEnabled && (config.debug || config.enabledEnvironments.contains(environment))
        let persisted = Self.loadPersisted(from: storeURL)
        self.storeURL = storeURL
        self.encoder = EventCoding.makeEncoder()
        self.environment = environment
        self.collecting = collecting
        self.queue = persisted

        Self.announce(
            config: config, environment: environment, collecting: collecting,
            endpoint: self.endpoint, userID: userID, waiting: persisted.count)
    }

    deinit {
        heartbeatTask?.cancel()
        flushTask?.cancel()
        refineTask?.cancel()
    }

    /// One console line per `configure`, in two situations only: debug mode is on (say what this
    /// build will do), or this build is silently not sending because of the environment gate -
    /// the "I hit Run and the dashboard stayed empty" moment. A normal App Store or TestFlight
    /// launch prints nothing, and neither does `isEnabled = false`.
    nonisolated private static func announce(
        config: AppGlance.Configuration, environment: AppEnvironment,
        collecting: Bool, endpoint: URL, userID: String, waiting: Int
    ) {
        if config.debug {
            var line = "debug mode on · environment: \(environment.rawValue)"
            if collecting {
                line += " · sending to \(endpoint.host ?? endpoint.absoluteString) · install id \(userID)"
                if waiting > 0 { line += " · \(waiting) event\(waiting == 1 ? "" : "s") waiting from an earlier run" }
                Log.line(line)
                if environment == .simulator || environment == .debug {
                    Log.line(
                        "events from this build are tagged \"\(environment.rawValue)\" - they show under All in the dashboard, never in Live"
                    )
                }
            } else {
                Log.line(line + " · NOT sending: isEnabled is false")
            }
        } else if config.isEnabled && !collecting {
            Log.line(
                "not sending: this is \(environment.humanName) and enabledEnvironments doesn't include \(environment.caseName)"
                    + " (the default keeps development traffic out of your numbers). To test from here, pass"
                    + " debug: true to AppGlance.configure - events are then tagged \"\(environment.rawValue)\" and appear"
                    + " under All in the dashboard, never in Live.")
        }
    }

    /// Debug-mode narration; a no-op unless `debug` is on.
    private func log(_ message: @autoclosure () -> String) {
        guard config.debug else { return }
        Log.line(message())
    }

    // MARK: - Commands (called by the `AppGlance` facade)

    /// Records `install`, exactly once per install, ahead of everything else. The facade calls
    /// this before applying any other command.
    func recordInstallIfNeeded() {
        guard isNewInstall, !installRecorded else { return }
        installRecorded = true
        track(signal: Signal.install, metadata: nil, at: installAt)
    }

    /// Stops the timers and retires the client: it records nothing further and, above all,
    /// never writes the queue file again - a later `configure` has replaced it, and the
    /// replacement now owns that file. A send already in flight completes on its own; what it
    /// carried is either acknowledged (and deduplicated by event id if the replacement re-sends
    /// it) or already persisted for the replacement to pick up.
    func shutdown() {
        retired = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        flushTask?.cancel()
        flushTask = nil
        refineTask?.cancel()
        refineTask = nil
        queue.removeAll()
    }

    /// Starts (or restarts) the ask for the store's environment answer; the facade calls this
    /// right after `configure`, and `flush()` calls it again while the question is still open.
    /// Separate from init so tests own exactly when (and whether) it runs.
    func beginEnvironmentRefinement() {
        guard refineTask == nil, !retired, !environmentAnswered else { return }
        if AppEnvironment.isCompileTimeDetermined {
            environmentAnswered = true
            return
        }
        refineTask = Task { [weak self] in
            let answer = await AppEnvironment.storeAnswer()
            await self?.adoptStoreAnswer(answer)
        }
    }

    /// nil means the store had no answer this time: the task slot clears so a later flush asks
    /// again, and the guessed label stands meanwhile.
    func adoptStoreAnswer(_ answer: AppEnvironment?) {
        refineTask = nil
        guard let answer, !retired, !environmentAnswered else { return }
        environmentAnswered = true
        adoptEnvironment(answer)
    }

    /// Adopts the store's answer for where this build runs. Queued events carrying this run's
    /// guessed label are restamped - the first flush waits for the refinement, so nothing
    /// leaves with the wrong tag. Labels that differ from the guess are kept: they came from
    /// an earlier run whose channel this process cannot vouch for. If the corrected
    /// environment closes the sending gate, the queue is dropped - those events belong to an
    /// environment the app said should never send.
    func adoptEnvironment(_ refined: AppEnvironment) {
        guard !retired, refined != environment else { return }
        let guessed = environment.rawValue
        environment = refined
        let wasCollecting = collecting
        collecting = config.isEnabled && (config.debug || config.enabledEnvironments.contains(refined))
        queue = queue.map { $0.environment == guessed ? $0.relabeled(environment: refined.rawValue) : $0 }
        if !collecting { queue.removeAll() }
        persist()
        if wasCollecting != collecting {
            // The announce line at configure spoke for the guess; say so when the answer differs.
            Log.line(
                collecting
                    ? "environment corrected to \(refined.rawValue) - this build sends after all"
                    : "environment corrected to \(refined.rawValue) - not sending: enabledEnvironments doesn't include \(refined.caseName)")
        } else {
            log("environment corrected: \(guessed) is really \(refined.rawValue)")
        }
    }

    /// `at` is when the app made the call - the facade stamps it before queueing - so events
    /// tracked back to back keep their order even if they are applied a moment later.
    func track(signal: String, metadata: [String: String]?, at: Date? = nil) {
        guard collecting, !retired else { return }
        let event = Event(
            event_id: UUID().uuidString.lowercased(),
            session_id: sessionID,
            app_id: config.appID,
            user_id: userID,
            signal: signal,
            app_version: config.appVersion,
            os_name: DeviceInfo.osName,
            os_version: DeviceInfo.osVersion,
            environment: environment.rawValue,
            country: config.collectsCountry ? DeviceInfo.country : nil,
            client_ts: at ?? now(),
            metadata: metadata
        )
        queue.append(event)
        trim()
        // Written now, not only after a failed send: a crash or a kill must not take the
        // session's events with it. A few KB, at most once a minute in steady state.
        persist()
        log("▸ \(signal)\(signal == Signal.heartbeat ? " (presence ping)" : "")" + (metadata.map { " \($0)" } ?? ""))

        if queue.count >= config.maxBatchSize {
            Task { await self.flush() }
        } else {
            scheduleFlush()
        }
    }

    /// Merges `patch` into the user's properties; an empty-string value removes that key. Only a
    /// change is sent - as `user.identify` whose metadata is the whole merged set, so the server
    /// stores it as-is. Keys are clamped to 40 characters and values to 200, the limits the
    /// ingest API applies, so what the SDK remembers is exactly what the server stored.
    func identify(_ patch: [String: String], at: Date? = nil) {
        guard collecting, !retired else { return }
        var merged = traits
        for (key, value) in patch {
            let k = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTraitKeyLength))
            guard !k.isEmpty else { continue }
            let v = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTraitValueLength))
            if v.isEmpty { merged.removeValue(forKey: k) } else { merged[k] = v }
        }
        // The ingest API keeps at most 20 metadata keys per event; beyond that the extra properties
        // would be dropped server-side, so cap here - reserved keys first.
        if merged.count > maxTraits {
            let keep = merged.keys.sorted { a, b in
                let ra = a.hasPrefix("$"), rb = b.hasPrefix("$")
                return ra != rb ? ra : a < b
            }.prefix(maxTraits)
            merged = merged.filter { keep.contains($0.key) }
        }
        guard merged != traits else { return }
        traits = merged
        persistTraits()
        track(signal: Signal.identify, metadata: merged, at: at)
    }

    /// Forgets every property attached to this install (sign-out) and sends `user.reset` if
    /// there was anything to forget. The install id itself is untouched.
    func reset(at: Date? = nil) {
        guard collecting, !retired, !traits.isEmpty else { return }
        traits = [:]
        persistTraits()
        track(signal: Signal.reset, metadata: nil, at: at)
    }

    /// Foreground / background transitions. Idempotent: SwiftUI reports "active" twice at launch
    /// (`onAppear` and the first `scenePhase`) and leaving as `.inactive` then `.background`,
    /// and each pair must act exactly once. Active after more than `sessionTimeout` away starts a
    /// session, whether the app was cold-launched or resumed; inactive stops the heartbeat and
    /// flushes, holding the process open long enough for the send to finish.
    func setActive(_ active: Bool, at: Date? = nil) {
        guard collecting, !retired, active != isActive else { return }
        isActive = active
        let t = at ?? now()
        if active {
            let resumes =
                lastActiveAt.map { sessionID != nil && t.timeIntervalSince($0) <= config.sessionTimeout } ?? false
            if !resumes {
                sessionID = UUID().uuidString.lowercased()
                track(signal: Signal.sessionStart, metadata: nil, at: t)
            }
            rememberActive(t)
            startHeartbeat()
        } else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            rememberActive(t)
            Task { await self.flushHoldingProcess() }
        }
    }

    /// The moment we last knew the app was in front of the user; the session timeout counts from
    /// here. Refreshed on every transition and every heartbeat, so a process killed while in the
    /// foreground still leaves a recent stamp behind.
    private func rememberActive(_ t: Date) {
        lastActiveAt = t
        UserDefaults.standard.set(t.timeIntervalSince1970, forKey: lastActiveKey)
        UserDefaults.standard.set(sessionID, forKey: sessionKey)
    }

    private func persistTraits() {
        if traits.isEmpty {
            UserDefaults.standard.removeObject(forKey: traitsKey)
        } else {
            UserDefaults.standard.set(traits, forKey: traitsKey)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = config.heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                // Back from a brief interruption: finish the interval that was running rather
                // than tick again straight away.
                if let wait = await self?.timeUntilNextHeartbeat(), wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await self?.heartbeat()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func timeUntilNextHeartbeat() -> TimeInterval {
        guard let last = lastHeartbeatAt else { return 0 }
        return config.heartbeatInterval - now().timeIntervalSince(last)
    }

    private func heartbeat() {
        // `setActive(false)` cancels the heartbeat task on the actor; a tick that was already
        // waiting for its turn must not land after it.
        guard isActive, !Task.isCancelled else { return }
        let t = now()
        lastHeartbeatAt = t
        rememberActive(t)
        track(signal: Signal.heartbeat, metadata: nil, at: t)
    }

    // MARK: - Flushing

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let interval = config.flushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            // An explicit flush cancels this timer; a cancelled timer must not flush anyway.
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// `flush()` under a process assertion, so leaving the foreground does not suspend the
    /// process mid-request. Without it the request goes out, the server stores the batch, and
    /// the 2xx reaches a suspended process: the client would count the send as failed and
    /// re-send at the next launch. Server-side dedupe by event id is the safety net; this stops
    /// the replays at the source.
    func flushHoldingProcess() async {
        let hold = ProcessHold(reason: "AppGlance.flush")
        await flush()
        hold.release()
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        // Ask again if the store has not answered yet, then wait briefly: the usual case is an
        // answer in milliseconds and no batch leaves with the guessed label; the offline first
        // launch sends with the guess after the grace and is corrected at a later flush.
        beginEnvironmentRefinement()
        if let refineTask {
            let grace = environmentAnswerGrace
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await refineTask.value }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000)) }
                await group.next()
                group.cancelAll()
            }
        }
        // The actor suspends inside `drain()`, so a second flush can arrive mid-send. It joins
        // the send in progress instead of racing it - the slice was claimed out of the queue
        // before the await, so nothing is ever sent twice, and a caller holding the process open
        // stays until the send has landed.
        while let running = inFlight {
            await running.value
        }
        guard !queue.isEmpty, !retired else { return }
        let sending = Task { await self.drain() }
        inFlight = sending
        await sending.value
    }

    /// Sends the queue in request-sized slices, oldest first, until it is empty or the network
    /// says "later". Each slice is claimed out of the queue before the await, so events tracked
    /// meanwhile line up behind it.
    private func drain() async {
        defer { inFlight = nil }
        var slice = maxEventsPerRequest
        while !queue.isEmpty, !retired {
            let batch = Array(queue.prefix(slice))
            queue.removeFirst(batch.count)
            inFlightBatch = batch
            persist()
            let count = "\(batch.count) event\(batch.count == 1 ? "" : "s")"
            log("↑ sending \(count)…")
            do {
                try await send(batch)
                inFlightBatch = []
                persist()
                log("✓ sent \(count)" + (environment == .simulator || environment == .debug ? " (scope: All)" : ""))
            } catch SendError.status(let status) where status == 413 && batch.count > 1 {
                // Too big for one request: put it back and go smaller for the rest of this drain.
                // The server rejected the body without processing any of it, so its heartbeats
                // were never counted and are safe to re-send.
                log("↩ 413 - the batch is too big for one request; retrying in smaller slices")
                inFlightBatch = []
                requeue(batch, keepingHeartbeats: true)
                slice = max(1, batch.count / 2)
            } catch SendError.status(let status) where Self.isPermanent(status) {
                // A 4xx no retry will fix - unknown key, malformed, one oversized event. Dropping
                // the slice beats a queue that can never drain again.
                log(
                    "✕ HTTP \(status) - \(status == 401 || status == 403 ? "check the write key (Setup tab in the dashboard); " : "")"
                        + "a retry could never succeed, so this batch is dropped")
                inFlightBatch = []
                persist()
            } catch {
                // Offline, 5xx, 429: keep everything, in order, for a later attempt.
                let why: String
                if case SendError.status(let status) = error {
                    why = "HTTP \(status)"
                } else {
                    why = error.localizedDescription
                }
                log("⟳ couldn't send (\(why)) - keeping \(count) for the next try")
                inFlightBatch = []
                requeue(batch, keepingHeartbeats: !Self.mayHaveBeenApplied(error))
                return
            }
        }
    }

    /// Puts a batch back at the front of the queue, ahead of anything queued meanwhile.
    ///
    /// Heartbeats are kept only when the server definitely did not process the batch. Every
    /// other signal carries an event id and the server ignores a replay, so retrying it is free;
    /// heartbeats are folded into presence and session-length rollups on arrival, and a re-sent
    /// one is counted twice, permanently. A dropped tick costs a minute of resolution on a chart
    /// that is approximate by design; a doubled tick corrupts the numbers.
    private func requeue(_ batch: [Event], keepingHeartbeats: Bool) {
        let retryable = keepingHeartbeats ? batch : batch.filter { $0.signal != Signal.heartbeat }
        let dropped = batch.count - retryable.count
        if dropped > 0 {
            log(
                "· dropped \(dropped) presence ping\(dropped == 1 ? "" : "s") rather than risk counting \(dropped == 1 ? "it" : "them") twice"
            )
        }
        queue.insert(contentsOf: retryable, at: 0)
        trim()
        persist()
    }

    private func trim() {
        if queue.count > maxQueuedEvents {
            queue.removeFirst(queue.count - maxQueuedEvents)
        }
    }

    /// Could the server have processed this batch despite the failure? A timeout or a connection
    /// dropped mid-flight looks the same whether the request was applied and the response lost,
    /// or never arrived at all - so those answer "maybe". The failures where no connection was
    /// ever established are the exception: nothing on the other end could have counted anything.
    /// That case matters, because being offline is the ordinary case the on-disk queue exists
    /// for, and dropping every presence ping for the length of a flight would be loss bought
    /// for no safety.
    private static func mayHaveBeenApplied(_ error: Error) -> Bool {
        if case SendError.status = error { return true }  // the server answered, so it saw the request
        guard let urlError = error as? URLError else { return true }
        switch urlError.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return false  // never left the device
        default:
            return true  // includes .timedOut and .networkConnectionLost
        }
    }

    /// Client errors that mean "this batch will never be accepted as is". 408 (timeout), 425 (too
    /// early) and 429 (rate limited) are the 4xx that do deserve a retry.
    private static func isPermanent(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![408, 425, 429].contains(status)
    }

    // MARK: - Networking

    private enum SendError: Error {
        case status(Int)
    }

    private func send(_ batch: [Event]) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try encoder.encode(batch)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SendError.status(-1) }
        guard (200..<300).contains(http.statusCode) else { throw SendError.status(http.statusCode) }
    }

    // MARK: - Offline persistence

    /// Writes what is still owed to disk: the queue, plus the in-flight slice's non-heartbeat
    /// events. If the process is killed before the response arrives, the next launch re-sends
    /// those (the server ignores replays by event id) and never the heartbeats, which may already
    /// have been counted. Refused once retired, so a replaced client cannot clobber the file.
    private func persist() {
        guard !retired else { return }
        let owed = inFlightBatch.filter { $0.signal != Signal.heartbeat } + queue
        guard let data = try? encoder.encode(owed) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    nonisolated private static func loadPersisted(from url: URL) -> [Event] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? EventCoding.makeDecoder().decode([Event].self, from: data)) ?? []
    }

    nonisolated static func makeStoreURL(appID: String) -> URL {
        let safeID = appID.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let directory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("appglance-\(safeID).json")
    }

    // MARK: - Test hooks

    /// Signals waiting for the next flush, in order.
    func pendingSignals() -> [String] { queue.map(\.signal) }

    /// The queued events themselves, in order.
    func pendingEvents() -> [Event] { queue }

    /// The user properties as the SDK believes the server has them.
    func currentTraits() -> [String: String] { traits }

    /// The current session id (nil until the first `session.start`).
    func currentSessionID() -> String? { sessionID }

    /// Forgets the persisted session state and user properties for an app id.
    nonisolated static func resetSessionState(appID: String) {
        UserDefaults.standard.removeObject(forKey: "app.appglance.lastActive.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.session.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.traits.\(appID)")
    }
}
