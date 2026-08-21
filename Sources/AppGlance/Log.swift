import Foundation

/// The SDK's console output, prefixed so it can be filtered in Xcode. `print` rather than
/// `os_log` on purpose: these lines exist for a developer running from Xcode with `debug: true`,
/// and stdout is what reliably reaches that console. Nothing is printed in a normal App Store or
/// TestFlight launch.
enum Log {
    /// A test's stand-in for the console. Set, a line goes here instead of stdout; the suite is
    /// the only assignment site, and assertions about wording read what it collected. Same shape
    /// as `refuseQueueWritesForTesting`: a seam, because stdout cannot be asserted against.
    nonisolated(unsafe) static var captureForTesting: ((String) -> Void)?

    static func line(_ message: String) {
        if let captureForTesting {
            captureForTesting(message)
        } else {
            print("[AppGlance] \(message)")
        }
    }
}
