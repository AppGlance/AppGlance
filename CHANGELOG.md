# Changelog

All notable changes to the AppGlance Swift SDK. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org). Every version tag also gets a
[GitHub Release](https://github.com/AppGlance/appglance-apple/releases) with the same notes.
The Kotlin SDK has [its own changelog](https://github.com/AppGlance/appglance-android/blob/main/CHANGELOG.md).

## [Unreleased]

### Fixed

- TestFlight builds are labelled `testflight` again. The legacy receipt heuristic stopped
  distinguishing TestFlight from the App Store for apps built with the iOS 18 SDK or later
  (both channels get a receipt URL ending in plain `receipt`), so TestFlight events landed in
  the App Store scope. The environment is now read from the store's signed `AppTransaction`,
  with the receipt heuristic kept as the fallback for builds the store cannot vouch for. The
  answer arrives asynchronously; the first flush waits for it and restamps anything queued, so
  no event leaves with the wrong label. A store-signed build launched from the developer tools
  (`AppTransaction.environment == .xcode`) now labels itself `debug` rather than `appstore`.

## [1.0.0] - 2026-08-16

First public release.

### Added

- `AppGlance.configure(apiKey:)` for the hosted service; `AppGlance.configure(_:)` with an
  `AppGlance.Configuration` for full control, including your own Supabase project.
- `.trackAppLifecycle()` for SwiftUI; `AppGlance.setActive(_:)` for UIKit; `.trackScreen(_:)`
  and `AppGlance.trackScreen(_:)` for funnels.
- A random install id kept in the Keychain, so delete-and-reinstall counts as one user. Never
  the IDFA, never an IP-derived location, never a device fingerprint.
- Sessions with a `session_id` on every event and a configurable `sessionTimeout` (default five
  minutes, matching how the dashboard splits sessions); a foreground presence heartbeat; the
  device's region setting as the country (`collectsCountry`); and anything you `track`.
- Optional user properties: `identify(id:email:name:properties:)`, `setUserProperties(_:)`,
  `reset()`. Sent as `user.identify` only when they change; keys and values clamped to the
  server's limits (20 keys, 40 / 200 characters).
- Environments: every event is tagged `appstore`, `testflight`, `simulator` or `debug`.
  `enabledEnvironments` defaults to `[.appStore, .testFlight]`, so Simulator and Debug builds
  stay out of your numbers; TestFlight is detected at runtime on every platform, including macOS.
- Debug mode (`debug: true`): the current build sends whatever its environment (the tag stays
  truthful, so those events appear under *All* in the dashboard and never in Live) and logs to
  the console. Without it, a gated build prints one line explaining why nothing is sent.
- Delivery: events are persisted as they are tracked, sent oldest-first in slices of 100 through
  one serial sender, and retried after transient failures. Every event carries a client-minted
  `event_id`; both the hosted ingest and the Supabase backend ignore replays, so a batch whose
  acknowledgement was lost is stored once. Presence pings, which the server folds into rollups
  on arrival, are re-sent only when it provably never saw them - including after a process killed
  mid-request, since the on-disk queue never holds an in-flight ping.
- Calls apply strictly in call order through one internal queue, timestamps taken at call time.
  Calls made before `configure`, or before the Keychain is readable after a reboot, are held
  (up to 200) and replayed; `install` is always the first event.
- A flush on the way to the background runs under a process assertion. Permanent `4xx`
  responses drop the slice instead of retrying forever; `413` halves it.
- Supabase mode requires the AppGlance events schema; its unique index over `(app_id, event_id)`
  is what makes a retried batch idempotent.
- iOS 16+, macOS 13+, tvOS 16+, watchOS 9+, visionOS 1+. Swift 5.10. No dependencies. Compiles
  cleanly under strict concurrency checking and in Swift 6 language mode.
