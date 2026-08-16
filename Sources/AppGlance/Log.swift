import Foundation

/// The SDK's console output, prefixed so it can be filtered in Xcode. `print` rather than
/// `os_log` on purpose: these lines exist for a developer running from Xcode with `debug: true`,
/// and stdout is what reliably reaches that console. Nothing is printed in a normal App Store or
/// TestFlight launch.
enum Log {
    static func line(_ message: String) {
        print("[AppGlance] \(message)")
    }
}
