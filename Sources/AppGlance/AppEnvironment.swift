import Foundation
import Security
import StoreKit

/// Where the app is running. Every event carries it, and it keeps development traffic out of
/// your numbers: by default only `.appStore` and `.testFlight` builds send (see
/// `AppGlance.Configuration.enabledEnvironments`), and the dashboard's Live scope shows App Store
/// only. Debug mode lets the current build send regardless; the tag stays truthful either way.
///
/// `.simulator` and `.debug` are compile-time facts. `.testFlight` versus `.appStore` comes from
/// the store's signed `AppTransaction`: `.sandbox` is TestFlight, `.production` the App Store.
/// The store answers asynchronously, so a launch starts from a guess and the first flush waits
/// briefly for the real answer; whatever is still queued is restamped when it arrives.
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

    /// True when the environment is a compile-time fact (Simulator, Debug) and the store has
    /// nothing to add.
    static var isCompileTimeDetermined: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The store's answer for where this build runs, or nil when it has none right now.
    ///
    /// The signed `AppTransaction` names the channel that delivered this build. The receipt
    /// cannot: under the iOS 18 SDK both channels get a URL ending in plain `receipt`, so the
    /// heuristic below reads a TestFlight install as App Store and stands only as the guess a
    /// launch starts from. A fresh install may have nothing cached to answer with and the fetch
    /// can fail (an offline first launch, an ad hoc or enterprise build). Callers treat nil as
    /// "ask again later", never as an answer, and `AppTransaction.refresh()` is not an option:
    /// it can put a sign-in prompt on screen, which an analytics SDK must never do.
    static func storeAnswer() async -> (answer: AppEnvironment?, failure: String?) {
        guard !isCompileTimeDetermined else { return (nil, nil) }
        do {
            let transaction = try await AppTransaction.shared.payloadValue
            return (refined(from: transaction.environment, fallback: current), nil)
        } catch {
            // The reason travels back for debug-mode narration: a diagnostic TestFlight build
            // with `debug: true` is the one place this failure can actually be watched.
            return (nil, String(describing: error))
        }
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
