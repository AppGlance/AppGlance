# Changelog

All notable changes to the AppGlance Swift SDK. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org). Every version tag also gets a
[GitHub Release](https://github.com/AppGlance/appglance-apple/releases) with the same notes.
The Kotlin SDK has [its own changelog](https://github.com/AppGlance/appglance-android/blob/main/CHANGELOG.md).

## [1.0.2] - 2026-08-17

### Fixed

- First launches no longer count as two sessions. The session id used to be minted only at the
  first foreground, after `install` had already been recorded with no session id, and a
  session-id-less event opens its own session server-side, so every first launch produced one
  session holding `install` and another holding `session.start`. The id is now minted at
  client startup whenever a fresh session is inevitable (a first launch, or a relaunch after
  `sessionTimeout`), so `install` and every event recorded before the first foreground carry
  the same session id that `session.start` then adopts, and the server folds them into one
  session. The pre-minted id is persisted as unadopted: if the process dies before its first
  foreground, the next launch reuses it, so the session `install` opened still receives its
  `session.start`. Resumed sessions behave exactly as before.
- The environment correction now retries. A fresh install's very first ask can find no cached
  `AppTransaction` (and the fetch can fail on an offline first launch), and 1.0.1 asked
  exactly once per process, so such installs kept the `appstore` guess for the whole run. The
  store is re-asked at every flush until it answers, and a flush waits at most three seconds
  for it, so a slow or offline first launch cannot delay sending; a late answer corrects the
  label for everything still queued and everything that follows.
- The heartbeat's timing now survives a relaunch. The last-heartbeat stamp was memory only, so
  quitting and relaunching inside the session timeout beat again immediately and slightly
  inflated the additive presence and session-length rollups. The stamp is persisted alongside
  the last-active stamp and honored at startup, so a relaunch beats only once the heartbeat
  interval has genuinely passed.
- A test seeded with a label equal to the iOS Simulator host's own environment guess no longer
  fails there, and a formatting violation is fixed, so the whole CI matrix is green again.

### Added

- Failed sends now back off. After a retryable failure (offline, `429`, `5xx`), automatic
  delivery waits exponentially longer between attempts, with jitter, capped at 60 seconds and
  reset by any successful send, and a numeric `Retry-After` on a `429` is honored as the floor
  for that wait. An explicit `AppGlance.flush()` still attempts immediately.

### Changed

- Publishing a release is now gated on CI: the release workflow runs the full lint, build and
  test matrix first and publishes only when everything passes.
- The README and the doc comments describe the TestFlight versus App Store split as currently
  known to behave: the mapping from the store's signed `AppTransaction` is in place and
  covered by tests, but on-device confirmation from a real TestFlight install is still
  pending, and TestFlight installs have been observed reporting `appstore` in the field.

## [1.0.1] - 2026-08-16

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
