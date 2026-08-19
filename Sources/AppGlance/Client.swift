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
    private static let maxQueuedEvents = 500
    /// Events per request. The ingest API accepts up to 500 events / 256 KB per batch; a
    /// long-offline queue drains in slices this size rather than as one oversized POST.
    private let maxEventsPerRequest = 100
    private let maxTraits = 20
    private let maxTraitKeyLength = 40
    private let maxTraitValueLength = 200

    private var queue: [Event]
    /// The slice currently on the wire. One slot, because one delivery runs at a time: `flush`
    /// claims `inFlight` before it suspends, so a second flush joins that delivery instead of
    /// starting a drain whose own slice would take this one's place. See `persist()`.
    private var inFlightBatch: [Event] = []
    /// The ids of the events this client read from the queue file instead of recording itself.
    /// They belong to the build that wrote them, not to this run, and that difference decides
    /// what stays on disk if a late store answer closes the environment gate: see
    /// `adoptEnvironment`. Bounded by the queue cap, and empty on the ordinary launch that finds
    /// no file at all.
    private var inheritedEventIDs: Set<String>
    /// The presence stamps this install had when the client started. They are the install's and
    /// not this run's - every build sharing the container reads them - and until the store has
    /// answered, this run does not know whether it was ever entitled to move them. See
    /// `adoptEnvironment`.
    private let startupPresence: (heartbeat: Date?, event: Date?, active: Date?)
    /// The session this install was in the middle of when the client started, and whether it was
    /// still owed its `session.start`. The install's too, and read before the mint in init can
    /// move either: an answer that closes the gate has to give the pair back together, or the
    /// events the close keeps on disk are left under a session nothing on disk names.
    private let startupSession: (id: String?, unadopted: Bool)
    /// The delivery in progress: the wait for the store's label, and the drain that follows.
    private var inFlight: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    /// True from the moment the batch-size trigger asks for a delivery until that delivery is
    /// over. The trigger is reached again on every event past the threshold, and without this
    /// each of those events starts a delivery of its own: it joins the one already running, then
    /// finds the single event queued since and sends that as a request in its own right, so a
    /// burst leaves the device as one request - one round trip, one full set of headers - per
    /// event. Held instead, everything queued meanwhile rides along in the batch `drain` is
    /// already sending. The Kotlin client coalesces the same way.
    private var flushRequested = false
    private var heartbeatTask: Task<Void, Never>?
    /// The in-flight ask for the store's environment answer; each flush waits briefly for it.
    /// See `adoptStoreAnswer`.
    private var refineTask: Task<Void, Never>?
    /// True once the store has answered (or the environment is a compile-time fact). Until
    /// then a flush asks again: a fresh install's first ask can find nothing cached.
    private var environmentAnswered = false
    /// Asks so far, against the ceiling. Asking again is worth a few tries - a fresh install's
    /// first ask finds nothing cached, and an offline launch's fails - but some builds can never
    /// be answered for at all (a directly downloaded Mac app, an ad hoc or enterprise build, a
    /// device where StoreKit is restricted), and those would otherwise pay a task and a storekitd
    /// round trip on every flush for as long as the process lives. Once the ceiling is reached
    /// the guessed label stands for the rest of the run.
    private var environmentAsks = 0
    private let maxEnvironmentAsks = 5
    /// How long a flush waits for the store's answer before sending with the guessed label -
    /// a slow or offline first launch must not hold batches hostage; later flushes correct
    /// what follows. Injected for the same reason `asksTheStore` is: the ask a test host makes
    /// resolves at once, so a grace in seconds is otherwise only observable by waiting it out.
    private let environmentAnswerGrace: TimeInterval
    /// Flushes parked on that grace, resumed by whichever comes first: the ask settling, or the
    /// grace running out. See `awaitEnvironmentAnswer`.
    private var environmentWaiters: [CheckedContinuation<Void, Never>] = []
    /// True once one flush has waited out the grace. Only the first waits: after that the batch
    /// goes with the guessed label and `adoptEnvironment` restamps whatever is still queued if
    /// the answer ever arrives, so a build the store never answers for does not pay the wait
    /// again and again.
    private var environmentGracePaid = false
    /// Set by `shutdown()` once a later `configure` has replaced this client.
    private var retired = false

    // The missing-lifecycle check. Nothing in the SDK reports foreground and background on its
    // own: `.trackAppLifecycle()` (SwiftUI) or `AppGlance.setActive(_:)` (UIKit) has to, and
    // without it `setActive` never runs, so no session ever opens, no presence ping ever fires,
    // and every event this install ever sends carries the one pre-minted session id. From inside
    // the app that mistake is invisible - `install` and every `track` still arrive, the flush
    // timer still sends, and the dashboard's setup badge still turns green - so the SDK says it
    // out loud once, a little after `configure`, if the signal has not arrived. Unconditional,
    // like the environment-gate hint in `announce`: it is the one integration mistake a customer
    // cannot debug from the console, and hiding it behind `debug` hides it from the build where
    // it happens.
    private var sawLifecycleSignal = false
    private var lifecycleCheckTask: Task<Void, Never>?
    private var lifecycleCheckDone = false
    private let lifecycleSignalGrace: TimeInterval = 10
    /// The grace the facade asked for, kept because the client that is asked is not always the
    /// one that can arm: a closed environment gate refuses, and the store's answer re-arms later
    /// with no caller left to ask again.
    private var lifecycleCheckGrace: TimeInterval?

    // Retry backoff. Automatic delivery (the batch-size trigger, the flush timer) waits
    // exponentially longer after consecutive retryable failures, so a struggling server is not
    // hammered once a minute by every install; an explicit `flush()` call is the developer's
    // own decision and always attempts. Backoff delays attempts, nothing more: what is retried,
    // and which events a retry may carry, is decided entirely by `drain()`.
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?
    /// The retry ceiling, and the wider one a sustained outage earns. A minute is the right
    /// cadence for a server that is briefly unwell. An outage that has already survived ten
    /// attempts is not that, and retrying every 30 to 60 s for the length of it re-uploads the
    /// same head slice over and over: an hour of 503s costs a foregrounded install 2.7 MB of
    /// upload, 94% of it bytes already put on the wire, aimed at an ingest that is failing and
    /// can least absorb the herd. Waiting longer loses nothing - the queue is on disk, `flush()`
    /// and the flush on the way to the background both ignore the backoff entirely, and a track
    /// or a presence ping re-arms the timer - so the install still looks at least once a cadence.
    private let maxBackoff: TimeInterval = 60
    private let sustainedOutageBackoff: TimeInterval = 300
    private let sustainedOutageAfter = 10

    // Session state. A session is "the app is in front of the user"; it survives short
    // interruptions and ends only after `sessionTimeout` of absence - the same gap the dashboard
    // uses, so the two agree on what a session is. Persisted so a quit-and-relaunch inside the
    // timeout continues the session and a relaunch after it starts a new one.
    private var isActive = false
    /// The last foreground state the app reported, whatever this client did with it. `isActive`
    /// moves only for a client that collects, and only on a change, so it is not a record of what
    /// the app said; this is. nil means the app has reported nothing yet.
    private var reportedActive: Bool?
    private var lastActiveAt: Date?
    private var lastHeartbeatAt: Date?
    /// The newest ping the server has acknowledged: seeded from the persisted stamp, moved only
    /// by an accepted batch, and what a dropped ping's stamp is rolled back to. See
    /// `rollBackHeartbeatStamp`.
    private var deliveredHeartbeatAt: Date?
    /// When this install last recorded a real (non-heartbeat) event. A real event proves
    /// presence exactly as a ping does - the server moves the same "last seen" stamps for
    /// both - so the heartbeat waits for `heartbeatInterval` of *silence*, measured from the
    /// later of this and `lastHeartbeatAt`. Persisted for the same reason the ping stamp is: a
    /// relaunch inside `sessionTimeout` resumes and records no `session.start`, and a visit
    /// shorter than one interval leaves no ping stamp behind either, so without it a fresh
    /// process would owe a ping at once however recently the app was really heard from.
    private var lastEventAt: Date?
    /// The server's floor for the presence cadence, from the ingest response
    /// (`heartbeat_interval`, seconds). Plans differ in how often they need to hear from an
    /// install; the effective interval is the larger of this and the configured one. Persisted,
    /// so a launch paces itself correctly before its first response arrives.
    private var serverHeartbeatFloor: TimeInterval?
    /// A background transition sends one last ping if the server has heard nothing for this
    /// long, so the session's length is exact however sparse the cadence is.
    private let closingTickAfter: TimeInterval = 60
    /// The soonest a ping may replace one that was dropped (see `rollBackHeartbeatStamp`). Far
    /// enough out that a ping which did land after all is not followed by a second tick in the
    /// same second; short enough that the sparsest cadence a plan asks for (240 s) plus one
    /// dropped ping still keeps the install inside the dashboard's five-minute presence window.
    /// It is also the finest presence resolution `heartbeatInterval` itself allows. Injected
    /// rather than read straight from here so a test can watch the replacement ping arrive
    /// instead of spending fifteen seconds of real time on it; a shipped app takes the default.
    private let minHeartbeatRetry: TimeInterval
    private var sessionID: String?
    /// True while `sessionID` is pre-minted and no `session.start` has been sent for it: the id
    /// exists so `install` and everything else recorded before the first foreground carry the
    /// session they belong to, and the first non-resume `setActive(true)` must adopt it rather
    /// than mint another. Mirrored on disk so a process that dies before its first foreground
    /// hands the id to the next launch instead of leaving the server session it opened orphaned.
    private var sessionUnadopted = false
    private let lastActiveKey: String
    private let sessionKey: String
    private let sessionUnadoptedKey: String
    private let lastHeartbeatKey: String
    private let lastEventKey: String
    private let heartbeatFloorKey: String

    // User properties. `traits` is the snapshot the server has ACKNOWLEDGED: it moves only when a
    // batch carrying the `user.identify` (or `user.reset`) that changed it comes back accepted, so
    // `identify` with the same values on every launch stays free while what it recorded is really
    // stored, and starts sending again the moment a carrying event is lost. What an event still
    // owed will leave the server with is read from the queue instead of being kept beside this,
    // because the queue is the one place that knows whether that event still exists: a trim, a
    // permanent 4xx, a dropped queue file and a relaunch all move it, and a second copy of the
    // answer would disagree with the first. See `pendingTraits`.
    private var traits: [String: String]
    private let traitsKey: String

    /// True exactly once per install: the launch that minted the install id.
    private let isNewInstall: Bool
    private let installAt: Date
    private var installRecorded = false
    /// Set while this install still owes its `install` event, and cleared the moment the event is
    /// queued. The launch that mints the id is not always one that can record: the environment
    /// gate excludes Debug and the Simulator by default, and an app waiting for consent
    /// configures with `isEnabled: false`, so `track` is a no-op on both. `isNewInstall` is true
    /// on that one launch only, so without a note on disk the event is owed by a launch that is
    /// already over and is lost for the life of the install. Nothing written means nothing owed,
    /// which is how every install set up by an earlier version reads: those were counted when
    /// they were new.
    private let installPendingKey: String

    /// Whether this build has anything to ask the store about. A compile-time environment
    /// (Simulator, Debug) has not, so the question is closed before it is opened. Injected rather
    /// than read directly so tests can drive the ask path at all: a test host is a Debug build,
    /// where it is never entered.
    private let asksTheStore: Bool
    /// The ask itself, injected alongside `asksTheStore` and for the same reason: the real one
    /// answers a test host instantly, so a wait a slow store is meant to bound has nothing to
    /// bound there.
    private let storeAnswer: @Sendable () async -> (answer: AppEnvironment?, failure: String?)

    init(
        config: AppGlance.Configuration, userID: String, isNewInstall: Bool = false, installAt: Date = Date(),
        session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() },
        asksTheStore: Bool = !AppEnvironment.isCompileTimeDetermined,
        storeAnswer: @escaping @Sendable () async -> (answer: AppEnvironment?, failure: String?) = {
            await AppEnvironment.storeAnswer()
        },
        environmentAnswerGrace: TimeInterval = 3,
        minHeartbeatRetry: TimeInterval = 15
    ) {
        self.config = config
        self.session = session
        self.asksTheStore = asksTheStore
        self.storeAnswer = storeAnswer
        self.environmentAnswerGrace = environmentAnswerGrace
        self.minHeartbeatRetry = minHeartbeatRetry
        self.userID = userID
        self.isNewInstall = isNewInstall
        self.installAt = installAt
        self.now = now

        // On-disk keys are part of the SDK's contract with existing installs; see CONTRIBUTING.
        self.lastActiveKey = "app.appglance.lastActive.\(config.appID)"
        self.sessionKey = "app.appglance.session.\(config.appID)"
        self.sessionUnadoptedKey = "app.appglance.sessionUnadopted.\(config.appID)"
        self.lastHeartbeatKey = "app.appglance.lastHeartbeat.\(config.appID)"
        self.lastEventKey = "app.appglance.lastEvent.\(config.appID)"
        self.heartbeatFloorKey = "app.appglance.heartbeatFloor.\(config.appID)"
        self.traitsKey = "app.appglance.traits.\(config.appID)"
        self.installPendingKey = "app.appglance.installPending.\(config.appID)"
        let defaults = UserDefaults.standard
        // A minted id means this device is not the one that state was written on. The install id
        // is device-bound (a `ThisDeviceOnly` Keychain item, mirrored outside the backup), but
        // everything below it is in `UserDefaults`, which an iCloud or encrypted backup and a
        // device-to-device transfer all carry - so a restored handset mints its own id and then
        // reads the old device's session, presence stamps and user properties as its own. The
        // traits are the lasting half: `identify` only sends a change, so an install whose cache
        // says the server already has these properties never sends them, and its page in the
        // dashboard stays empty however often the app calls `identify`. A genuinely new install
        // has nothing here to clear, so this costs it nothing.
        if isNewInstall { Self.resetSessionState(appID: config.appID) }
        if let floor = defaults.object(forKey: heartbeatFloorKey) as? Double, Self.isSaneHeartbeatFloor(floor) {
            self.serverHeartbeatFloor = floor
        }
        let persistedSessionID = defaults.string(forKey: sessionKey)
        let persistedUnadopted = defaults.bool(forKey: sessionUnadoptedKey)
        self.startupSession = (persistedSessionID, persistedUnadopted)
        let bootTime = now()
        let restoredLastActive = Self.restoredStamp(defaults.object(forKey: lastActiveKey) as? Double, at: bootTime)
        // The heartbeat stamp survives a relaunch for the same reason the session does: the
        // interval is a wall-clock promise, at most one presence ping per heartbeatInterval,
        // and the server folds pings into additive rollups that a doubled tick would inflate.
        self.lastHeartbeatAt = Self.restoredStamp(defaults.object(forKey: lastHeartbeatKey) as? Double, at: bootTime)
        // A ping an earlier process stamped is the best proof of delivery this one can have: the
        // queue file never holds a ping that was in flight, so there is nothing left to re-send
        // either way. A roll-back therefore undoes only this process's own unconfirmed pings.
        self.deliveredHeartbeatAt = self.lastHeartbeatAt
        // The event stamp comes back with it: it is the other half of the silence the interval
        // measures, and a resumed session records no event of its own to replace it.
        self.lastEventAt = Self.restoredStamp(defaults.object(forKey: lastEventKey) as? Double, at: bootTime)
        self.startupPresence = (self.lastHeartbeatAt, self.lastEventAt, restoredLastActive)
        self.traits = (defaults.dictionary(forKey: traitsKey) as? [String: String]) ?? [:]

        let environment = AppEnvironment.current
        // Debug mode lifts the environment gate and nothing else; the developer's own off-switch wins.
        let collecting = config.isEnabled && (config.debug || config.enabledEnvironments.contains(environment))

        // A fresh session is inevitable when there is nothing to resume: no earlier run, a gap
        // already past the timeout, or no session id left behind. Its id is minted here, before
        // any event exists, so `install` and everything recorded before the first foreground
        // carry the id that `session.start` will adopt; on the server they all fold into one
        // session. Persisted immediately, marked unadopted, and the last-active stamp is left
        // alone: the stamp keeps deciding resume vs new session exactly as it always has. A
        // client the gate has closed records nothing, so it mints nothing and writes nothing:
        // its own run must not renumber the session state a sending build left behind.
        let gapExceedsTimeout = Self.secondsSince(restoredLastActive, at: bootTime) > config.sessionTimeout
        var startupSessionID: String?
        if restoredLastActive != nil { startupSessionID = persistedSessionID }
        var startupUnadopted = false
        if collecting {
            if persistedUnadopted, let preMinted = persistedSessionID, !preMinted.isEmpty {
                // A run that died between minting and its first foreground: the same id is still
                // owed its `session.start`, so it is reused, never replaced.
                startupSessionID = preMinted
                startupUnadopted = true
            } else if gapExceedsTimeout || startupSessionID == nil {
                let minted = UUID().uuidString.lowercased()
                startupSessionID = minted
                startupUnadopted = true
                defaults.set(minted, forKey: sessionKey)
                defaults.set(true, forKey: sessionUnadoptedKey)
            }
        }
        self.lastActiveAt = restoredLastActive
        self.sessionID = startupSessionID
        self.sessionUnadopted = startupUnadopted

        // Both backends take the same JSON array of events; they differ in where it goes and how it
        // authenticates. Both ignore a replayed `(app_id, event_id)` - the hosted ingest by design,
        // Supabase through PostgREST's `on_conflict` + `ignore-duplicates` over the schema's unique index.
        switch config.backend {
        case .hosted(let endpoint, let apiKey):
            self.endpoint = endpoint
            self.headers = [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)",
                "User-Agent": Self.userAgent,
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
                "User-Agent": Self.userAgent,
            ]
        }

        let storeURL = Self.makeStoreURL(appID: config.appID)
        // Consent withdrawal applies to what is already on disk, not only to what happens next.
        // The way an app honours it is to `configure` again with `isEnabled: false`, and the
        // events recorded before that are exactly the ones consent was withdrawn for: a later
        // `flush()` must not ship them, and turning the switch back on must not resurrect them.
        //
        // The delete is keyed on `isEnabled` alone, NOT on `collecting`. `collecting` also folds
        // in the environment gate, and that gate closing is not a withdrawal of consent: a
        // developer building from Xcode over an installed App Store copy closes it for that run,
        // and deleting the file there would throw away a real queue the store build saved during
        // an outage. A closed environment gate stops the queue being loaded; only a closed
        // consent switch destroys it.
        let persisted = collecting ? Self.loadPersisted(from: storeURL) : []
        if !config.isEnabled {
            try? FileManager.default.removeItem(at: storeURL)
            // The person goes with the events. `$email`, `$name` and `$id` are the only personal
            // data the SDK puts on disk, they live in `UserDefaults` - inside the iCloud and the
            // encrypted backup - and the one API that clears them, `reset()`, records nothing on
            // a client that is not collecting, so an app that turns the switch off first can
            // never reach them again. Keyed on `isEnabled` for the same reason the delete above
            // is: a closed environment gate is not a withdrawal, and clearing on one would throw
            // away the shipped build's record of what the server holds, from a build sharing its
            // container. The install id itself stays: turning collection back on has to be the
            // same install, not a new one.
            defaults.removeObject(forKey: traitsKey)
            self.traits = [:]
        }
        self.storeURL = storeURL
        self.encoder = EventCoding.makeEncoder()
        self.environment = environment
        self.collecting = collecting
        self.queue = persisted
        self.inheritedEventIDs = Set(persisted.map(\.event_id))

        Self.announce(
            config: config, environment: environment, collecting: collecting,
            endpoint: self.endpoint, userID: userID, waiting: persisted.count)
    }

    deinit {
        heartbeatTask?.cancel()
        flushTask?.cancel()
        refineTask?.cancel()
        lifecycleCheckTask?.cancel()
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
    /// this before applying any other command, and `adoptEnvironment` calls it again when a gate
    /// that was closed at startup opens.
    ///
    /// A launch that mints the install id and cannot record writes the debt down instead, and the
    /// first launch that is collecting pays it, stamped with its own `configure`: the moment this
    /// install can first be counted, and the moment the rest of that first batch belongs to. An
    /// older stamp would date the install to a run the app asked to be left out of its numbers.
    /// Only a launch that mints the id ever writes the marker, so an Xcode run over an installed
    /// App Store copy leaves nothing behind and no install is ever recorded twice.
    func recordInstallIfNeeded() {
        guard !installRecorded, !retired else { return }
        let defaults = UserDefaults.standard
        let owed = defaults.bool(forKey: installPendingKey)
        guard isNewInstall || owed else { return }
        guard collecting else {
            // The facade asks again on every command; write only what is not already there.
            if !owed { defaults.set(true, forKey: installPendingKey) }
            return
        }
        installRecorded = true
        // Cleared before the event is queued, as the unadopted-session marker is: a death in
        // between costs this install its `install`, where clearing it afterwards would record a
        // second one on the next launch. One uncounted install beats one counted twice.
        defaults.removeObject(forKey: installPendingKey)
        track(signal: Signal.install, metadata: nil, at: installAt)
    }

    /// Where the app is, according to what it last reported to this client, or nil if it has
    /// reported nothing. The facade reads it before `shutdown()` and hands it to the client that
    /// takes this one's place.
    ///
    /// A `configure` in the middle of a visit - the documented way to apply a consent change -
    /// is the one moment nothing reports the app's state: SwiftUI reports the front through
    /// `onAppear` and through scene-phase *changes*, and a configure mid-visit is neither, while
    /// a UIKit app's `setActive(_:)` calls come from those same two transitions. Without the
    /// hand-over the replacement starts inactive and stays that way for the rest of the visit:
    /// no `session.start`, no presence ping, no flush on the way to the background, and no
    /// last-active stamp for the next launch to judge resume-or-new-session by.
    func reportedForegroundState() -> Bool? { reportedActive }

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
        lifecycleCheckTask?.cancel()
        lifecycleCheckTask = nil
        queue.removeAll()
        // A flush parked on the environment grace has nothing left to send: it is told so now
        // rather than after sitting out the rest of the wait.
        releaseEnvironmentWaiters()
    }

    /// Arms the missing-lifecycle check; the facade calls this once, right after `configure`.
    /// Separate from init so tests own exactly when (and whether) it runs, and so the delay can
    /// be shortened in a test rather than waited out.
    func armLifecycleCheck(after grace: TimeInterval? = nil) {
        if let grace { lifecycleCheckGrace = grace }
        guard collecting, !retired, !sawLifecycleSignal, !lifecycleCheckDone, lifecycleCheckTask == nil else { return }
        let wait = lifecycleCheckGrace ?? lifecycleSignalGrace
        lifecycleCheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(wait))
            guard !Task.isCancelled else { return }
            await self?.reportMissingLifecycleIfNeeded(after: wait)
        }
    }

    private func reportMissingLifecycleIfNeeded(after waited: TimeInterval) {
        lifecycleCheckTask = nil
        guard !retired, collecting, !sawLifecycleSignal, !lifecycleCheckDone else { return }
        lifecycleCheckDone = true
        Log.line(
            "no foreground signal \(Int(waited)) s after configure: add .trackAppLifecycle() to your root"
                + " view (SwiftUI), or call AppGlance.setActive(_:) from your scene or app delegate (UIKit). Without it"
                + " no session ever opens, \"active right now\" stays empty, and every event this install sends carries"
                + " one session that never ends, so session counts and lengths are wrong.")
    }

    /// Starts (or restarts) the ask for the store's environment answer; the facade calls this
    /// right after `configure`, and `flush()` calls it again while the question is still open.
    /// Separate from init so tests own exactly when (and whether) it runs.
    func beginEnvironmentRefinement() {
        guard refineTask == nil, !retired, !environmentAnswered, environmentAsks < maxEnvironmentAsks else { return }
        guard asksTheStore else {
            environmentAnswered = true
            return
        }
        environmentAsks += 1
        let ask = storeAnswer
        refineTask = Task { [weak self] in
            let (answer, failure) = await ask()
            await self?.adoptStoreAnswer(answer, failure: failure)
        }
    }

    /// nil means the store had no answer this time: the task slot clears so a later flush asks
    /// again, and the guessed label stands meanwhile. Once the ask ceiling is reached the guess
    /// stands for the rest of the run.
    func adoptStoreAnswer(_ answer: AppEnvironment?, failure: String? = nil) {
        refineTask = nil
        // Whatever this ask settled - a corrected label, or the guess standing for the run - is
        // what a flush parked on the grace is waiting for, so it goes on from here.
        defer { releaseEnvironmentWaiters() }
        guard !retired else { return }
        guard let answer else {
            let again = environmentAsks < maxEnvironmentAsks
            log(
                "the store had no environment answer\(failure.map { " (\($0))" } ?? "")"
                    + (again
                        ? " - asking again at the next flush"
                        : " - staying with the \(environment.rawValue) guess for this run"))
            return
        }
        guard !environmentAnswered else { return }
        environmentAnswered = true
        adoptEnvironment(answer)
    }

    /// Adopts the store's answer for where this build runs. Queued events carrying this run's
    /// guessed label are restamped - the first flush waits for the refinement, so nothing
    /// leaves with the wrong tag. Labels that differ from the guess are kept: they came from
    /// an earlier run whose channel this process cannot vouch for.
    ///
    /// The answer can move the sending gate either way, and both directions have to arrive at
    /// the state init would have set up had the guess been right from the start.
    ///
    /// - It opens. This client is the recording one now, so it takes the session state init
    ///   withheld from it (`adoptStartupSession`) and reads the queue file init did not read.
    /// - It closes. This client records nothing further and sends nothing, so everything it
    ///   queued under the guess goes with the gate: those events belong to an environment the
    ///   app said should never send. What was already on disk when this client started stays
    ///   there. That is init's rule word for word - a closed environment gate is not a
    ///   withdrawal of consent, and a debuggable build run over an installed release copy must
    ///   not destroy the queue that copy saved during an outage - and it holds however late the
    ///   answer arrives. The state this run shares with the builds beside it goes back the way it
    ///   was found: the presence stamps, the session id and the marker that says a session is
    ///   still owed its `session.start`. So does this run's own `install`, which no later launch
    ///   could record in its place.
    func adoptEnvironment(_ refined: AppEnvironment) {
        guard !retired, refined != environment else { return }
        let guessed = environment.rawValue
        environment = refined
        let wasCollecting = collecting
        collecting = config.isEnabled && (config.debug || config.enabledEnvironments.contains(refined))
        if collecting {
            if !wasCollecting {
                adoptStartupSession()
                // The events an earlier run left owed are this client's to deliver now. They are
                // read at the labels they carry and restamped below by the same rule as this
                // run's own, and reading them is also what keeps the write below from putting an
                // empty queue over a file this client had not looked at.
                let waiting = Self.loadPersisted(from: storeURL)
                inheritedEventIDs.formUnion(waiting.map(\.event_id))
                queue = waiting + queue
                // Two capped queues concatenated are twice the cap. Trimmed here rather than at
                // the next `track`, which on a build that has just been let through the gate may
                // be a long way off.
                trim()
            }
            // The slice on the wire is restamped with the queue, by the same rule. Those events
            // are beyond recall as sent, but `persist` writes them as the crash record, and a
            // next launch that never gets an answer of its own would deliver them under the
            // guess: beta or development traffic landing in the dashboard's Live scope, which is
            // the one thing the label exists to prevent.
            inFlightBatch = inFlightBatch.map {
                $0.environment == guessed ? $0.relabeled(environment: refined.rawValue) : $0
            }
            queue = queue.map { $0.environment == guessed ? $0.relabeled(environment: refined.rawValue) : $0 }
            persist()
            // The check the facade armed refused at the closed gate, and it is the one integration
            // mistake a customer cannot debug from the console. A build gated out at startup and
            // opened by the answer is exactly the shipping build where the mistake is live.
            if !wasCollecting { armLifecycleCheck() }
        } else {
            // The slice on the wire is judged with the queue and by the same rule, minus its
            // pings for the reason `persist` leaves them out, and it is read before the queue is
            // emptied because a drain may have claimed the inherited events out of it already.
            // A client that never read the file does not write it either, or a gate that was
            // closed all along would truncate a queue it was never allowed to look at.
            let inherited = owedEvents.filter { inheritedEventIDs.contains($0.event_id) }
            // This run's own `install` is the one event the close cannot simply drop. Anything
            // else the app records again the next time it happens; that one is owed by a launch
            // already over, because `isNewInstall` is true on this launch alone and the marker
            // was cleared the moment the event was queued. So the debt goes back on disk and the
            // first launch that really collects pays it. Only a copy still in the queue is
            // re-owed: one already claimed for the wire may yet be accepted, and a re-recorded
            // install carries a fresh event id that the ingest's dedupe has nothing to collapse
            // it against - one uncounted install beats one counted twice. An inherited copy is
            // written back below and was never this run's to owe.
            if installRecorded,
                queue.contains(where: { $0.signal == Signal.install && !inheritedEventIDs.contains($0.event_id) })
            {
                installRecorded = false
                UserDefaults.standard.set(true, forKey: installPendingKey)
            }
            queue.removeAll()
            inFlightBatch.removeAll()
            if wasCollecting {
                writeQueueFile(inherited)
                // The events go and the stamps they moved go with them. `track` writes the
                // last-event stamp on every call, and it is the install's, so a Release build run
                // from Xcode over the App Store copy would otherwise leave the shipped build
                // owing no presence ping for up to a whole interval on its next launch - four
                // minutes of a real session missing from "active right now" at the cadence a
                // free-plan account is asked for. This run was told it should never have been
                // collecting, so it puts back what it found.
                restoreStartupState()
            }
            heartbeatTask?.cancel()
            heartbeatTask = nil
            flushTask?.cancel()
            flushTask = nil
        }
        if wasCollecting != collecting {
            // The announce line at configure spoke for the guess; say so when the answer differs.
            Log.line(
                collecting
                    ? "environment corrected to \(refined.rawValue) - this build sends after all"
                    : "environment corrected to \(refined.rawValue)"
                        + " - not sending: enabledEnvironments doesn't include \(refined.caseName)")
        } else {
            log("environment corrected: \(guessed) is really \(refined.rawValue)")
        }
        // A gate that opens is the first moment this client can record anything, and an install
        // minted behind a closed one is still owed its `install`.
        if collecting, !wasCollecting { recordInstallIfNeeded() }
    }

    /// Puts the install's presence stamps and session state back where this client found them.
    private func restoreStartupState() {
        lastHeartbeatAt = startupPresence.heartbeat
        deliveredHeartbeatAt = startupPresence.heartbeat
        lastEventAt = startupPresence.event
        lastActiveAt = startupPresence.active
        Self.write(startupPresence.heartbeat, forKey: lastHeartbeatKey)
        Self.write(startupPresence.event, forKey: lastEventKey)
        Self.write(startupPresence.active, forKey: lastActiveKey)
        // The session goes back with them, and the marker above all: a first foreground that
        // adopts a pre-minted id clears it, and the events carrying that id are exactly the ones
        // the close keeps on disk. Left cleared, the next launch of the sending build finds no
        // session pending, mints over the top, and those events are filed under a session it
        // never opens. An absent key is what "never happened" looks like for these two as well.
        sessionID = startupSession.id
        sessionUnadopted = startupSession.unadopted
        let defaults = UserDefaults.standard
        if let id = startupSession.id {
            defaults.set(id, forKey: sessionKey)
        } else {
            defaults.removeObject(forKey: sessionKey)
        }
        if startupSession.unadopted {
            defaults.set(true, forKey: sessionUnadoptedKey)
        } else {
            defaults.removeObject(forKey: sessionUnadoptedKey)
        }
    }

    /// A stamp on disk, or no stamp at all: an absent key is what "never happened" looks like
    /// everywhere else this file reads one.
    nonisolated private static func write(_ stamp: Date?, forKey key: String) {
        if let stamp {
            UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Gives this client the startup session state init withheld from it, by init's own test.
    ///
    /// A client the gate has closed records nothing, so init mints no id for it and never looks
    /// at the pre-mint marker: `sessionID` holds only what a previous run left behind, which can
    /// be a session that ended days ago. The gate opening makes this a recording client, so the
    /// question init answers for every collecting client is answered here, against the same
    /// stored state and in the same order. The gap is judged now rather than at init, for the
    /// reason `setActive` judges it there: it can have crossed the timeout since.
    private func adoptStartupSession() {
        let defaults = UserDefaults.standard
        let persistedSessionID = defaults.string(forKey: sessionKey)
        if defaults.bool(forKey: sessionUnadoptedKey), let preMinted = persistedSessionID, !preMinted.isEmpty {
            // A run that died between minting and its first foreground: the same id is still
            // owed its `session.start`, so it is reused, never replaced.
            sessionID = preMinted
            sessionUnadopted = true
            return
        }
        var gapExceedsTimeout = true
        if let last = lastActiveAt, now().timeIntervalSince(last) <= config.sessionTimeout {
            gapExceedsTimeout = false
        }
        // A session that can still be resumed keeps its restored id and stays unmarked, so the
        // first foreground resumes it instead of opening a second one. Anything else needs an id
        // of its own, minted and marked before a single event can carry it.
        guard gapExceedsTimeout || sessionID == nil else { return }
        let minted = UUID().uuidString.lowercased()
        sessionID = minted
        sessionUnadopted = true
        defaults.set(minted, forKey: sessionKey)
        defaults.set(true, forKey: sessionUnadoptedKey)
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
        // A real event is presence: the next ping is due only after an interval of silence
        // from here. (Ping stamps are kept separately, in `heartbeat()`.) Persisted like the
        // ping stamp, on the code path that has just written the queue file anyway.
        if signal != Signal.heartbeat {
            lastEventAt = event.client_ts
            UserDefaults.standard.set(event.client_ts.timeIntervalSince1970, forKey: lastEventKey)
        }
        log("▸ \(signal)\(signal == Signal.heartbeat ? " (presence ping)" : "")" + (metadata.map { " \($0)" } ?? ""))

        if queue.count >= config.maxBatchSize {
            requestFlush()
        } else {
            scheduleFlush()
        }
    }

    /// Merges `patch` into the user's properties; an empty-string value removes that key. Only a
    /// change is sent - as `user.identify` whose metadata is the whole merged set, so the server
    /// stores it as-is. Keys are clamped to 40 characters and values to 200, the limits the
    /// ingest API applies, so what the SDK remembers is exactly what the server stored.
    ///
    /// "A change" is measured against what the server will hold once everything already owed has
    /// landed, not against what it holds now: an identify made while an earlier one is still
    /// queued or on the wire merges on top of that one and never re-sends it.
    func identify(_ patch: [String: String], at: Date? = nil) {
        guard collecting, !retired else { return }
        let known = pendingTraits ?? traits
        var merged = known
        for (key, value) in patch {
            let k = Self.clamped(key, to: maxTraitKeyLength)
            guard !k.isEmpty else { continue }
            let v = Self.clamped(value, to: maxTraitValueLength)
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
        // The acknowledged snapshot is deliberately not touched here: it names what the server
        // has, and this call's event has not been sent yet, let alone accepted. It moves in
        // `noteDeliveredTraits` and nowhere else.
        guard merged != known else { return }
        track(signal: Signal.identify, metadata: merged, at: at)
    }

    /// Forgets every property attached to this install (sign-out) and sends `user.reset` if
    /// there was anything to forget. The install id itself is untouched.
    ///
    /// The stored snapshot is cleared here rather than when the `user.reset` lands, and this is
    /// the one place where clearing ahead of delivery is right. An empty snapshot suppresses
    /// nothing: every later `identify` sends its whole set whatever became of the reset, and each
    /// one replaces the stored set wholesale server-side. Holding the person's email and name on
    /// disk until the server acknowledged the sign-out would keep them exactly where the sign-out
    /// asked for them to be gone.
    func reset(at: Date? = nil) {
        guard collecting, !retired, !(pendingTraits ?? traits).isEmpty else { return }
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
        // Both are recorded before the guards, because what the app reports is a fact about the
        // app and not about this client: a repeated "active", or one made while the gate is
        // closed, still proves the app reports its lifecycle at all - which is all the
        // missing-lifecycle check is asking about - and still says where the app is, which is
        // what a client replacing this one has no other way to learn.
        sawLifecycleSignal = true
        reportedActive = active
        lifecycleCheckTask?.cancel()
        lifecycleCheckTask = nil
        guard collecting, !retired, active != isActive else { return }
        isActive = active
        let t = at ?? now()
        if active {
            // The gap is judged now, not at init: it can have crossed the timeout since. A
            // pre-minted id is never a resume candidate - nothing has opened its session yet.
            let resumes =
                sessionID != nil && !sessionUnadopted
                && Self.secondsSince(lastActiveAt, at: t) <= config.sessionTimeout
            if !resumes {
                if sessionUnadopted {
                    // Adopt the pre-minted id, exactly once: `install` and everything recorded
                    // before this foreground already carry it, and this `session.start` is the
                    // one that completes that session. Later sessions in this process mint
                    // their own ids below. The marker clears before the event is queued, so a
                    // death in between re-mints rather than re-adopting an id whose
                    // `session.start` is already in the persisted queue.
                    sessionUnadopted = false
                    UserDefaults.standard.removeObject(forKey: sessionUnadoptedKey)
                } else {
                    // Written before the event that carries it, as the pre-minted id is: a death
                    // in between would otherwise leave a `session.start` for an id nothing on
                    // disk names, and the next launch inside the timeout would resume the id
                    // before it and file the whole visit under a session it never opened.
                    let minted = UUID().uuidString.lowercased()
                    sessionID = minted
                    UserDefaults.standard.set(minted, forKey: sessionKey)
                }
                track(signal: Signal.sessionStart, metadata: nil, at: t)
            }
            rememberActive(t)
            startHeartbeat()
        } else {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            // The closing tick. If the server has heard nothing from this install for a while,
            // one last ping goes out with the flush that follows, so the session's length on
            // the dashboard ends where the visit actually ended rather than at the last thing
            // that happened to be sent. Free at a one-minute cadence (the stamp is never that
            // old); one extra ping per silent visit at the sparser cadences a plan may ask for.
            if Self.secondsSince(lastPresenceAt, at: t) > closingTickAfter {
                stampHeartbeat(t)
                track(signal: Signal.heartbeat, metadata: nil, at: t)
                log("· closing presence ping (quiet for over a minute)")
            }
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

    /// Trimmed, then cut to `max` UTF-16 code units: the unit the ingest counts in, so what the
    /// SDK remembers is what the server stored rather than something longer that the server then
    /// cut again. `String.prefix` counts characters, which for anything outside the basic plane -
    /// an emoji, a flag, most non-Latin scripts - is a different and larger number, and a
    /// snapshot that can never match what was stored is one a repeat `identify` can never
    /// correct. A cut that would split a surrogate pair drops the half rather than emitting a
    /// lone one, which is what the ingest does with it anyway.
    nonisolated private static func clamped(_ value: String, to max: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let units = trimmed.utf16
        guard units.count > max else { return trimmed }
        var kept = Array(units.prefix(max))
        if let last = kept.last, (0xD800...0xDBFF).contains(last) { kept.removeLast() }
        return String(decoding: kept, as: UTF16.self)
    }

    /// The set the newest `user.identify` or `user.reset` still owed - queued or on the wire -
    /// will leave the server with once it lands; nil when nothing is owed, in which case `traits`
    /// is the whole truth. A `user.reset` owes the empty set, which is not the same answer as nil.
    private var pendingTraits: [String: String]? {
        Self.outstandingTraits(in: inFlightBatch + queue)
    }

    /// What the server ends up holding once every identify and reset in `owed` has landed: the
    /// last one wins, exactly as it does server-side, where each `user.identify` replaces the
    /// stored set wholesale and `user.reset` deletes it.
    nonisolated private static func outstandingTraits(in owed: [Event]) -> [String: String]? {
        guard let last = owed.last(where: { $0.signal == Signal.identify || $0.signal == Signal.reset })
        else { return nil }
        return last.signal == Signal.reset ? [:] : (last.metadata ?? [:])
    }

    /// Commits the snapshot a batch the server accepted has just left it holding. The only place
    /// `traits` moves forward: what `identify` recorded is not what the server has until a batch
    /// carrying it comes back accepted, and every way that event can die - the queue cap trimming
    /// the oldest, a permanent 4xx dropping the slice, the file being replaced - then leaves the
    /// snapshot where it was, so the next `identify` sends again instead of matching a cache the
    /// server never received.
    ///
    /// `accepted` is the ingest's own count of the rows it took. A 2xx alone is not proof that
    /// they were stored: past the plan's grace ceiling, and under the per-install rate limiter,
    /// the answer is still 202 and the identify is discarded. A batch counted short of what was
    /// sent commits nothing. nil is "the answer said nothing about it" - the Supabase backend
    /// replies with no body at all - and is not a claim that anything was dropped.
    ///
    /// Nothing is committed while a NEWER identify or reset is still owed either: what the server
    /// holds now is already superseded, and re-persisting it would put properties a sign-out has
    /// just cleared back on disk. That one commits when its own batch lands.
    private func noteDeliveredTraits(_ batch: [Event], accepted: Int?) {
        if let accepted, accepted < batch.count { return }
        guard let delivered = Self.outstandingTraits(in: batch) else { return }
        guard pendingTraits == nil, delivered != traits else { return }
        traits = delivered
        persistTraits()
    }

    private func persistTraits() {
        if traits.isEmpty {
            UserDefaults.standard.removeObject(forKey: traitsKey)
        } else {
            UserDefaults.standard.set(traits, forKey: traitsKey)
        }
    }

    // MARK: - Heartbeat

    /// The presence cadence: a ping goes out only after this long with nothing else sent. The
    /// larger of what the app configured and what the server asked for.
    var heartbeatInterval: TimeInterval {
        max(config.heartbeatInterval, serverHeartbeatFloor ?? 0)
    }

    /// The last moment the server has (or will have, once the queue flushes) proof that this
    /// install was in front of someone: the later of the last ping and the last real event.
    private var lastPresenceAt: Date? {
        switch (lastHeartbeatAt, lastEventAt) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    /// One task per foreground stretch. It never sleeps blindly for an interval: it sleeps
    /// until the next ping is due, then looks again, because in the meantime a real event may
    /// have proved presence (pushing the due moment out) or the server may have asked for a
    /// sparser cadence. Only when the install has been silent for a whole interval does it
    /// tick. `notBefore` holds the first wait open for at least that long, which is what a ping
    /// replacing a dropped one is armed with.
    private func startHeartbeat(notBefore floor: TimeInterval = 0) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var minimumWait = floor
            while !Task.isCancelled {
                guard let self else { return }
                let wait = max(await self.timeUntilNextHeartbeat(), minimumWait)
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(wait))
                    minimumWait = 0  // it applied to the first wait, and that one has been served
                    continue
                }
                guard !Task.isCancelled else { return }
                // A tick that finds the app no longer active is a stale wake-up; the task that
                // owns the new stretch (if any) will do its own ticking.
                guard await self.heartbeat() else { return }
            }
        }
    }

    /// Seconds until the next ping is due: a full interval of silence after the last proof of
    /// presence. Zero means now - including the case where nothing has been sent yet, such as a
    /// resumed session that started before this process. Never more than one interval, whatever
    /// the stamps say: this number becomes a sleep the whole presence loop is paced by, and a
    /// wait that outlives the visit is the same thing as no presence at all.
    private func timeUntilNextHeartbeat() -> TimeInterval {
        let t = now()
        dropPresenceStampsAheadOf(t)
        let silence = Self.secondsSince(lastPresenceAt, at: t)
        return silence >= heartbeatInterval ? 0 : heartbeatInterval - silence
    }

    /// Forgets presence stamps that lie ahead of the clock. `restoredStamp` catches the ones an
    /// earlier process wrote; this catches the ones this process wrote before the clock was
    /// corrected backwards underneath it, which nothing at startup can see coming.
    ///
    /// It belongs here, where the cadence is decided, because this is the one place a stamp in
    /// the future is not merely unusable but self-sustaining: the silence it measures never
    /// grows, so a ping does not answer it and the loop would ask for another immediately, and
    /// again, for as long as the app stayed in front. Presence is counted additively on the
    /// server, so that flood would be permanent in the numbers. Dropping the stamp costs one
    /// ping that was not owed and leaves the next one paced from it.
    private func dropPresenceStampsAheadOf(_ t: Date) {
        if let beat = lastHeartbeatAt, beat.timeIntervalSince(t) > Self.clockSkewTolerance {
            lastHeartbeatAt = nil
            UserDefaults.standard.removeObject(forKey: lastHeartbeatKey)
        }
        // With it, or the roll-back a dropped ping performs would restore the same bad stamp.
        if let delivered = deliveredHeartbeatAt, delivered.timeIntervalSince(t) > Self.clockSkewTolerance {
            deliveredHeartbeatAt = nil
        }
        if let event = lastEventAt, event.timeIntervalSince(t) > Self.clockSkewTolerance {
            lastEventAt = nil
            UserDefaults.standard.removeObject(forKey: lastEventKey)
        }
    }

    /// Records a ping now. Returns false without ticking when the app is no longer active
    /// (`setActive(false)` cancels the heartbeat task on the actor; a tick that was already
    /// waiting for its turn must not land after it), or when this client is no longer the one
    /// collecting.
    ///
    /// `collecting` is tested here and not left to the `track` below, because the two stamps
    /// above it are written first and they are the install's, shared by every build in the
    /// container: a client the environment gate has closed would prove a presence the shipped
    /// build has not proved, and move the stamp that build's next launch judges its session by.
    @discardableResult
    private func heartbeat() -> Bool {
        guard collecting, isActive, !Task.isCancelled else { return false }
        let t = now()
        stampHeartbeat(t)
        rememberActive(t)
        track(signal: Signal.heartbeat, metadata: nil, at: t)
        return true
    }

    /// The ping stamp is a wall-clock promise (at most one ping per interval, across relaunches),
    /// so it is persisted the moment it moves.
    private func stampHeartbeat(_ t: Date) {
        lastHeartbeatAt = t
        UserDefaults.standard.set(t.timeIntervalSince1970, forKey: lastHeartbeatKey)
    }

    /// Remembers the newest ping in a batch the server accepted.
    private func noteDeliveredHeartbeats(_ batch: [Event]) {
        guard let newest = batch.filter({ $0.signal == Signal.heartbeat }).map(\.client_ts).max() else { return }
        if newest > (deliveredHeartbeatAt ?? .distantPast) { deliveredHeartbeatAt = newest }
    }

    /// Undoes the stamp of a ping `requeue` has just dropped, putting it back to the newest ping
    /// the server acknowledged.
    ///
    /// The stamp is written when a ping is *queued*, because it is what paces the timer and a
    /// ping still on the wire must not earn a second one. But a dropped ping is one the server
    /// may never have seen, and leaving its stamp in place spends a whole fresh interval before
    /// the install proves presence again. At 60 s that costs a minute of resolution on a chart
    /// that is approximate by design; at the four-minute cadence a free-plan account is asked
    /// for, two intervals back to back are longer than the dashboard's five-minute presence
    /// window, so an install that is in the foreground the whole time drops out of "active right
    /// now" for three of them. Re-arming from the last acknowledged ping instead measures the
    /// silence that is really outstanding, and the replacement never piles up: the next failure
    /// drops the ping this one queues, so at most one unacknowledged ping is ever in the queue.
    ///
    /// The trade is one tick against another. If the dropped ping did land after all - a reply
    /// lost on the way back - the replacement is a second tick inside one interval, exactly the
    /// size of error a dropped tick is when it did not land. The answered failures that can
    /// reach a presence-only batch (a 429, an edge 5xx, a connection dropped after connect) are
    /// overwhelmingly ones the ingest never applied, and presence is the number the product is
    /// read for, so proving it again is the right way round. `minHeartbeatRetry` keeps the two
    /// apart in the case where it was not.
    private func rollBackHeartbeatStamp(newestDropped: Date) {
        // Nothing is re-armed on a client that is no longer sending. A store answer that closed
        // the environment gate has already put the install's stamps back where this run found
        // them, and the loop this would restart writes them once an interval for the rest of the
        // visit on a client whose events go nowhere. `requeue` refuses for the same reason; the
        // permanent-4xx branch drops its slice instead of putting it back, so it arrives here
        // without passing through that guard.
        guard collecting, !retired else { return }
        guard let current = lastHeartbeatAt, current <= newestDropped else { return }
        lastHeartbeatAt = deliveredHeartbeatAt
        if let restored = deliveredHeartbeatAt {
            UserDefaults.standard.set(restored.timeIntervalSince1970, forKey: lastHeartbeatKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastHeartbeatKey)
        }
        if isActive { startHeartbeat(notBefore: minHeartbeatRetry) }
    }

    /// The server's answer to a batch may carry `heartbeat_interval` (seconds): the sparsest
    /// presence cadence the account's plan needs. It is a floor, never a ceiling - an app that
    /// configured a longer interval keeps it - and it is remembered across launches. Out-of-range
    /// values are ignored rather than obeyed: 15 s is the tightest cadence that has any meaning
    /// to the dashboard's 5-minute presence window, and past an hour a "presence" ping is not one.
    private func adoptHeartbeatFloor(_ seconds: TimeInterval?) {
        guard let seconds, Self.isSaneHeartbeatFloor(seconds) else { return }
        guard seconds != serverHeartbeatFloor else { return }
        serverHeartbeatFloor = seconds
        UserDefaults.standard.set(seconds, forKey: heartbeatFloorKey)
        log("· presence pings at most every \(Int(heartbeatInterval)) s (the server asked for \(Int(seconds)) s)")
    }

    nonisolated private static func isSaneHeartbeatFloor(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 15 && seconds <= 3600
    }

    /// How far ahead of the clock a stamp may be and still be read as "now": the finest presence
    /// resolution anything here has (`heartbeatInterval`'s floor, and `minHeartbeatRetry`). Below
    /// it a skew is the distance between two clock reads - the facade stamps a call, the actor
    /// applies it, a time server nudges the clock a fraction of a second - and changes nothing
    /// anybody sees. Above it, a stamp in the future is a clock that was wrong when it was written.
    private static let clockSkewTolerance: TimeInterval = 15

    /// A persisted stamp, or nil when the number on disk cannot be one: not a finite moment, not
    /// after 1970, or ahead of `t`. The presence stamps are this install's only record of when it
    /// was last heard from, and a device whose clock was hours ahead when they were written leaves
    /// every one of them in the future, where the silence they measure reads as negative and no
    /// ping is ever due again. They get the same treatment as the server's cadence floor for the
    /// same reason: a value that cannot be true is worth less than no value at all. Discarding one
    /// costs this launch a ping it did not owe and a session boundary it did not need; keeping one
    /// costs every ping until the clock catches up, on this launch and on all the ones after it.
    nonisolated private static func restoredStamp(_ value: Double?, at t: Date) -> Date? {
        guard let value, value.isFinite, value > 0,
            value <= t.timeIntervalSince1970 + clockSkewTolerance
        else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// How long ago `stamp` was, as of `t`, when that is a duration worth acting on:
    /// `.greatestFiniteMagnitude` when there is no stamp at all, and when the stamp is ahead of
    /// `t` by more than `clockSkewTolerance` - a clock corrected backwards under a stamp this
    /// process itself wrote, which no check at startup can see coming.
    ///
    /// Every question the SDK asks of a stamp - resume this session or start a new one, is a ping
    /// owed, does leaving deserve a closing tick - is safe when the answer is "a long time" and
    /// stuck when it is "not yet", so a gap that cannot be measured reads as unbounded.
    nonisolated private static func secondsSince(_ stamp: Date?, at t: Date) -> TimeInterval {
        guard let stamp else { return .greatestFiniteMagnitude }
        let elapsed = t.timeIntervalSince(stamp)
        guard elapsed.isFinite, elapsed >= -clockSkewTolerance else { return .greatestFiniteMagnitude }
        return max(0, elapsed)
    }

    // MARK: - Flushing

    /// Seconds as a `Task.sleep` duration. Every wait in this file goes through here because the
    /// bare `UInt64(seconds * 1_000_000_000)` conversion traps on a negative, infinite or NaN
    /// value, and `try?` does not catch a trap: a crash here is a crash inside the customer's
    /// shipped app. The inputs are bounded already (the configuration is clamped, a server's
    /// `Retry-After` is clamped), and this makes the conversion total whatever reaches it.
    nonisolated private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 3600) * 1_000_000_000)
    }

    /// The batch-size trigger's delivery, one outstanding at a time. See `flushRequested`.
    private func requestFlush() {
        guard !flushRequested else { return }
        flushRequested = true
        Task { await self.deliverRequestedBatch() }
    }

    private func deliverRequestedBatch() async {
        await flushAutomatically()
        flushRequested = false
    }

    private func scheduleFlush(after delay: TimeInterval? = nil) {
        guard flushTask == nil else { return }
        let interval = delay ?? config.flushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(interval))
            // An explicit flush cancels this timer; a cancelled timer must not flush anyway.
            guard !Task.isCancelled else { return }
            await self?.flushAutomatically()
        }
    }

    /// The automatic triggers land here: inside the failure backoff the timer is re-armed for
    /// the remainder instead of touching the network. `flush()` itself never checks the
    /// backoff, so an explicit call and the on-the-way-to-background flush always attempt.
    func flushAutomatically() async {
        // Joined before the backoff is read, not after. Whatever is delivering now sets the
        // backoff as it finishes, so an attempt decided in front of it is decided against an
        // answer that has not arrived: the timer fires while a request is out, sees no backoff,
        // waits out the request inside `flush`, and then goes straight at a server that has since
        // asked for room. `flush()` joins again, which is a no-op by then, and it still ignores
        // the backoff itself, because an explicit call is the developer's own decision.
        while let running = inFlight {
            await running.value
        }
        if let nextAttemptAt {
            let remaining = nextAttemptAt.timeIntervalSince(now())
            if remaining > 0 {
                flushTask?.cancel()
                flushTask = nil
                scheduleFlush(after: remaining)
                return
            }
        }
        await flush()
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
        // A delivery suspends the actor - for the store's label, and again for every request -
        // so a second flush can arrive in the middle of one. It joins the delivery in progress
        // instead of racing it: the task is claimed in the same actor step that found the slot
        // free, with no await in between, so a second flush always finds it taken. One delivery
        // at a time is what keeps `inFlightBatch` the record of the only slice on the wire; each
        // slice being claimed out of the queue before its await is what keeps anything from
        // being sent twice; and awaiting the task is what keeps a caller holding the process
        // open there until the send has landed.
        while let running = inFlight {
            await running.value
        }
        // Nothing to label, nothing to send: an empty flush (the one after `setActive(false)`
        // when the previous flush already drained the queue, or an app calling `flush()` on a
        // hunch) must not pay the wait in `deliver` for a label no event is waiting on.
        guard collecting, !queue.isEmpty, !retired else { return }
        let sending = Task { await self.deliver() }
        inFlight = sending
        await sending.value
    }

    /// One delivery: the brief wait for the store's label, then the drain. The wait belongs
    /// inside the task `inFlight` holds rather than in front of it, because it is a suspension
    /// like any other, and a flush suspended while the slot is still free is a flush the next
    /// one does not join.
    private func deliver() async {
        defer { inFlight = nil }
        await awaitEnvironmentAnswer()
        // The answer can close the sending gate, and `adoptEnvironment` then drops the queue.
        guard collecting, !queue.isEmpty, !retired else { return }
        await drain()
    }

    /// Asks the store where this build runs, if the question is still open, and waits briefly for
    /// the answer: the usual case is an answer in milliseconds and no batch leaves with the
    /// guessed label. Only the first flush waits - an offline or unanswerable launch sends with
    /// the guess after the grace, and a late answer restamps whatever is still queued.
    private func awaitEnvironmentAnswer() async {
        beginEnvironmentRefinement()
        guard refineTask != nil, !environmentGracePaid else { return }
        environmentGracePaid = true
        // The wait is on a continuation the ask releases, not on the ask's own task. Awaiting a
        // task's `value` is not a cancellation point, so a timer racing it inside a task group
        // bounds nothing: a group returns only once every child has finished, and the child
        // awaiting the ask finishes when the store does. `AppTransaction` has no timeout of its
        // own, and the launch where it is slowest - one with no network - is exactly the launch
        // whose batches must not be held behind it.
        let timer = Task { [weak self, grace = environmentAnswerGrace] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(grace))
            guard !Task.isCancelled else { return }
            await self?.releaseEnvironmentWaiters()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            environmentWaiters.append(continuation)
        }
        timer.cancel()
    }

    /// Lets every flush parked on the environment grace go on: called when the ask settles, when
    /// the grace runs out, and at shutdown. Whichever comes first releases them; the others find
    /// nothing waiting.
    private func releaseEnvironmentWaiters() {
        let parked = environmentWaiters
        environmentWaiters.removeAll()
        for continuation in parked { continuation.resume() }
    }

    /// Sends the queue in request-sized slices, oldest first, until what it set out to send has
    /// gone or the network says "later". Each slice is claimed out of the queue before the await,
    /// so events tracked meanwhile line up behind it.
    ///
    /// What it sets out to send is what was owed when the delivery began, and that bound is what
    /// keeps a burst from leaving as one request per event. The loop is fed by the same queue the
    /// app is writing to, so an app recording as fast as the network answers - a screenful of
    /// items, a replayed queue of user actions - has every iteration after the first find exactly
    /// the one event tracked during the last round trip, and send it on its own: a full set of
    /// request headers and a round trip each. Anything tracked after the delivery began goes with
    /// the next one instead, which the batch-size trigger or the timer armed below asks for.
    private func drain() async {
        var slice = maxEventsPerRequest
        var owed = queue.count
        while collecting, owed > 0, !queue.isEmpty, !retired {
            let batch = Array(queue.prefix(min(slice, owed)))
            queue.removeFirst(batch.count)
            inFlightBatch = batch
            persist()
            let count = "\(batch.count) event\(batch.count == 1 ? "" : "s")"
            log("↑ sending \(count)…")
            do {
                let accepted = try await send(batch)
                owed -= batch.count
                inFlightBatch = []
                persist()
                consecutiveFailures = 0
                nextAttemptAt = nil
                noteDeliveredHeartbeats(batch)
                // After the slice has left `inFlightBatch`, so "still owed" means what it says.
                noteDeliveredTraits(batch, accepted: accepted)
                log("✓ sent \(count)" + (environment == .simulator || environment == .debug ? " (scope: All)" : ""))
            } catch SendError.status(let status, _) where status == 413 && batch.count > 1 {
                // Too big for one request: put it back and go smaller for the rest of this drain.
                // The server rejected the body without processing any of it, so its heartbeats
                // were never counted and are safe to re-send.
                log("↩ 413 - the batch is too big for one request; retrying in smaller slices")
                inFlightBatch = []
                requeue(batch, keepingHeartbeats: true)
                slice = max(1, batch.count / 2)
            } catch SendError.status(let status, _) where Self.isPermanent(status) {
                // A 4xx no retry will fix - unknown key, malformed, one oversized event. Dropping
                // the slice beats a queue that can never drain again.
                log(
                    "✕ HTTP \(status) - \(status == 401 || status == 403 ? "check the write key (Setup tab in the dashboard); " : "")"
                        + "a retry could never succeed, so this batch is dropped")
                owed -= batch.count
                inFlightBatch = []
                persist()
                // The pings in it go too, and they were never counted: the ingest rejects a batch
                // like this before it reads a row. Leaving their stamp in place would spend a
                // whole fresh interval before the install proved presence again, which is the
                // silence `rollBackHeartbeatStamp` exists to prevent - this branch simply never
                // asked for it, because it drops the slice instead of putting it back.
                if let newestDropped = batch.filter({ $0.signal == Signal.heartbeat }).map(\.client_ts).max() {
                    rollBackHeartbeatStamp(newestDropped: newestDropped)
                }
            } catch {
                // Offline, 5xx, 429: keep everything, in order, for a later attempt.
                let why: String
                var retryAfter: TimeInterval?
                if case SendError.status(let status, let after) = error {
                    why = "HTTP \(status)"
                    // Whatever the status said it. A maintenance window or a load shed answers
                    // 503 and states how long to stay away, which is the case the header exists
                    // for; 429 is the narrower one where this install alone is being throttled.
                    // `obeyableRetryAfter` has already bounded the value, and `flush()` and the
                    // flush on the way to the background ignore the backoff, so a header cannot
                    // silence an install however it is set.
                    retryAfter = after
                } else {
                    why = error.localizedDescription
                }
                consecutiveFailures += 1
                let delay = backoffDelay(floor: retryAfter)
                nextAttemptAt = now().addingTimeInterval(delay)
                log("⟳ couldn't send (\(why)) - keeping \(count) for a try in \(Int(delay.rounded()))s or on flush()")
                inFlightBatch = []
                requeue(batch, keepingHeartbeats: !Self.mayHaveBeenApplied(error))
                // The retry is armed here rather than left to whatever the app does next. The
                // batch-size trigger asks for one delivery at a time, so everything recorded
                // behind this one has already been folded into it: an app that goes quiet after
                // a burst would otherwise sit on a full queue until something else happened to it.
                if !queue.isEmpty { scheduleFlush(after: delay) }
                return
            }
        }
        // Whatever was tracked while this delivery ran still needs a trigger of its own: the
        // batch-size one is reached only by the next `track`, and this queue may already be past
        // it. A timer is already armed here as often as not, and this is a no-op then.
        if !queue.isEmpty { scheduleFlush() }
    }

    /// Puts a batch back at the front of the queue, ahead of anything queued meanwhile.
    ///
    /// Heartbeats are kept only when the server definitely did not process the batch. Every
    /// other signal carries an event id and the server ignores a replay, so retrying it is free;
    /// heartbeats are folded into presence and session-length rollups on arrival, and a re-sent
    /// one is counted twice, permanently. A dropped tick costs a minute of resolution on a chart
    /// that is approximate by design; a doubled tick corrupts the numbers.
    private func requeue(_ batch: [Event], keepingHeartbeats: Bool) {
        // Nothing goes back into a queue that is no longer being sent. A store answer that closed
        // the environment gate while this batch was on the wire drops the batch with the rest:
        // `adoptEnvironment` has already settled what stays on disk, and putting the slice back
        // would stand events the gate closed on, pings included, in front of it. Retired is the
        // same story from `shutdown`.
        guard collecting, !retired else { return }
        let retryable = keepingHeartbeats ? batch : batch.filter { $0.signal != Signal.heartbeat }
        let dropped = batch.count - retryable.count
        if dropped > 0 {
            log(
                "· dropped \(dropped) presence ping\(dropped == 1 ? "" : "s") rather than risk counting \(dropped == 1 ? "it" : "them") twice"
            )
            // Dropped, so not proof of anything: the next ping is owed from the last one the
            // server acknowledged, not from these. See `rollBackHeartbeatStamp`.
            if let newestDropped = batch.filter({ $0.signal == Signal.heartbeat }).map(\.client_ts).max() {
                rollBackHeartbeatStamp(newestDropped: newestDropped)
            }
        }
        queue.insert(contentsOf: retryable, at: 0)
        trim()
        persist()
    }

    private func trim() {
        if queue.count > Self.maxQueuedEvents {
            queue.removeFirst(queue.count - Self.maxQueuedEvents)
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

    /// How long automatic delivery waits after the latest failure: exponential in the number of
    /// consecutive failures, with jitter so a fleet of installs does not retry in lockstep, capped
    /// at `maxBackoff` and at `sustainedOutageBackoff` once the streak passes `sustainedOutageAfter`
    /// - past that many attempts it is an outage rather than a blip, and the on-disk queue is the
    /// better answer than a tight retry. A server-stated Retry-After is the floor, never shortened.
    private func backoffDelay(floor retryAfter: TimeInterval?) -> TimeInterval {
        let ceiling = consecutiveFailures > sustainedOutageAfter ? sustainedOutageBackoff : maxBackoff
        let exponential = min(ceiling, pow(2, Double(consecutiveFailures)))
        return max(exponential * Double.random(in: 0.5...1), retryAfter ?? 0)
    }

    // MARK: - Networking

    /// Names the SDK and its version to the ingest, so an install still on an older release can
    /// be told from one that has updated.
    nonisolated static let userAgent = "AppGlance-Apple/\(AppGlance.version)"

    /// Refuses to follow a redirect on the batch POST.
    ///
    /// `URLSession` follows them by default and re-applies the original request's headers to the
    /// new one, so a `301` or a `302` would carry the write key - and whatever a `user.identify`
    /// is holding, an email and a name - to whatever host the answer names, and a `2xx` from that
    /// host would be read as the batch being delivered. The ingest does not redirect. The case
    /// where one can appear is an app pointing `endpoint` at its own deployment, and there the
    /// right answer is to fail and let the queue retry, not to follow a stranger. The Kotlin
    /// transport refuses them too, so the two SDKs answer this the same way.
    private final class RefusesRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    private let redirectPolicy = RefusesRedirects()

    private enum SendError: Error {
        /// The status, and the server's numeric Retry-After in seconds when it sent one. The
        /// HTTP-date form of the header is rare on rate limits and is ignored.
        case status(Int, retryAfter: TimeInterval?)
    }

    /// The longest wait the SDK will obey from a `Retry-After`. Past this it is not rate limiting
    /// any more, it is an outage, and the on-disk queue plus the flush on the way to the
    /// background are the better answer than a foreground stretch that never sends.
    private static let maxRetryAfter: TimeInterval = 900

    /// A server's `Retry-After` gets the same treatment as the presence cadence the server asks
    /// for: obeyed only as a finite, positive number of seconds, and clamped. `TimeInterval(_:
    /// String)` happily parses "inf" and "99999999999" - a header alone must not be able to stop
    /// an install sending for a day, and the value ends up in a sleep duration where an absurd
    /// one is a crash inside the host app.
    nonisolated private static func obeyableRetryAfter(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return min(seconds, maxRetryAfter)
    }

    /// The longest a batch POST may take, kept under the ceiling `ProcessHold` waits for. The
    /// flush on the way to the background and every explicit `flush()` run under that assertion,
    /// and `URLSession.shared`'s own default is more than twice as long: a request still
    /// outstanding when the assertion expires is one whose answer arrives at a suspended process,
    /// so the batch is counted as failed and the whole slice is re-uploaded on the next launch -
    /// exactly what the assertion is held to prevent. Failing inside the hold instead is a clean
    /// failure: the backoff is recorded and the queue is already on disk. Set on the request
    /// rather than through a session of the SDK's own, which would also cost the app's shared
    /// connection pool. The Kotlin transport is bounded at 15 s connect plus 15 s read.
    private static let requestTimeout: TimeInterval = 20

    /// Returns the ingest's `accepted` count when the answer carries one, nil when it does not.
    private func send(_ batch: [Event]) async throws -> Int? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try encoder.encode(batch)

        let (data, response) = try await session.data(for: request, delegate: redirectPolicy)
        guard let http = response as? HTTPURLResponse else { throw SendError.status(-1, retryAfter: nil) }
        guard (200..<300).contains(http.statusCode) else {
            let stated = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            throw SendError.status(http.statusCode, retryAfter: Self.obeyableRetryAfter(stated))
        }
        // The hosted ingest answers `{"accepted": n, ...}` and may add `heartbeat_interval`; the
        // Supabase backend answers nothing (return=minimal). Anything unparseable is simply not
        // a hint - the batch was accepted either way.
        adoptHeartbeatFloor(Self.heartbeatFloor(in: data))
        return Self.acceptedCount(in: data)
    }

    /// `accepted` from an ingest response body, if it carries one: how many of the rows sent the
    /// server actually took. A batch can be answered 2xx and still be counted short - past the
    /// plan's grace ceiling, or under the per-install rate limiter.
    nonisolated private static func acceptedCount(in data: Data) -> Int? {
        guard !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["accepted"]
        else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// `heartbeat_interval` from an ingest response body, if it carries one.
    nonisolated private static func heartbeatFloor(in data: Data) -> TimeInterval? {
        guard !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object["heartbeat_interval"]
        else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }

    // MARK: - Offline persistence

    /// What the queue file says, as the events it holds rather than as the bytes that hold them:
    /// `JSONEncoder` orders an object's keys differently from one call to the next, so two
    /// encodings of the same events agree on everything a reload can see and almost never agree
    /// byte for byte.
    ///
    /// A write of what the file already holds is skipped, because several of the calls into
    /// `persist()` cannot change what is owed at all. Claiming a slice with no presence ping in
    /// it moves events from `queue` into `inFlightBatch`, and the union of the two is what gets
    /// written, so the file would come out saying exactly what it already says; handing that
    /// same slice back after a transient failure moves them again, for the same answer. Each of
    /// those pays a full atomic rewrite, which costs about as much for four hundred bytes as for
    /// two hundred kilobytes, because what it buys is filesystem metadata rather than throughput.
    ///
    /// Only this client writes the file while it lives, so the record cannot go stale underneath
    /// it: init reads the file, `shutdown()` retires the client, and a replacement is built only
    /// after that. It is set by a write that reported success and dropped by one that threw.
    private var lastWrittenQueue: [Event]?
    /// The write itself, held as a function because the rule above - the record holds the bytes
    /// that landed, never the bytes that were offered - only means anything against a store that
    /// refuses one, and a real Caches directory cannot be made to refuse on demand.
    private var saveQueueFile: @Sendable (Data, URL) throws -> Void = Client.atomicWrite
    /// Through a temporary file the system renames into place, so a kill mid-write leaves the
    /// queue file as it was rather than half of a new one.
    private static let atomicWrite: @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
    /// Writes this client really made. Skipping a write and making the same one twice look alike
    /// from the file, so a test needs to be told which happened.
    private var queueFileWrites = 0

    /// What is still owed: the queue, plus the in-flight slice's non-heartbeat events. If the
    /// process is killed before the response arrives, the next launch re-sends those (the server
    /// ignores replays by event id) and never the heartbeats, which may already have been counted.
    private var owedEvents: [Event] {
        inFlightBatch.filter { $0.signal != Signal.heartbeat } + queue
    }

    /// Saves what is owed. Refused once retired, so a replaced client cannot clobber the file,
    /// and refused once the environment gate is closed: a client that is not collecting has
    /// nothing of its own to save, and the file it would write over belongs to another build.
    /// `adoptEnvironment` settles that file the moment the gate closes, and a send that was still
    /// on the wire then must not undo it on the way back.
    private func persist() {
        guard !retired, collecting else { return }
        writeQueueFile(owedEvents)
    }

    /// The only writer of the queue file.
    private func writeQueueFile(_ events: [Event]) {
        // Judged before the encode, which is the expensive half at a deep queue, and against a
        // file confirmed to still be there: Caches can be reclaimed at any moment, and a skip
        // measured against a file the system has taken away would leave the queue nowhere at
        // all. A `stat` is a microsecond or two against a write of the better part of a
        // millisecond.
        if events == lastWrittenQueue, FileManager.default.fileExists(atPath: storeURL.path) { return }
        guard let data = try? encoder.encode(events) else { return }
        do {
            try saveQueueFile(data, storeURL)
            lastWrittenQueue = events
            queueFileWrites += 1
        } catch {
            // The record is only ever set by a write that reported success, so it still describes
            // the file as far as anything here knows. It is dropped anyway: a write that failed
            // may have disturbed the destination on its way out, and the next write is the one
            // chance to put that right rather than skip it.
            lastWrittenQueue = nil
        }
    }

    nonisolated private static func loadPersisted(from url: URL) -> [Event] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let stored = (try? EventCoding.makeDecoder().decode([Event].self, from: data)) ?? []
        // Trimmed on the way in, not left to the next `track`. The file holds what is OWED, which
        // is the queue plus the non-ping half of the slice that was on the wire, so it can carry
        // `maxEventsPerRequest` more than the queue's own cap. Restoring it whole started the
        // launch over that cap and kept it there until something else was tracked, which is how a
        // documented 500-event ceiling became 600 on exactly the launch that follows a crash.
        // Oldest first, the same end the cap drops from everywhere else.
        return stored.count > maxQueuedEvents ? Array(stored.suffix(maxQueuedEvents)) : stored
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

    /// How many times this client has really written the queue file.
    func queueFileWritesForTesting() -> Int { queueFileWrites }

    /// Puts a store that refuses every write in place of the real one, or takes it away again:
    /// the full disk, or the container the system has made read-only. The refused bytes never
    /// reach `storeURL`, which keeps whatever it already held.
    func refuseQueueWritesForTesting(_ refusing: Bool) {
        if refusing {
            saveQueueFile = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        } else {
            saveQueueFile = Client.atomicWrite
        }
    }

    /// The queued events themselves, in order.
    func pendingEvents() -> [Event] { queue }

    /// The user properties as they stand: what an identify or reset still owed will leave the
    /// server with, or the acknowledged snapshot when nothing is owed.
    func currentTraits() -> [String: String] { pendingTraits ?? traits }

    /// The snapshot the server has acknowledged - what a repeat `identify` is measured against
    /// once the queue is empty.
    func deliveredTraits() -> [String: String] { traits }

    /// The current session id. Non-nil from init on: pre-minted whenever a fresh session is
    /// inevitable, restored when one can be resumed.
    func currentSessionID() -> String? { sessionID }

    /// Whether the current session id is a pre-minted one still waiting for its `session.start`.
    func currentSessionIsUnadopted() -> Bool { sessionUnadopted }

    /// Whether this client believes the app is in front of the user.
    func isActiveForTesting() -> Bool { isActive }

    /// Whether a presence loop is armed. A client that is no longer collecting must not have
    /// one: the stamps it writes are the install's, and every build sharing the container
    /// reads them.
    func presenceLoopIsArmedForTesting() -> Bool { heartbeatTask != nil }

    /// One tick of the presence loop, asked for directly. The guards `heartbeat` applies are
    /// defence in depth - every path that arms the loop is gated already, and every path that
    /// closes the gate cancels it - so this is the only way to ask whether the innermost one
    /// still holds.
    @discardableResult
    func heartbeatForTesting() -> Bool { heartbeat() }

    /// The presence cadence in force: the configured interval or the server's floor, whichever
    /// is larger.
    func heartbeatIntervalForTesting() -> TimeInterval { heartbeatInterval }

    /// How long the presence loop is about to wait. Bounded by one interval whatever the stamps
    /// say, which is the part a test can pin without waiting out a real sleep.
    func timeUntilNextHeartbeatForTesting() -> TimeInterval { timeUntilNextHeartbeat() }

    /// Whether the missing-lifecycle line has been printed for this client.
    func reportedMissingLifecycleForTesting() -> Bool { lifecycleCheckDone }

    /// Whether the app has reported a foreground transition to this client, which is what
    /// decides whether the missing-lifecycle line can still be printed.
    func sawLifecycleSignalForTesting() -> Bool { sawLifecycleSignal }

    /// How many times the store has been asked where this build runs, and whether an ask is open.
    func environmentAsksForTesting() -> Int { environmentAsks }
    func environmentAskIsOpenForTesting() -> Bool { refineTask != nil }

    /// The retry backoff as it stands: consecutive failures, and the earliest moment an
    /// automatic attempt may touch the network (nil when none is scheduled).
    func backoffForTesting() -> (failures: Int, nextAttemptAt: Date?) {
        (consecutiveFailures, nextAttemptAt)
    }

    /// Forgets the persisted session state, the owed `install` and the user properties for an app id.
    nonisolated static func resetSessionState(appID: String) {
        UserDefaults.standard.removeObject(forKey: "app.appglance.lastActive.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.heartbeatFloor.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.session.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.sessionUnadopted.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.lastHeartbeat.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.lastEvent.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.installPending.\(appID)")
        UserDefaults.standard.removeObject(forKey: "app.appglance.traits.\(appID)")
    }
}
