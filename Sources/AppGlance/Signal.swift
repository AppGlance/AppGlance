import Foundation

/// The signal names the SDK reserves. Anything else passed to `AppGlance.track` is yours.
public enum Signal {
    /// Recorded exactly once per install, on the first launch that collects: the launch that
    /// minted the install id, or, if the environment gate or `isEnabled` was closed then, the
    /// first launch after it that sends.
    public static let install = "install"
    /// Recorded once per session: when the app comes to the foreground after more than
    /// `sessionTimeout` away - a cold launch, or a return from the background after the gap.
    /// Brief interruptions (a notification, a quick app switch) do not start a new one.
    public static let sessionStart = "session.start"
    /// The presence ping, sent after `heartbeatInterval` in the foreground with nothing else
    /// sent: a real event proves presence exactly as a ping does, so an app that keeps tracking
    /// events never pings. Powers "active right now" and session length; never billable, never
    /// shown as an event.
    public static let heartbeat = "heartbeat"
    /// Sent by `AppGlance.identify` / `setUserProperties` when the user's properties change; its
    /// metadata is the full merged set. Never billable.
    public static let identify = "user.identify"
    /// Sent by `AppGlance.reset()`: forget every property attached to this install. Never billable.
    public static let reset = "user.reset"
}

/// Property names the SDK reserves inside the user-properties dictionary. Anything else is a
/// custom property, shown as-is on the user's page in the dashboard.
public enum UserProperty {
    /// Your own identifier for the person (an account id, a customer number). Searchable in the
    /// dashboard; ties several installs to one account without changing the install id.
    public static let id = "$id"
    public static let email = "$email"
    public static let name = "$name"
}
