import Foundation

extension AppGlance {

    /// Everything `AppGlance.configure` needs. Two ways to run:
    ///
    /// **Hosted** - one write key from the dashboard's Setup page:
    /// ```swift
    /// AppGlance.configure(apiKey: "glance_live_…")
    /// ```
    ///
    /// **Your own Supabase project** - events go straight from the device to a database you
    /// control, one that runs the AppGlance events schema:
    /// ```swift
    /// AppGlance.configure(.init(
    ///     supabaseURL: URL(string: "https://YOUR-REF.supabase.co")!,
    ///     publishableKey: "sb_publishable_…",
    ///     appID: "com.example.app"
    /// ))
    /// ```
    public struct Configuration: Sendable {

        /// Where events are sent. Chosen by the initializer.
        enum Backend: Sendable {
            /// The AppGlance ingest API, authenticated by the app's write key.
            case hosted(endpoint: URL, apiKey: String)
            /// A Supabase project's PostgREST endpoint, authenticated by its publishable key.
            case supabase(url: URL, publishableKey: String)
        }

        /// The hosted ingest endpoint. Pass another `endpoint` to `init(apiKey:…)` to use a
        /// self-hosted deployment of the ingest service.
        public static let defaultEndpoint = URL(string: "https://api.appglance.app/v1/events")!

        let backend: Backend

        /// A stable identifier for the app, e.g. `"com.example.app"`. In hosted mode the server
        /// derives the app from the key, so this is informational; in Supabase mode it separates
        /// apps that share one database. Defaults to the bundle identifier in hosted mode.
        public var appID: String

        /// Marketing version of the app. Defaults to `CFBundleShortVersionString`.
        public var appVersion: String

        /// Seconds to wait before sending a partial batch. Default 10, clamped to 1...3600.
        public var flushInterval: TimeInterval

        /// Send at once when this many events are queued. Default 20, clamped to 1...500 (the
        /// largest batch the ingest API accepts).
        public var maxBatchSize: Int

        /// How long the app can be in the foreground with nothing sent before a presence ping
        /// goes out. Pings power "active right now" and session length and are never billable;
        /// a real event proves presence just as well, so a ping is only sent after this many
        /// seconds of silence. Default 60, clamped to 15...3600: there is no "off" here, and a
        /// tighter cadence than 15 s means nothing to the dashboard's five-minute presence
        /// window. The server may ask for a sparser cadence for the account's plan; the SDK then
        /// uses the larger of the two, so this is a floor you can raise, not lower. One extra
        /// ping goes out when the app leaves the foreground after more than a minute of silence,
        /// so a session's length is exact whatever the cadence.
        public var heartbeatInterval: TimeInterval

        /// How long the app can be away - backgrounded, or quit and relaunched - before coming
        /// back starts a new session (`session.start`). Default 300 (five minutes), the same gap
        /// the dashboard uses to split an install's events into sessions. Clamped to 1...86400.
        public var sessionTimeout: TimeInterval

        /// Master switch. `false` records and sends nothing (e.g. behind a user setting). Default
        /// true. Turning it off also discards whatever an earlier run left queued on disk and the
        /// user properties `identify` stored, so a consent withdrawal takes effect for what was
        /// already recorded and not only for what comes next. The install id itself stays, so
        /// turning it back on is the same install rather than a new one.
        public var isEnabled: Bool

        /// Attach the device's region setting (e.g. `"US"`) to events - a locale, never GPS or IP,
        /// so it adds nothing to the app's privacy labels. `false` sends no country at all and the
        /// dashboard's map stays empty. Default true.
        public var collectsCountry: Bool

        /// Which environments actually send. Default `[.appStore, .testFlight]`: Simulator and
        /// Debug builds send nothing unless `debug` is on. TestFlight events are tagged
        /// `testflight` and kept out of the dashboard's Live numbers, which show App Store only.
        /// See `AppEnvironment` for where that split comes from.
        public var enabledEnvironments: Set<AppEnvironment>

        /// When this person first got your app, if you already know. Optional, and only worth
        /// setting if you are adding AppGlance to an app that already has users.
        ///
        /// Without it, every existing user mints an install id on the day your first AppGlance
        /// build ships, so all of them read as new users that day and your real arrivals are lost
        /// among them. On Apple platforms the SDK asks the App Store for the answer by itself and
        /// usually gets it, so setting this is a refinement rather than a requirement. Set it when
        /// your app knows better than the store does, which it does whenever you keep your own
        /// signup or first-launch date:
        ///
        /// ```swift
        /// var config = AppGlance.Configuration(apiKey: "glance_live_…")
        /// config.firstInstalledAt = myAccount.createdAt
        /// AppGlance.configure(config)
        /// ```
        ///
        /// It is a date, never a name or an id, it is sent once per install, and it changes
        /// nothing about the events themselves: the dashboard uses it to sort a first sighting
        /// into "new" or "was already here" and for nothing else. A date in the future, or one
        /// before the App Store existed, is ignored.
        public var firstInstalledAt: Date?

        /// Debug mode, for while you wire the SDK up. Default false. When on:
        ///
        /// - **This build sends**, whatever its environment. Events keep their real tag
        ///   (`simulator` / `debug`), so they appear under **All** in the dashboard and never in Live.
        /// - **The SDK logs** to the console (`[AppGlance] …`): environment and install id at
        ///   configure, each event as it is queued, each send and the server's answer.
        ///
        /// `isEnabled = false` still wins. Gate it on `#if DEBUG`, or turn it off before shipping.
        public var debug: Bool

        /// Hosted mode. `apiKey` is the app's write key from the dashboard's Setup page.
        public init(
            apiKey: String,
            appID: String? = nil,
            endpoint: URL = Configuration.defaultEndpoint,
            appVersion: String? = nil,
            flushInterval: TimeInterval = 10,
            maxBatchSize: Int = 20,
            heartbeatInterval: TimeInterval = 60,
            sessionTimeout: TimeInterval = 300,
            isEnabled: Bool = true,
            collectsCountry: Bool = true,
            enabledEnvironments: Set<AppEnvironment> = [.appStore, .testFlight],
            debug: Bool = false,
            firstInstalledAt: Date? = nil
        ) {
            self.init(
                backend: .hosted(endpoint: endpoint, apiKey: apiKey),
                appID: appID ?? Bundle.main.bundleIdentifier ?? "unknown",
                appVersion: appVersion,
                flushInterval: flushInterval,
                maxBatchSize: maxBatchSize,
                heartbeatInterval: heartbeatInterval,
                sessionTimeout: sessionTimeout,
                isEnabled: isEnabled,
                collectsCountry: collectsCountry,
                enabledEnvironments: enabledEnvironments,
                debug: debug,
                firstInstalledAt: firstInstalledAt
            )
        }

        /// Your own Supabase project. `publishableKey` is the publishable (anon) key - safe to
        /// embed in an app; never the service-role key.
        public init(
            supabaseURL: URL,
            publishableKey: String,
            appID: String,
            appVersion: String? = nil,
            flushInterval: TimeInterval = 10,
            maxBatchSize: Int = 20,
            heartbeatInterval: TimeInterval = 60,
            sessionTimeout: TimeInterval = 300,
            isEnabled: Bool = true,
            collectsCountry: Bool = true,
            enabledEnvironments: Set<AppEnvironment> = [.appStore, .testFlight],
            debug: Bool = false,
            firstInstalledAt: Date? = nil
        ) {
            self.init(
                backend: .supabase(url: supabaseURL, publishableKey: publishableKey),
                appID: appID,
                appVersion: appVersion,
                flushInterval: flushInterval,
                maxBatchSize: maxBatchSize,
                heartbeatInterval: heartbeatInterval,
                sessionTimeout: sessionTimeout,
                isEnabled: isEnabled,
                collectsCountry: collectsCountry,
                enabledEnvironments: enabledEnvironments,
                debug: debug,
                firstInstalledAt: firstInstalledAt
            )
        }

        /// Supabase mode with the project URL as a string. Returns `nil` unless it is a
        /// well-formed `http(s)` URL with a host - a bare `"my-ref.supabase.co"` is rejected.
        public init?(
            supabaseURLString: String,
            publishableKey: String,
            appID: String,
            appVersion: String? = nil
        ) {
            guard let url = URL(string: supabaseURLString),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                url.host?.isEmpty == false
            else { return nil }
            self.init(supabaseURL: url, publishableKey: publishableKey, appID: appID, appVersion: appVersion)
        }

        private init(
            backend: Backend,
            appID: String,
            appVersion: String?,
            flushInterval: TimeInterval,
            maxBatchSize: Int,
            heartbeatInterval: TimeInterval,
            sessionTimeout: TimeInterval,
            isEnabled: Bool,
            collectsCountry: Bool,
            enabledEnvironments: Set<AppEnvironment>,
            debug: Bool,
            firstInstalledAt: Date? = nil
        ) {
            self.backend = backend
            self.appID = appID
            self.appVersion =
                appVersion
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "unknown"
            self.flushInterval = Self.clamped(flushInterval, to: Self.flushIntervalBounds, fallback: 10)
            self.maxBatchSize = min(
                max(maxBatchSize, Self.maxBatchSizeBounds.lowerBound), Self.maxBatchSizeBounds.upperBound)
            self.heartbeatInterval = Self.clamped(
                heartbeatInterval, to: Self.heartbeatIntervalBounds, fallback: 60)
            self.sessionTimeout = Self.clamped(sessionTimeout, to: Self.sessionTimeoutBounds, fallback: 300)
            self.isEnabled = isEnabled
            self.collectsCountry = collectsCountry
            self.enabledEnvironments = enabledEnvironments
            self.debug = debug
            self.firstInstalledAt = firstInstalledAt
        }

        // MARK: - Bounds

        // Every number below reaches arithmetic where an out-of-range value is a crash or a spin
        // inside somebody else's shipped app, which cannot be hot-fixed: `flushInterval` and the
        // retry delay become `Task.sleep` durations, whose `UInt64` conversion traps on a
        // negative, infinite or NaN value; `heartbeatInterval` paces the presence loop, which
        // sleeps only while the next ping is still in the future, so zero or less makes it tick
        // (and re-encode the queue file, and POST) as fast as the CPU allows; `maxBatchSize`
        // decides when a batch is full, so zero or less makes every single event its own request.
        // Out-of-range values are clamped and a non-finite one falls back to the default rather
        // than trapping or being rejected: an app that ships a bad number keeps working, with a
        // cadence it can live with. The presence bounds are the same 15...3600 the SDK already
        // applies to the cadence the *server* asks for; the Kotlin SDK validates the same fields.
        private static let flushIntervalBounds: ClosedRange<TimeInterval> = 1...3600
        private static let heartbeatIntervalBounds: ClosedRange<TimeInterval> = 15...3600
        private static let sessionTimeoutBounds: ClosedRange<TimeInterval> = 1...86_400
        private static let maxBatchSizeBounds: ClosedRange<Int> = 1...500

        /// The bounds applied to a whole configuration: the designated initializer run again over
        /// the values the struct currently holds. `configure` calls this because the properties
        /// are `var`s, so a value assigned after the initializer ran would otherwise reach the
        /// same arithmetic unchecked.
        func withinBounds() -> Configuration {
            Configuration(
                backend: backend, appID: appID, appVersion: appVersion, flushInterval: flushInterval,
                maxBatchSize: maxBatchSize, heartbeatInterval: heartbeatInterval, sessionTimeout: sessionTimeout,
                isEnabled: isEnabled, collectsCountry: collectsCountry,
                enabledEnvironments: enabledEnvironments, debug: debug,
                firstInstalledAt: firstInstalledAt)
        }

        private static func clamped(
            _ value: TimeInterval, to bounds: ClosedRange<TimeInterval>, fallback: TimeInterval
        ) -> TimeInterval {
            guard value.isFinite else { return fallback }
            return min(max(value, bounds.lowerBound), bounds.upperBound)
        }
    }
}
