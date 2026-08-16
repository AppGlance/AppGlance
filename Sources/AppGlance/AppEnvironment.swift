import Foundation
import Security
import StoreKit

/// Where the app is running. Every event carries it, and it keeps development traffic out of
/// your numbers: by default only `.appStore` and `.testFlight` builds send (see
/// `AppGlance.Configuration.enabledEnvironments`), and the dashboard's Live scope shows App Store
/// only. Debug mode lets the current build send regardless; the tag stays truthful either way.
public enum AppEnvironment: String, Sendable, CaseIterable {
    case appStore = "appstore"
    case testFlight = "testflight"
    case simulator = "simulator"
    case debug = "debug"

    /// Detected once per process. Precedence: Simulator, then Debug build, then TestFlight,
    /// then App Store.
    public static let current: AppEnvironment = {
        #if targetEnvironment(simulator)
        return .simulator
        #elseif DEBUG
        return .debug
        #else
        return isTestFlight ? .testFlight : .appStore
        #endif
    }()

    /// `current` corrected against the store's own record.
    ///
    /// The receipt heuristic below stopped telling TestFlight and the App Store apart when the
    /// legacy receipt retired with the iOS 18 SDK: both channels now get a URL ending in plain
    /// `receipt`, so a TestFlight install reads as App Store. The signed `AppTransaction` names
    /// the storefront that actually delivered this build. Simulator and Debug are compile-time
    /// facts and skip the lookup; a build the store cannot vouch for (ad hoc, enterprise, no
    /// transaction) keeps the heuristic's answer.
    static func refined() async -> AppEnvironment {
        #if targetEnvironment(simulator)
        return current
        #elseif DEBUG
        return current
        #else
        guard let transaction = try? await AppTransaction.shared.payloadValue else { return current }
        return refined(from: transaction.environment, fallback: current)
        #endif
    }

    /// `.xcode` means a store-signed build launched by the developer tools; `debug` is the
    /// truthful scope for it - a developer's machine must never appear in Live.
    static func refined(from store: AppStore.Environment, fallback: AppEnvironment) -> AppEnvironment {
        switch store {
        case .sandbox: return .testFlight
        case .production: return .appStore
        case .xcode: return .debug
        default: return fallback
        }
    }

    private static var isTestFlight: Bool {
        #if os(macOS)
        // On the Mac the receipt is named `receipt` whichever channel installed the app, so the
        // channel is read from the code signature instead: TestFlight builds are signed with a
        // certificate that carries Apple's beta-distribution marker extension.
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
            let code
        else { return false }
        var requirement: SecRequirement?
        let marker = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.25.1]" as CFString
        guard SecRequirementCreateWithString(marker, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        #else
        // A TestFlight install carries a sandbox receipt; an App Store install a production one.
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}

extension AppEnvironment {
    /// "a Debug build" - for the not-sending hint.
    var humanName: String {
        switch self {
        case .appStore: return "an App Store build"
        case .testFlight: return "a TestFlight build"
        case .simulator: return "a Simulator run"
        case .debug: return "a Debug build"
        }
    }

    /// ".debug" - the hint reads as the code the developer would write.
    var caseName: String {
        switch self {
        case .appStore: return ".appStore"
        case .testFlight: return ".testFlight"
        case .simulator: return ".simulator"
        case .debug: return ".debug"
        }
    }
}
