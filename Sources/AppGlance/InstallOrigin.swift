import Foundation

/// What was already true about this app before AppGlance ever ran on it: when the app first
/// arrived, and which version arrived.
///
/// An app that adds the SDK years after launch has a user base the SDK has never seen. Every one
/// of those installs mints its id on the day that build ships, so every one of them reads as a new
/// user on that day and the real arrivals are buried among them. This is the evidence that tells
/// the two apart, and on Apple platforms it is free: the date rides the same `AppTransaction` the
/// SDK already fetches to label the environment.
///
/// The SDK sends the evidence and the server decides what counts as pre-existing. Apps pin SDK
/// versions and stay on them for months, so a threshold that lives in the SDK is a threshold
/// nobody can change.
struct InstallOrigin: Equatable, Sendable {

    /// Which question the date answers. The sources answer different ones, so the server is told
    /// which rather than left to guess from the platform.
    enum Evidence: String, Sendable {
        /// The App Store's own record of when this Apple ID first got the app. It survives
        /// deleting the app and follows the person to a new device, so it answers "new to the
        /// app, ever" rather than "new on this device".
        case store
        /// Passed by the app through `Configuration.firstInstalledAt`. Ranked above the store's
        /// answer because an app that keeps its own signup date knows things no platform API can
        /// see, including users who predate every device they now own.
        case app
    }

    let firstInstalledAt: Date
    let evidence: Evidence
    /// The version the app first arrived as, where the source knows it. Apple's is the build
    /// number (`CFBundleVersion`), not the marketing version shown on the App Store.
    let originalAppVersion: String?

    init(firstInstalledAt: Date, evidence: Evidence, originalAppVersion: String? = nil) {
        self.firstInstalledAt = firstInstalledAt
        self.evidence = evidence
        self.originalAppVersion = originalAppVersion
    }

    /// The metadata a carrier event travels with. `$`-prefixed, the same way every SDK-owned key
    /// in the user-properties dictionary is, so an app's own property can never collide with one.
    var metadata: [String: String] {
        var fields = [
            Key.installedAt: EventCoding.timestamp(firstInstalledAt),
            Key.evidence: evidence.rawValue,
        ]
        // An empty string is a value everywhere else in this SDK, so an absent version has to be
        // an absent key rather than one whose value is "".
        if let originalAppVersion, !originalAppVersion.isEmpty {
            fields[Key.originalVersion] = originalAppVersion
        }
        return fields
    }

    enum Key {
        static let installedAt = "$install_at"
        static let evidence = "$install_evidence"
        static let originalVersion = "$install_version"
    }

    /// A date the future cannot be trusted with. A device with its clock pushed forward, or a
    /// store answer read on a device whose date is wrong, would otherwise claim an install date
    /// after the moment it was read, which reads downstream as a user who arrived tomorrow.
    /// Rejected here rather than clamped: a nonsense date is not evidence, and no evidence is a
    /// state the server already knows how to handle.
    ///
    /// The floor is the one the server applies. An install date cannot predate the platform, and
    /// a signup date passed by the app that does is still evidence, so the floor is there only to
    /// catch a clock that was never set and reads as 1970.
    func isPlausible(now: Date) -> Bool {
        firstInstalledAt <= now.addingTimeInterval(60 * 60 * 24) && firstInstalledAt > Self.earliestPlausible
    }

    /// 2001-09-09, the same floor as the server's.
    private static let earliestPlausible = Date(timeIntervalSince1970: 1_000_000_000)
}
