import Foundation

/// The per-install anonymous identifier: a random UUID minted on first launch. Not the IDFA,
/// not derived from the device or the Apple ID, no personal data - so no tracking-consent
/// prompt applies. It is the "user" everywhere in AppGlance.
enum AnonymousIdentity {

    /// `isNew` is true exactly once per install - the launch that minted the id, which is when
    /// the SDK records `install`.
    ///
    /// Returns `nil` when the store cannot be read right now (the Keychain before the device's
    /// first unlock after a reboot, which is exactly when a background launch can happen).
    /// Minting then would invent a second user and a phantom `install`; the caller retries later.
    static func current(store: IdentityStoring) -> (id: String, isNew: Bool)? {
        switch store.lookup() {
        case .found(let existing):
            return (existing, false)
        case .unavailable:
            return nil
        case .absent:
            let generated = UUID().uuidString
            store.save(generated)
            return (generated, true)
        }
    }
}
