# AppGlance for Apple platforms

[![CI](https://github.com/AppGlance/appglance-apple/actions/workflows/ci.yml/badge.svg)](https://github.com/AppGlance/appglance-apple/actions/workflows/ci.yml) ![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen) ![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201-blue) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

The Swift SDK for [AppGlance](https://appglance.app): privacy-first, live analytics for apps.
It answers who is using your app right now, how many opened it today, where they are, and
anything you choose to track - with a random install id as the only identity, no IDFA, no
consent banner, and one line of setup. The Kotlin SDK is at
[AppGlance/appglance-android](https://github.com/AppGlance/appglance-android).

## Install

Xcode: **File → Add Package Dependencies…** and paste the repository URL. Or in `Package.swift`:

```swift
.package(url: "https://github.com/AppGlance/appglance-apple.git", from: "1.0.0")
```

| Platform | Minimum |
|---|---|
| iOS / iPadOS | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| watchOS | 9.0 |
| visionOS | 1.0 |
| Swift / Xcode | 5.10 / 15.3 |

No third-party dependencies, no binary blobs, and well under a quarter of a megabyte added to
an app. Compiles warning-free under strict concurrency checking and in Swift 6 language mode.

## Set up

Create an app in the [dashboard](https://appglance.app), copy its write key, and configure the
SDK as early as possible - your `App` initializer is the natural place:

```swift
import AppGlance

@main
struct MyApp: App {
    init() {
        AppGlance.configure(apiKey: "glance_live_…")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .trackAppLifecycle()   // sessions, presence, flush on background
        }
    }
}
```

`.trackAppLifecycle()` on your root view records `session.start` when the app comes to the
front after more than five minutes away, keeps a once-a-minute presence ping running while it is
in front, and flushes when it leaves. Brief interruptions - a notification, a quick app switch -
do not start a new session; neither does quitting and relaunching inside the timeout.

UIKit apps report the same transitions themselves, from the scene or application delegate:

```swift
func sceneDidBecomeActive(_ scene: UIScene) { AppGlance.setActive(true) }
func sceneWillResignActive(_ scene: UIScene) { AppGlance.setActive(false) }
```

**See yourself on the dashboard while integrating.** By default Simulator and Debug builds
send nothing, so your numbers only ever contain real installs. Turn on debug mode while you wire
things up:

```swift
AppGlance.configure(apiKey: "glance_live_…", debug: true)
```

This build now sends too - events tagged `simulator` / `debug`, visible under **All** in the
dashboard's scope switch, never in Live - and the SDK logs to the console (`[AppGlance] …`):
the environment and install id at configure, each event as it is queued, each send and what
the server said. Without debug mode, a gated build prints exactly one line saying it is not
sending and why.

## Track things

```swift
AppGlance.track("paywall.viewed", metadata: ["source": "settings"])   // any lowercase.dotted name; ≤ 20 string keys
AppGlance.trackScreen("paywall")                                     // records screen.paywall - the cheapest funnel step
```

In SwiftUI, `.trackScreen("paywall")` on a view records `screen.paywall` each time it appears.
Keep names short and stable, and never put personal data in a signal or its metadata.

## Who, if you choose

```swift
AppGlance.identify(id: account.id, email: account.email, name: account.name)   // labels on the install
AppGlance.setUserProperties(["plan": "pro"])                                   // free-form, filterable
AppGlance.reset()                                                              // on sign-out
```

The install id stays the analytics identity; these are labels merged onto it. Calling
`identify` with the same values on every launch is free - only a change is sent, as
`user.identify` (never billable). Reserved keys `$id`, `$email`, `$name`; up to 20 keys of 40
characters, values up to 200; an empty string removes a key. Passing an email or a name changes
your App Store privacy answers - the dashboard's Setup page shows exactly how.

## Configuration

```swift
AppGlance.configure(AppGlance.Configuration(
    apiKey: "glance_live_…",
    enabledEnvironments: [.appStore],   // narrow: production only
    heartbeatInterval: 120
))
```

| Option | Default | Notes |
|---|---|---|
| `flushInterval` | `10` s | Wait before sending a partial batch. |
| `maxBatchSize` | `20` | Send at once when this many events are queued. |
| `heartbeatInterval` | `60` s | Presence-ping cadence while foregrounded (drives "active now"). Never billable. |
| `sessionTimeout` | `300` s | Away longer than this and coming back is a new session - the dashboard splits on the same gap. |
| `isEnabled` | `true` | Master off-switch (e.g. behind a user setting). Wins over everything, including `debug`. |
| `collectsCountry` | `true` | The device's region *setting* as a two-letter code. Not GPS, not IP. |
| `enabledEnvironments` | `[.appStore, .testFlight]` | Which environments send; Simulator and Debug builds never do by default. |
| `debug` | `false` | Sends from any environment (tag stays truthful) and logs to the console. |
| `endpoint` | hosted ingest | Point it at your own deployment of the ingest service. |
| `appID`, `appVersion` | bundle id, `CFBundleShortVersionString` | Informational in hosted mode (the key identifies the app). |

### Environments

Every event is tagged `appstore`, `testflight`, `simulator` or `debug`. TestFlight vs App
Store is read from the store's signed `AppTransaction` (the sandbox receipt heuristic and, on
macOS, the beta-distribution signing certificate remain as fallbacks for builds the store
cannot vouch for), and TestFlight events stay out of the dashboard's Live numbers unless you
choose to include them. Simulator and Debug builds are excluded by the default
`enabledEnvironments`; debug mode lifts that gate without changing the tag.

## Guarantees

- Every public call is cheap and non-blocking. Calls apply strictly in call order on one
  background queue, timestamps are taken at call time, and calls made before `configure` (or
  before the Keychain is readable after a reboot) are held - up to 200 - and replayed.
- The install id is a random UUID in the Keychain, so delete-and-reinstall keeps it and the
  person is counted once. `install` is recorded exactly once, first.
- Events are written to disk as they are tracked, so a crash loses nothing. The queue is capped
  at 500 (oldest dropped), sent oldest-first in slices of 100, one send at a time. `429`, `5xx`
  and offline keep the batch for later; `413` halves it; any other `4xx` (an unknown key, say)
  drops that slice rather than wedging the queue.
- Retries never double-count. Every event carries a client-minted id and the server ignores
  replays; the presence ping - which is folded into rollups on arrival - is re-sent only when
  the server provably never saw it. A flush on the way to the background runs under a process
  assertion, so iOS does not suspend the app mid-request.

## Bring your own Supabase

The SDK can also write straight from the device to a Supabase project you control - nothing
passes through AppGlance. It needs a project running the AppGlance events schema (the `events`
table, its unique index over `(app_id, event_id)`, and an insert-only policy for the publishable
key). Configure with the project's URL and publishable key:

```swift
AppGlance.configure(.init(
    supabaseURL: URL(string: "https://YOUR-REF.supabase.co")!,
    publishableKey: "sb_publishable_…",
    appID: "com.example.app"
))
```

The publishable key can insert events, nothing else: raw rows are never readable from outside
(Row Level Security with no SELECT policy), and inserts are idempotent over `(app_id, event_id)`,
so a retried batch is stored once.

## Privacy and App Store labels

- **Identity** is a random per-install UUID in the Keychain - not the IDFA, not tied to the
  person. Reinstalls keep it; "erase all content" or a second device mints a new one.
- **Country** is `Locale.current.region` - a settings value, not location data.
- With the default setup, declare under *Data Not Linked to You*: Identifiers → User ID and
  Usage Data → Product Interaction, purpose Analytics, no tracking. With `identify`, add Contact
  Info (Email Address / Name), all under *Data Linked to You*, still no tracking. No ATT prompt
  either way - nothing here is tracking in Apple's sense. The dashboard's Setup page generates
  the exact answers per app.
- The package ships a `PrivacyInfo.xcprivacy` declaring the above and uses no required-reason
  APIs beyond its own UserDefaults keys.

## Documentation and support

- Guides and the HTTP API: [appglance.app/docs](https://appglance.app/docs)
- Release notes: [CHANGELOG.md](CHANGELOG.md) and [GitHub Releases](https://github.com/AppGlance/appglance-apple/releases)
- Questions or problems: [open an issue](https://github.com/AppGlance/appglance-apple/issues) or
  email [support@appglance.app](mailto:support@appglance.app)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · Security: [SECURITY.md](SECURITY.md)

## License

MIT - see [LICENSE](LICENSE).
