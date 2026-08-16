#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Wires app-lifecycle analytics to this view: `session.start` when the app comes to the
    /// front after more than `sessionTimeout` away, the presence heartbeat while it is in front,
    /// and a flush when it leaves. Attach it to your root view.
    func trackAppLifecycle() -> some View {
        modifier(AppGlanceLifecycleModifier())
    }

    /// Records `screen.<name>` every time this view appears - the cheapest way to get a funnel:
    /// `.trackScreen("paywall")` on the paywall, `.trackScreen("checkout")` on the next step.
    /// Names become part of the signal, so keep them short, stable, and free of personal data.
    func trackScreen(_ name: String, metadata: [String: String]? = nil) -> some View {
        onAppear { AppGlance.track("screen.\(name)", metadata: metadata) }
    }
}

/// Reports raw foreground/background transitions; the client decides what they mean. SwiftUI
/// reports "active" twice at launch (`onAppear`, then the first `scenePhase`) and leaving as
/// `.inactive` then `.background`; the client is idempotent about both, so nothing here needs to
/// remember state.
private struct AppGlanceLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .onAppear { AppGlance.setActive(true) }
            .onChange(of: scenePhase) { _, newPhase in AppGlance.setActive(newPhase == .active) }
        #else
        // The single-parameter form: the package supports iOS 16, where the two-parameter
        // `onChange` does not exist yet.
        content
            .onAppear { AppGlance.setActive(true) }
            .onChange(of: scenePhase) { newPhase in AppGlance.setActive(newPhase == .active) }
        #endif
    }
}
#endif
