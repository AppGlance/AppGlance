# Contributing

Small, focused pull requests are welcome; open an issue first for anything larger so we can
agree on the shape.

- `swift build && swift test` must pass. CI also lints with `swift format lint --strict`,
  builds for iOS, tvOS, watchOS, visionOS and Mac Catalyst, and runs the tests on an iOS
  Simulator. Format with `swift format --in-place --recursive Sources Tests`; the
  configuration is in `.swift-format`.
- The package builds warning-free under strict concurrency checking (`StrictConcurrency` is on
  in `Package.swift`) and in Swift 6 language mode; keep it that way.
- Keep the public API small, and give every public symbol a doc comment written for an app
  developer.
- **On-disk names are frozen**: the `app.appglance.*` UserDefaults keys, the Keychain service and
  account, and the queue file name. Changing any of them orphans every existing install's state
  and silently doubles the user count.
- This SDK and the [Kotlin SDK](https://github.com/AppGlance/appglance-android) implement one
  wire-format contract. Anything that changes what goes over the wire - field names, environment
  values, retry semantics - has to change in both. Open an issue before starting.
- Commit messages: `feat:` / `fix:` / `docs:` / `chore:`, with the *why* in the body.

## Releasing

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new `## [x.y.z] - YYYY-MM-DD`
   heading.
2. Set `AppGlance.version` to the new number and commit. It is the `User-Agent` every request
   carries, so a stale one makes the fielded versions unreadable.
3. Re-measure the footprint. The README and the appglance.app homepage quote it ("~200 KB", "no
   third-party dependencies"), and a stale number is worse than none:

   ```bash
   xcodebuild build -quiet -scheme AppGlance -configuration Release -destination "generic/platform=iOS" -derivedDataPath /tmp/appglance-dd
   size /tmp/appglance-dd/Build/Products/Release-iphoneos/AppGlance.o    # __TEXT + __DATA ≈ what an app gains
   ```

   1.0.0 measured ≈197 KB and 1.2.0 ≈208 KB on the toolchain of their day; 1.2.1 measures
   ≈268 KB with Swift 6.3.3, and the tagged 1.2.0 measures the same there, so that jump is the
   compiler's, not the code's. Compare like with like: measure the previous tag with the same
   toolchain before reading a diff as growth. If the figure moves past what is quoted, update the
   README (and tell whoever maintains the site).
4. `git tag x.y.z && git push origin main x.y.z`.
5. The Release workflow publishes a GitHub Release with that changelog section as its notes;
   Swift Package Manager picks the new version up from the tag.
