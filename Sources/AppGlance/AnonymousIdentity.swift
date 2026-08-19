import Foundation

/// The per-install anonymous identifier: a random UUID minted on first launch. Not the IDFA,
/// not derived from the device or the Apple ID, no personal data - so no tracking-consent
/// prompt applies. It is the "user" everywhere in AppGlance.
enum AnonymousIdentity {

    /// `isNew` is true exactly once per install - the launch that minted the id, which is when
    /// the SDK records `install`. It is claimed only for an id that reads back out of the store,
    /// because an id nothing kept belongs to this run and to no install.
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
            // A save that did not land is the same situation as a store that cannot be read, one
            // step later: the id is usable for this run, but it is not this install's id, because
            // the next launch will find nothing and mint another. Reporting it as new would
            // record an `install` per launch and a different user each time, which no dedupe on
            // the server can collapse - every one of them carries a fresh id. So the run uses the
            // id and claims nothing by it, exactly as the unreadable case does.
            guard case .found(let stored) = store.lookup(), stored == generated else {
                return (generated, false)
            }
            return (generated, true)
        }
    }
}
