import Foundation

/// The AppGlance SDK. `import AppGlance`, then:
///
/// ```swift
/// // At launch:
/// AppGlance.configure(apiKey: "glance_live_…")
///
/// // While wiring it up - sends from Xcode and the Simulator too, and logs to the console:
/// AppGlance.configure(apiKey: "glance_live_…", debug: true)
///
/// // Anywhere:
/// AppGlance.track("paywall.viewed", metadata: ["source": "settings"])
///
/// // Optional - put a name on the install once someone signs in:
/// AppGlance.identify(id: account.id, email: account.email, name: account.name)
/// AppGlance.setUserProperties(["plan": "pro"])
/// AppGlance.reset()   // on sign-out
/// ```
///
/// In SwiftUI, attach `.trackAppLifecycle()` to your root view: it records `session.start` when
/// the app comes to the front after more than `sessionTimeout` away, keeps the presence heartbeat
/// running while it is in front, and flushes when it leaves. UIKit apps call `setActive(_:)`
/// from their scene or application delegate instead.
///
/// Every call here is cheap and non-blocking: it stamps the time, drops a command on an ordered
/// queue, and returns. Commands are applied strictly in call order, so `track("a"); track("b")`
/// and `setActive(false); setActive(true)` mean what they say. Calls made before `configure` -
/// or while the install id cannot be read yet, such as a background launch before the device's
/// first unlock - are held (up to 200) and replayed once the SDK is ready.
public enum AppGlance {

    /// The SDK version, sent as the `User-Agent` of every request.
    public static let version = "1.2.3"

    /// The whole hosted setup: one write key from the dashboard's Setup page. Call once, as
    /// early as possible - your `App` initializer, or `application(_:didFinishLaunching…)`.
    ///
    /// By default Simulator and Debug builds send nothing, so your numbers only ever contain
    /// real installs. While you are testing the integration, pass `debug: true`: this build
    /// sends too (events tagged `simulator` / `debug`, visible under **All** in the dashboard,
    /// never in Live) and the SDK logs what it does to the console. See `Configuration.debug`.
    public static func configure(apiKey: String, debug: Bool = false) {
        configure(Configuration(apiKey: apiKey, debug: debug))
    }

    /// Configure with full control: intervals, environments, a self-hosted endpoint, or your
    /// own Supabase project. Call once, as early as possible.
    public static func configure(_ configuration: Configuration) {
        guard !isAppExtension() else {
            Log.line(
                "not collecting in this process: AppGlance runs in the app, not in its extensions. An extension is"
                    + " a separate process with its own container and its own Keychain access group, so it cannot see"
                    + " the app's install id: it would mint a second one, record a second install, and report one"
                    + " device as two users. Configure from the app instead.")
            return
        }
        intake.yield(.configure(configuration, KeychainIdentityStore(), .shared, Date()))
    }

    /// Whether this process is an app extension (a widget, a share sheet, a notification service)
    /// rather than the app. Its bundle is the tell: extensions are `.appex` bundles and declare
    /// `NSExtension`.
    static func isAppExtension(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "appex" || bundle.infoDictionary?["NSExtension"] != nil
    }

    /// Records an event. `signal` is a short, stable, lowercase name (`paywall.viewed`);
    /// `metadata` is small string context (`["source": "settings"]`, at most 20 keys). Never put
    /// personal data in either - that is what `identify` is for.
    public static func track(_ signal: String, metadata: [String: String]? = nil) {
        intake.yield(.track(signal, metadata, Date()))
    }

    /// Records `screen.<name>` - the plain-Swift twin of the SwiftUI `.trackScreen(_:)`
    /// modifier, for `viewDidAppear` and friends. Screens are the cheapest funnel steps.
    public static func trackScreen(_ name: String, metadata: [String: String]? = nil) {
        track("screen.\(name)", metadata: metadata)
    }

    /// Attaches who this install belongs to. Everything is optional; pass what you have. The
    /// install id stays the analytics identity - these are labels on it, shown on the user's page
    /// in the dashboard, searchable, and merged with anything set before. Calling this with the
    /// same values on every launch is free: only a change is sent.
    ///
    /// Privacy: the moment you pass an email or a name, your App Store privacy answers change
    /// (Contact Info, linked to the user) - the dashboard's Setup page shows exactly how. Never
    /// pass anything the person did not give you.
    public static func identify(
        id: String? = nil, email: String? = nil, name: String? = nil,
        properties: [String: String]? = nil
    ) {
        var patch = properties ?? [:]
        if let id { patch[UserProperty.id] = id }
        if let email { patch[UserProperty.email] = email }
        if let name { patch[UserProperty.name] = name }
        guard !patch.isEmpty else { return }
        intake.yield(.identify(patch, Date()))
    }

    /// Sets or updates custom properties on the current user (`["plan": "pro"]`). Merged with
    /// existing ones; an empty string removes a key. Up to 20 keys of 40 characters, values up
    /// to 200. They show up as filterable pills in the dashboard's Users tab.
    public static func setUserProperties(_ properties: [String: String]) {
        guard !properties.isEmpty else { return }
        intake.yield(.identify(properties, Date()))
    }

    /// Forgets every property attached to this install - call it on sign-out. The install id
    /// (and its history) stays; only the labels go.
    public static func reset() {
        intake.yield(.reset(Date()))
    }

    /// Reports a foreground (`true`) / background (`false`) transition. The SwiftUI
    /// `.trackAppLifecycle()` modifier calls this for you. Safe to call redundantly: `true`
    /// after more than `sessionTimeout` of `false` starts a new session; anything else is a
    /// no-op or a resume of the current one.
    public static func setActive(_ active: Bool) {
        intake.yield(.setActive(active, Date()))
    }

    /// Sends any queued events now. The process is held open - from this call, before anything
    /// is queued - long enough for the send to land, so it is safe on the way to the background.
    public static func flush() {
        intake.yield(.flush(ProcessHold(reason: "AppGlance.flush")))
    }

    // MARK: - The command queue

    private enum Command {
        case configure(Configuration, IdentityStoring, URLSession, Date)
        case track(String, [String: String]?, Date)
        case identify([String: String], Date)
        case reset(Date)
        case setActive(Bool, Date)
        case flush(ProcessHold)
        case barrier(CheckedContinuation<Void, Never>)  // tests: everything before me has been applied
        case resetState  // tests: back to "never configured"
    }

    /// One stream, one consumer, strict FIFO. Created on first use - Swift runs a static
    /// initializer exactly once, thread-safely - and the pump lives for the process.
    private static let intake: AsyncStream<Command>.Continuation = {
        var continuation: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command>(bufferingPolicy: .unbounded) { continuation = $0 }
        Task.detached(priority: .utility) { await pump(stream) }
        return continuation
    }()

    private struct PendingConfiguration {
        let configuration: Configuration
        let store: IdentityStoring
        let session: URLSession
        let at: Date
    }

    // Owned by the pump task; touched from nowhere else.
    nonisolated(unsafe) private static var client: Client?
    /// `configure` ran but the install id could not be read yet; retried on the next command.
    nonisolated(unsafe) private static var pending: PendingConfiguration?
    /// Commands that arrived before the SDK could take them.
    nonisolated(unsafe) private static var waiting: [Command] = []
    private static let maxWaiting = 200
    /// Where the app is, according to the client a `configure` has just replaced, stamped with
    /// the moment that `configure` was called. It is handed to the replacement as its first
    /// command after `install`, because nothing else will: SwiftUI reports the front through
    /// `onAppear` and through scene-phase changes, and a configure mid-visit is neither, so the
    /// replacement would otherwise sit inactive for the rest of the visit. `setActive` is
    /// idempotent and judges resume-or-new-session from the persisted stamps, so the replacement
    /// rejoins the running session instead of opening a second one; a `false` wakes nothing up
    /// and carries only the fact that this app does report its lifecycle. nil when the app has
    /// reported nothing at all: no client is told where the app is on the strength of a guess,
    /// and a replacement that inherits no signal must still be free to say the modifier is missing.
    nonisolated(unsafe) private static var handover: (active: Bool, at: Date)?

    private static func pump(_ stream: AsyncStream<Command>) async {
        for await command in stream {
            switch command {
            case .configure(let configuration, let store, let session, let at):
                handover = nil
                if let outgoing = client {
                    if let active = await outgoing.reportedForegroundState() {
                        handover = (active: active, at: at)
                    }
                    await outgoing.shutdown()
                }
                client = nil
                pending = PendingConfiguration(configuration: configuration, store: store, session: session, at: at)
            case .barrier(let continuation):
                continuation.resume()
                continue
            case .resetState:
                await client?.shutdown()
                client = nil
                pending = nil
                handover = nil
                waiting.removeAll()
                continue
            default:
                break
            }

            guard let client = startPendingIfPossible() else {
                switch command {
                case .flush(let hold): hold.release()  // nothing to send yet
                case .configure: break
                default:
                    waiting.append(command)
                    if waiting.count > maxWaiting { waiting.removeFirst(waiting.count - maxWaiting) }
                }
                continue
            }
            await client.recordInstallIfNeeded()  // `install` goes first, always
            if let handedOver = handover {
                // Ahead of the replay and of the command that started this client: where the app
                // is was true before any of them were called.
                handover = nil
                await client.setActive(handedOver.active, at: handedOver.at)
            }
            if !waiting.isEmpty {
                let replay = waiting
                waiting.removeAll()
                for early in replay { await apply(early, to: client) }
            }
            await apply(command, to: client)
        }
    }

    /// Builds the client from the pending configuration if the install id can be read now.
    /// `isNew` is true exactly once per install, and the client stamps `install` with the moment
    /// `configure` was called.
    private static func startPendingIfPossible() -> Client? {
        if let client { return client }
        guard let pending, let identity = AnonymousIdentity.current(store: pending.store) else { return nil }
        self.pending = nil
        // `withinBounds()` again, not only in the initializer: `Configuration`'s properties are
        // `var`s, so an interval assigned after the struct was built would otherwise reach the
        // client - and its sleeps and its presence loop - unchecked.
        // `install` is stamped with the earliest moment this SDK holds for the install, which is
        // `configure` unless calls made before it are still waiting. The README promises `install`
        // is recorded first, and it is queued first, but a call an app makes from an initializer
        // that runs ahead of `configure` carries an earlier time: the platform's first-seen
        // rollup takes the smallest timestamp per install, so stamping `install` with `configure`
        // dates the install after an event that provably preceded it.
        let started = Client(
            config: pending.configuration.withinBounds(), userID: identity.id,
            isNewInstall: identity.isNew, installAt: min(pending.at, earliestWaiting() ?? pending.at),
            session: pending.session)
        client = started
        // TestFlight vs App Store is answered by the store asynchronously; the client's first
        // flush waits for it, so the answer lands before anything is sent. The lifecycle check
        // starts here too: it is the absence of a call that it watches for.
        Task {
            await started.beginEnvironmentRefinement()
            await started.armLifecycleCheck()
        }
        return started
    }

    /// The moment of the oldest call still waiting to be replayed, if any.
    private static func earliestWaiting() -> Date? {
        waiting.compactMap { command -> Date? in
            switch command {
            case .track(_, _, let at), .identify(_, let at), .reset(let at), .setActive(_, let at):
                return at
            case .configure(_, _, _, let at):
                return at
            case .flush, .barrier, .resetState:
                return nil
            }
        }.min()
    }

    /// Every case is a quick hop into the actor; nothing here awaits the network, so a slow
    /// send can never delay the next `track` or a `setActive(true)`.
    private static func apply(_ command: Command, to client: Client) async {
        switch command {
        case .track(let signal, let metadata, let at):
            await client.track(signal: signal, metadata: metadata, at: at)
        case .identify(let patch, let at):
            await client.identify(patch, at: at)
        case .reset(let at):
            await client.reset(at: at)
        case .setActive(let active, let at):
            await client.setActive(active, at: at)
        case .flush(let hold):
            Task {
                await client.flush(); hold.release()
            }
        case .configure, .barrier, .resetState:
            break
        }
    }

    // MARK: - Test hooks

    /// Configure against an injected identity store (no Keychain on the test host) and URLSession.
    static func configure(_ configuration: Configuration, identityStore store: IdentityStoring, session: URLSession) {
        intake.yield(.configure(configuration, store, session, Date()))
    }

    /// Resolves once every command issued before it has been applied.
    static func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            intake.yield(.barrier(continuation))
        }
    }

    /// The live client, if any, once every command issued so far has been applied.
    static func currentClientForTesting() async -> Client? {
        await drain()
        return client
    }

    /// Back to "never configured": drops the client, any pending configuration, and every
    /// buffered command. Tests share one process.
    static func resetForTesting() async {
        intake.yield(.resetState)
        await drain()
    }
}
