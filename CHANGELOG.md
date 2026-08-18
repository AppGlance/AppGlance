# Changelog

All notable changes to the AppGlance Swift SDK. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org). Every version tag also gets a
[GitHub Release](https://github.com/AppGlance/appglance-apple/releases) with the same notes.
The Kotlin SDK has [its own changelog](https://github.com/AppGlance/appglance-android/blob/main/CHANGELOG.md).

## [Unreleased]

## [1.2.0] - 2026-08-18

### Fixed

- The install id no longer follows a restore onto a second device. The Keychain item was always
  `…ThisDeviceOnly`, but the copy kept beside it, as insurance against a momentary Keychain
  failure, lived in `UserDefaults` - which an iCloud or encrypted backup and a device-to-device
  transfer both carry. On the new device the Keychain came up empty, the copy answered instead,
  and the old device's id was adopted and written back, so two handsets in use reported as one
  install. The copy now lives in a file in the app's Caches directory that is marked excluded
  from backup, the preferences key it used is cleared when an id is resolved, and the doc comment
  and the README say what actually happens.
- Configuration values are clamped instead of trusted. `heartbeatInterval: 0` (a plausible guess
  for "no presence pings", which is not a thing the SDK offers) turned the presence loop into a
  spin that pegged a core, rewrote the queue file continuously and POSTed a batch every few
  milliseconds; `flushInterval: .infinity` or a negative value crashed the app at the first
  tracked event, on the `UInt64` conversion inside `Task.sleep`. The designated initializer now
  clamps `flushInterval` to 1-3600, `heartbeatInterval` to 15-3600 (the bounds the SDK already
  applied to the cadence the server asks for), `sessionTimeout` to 1-86400 and `maxBatchSize` to
  1-500, falling back to the default for a value that is not finite, and `configure` applies the
  same bounds to a configuration whose properties were assigned afterwards. Every wait in the
  client goes through one total conversion, so no reachable value can trap.
- Turning collection off now discards what was already queued. `isEnabled: false` is how an app
  honours a consent withdrawal, but the events recorded before the switch was flipped stayed in
  the on-disk queue: an explicit `AppGlance.flush()` shipped them, and turning the switch back on
  resurrected them. A client that is not collecting drops the persisted queue and deletes the
  file at startup, and `flush()` and the sender are gated on the same switch.
- A server's `Retry-After` is bounded. The header was parsed with no range and no finiteness
  check, so `Retry-After: 86400` stopped an install sending for a day and `Retry-After: inf`
  crashed the host app on the next automatic flush. It is now obeyed only as a finite, positive
  number of seconds, capped at 15 minutes - the same distrust the SDK already showed the
  server's presence cadence.
- A relaunch inside the session timeout no longer pings the moment it comes up. The stamp for
  the last real event was kept in memory only, and a visit shorter than one interval leaves no
  ping stamp behind either, so a fresh process had no proof of presence of its own however
  recently the server had heard from that install. It is now persisted beside the ping stamp.
  Every jetsam-and-reopen inside a visit was costing one extra tick in rollups the server folds
  additively.
- A presence ping that is dropped rather than retried no longer spends a whole fresh interval.
  The stamp that paces the next ping is written when the ping is queued, so a batch answered
  with a `5xx` or a `429`, or one whose connection died after connecting, left the install
  silent for two intervals. At the four-minute cadence a free-plan account is asked for, that is
  longer than the dashboard's five-minute presence window, so an app in the foreground the whole
  time dropped out of "active right now" for about three minutes. The next ping is now measured
  from the last ping the server acknowledged.
- A client the environment gate has closed writes no session state. A developer's Xcode run over
  an installed App Store copy minted and persisted a session id that its own run could never
  use, renumbering state the store build owns. A corrected environment that closes the gate now
  also stops the presence and flush timers, which had nothing left to send; one that opens it
  mints the session id that client skipped at startup.

### Added

- `AppGlance.version`, sent as the `User-Agent` of every request (`AppGlance-Apple/1.2.0`), so
  an install still on an older release can be told from one that has updated.
- `configure` called from an app extension records nothing and says why. An extension is a
  separate process with its own container and its own Keychain access group, so it cannot see
  the app's install id: it would mint a second one, record a second `install`, and report one
  device as two users with a session each.
- A missing `.trackAppLifecycle()` is now diagnosable. Sessions, presence and the flush on the
  way to the background all hang off the lifecycle signal, and nothing in the SDK reports it on
  its own, so an app that configures the SDK and forgets the modifier sends `install` and its
  own events - which all look healthy, including in debug mode - while no session ever opens and
  every event carries one session id that never ends. If no foreground signal has arrived ten
  seconds after `configure`, the SDK prints one line naming `.trackAppLifecycle()` for SwiftUI
  and `AppGlance.setActive(_:)` for UIKit. Once, unconditionally, and only when the mistake is
  actually present.

### Changed

- The environment refinement stops asking. A build the store can never answer for - a Mac app
  downloaded from a website, an ad hoc or enterprise build, a device where StoreKit is
  restricted - re-asked on every flush for the life of the process and stalled each flush behind
  a three-second grace. The store is now asked at most five times (enough for a fresh install
  with nothing cached, or an offline first launch), only one flush waits out the grace, and a
  flush with an empty queue neither asks nor waits, since the label only matters for events
  about to leave.
- The README and the environment documentation describe the store-channel split as it behaves:
  the tag follows the store's signed `AppTransaction`, a launch starts from the receipt as a
  guess, and only a build the store cannot vouch for at all keeps that guess.

## [1.1.0] - 2026-08-17

### Changed

- The presence ping now measures silence, not time. A real event proves the app is in front of
  someone exactly as a ping does (the server moves the same "last seen" and session stamps for
  both), so a `heartbeat` is sent only after `heartbeatInterval` with nothing else sent: the
  tick that used to fire at the start of every session alongside `session.start` is gone, an
  install that keeps sending events never pings, and a quiet one pings once per interval of
  quiet. Nothing on the dashboard changes: "active right now" and session length read the same
  stamps as before. What changes is the bill behind the free presence promise, on the server's
  side: roughly half of all pings were the redundant first one.
- Leaving the foreground after more than a minute of silence sends one closing ping with the
  flush the SDK already does, so a session's length ends where the visit ended instead of at
  the last thing that happened to be sent. At the default cadence the stamp is never that old,
  so nothing extra is sent; it matters when the server asks for a sparser cadence (below).

### Added

- The server may ask for a sparser presence cadence for the account's plan by answering a batch
  with `heartbeat_interval` (seconds). The SDK obeys it as a floor (the effective interval is
  the larger of the configured `heartbeatInterval` and the server's value, so an app that
  configured a longer interval keeps it), remembers it across launches, and ignores values
  outside 15 s to 1 h. Servers that send nothing (including the Supabase backend) leave the
  configured interval in force, so this is fully additive on the wire.

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
