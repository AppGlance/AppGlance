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

        /// Seconds to wait before sending a partial batch. Default 10.
        public var flushInterval: TimeInterval

        /// Send at once when this many events are queued. Default 20.
        public var maxBatchSize: Int

        /// Seconds between presence pings while the app is in the foreground. They power
        /// "active right now" and session length, and are never billable. Default 60.
        public var heartbeatInterval: TimeInterval

        /// How long the app can be away - backgrounded, or quit and relaunched - before coming
        /// back starts a new session (`session.start`). Default 300 (five minutes), the same gap
        /// the dashboard uses to split an install's events into sessions.
        public var sessionTimeout: TimeInterval

        /// Master switch. `false` records and sends nothing (e.g. behind a user setting). Default true.
        public var isEnabled: Bool

        /// Attach the device's region setting (e.g. `"US"`) to events - a locale, never GPS or IP,
        /// so it adds nothing to the app's privacy labels. `false` sends no country at all and the
        /// dashboard's map stays empty. Default true.
        public var collectsCountry: Bool

        /// Which environments actually send. Default `[.appStore, .testFlight]`: Simulator and
        /// Debug builds send nothing unless `debug` is on. TestFlight events are designed to be
        /// tagged `testflight` and kept out of the dashboard's Live numbers, but the split
        /// between the two store channels is best effort for now: on-device confirmation of the
        /// store's answer is pending, and TestFlight installs have been observed reporting
        /// `appstore`. See `AppEnvironment`.
        public var enabledEnvironments: Set<AppEnvironment>

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
            debug: Bool = false
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
                debug: debug
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
            debug: Bool = false
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
                debug: debug
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
            debug: Bool
        ) {
            self.backend = backend
            self.appID = appID
            self.appVersion =
                appVersion
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "unknown"
            self.flushInterval = flushInterval
            self.maxBatchSize = maxBatchSize
            self.heartbeatInterval = heartbeatInterval
            self.sessionTimeout = sessionTimeout
            self.isEnabled = isEnabled
            self.collectsCountry = collectsCountry
            self.enabledEnvironments = enabledEnvironments
            self.debug = debug
        }
    }
}
