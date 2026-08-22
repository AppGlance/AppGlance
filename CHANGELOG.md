# Changelog

All notable changes to the AppGlance Swift SDK. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org). Every version tag also gets a
[GitHub Release](https://github.com/AppGlance/appglance-apple/releases) with the same notes.
The Kotlin SDK has [its own changelog](https://github.com/AppGlance/appglance-android/blob/main/CHANGELOG.md).

## [Unreleased]

### Added

- **Existing users are no longer counted as new.** An app that adds AppGlance years after launch
  has a user base the SDK has never seen, and every one of those installs used to read as a brand
  new user on the day that build shipped: one enormous spike, with the real arrivals buried in it.
  The SDK now reports when the app first arrived, so the dashboard can tell the two apart.

  On Apple platforms the answer is already in hand and costs nothing: the signed `AppTransaction`
  the SDK fetches to label the environment also carries `originalPurchaseDate`, the date this
  Apple ID first got the app. No new API, no permission, no privacy-manifest entry, nothing added
  to your App Store answers - it is a date about the app, not about the person, and it is sent
  once per install. TestFlight builds send no store date: the sandbox answers every account with
  the same placeholder, which is not evidence of anything.

  Nothing to do to get it. Upgrading is enough: an install that has never sent one backfills on
  its next `session.start`, so an app already running an older AppGlance corrects its whole base
  as people open it.

- `Configuration.firstInstalledAt`, for when your app knows better than the App Store does. The
  store's date is per Apple ID, so it cannot see a user who had an account with you before they
  had this device. If you keep your own signup or first-launch date, pass it and it wins:

  ```swift
  var config = AppGlance.Configuration(apiKey: "glance_live_…")
  config.firstInstalledAt = myAccount.createdAt
  AppGlance.configure(config)
  ```

  A date in the future, or one from before 2001, is ignored.

## [1.2.3] - 2026-08-21

### Added

- Debug mode now says out loud when the server deliberately kept less than it was sent. A 202
  can carry `throttled` (the per-install rate limiter: one install sending faster than any real
  usage does, in practice an event call in a loop) and `over_quota_dropped` (the plan gate: the
  account is past its cap and its grace). Both counts were already in the response and the SDK
  read past them, so the one place the problem was visible was read only by the loop that caused
  it. With `debug: true` each now logs one line naming the count and the likely cause. Release
  builds are unchanged: nothing is printed, nothing is re-sent, and none of it ever counts
  against the plan.

## [1.2.2] - 2026-08-19

### Fixed

- A dropped presence ping's replacement keeps its distance when the visit ends in between. The
  15 second floor between a dropped ping and the ping that replaces it was enforced only by the
  running presence loop, and the loop runs only while the app is in front: a ping dropped by the
  flush on the way to the background left nothing behind but the rolled-back stamp, so coming
  back seconds later ticked at once, and a kill and relaunch inside the interval did the same
  with no live state at all. If the dropped ping had in fact been counted - the ambiguity that
  makes dropping the safe choice - the two ticks landed seconds apart in rollups the server folds
  additively and never dedupes. The floor now lives in the stamp itself, which survives both: the
  replacement is due 15 seconds after the ping it replaces, however the visit ends. The Kotlin
  SDK makes the same change.
- A client retired by a second `configure` no longer writes the install's preferences when its
  last send completes. A request already on the wire cannot be recalled, and its answer can carry
  the server's presence cadence and acknowledge a `user.identify`. Both were recorded to keys the
  replacement client had already read at its own init, and the two clients' sends are not
  serialized against each other, so a late commit could put an older user-properties snapshot
  over a newer one the replacement had already recorded. A retired client now adopts and commits
  nothing; a gate-closed client still does both, because those facts are the install's and no
  replacement exists to own them.
- A gate that opens with the app already on screen starts the visit's session. The launch's
  foreground report arrived at the closed gate and moved nothing but the record of it, and
  nothing re-reports it: an app that collects from TestFlight builds only starts every launch
  gated behind the App Store guess, so each visit passed with no `session.start`, no presence
  ping and no flush on leaving, until the next scene-phase change happened to wake it. The
  reported foreground is re-applied when the gate opens, after `install`, the same way a second
  `configure` hands it to the replacement client. The events the open inherits from the queue
  file also get a delivery timer of their own, rather than waiting for a track that may never
  come.
- A batch-size trigger that finds a delivery already running leaves the flush timer armed. An
  event tracked between that delivery's final look at the queue and its trigger clearing had no
  trigger of its own at `maxBatchSize: 1`, so it sat queued until the app's next call into the
  SDK.

## [1.2.1] - 2026-08-19

### Fixed

- The 500-event queue cap holds on the launch after a crash, and when a late environment answer
  opens the gate. The file holds what is OWED, which is the queue plus the non-ping half of the
  slice that was on the wire, so it can carry a whole request more than the cap; restoring it
  whole started that launch at up to 600 and left it there until something else was tracked. The
  gate-open path is worse: it puts the file in front of the queue this run already has, and two
  capped queues concatenated are twice the cap. Both are trimmed where they are read, oldest
  first, the same end the cap drops from everywhere else. The Kotlin SDK trims on the same path.

## [1.2.0] - 2026-08-19

### Fixed

- A restored device no longer inherits the install it was restored from. The install id is
  device-bound - a `…ThisDeviceOnly` Keychain item, mirrored outside the backup - so a second
  handset correctly mints its own; the session, the presence stamps and the user properties
  beside it live in `UserDefaults`, which an iCloud or encrypted backup and a device-to-device
  transfer all carry. The new install read that state as its own. It continued the old device's
  session when the app was opened within `sessionTimeout` of that device's last use, so its first
  visit recorded no `session.start`; and, with no time limit at all, it began believing the server
  already held the old device's user properties, so `identify` with those values sent nothing and
  the install's page in the dashboard stayed empty however often the app called it. State left by
  an install that is not this one is now dropped when an id is minted.
- A late answer about where this build runs no longer destroys the queue another build left on
  disk. The initializer states the rule: the queue file is deleted when consent is withdrawn and
  never when the environment gate closes, because a debuggable build run over an installed
  release copy shares that file and must not throw away a real queue the shipped build saved
  during an outage. Adopting the store's answer broke it by writing the queue over the file
  unconditionally, in both directions. An app that collects from betas only guesses App Store on
  every launch, so the answer opened its gate and wrote an empty file over the events its own
  last run had left, and no outage backlog could ever survive a relaunch; a Release build
  launched from Xcode over an App Store copy loaded that copy's queue and then wrote an empty
  file in its place. An answer that closes the gate now keeps exactly what this client inherited
  and drops only what this run recorded under the guess, including the slice on the wire; an
  answer that opens it reads the file the client was not allowed to read at startup; and a
  client that is no longer collecting neither writes that file nor puts a failed batch back into
  a queue it will never send.
- A gate that opens late starts a session instead of joining one that is over. The initializer
  decides a session in two steps and only the second is inside its `collecting` check, so a
  client the gate had closed began holding whatever session id the last run left behind, however
  old. Adopting the store's answer tested only whether that id was missing, so it kept a session
  that had ended days earlier and filed every event recorded before the first foreground into
  it, which the dashboard reads as one visit spanning both. The answer now asks the same
  question the initializer asks: an id a previous run pre-minted and never opened is reused and
  still owed its `session.start`, a session inside `sessionTimeout` is resumed, and anything
  else gets a new id, minted and written down before a single event can carry it.
- A first launch that cannot send no longer costs the install its `install` event. The id is
  minted and stored before anything knows whether this build collects, and a launch behind a
  closed environment gate (the default excludes Debug and the Simulator) or with
  `isEnabled: false` while the app waits for consent records nothing. Every later launch found
  the stored id, so the one launch that could have recorded the event was already over and the
  install never appeared at all: a developer's first Run, then TestFlight, was enough to lose it
  for good. A launch that mints the id and cannot record now notes the debt, and the first launch
  that is collecting records `install`, stamped with its own `configure`. The same applies inside
  one run: a store answer that opens the gate records the install its client could not.
- Two flushes can no longer overlap. A flush claimed the send only after waiting for the store's
  environment label, so a second flush arriving during that wait found the slot free, passed the
  same checks and began a drain of its own. Both then wrote to the single record of the slice on
  the wire, and the first one's batch ended up in neither the queue nor the file a killed process
  is recovered from; the second one's events left carrying the label the first was still waiting
  to correct; and a flush holding the process open for a send could return, and let the process
  suspend, while that send was still in flight. A flush now claims the send before it waits for
  anything, so a second one joins the whole of it.
- The three-second wait for the store's environment label is now a limit. It raced the ask against
  a timer inside a task group, and a task group returns only once every child has finished, so the
  timer expiring ended nothing and the first flush of a launch waited for `AppTransaction` however
  long it took. On the launch where that is slowest, one with no network, the batch on the way to
  the background missed the window its process assertion holds open.
- The user-properties snapshot records what the server acknowledged, not what was queued.
  `identify` committed the merged set the moment it queued the `user.identify` carrying it, and
  only a change is ever sent, so any event lost after that froze the install's properties for
  good: the 500-event cap trimming the oldest, a permanent `4xx` dropping the slice, or the ingest
  answering `202` while storing nothing (past the plan's grace ceiling, or under the per-install
  rate limiter). The install's page in the dashboard then stayed blank however often the app
  called `identify` with the same values, which the documentation tells it to do at every launch.
  The snapshot now moves only when a batch carrying that event comes back accepted and counted
  whole; what an event still owed will leave behind is read from the queue itself, so an
  `identify` made while an earlier one is in flight merges on top of it instead of re-sending it,
  and a repeat of values the server really has is still free.
- Withdrawing consent now clears the user properties as well as the queue. `isEnabled: false`
  discarded the queued events, but `$email`, `$name` and `$id` stayed in `UserDefaults`, inside
  the iCloud and the encrypted backup, and `reset()` - the only other thing that clears them -
  records nothing on a client that is not collecting. So the natural order of honouring a
  withdrawal, turn collection off and then forget the person, left them on disk indefinitely.
  They are deleted with the queue now, keyed on `isEnabled` alone: a closed environment gate is
  not a withdrawal and still leaves both alone. The install id is untouched, so turning
  collection back on is the same install rather than a new one.
- A second `configure` while the app is on screen no longer leaves the SDK inactive for the rest
  of the visit. Every client starts out believing the app is in the background, and nothing told
  the replacement otherwise: SwiftUI reports the front through `onAppear` and through scene-phase
  changes, and a `configure` in the middle of a visit is neither, so the one documented way to
  apply a consent change silently stopped the SDK dead. No `session.start`, no presence ping at
  all, no flush on the way to the background, and no last-active stamp, which then skewed the
  next launch's resume-or-new-session decision. A `configure` now hands the replacement the last
  foreground state the app reported, so it rejoins the session already running rather than
  opening a second one. What the app reported is what is carried, not what the outgoing client
  made of it: an app that configured with `isEnabled: false` while it waited for consent has a
  client that never became active, and its visit still opens a session the moment consent is
  granted. A reported background carries nothing but the fact that this app does report its
  lifecycle, so no session is invented for an app that is not on screen and no console line
  accuses it of forgetting `.trackAppLifecycle()`.
- A presence stamp in the future no longer silences the presence ping. The last-ping, last-event
  and last-active stamps were restored from disk and used as read, with no check against the
  clock, while the server's cadence floor sitting on the next line was checked. A device whose
  clock ran hours ahead wrote all three ahead of real time, and after the correction the silence
  they measure read as negative: no ping was ever due again, on that launch and on every launch
  after it, so an install in the foreground the whole time dropped out of "active right now" and
  its sessions ended early. The stamps now get the same treatment as the cadence floor, a value
  that cannot be true is discarded rather than obeyed, and every decision taken from one - resume
  this session or start a new one, is a ping owed, does leaving deserve a closing tick - reads an
  unmeasurable gap as a long one, which is the safe direction for all three. A clock corrected
  backwards during a visit is caught the same way, where the startup check cannot see it: the
  stamps this process wrote ahead of the new time are dropped once, one ping proves presence, and
  the interval paces the next.
- On macOS the install id is now kept where the device binding actually holds. The item was
  written with `…ThisDeviceOnly`, but the query never named a keychain, and a query that does not
  name one gets the file-based login keychain, where Apple documents that attribute as having no
  effect. Migration Assistant and a Time Machine restore copy that keychain onto the next Mac
  verbatim, so the id travelled, the new Mac was not a new install, and two machines in daily use
  reported as one. The query now names the data protection keychain on macOS, and an id an
  earlier version left in the login keychain is moved across rather than hidden, so no existing
  Mac install is renumbered: it is deleted from the old keychain only once its replacement is
  written, and a build that cannot reach the data protection keychain at all (an app signed
  without the entitlement that grants a keychain access group) keeps the id exactly where the
  next launch will find it. Every other platform has one keychain and ignores the key, so the
  query they send is unchanged.
- The install id's local mirror can no longer be left inside backups. Marking the file excluded
  from backup is a separate call from writing it and its failure is silent, and it was attempted
  only when the contents changed, so one failure was permanent: every later write found the id
  already there and returned early. The file then rode along in the iCloud and encrypted backups
  for the life of the install, which is what carries an id to a second device and makes two
  handsets report as one. The exclusion is now checked whenever the mirror is written.
- A minted install id that the store did not keep is no longer reported as a new install. The id
  was returned as new without asking whether the save landed, and neither the Keychain write nor
  the mirror write can report failure. A build where both fail - an unentitled Mac app whose
  Caches directory is also unwritable - minted a different id on every launch and recorded an
  `install` for each, so one device arrived as an unbounded stream of users that nothing on the
  server could collapse. The id is now read back before it is claimed, and a run whose id nothing
  kept uses it for its events and records no install, the same trade the unreadable-store case
  already made.
- `install` is no longer stamped later than the calls that were made before `configure`. Calls
  made before the SDK is configured are held and replayed, and each keeps the moment the app made
  it, while `install` was stamped with `configure` - so an app that tracks from an initializer
  running ahead of `configure` sent an `install` dated after an event that preceded it, and the
  platform's first-seen rollup takes the smallest timestamp an install ever sends. `install` now
  carries the earliest moment the SDK holds for that install.
- A batch rejected for good no longer costs the install a whole interval of presence. A permanent
  `4xx` drops the slice, and the ingest rejects a batch like that before it reads a row, so any
  presence pings in it were provably never counted - but their stamp was left in place, so the
  next ping was not due for a full interval. At the cadence a free-plan account is asked for that
  is longer than the dashboard's five-minute presence window, so an install in the foreground the
  whole time dropped out of "active right now". The stamp is now rolled back to the last ping the
  server acknowledged, which is what the retryable path already did.
- An automatic flush no longer retries inside the backoff it should be obeying. The flush timer
  read the backoff before joining the send in progress, so a timer that fired while a request was
  out saw no backoff, waited out that request, and then went straight at a server that had just
  asked for room, counting a second failure from one outage. The backoff is read after joining.
  An explicit `flush()` still always attempts.
- User-property keys and values are clamped in the units the ingest counts in. The SDK cut at 40
  and 200 characters and the server cuts at 40 and 200 UTF-16 code units, so any value outside
  the basic plane - an emoji, a flag, most non-Latin scripts - was stored by the server shorter
  than the SDK remembered it. The snapshot could then never match what was stored, and because
  only a change is sent, no later `identify` with the same values could correct it. A cut that
  would split a surrogate pair now drops the half rather than sending one.
- A store answer that opens the environment gate now also restamps the batch already on the wire,
  arms the missing-lifecycle check its client refused while gated, and records the install it
  could not. The first of those matters after a crash: the copy kept for a killed process still
  carried the guessed label, so a next launch that never got an answer of its own would have
  delivered beta or development traffic into the dashboard's Live scope. The second matters
  because a build the startup guess gated out and the answer let through is a shipping build that
  is sending, which is exactly where a missing `.trackAppLifecycle()` costs every session.
- A store answer that closes the gate now gives back the presence stamps that run had moved. The
  last-event stamp is written on every `track` and belongs to the install, not to the run, so a
  Release build launched from Xcode over the installed App Store copy left the shipped build
  owing no presence ping for up to a whole interval on its next launch, for a moment it had
  nothing to do with. The events are dropped, and the stamps they moved go with them.
- A store answer that closes the gate no longer costs the install its `install` event. A launch
  that mints the install id and is collecting records the event and clears the note that says one
  is owed, and an answer arriving a moment later drops everything that launch recorded. The debt
  went with it, and `isNewInstall` is true on that one launch only, so every later launch found
  the stored id, owed nothing, and the install never appeared in the dashboard at all. It is the
  ordinary path rather than a corner: the startup heuristic reads a TestFlight install as App
  Store, so every tester of an app that collects from App Store builds only arrived here on their
  first launch. The debt now goes back on disk whenever the close discards this run's own
  `install`, so the first launch that really collects records it. A copy already claimed for the
  wire is left alone: it may still be accepted, and a re-recorded install carries a new event id
  that the ingest's dedupe has nothing to collapse it against.
- A store answer that closes the gate now gives back the session state that run had adopted, along
  with the presence stamps. The close keeps what an earlier build left on disk, and one of the
  things that build can leave is a session id pre-minted and never opened, still owed its
  `session.start`, with events already carrying it. This run's first foreground adopted that id
  and cleared the marker that says it is owed, and the close returned the events without it: the
  sending build's next launch found no session pending, minted a fresh id over the top, and those
  events stayed filed under a session the server is never told about. The id and the marker are
  now restored with the stamps, so a run that is told it should never have been collecting leaves
  the whole of that state as it found it.
- A batch rejected for good no longer restarts the presence loop on a build the store's answer has
  just gated out. Dropping a permanent `4xx` re-arms the presence timer from the last ping the
  server acknowledged, and the answer can close the gate while that batch is still on the wire, so
  the loop came back on a client whose events go nowhere. The two stamps a ping writes before
  anything asks whether this build sends are the install's, shared by every build in the
  container: a Release build run from Xcode against a rotated write key went on proving a presence
  the shipped build had not proved, and moving the stamp its next launch judges
  resume-or-new-session by, once per interval for the rest of the visit. The roll-back and the
  ping itself both stop now at a client that is no longer collecting.
- A second session opened inside one process now writes its id down before the event that carries
  it. The `session.start` was queued, and persisted, ahead of the id reaching preferences, so a
  process killed in that window - a force-quit as the app is coming back - left a start for a
  session nothing on disk named, and the next launch inside the timeout resumed the id before it
  and filed the whole visit under a session it never opened. The pre-minted id was already
  written in this order; this is the one mint that was not.
- The batch POST no longer follows redirects. `URLSession` follows them by default and re-applies
  the original request's headers to the new one, so a `301` or `302` from a proxy, a captive
  portal, or an `endpoint` host that has changed hands carried the write key - and whatever a
  `user.identify` was holding, an email and a name - to whatever host the answer named, and a
  `2xx` from that host was read as the batch being delivered, so the events were dropped as well.
  A redirect is now refused and treated as a failed attempt, so the queue keeps the batch and
  retries against the configured host. The Kotlin transport already refused them; the two SDKs
  now answer this the same way.
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

- A burst of events leaves the device as one delivery rather than one request per event. The send
  loop is fed by the same queue the app is writing to, so an app recording as fast as the network
  answers - a screenful of items, a replayed queue of user actions - had every round after the
  first find exactly the one event tracked during the last round trip and send it on its own: a
  full set of request headers and a round trip each. A delivery now sends what was owed when it
  began, and the batch-size trigger asks for one delivery at a time rather than one for every
  event past the threshold. Anything tracked after a delivery begins goes with the next one, which
  the delivery arms before it returns. The Kotlin SDK bounds its drain the same way.
- Automatic delivery backs off further during a long outage. The retry ceiling stays at 60 seconds
  for the first ten consecutive failures and widens to five minutes past that: after ten attempts a
  server is having an outage rather than a blip, and the on-disk queue serves the install better
  than a tight retry does. An hour of `503` cost 85 attempts and 2.68 MB of re-uploaded queue head
  before this. An explicit `flush()` and the flush on backgrounding are not held by it, as before.
- A numeric `Retry-After` is honoured on any answered status, not on a `429` alone. A `503` that
  states one was previously ignored and the SDK backed off on its own schedule instead. The
  15 minute clamp still bounds it. The Kotlin SDK makes the same change in the same release.
- The offline queue file is no longer rewritten by a delivery that cannot change what is owed.
  Claiming a slice with no presence ping in it, and handing that same slice back after a
  transient failure, both leave the file saying exactly what it already said, and each used to
  pay a full atomic rewrite, which costs about as much for four hundred bytes as for two hundred
  kilobytes. An ordinary session loses one queue write in three, and a foregrounded install
  riding out a server outage with a deep queue stops writing the file between attempts
  altogether. What is written, and the moment at which a tracked event becomes durable, are
  unchanged.
- The README's setup section and the `Signal.heartbeat` documentation describe the presence ping
  the SDK actually sends: one after `heartbeatInterval` of silence in the foreground, none while
  real events are flowing, and a sparser cadence when the server asks for one. Both still
  promised a ping every interval, which the SDK stopped sending in 1.1.0, and the README's setup
  section contradicted its own configuration table further down the same file.
- The README says what the missing-lifecycle warning actually promises, and what setup actually
  costs. The warning is printed only by a build that is sending, so a Debug run with the default
  environment gate never sees it; and the intro sold "one line of setup" while the section below
  it called `.trackAppLifecycle()` not optional, which is a second.
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
