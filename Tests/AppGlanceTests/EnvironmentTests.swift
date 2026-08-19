import Foundation
import StoreKit
import XCTest

@testable import AppGlance

/// The environment correction: the store's answer maps onto the SDK's vocabulary, queued
/// events are restamped before anything is sent, and the sending gate follows the corrected
/// environment, not the guess.
final class EnvironmentTests: XCTestCase {

    func testStoreEnvironmentMapsOntoSDKVocabulary() {
        XCTAssertEqual(AppEnvironment.refined(from: .sandbox, fallback: .appStore), .testFlight)
        XCTAssertEqual(AppEnvironment.refined(from: .production, fallback: .testFlight), .appStore)
        XCTAssertEqual(AppEnvironment.refined(from: .xcode, fallback: .appStore), .debug)
    }

    func testAdoptRestampsQueueAndSendsCorrectedLabel() async throws {
        let appID = "env.restamp"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)
        await client.track(signal: Signal.heartbeat, metadata: nil)

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingEvents()
        XCTAssertEqual(Set(queued.map(\.environment)), ["testflight"])
        await client.flush()
        let sent = RecordingProtocol.receivedBatches().flatMap { $0 }
        XCTAssertEqual(Set(sent.map(\.environment)), ["testflight"])
    }

    func testAdoptKeepsLabelsFromEarlierRuns() async throws {
        let appID = "env.foreign"
        TestSupport.fresh(appID)
        // An event persisted by an earlier run under a different label; this process cannot
        // vouch for that run's channel, so the correction must not touch it. The label must
        // differ from every test host's guess (macOS guesses debug, an iOS Simulator host
        // guesses simulator), or the restamp would legitimately rewrite it.
        let foreign = Event(
            event_id: "11111111-1111-1111-1111-111111111111", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "purchase", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([foreign])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)
        await client.adoptEnvironment(.testFlight)

        let labels = await client.pendingEvents().map(\.environment).sorted()
        XCTAssertEqual(labels, ["appstore", "testflight"], "the foreign label survives; the guessed one is restamped")
    }

    /// A client the gate has closed records nothing, so it must not write session state either:
    /// a developer's Xcode run over an installed App Store copy would otherwise renumber the
    /// session the store build is in the middle of.
    func testAGatedClientWritesNoSessionState() async throws {
        let appID = "env.gated.state"
        TestSupport.fresh(appID)
        let sessionKey = "app.appglance.session.\(appID)"
        let unadoptedKey = "app.appglance.sessionUnadopted.\(appID)"

        _ = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())

        XCTAssertNil(UserDefaults.standard.string(forKey: sessionKey), "no session id was minted")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: unadoptedKey), "and nothing is owed a session.start")
    }

    /// A gate that opens mints the session id its client did not mint at startup, so events
    /// recorded before the first foreground still carry the one `session.start` will adopt.
    func testAGateThatOpensMintsTheSessionIDItsClientSkipped() async throws {
        let appID = "env.gated.opens"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())
        var sessionID = await client.currentSessionID()
        XCTAssertNil(sessionID, "a gated client mints nothing")

        await client.adoptEnvironment(.appStore)

        sessionID = await client.currentSessionID()
        XCTAssertNotNil(sessionID)
        let unadopted = await client.currentSessionIsUnadopted()
        XCTAssertTrue(unadopted, "and it is owed a session.start")
        await client.track(signal: "paywall.viewed", metadata: nil)
        let queued = await client.pendingEvents()
        XCTAssertEqual(queued.map(\.session_id), [sessionID])
    }

    /// A gate that opens with the app already on screen starts the visit's session then and
    /// there. The launch's setActive(true) arrived at the closed gate and moved nothing but the
    /// report, and nothing re-reports it: an app that collects from TestFlight builds only starts
    /// every launch gated behind the App Store guess, so without the re-apply its whole visit
    /// passed with no session, no presence and no flush on leaving, until the next scene-phase
    /// change happened to wake it.
    func testAGateThatOpensWhileTheAppIsOnScreenStartsTheSession() async throws {
        let appID = "env.gated.foreground"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.setActive(true)  // the launch transition, refused at the closed gate
        var active = await client.isActiveForTesting()
        XCTAssertFalse(active, "gated: the report was recorded, not acted on")

        await client.adoptEnvironment(.appStore)

        active = await client.isActiveForTesting()
        XCTAssertTrue(active, "the answer opened the gate with the app on screen")
        let queued = await client.pendingSignals()
        XCTAssertTrue(queued.contains(Signal.sessionStart), "so the visit gets its session.start")
        let looping = await client.presenceLoopIsArmedForTesting()
        XCTAssertTrue(looping, "and its presence loop")
        await client.shutdown()
    }

    /// The queue a gate-open inherits has no trigger of its own: the batch-size trigger is
    /// reached only by the next `track`, and an app that only ever listens records nothing for
    /// the rest of the visit. The open arms the flush timer for it.
    func testAGateThatOpensArmsDeliveryForTheQueueItInherited() async throws {
        let appID = "env.gated.inherited.trigger"
        TestSupport.fresh(appID)
        let waiting = Event(
            event_id: "22222222-2222-2222-2222-222222222222", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "purchase", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([waiting])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())

        await client.adoptEnvironment(.appStore)

        let armed = await client.flushTimerIsArmedForTesting()
        XCTAssertTrue(armed, "the inherited events must not wait for a track that may never come")
        await client.shutdown()
    }

    func testAdoptDropsQueueWhenGateCloses() async throws {
        let appID = "env.gate.closes"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "paywall.viewed", metadata: nil)

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingEvents()
        XCTAssertTrue(queued.isEmpty)
        await client.track(signal: "after", metadata: nil)
        let after = await client.pendingEvents()
        XCTAssertTrue(after.isEmpty)
    }

    func testNilStoreAnswerLeavesGuessAndAllowsRetry() async throws {
        let appID = "env.retry"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "first", metadata: nil)

        await client.adoptStoreAnswer(nil)
        let unchanged = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(unchanged), [AppEnvironment.current.rawValue])

        await client.adoptStoreAnswer(.testFlight)
        let corrected = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(corrected), ["testflight"])
    }

    func testStoreAnswerIsAdoptedOnce() async throws {
        let appID = "env.once"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.adoptStoreAnswer(.testFlight)
        await client.adoptStoreAnswer(.appStore)
        await client.track(signal: "after", metadata: nil)
        let labels = await client.pendingEvents().map(\.environment)
        XCTAssertEqual(Set(labels), ["testflight"])
    }

    /// A build the store can never answer for - a directly downloaded Mac app, an ad hoc or
    /// enterprise build - must not spend a task and a storekitd round trip per flush for the
    /// life of the process. `asksTheStore` is injected because a test host is a Debug build,
    /// whose environment is a compile-time fact, so the ask path is otherwise never entered.
    func testTheStoreIsNotAskedForeverWhenItNeverAnswers() async throws {
        let appID = "env.ceiling"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession(), asksTheStore: true)

        for _ in 0..<10 {
            await client.beginEnvironmentRefinement()
            // The ask resolves to "no answer" at once on this host; let the slot clear, or the
            // next call would be swallowed by the one-ask-at-a-time guard rather than the ceiling.
            let deadline = Date().addingTimeInterval(2)
            while await client.environmentAskIsOpenForTesting(), Date() < deadline {
                await TestSupport.settle(0.01)
            }
        }

        let asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 5, "a few retries for the fresh install that has nothing cached, then the guess stands")
    }

    /// The label only matters for events about to leave, so a flush with nothing to send neither
    /// asks nor waits for an answer.
    func testAnEmptyFlushDoesNotAskTheStore() async throws {
        let appID = "env.emptyflush"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession(), asksTheStore: true)

        await client.flush()
        var asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 0, "nothing queued: no ask, and no wait for one")

        await client.track(signal: "a", metadata: nil)
        await client.flush()
        asks = await client.environmentAsksForTesting()
        XCTAssertEqual(asks, 1, "a flush that has something to label does ask")
        XCTAssertEqual(RecordingProtocol.signals(), ["a"])
    }

    func testAdoptOpensGateForCorrectedEnvironment() async throws {
        let appID = "env.gate.opens"
        TestSupport.fresh(appID)
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.testFlight]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "dropped.by.guess", metadata: nil)

        await client.adoptEnvironment(.testFlight)

        await client.track(signal: "collected", metadata: nil)
        let signals = await client.pendingSignals()
        XCTAssertEqual(signals, ["collected"])
    }

    /// The same loss inside one run: the gate is closed when the client starts, so the launch that
    /// minted the install id records nothing, and the store's answer opens it a moment later. That
    /// answer is the first moment this install can be counted.
    func testAGateThatOpensRecordsTheInstallItsClientCouldNotRecord() async throws {
        let appID = "env.gate.install"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", isNewInstall: true, session: TestSupport.recordingSession())
        await client.recordInstallIfNeeded()
        let whileGated = await client.pendingSignals()
        XCTAssertEqual(whileGated, [], "a gated client records nothing")

        await client.adoptEnvironment(.appStore)

        let afterOpening = await client.pendingSignals()
        XCTAssertEqual(afterOpening, [Signal.install], "the install the closed gate swallowed")
        let sessionID = await client.currentSessionID()
        let sessions = await client.pendingEvents().map(\.session_id)
        XCTAssertEqual(sessions, [sessionID], "in the session the gate opening minted for it")
    }

    /// The mirror image, and the same install lost. The startup guess collects, so the launch that
    /// mints the id records its `install` and clears the note that says one is owed; then the
    /// store's answer closes the gate and everything this run recorded goes with it. `isNewInstall`
    /// is true on this launch only, so unless the debt goes back on disk that install is never
    /// counted for as long as the id lives. It is the ordinary path, not a corner: the startup
    /// heuristic reads a TestFlight install as App Store, so every tester of an app configured for
    /// `.appStore` arrives here on their first launch.
    func testALateGateCloseGivesTheInstallBackToTheNextLaunchThatCollects() async throws {
        let appID = "env.gate.closes.install"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let session = TestSupport.recordingSession()

        let guessing = Client(
            config: TestSupport.configuration(
                appID: appID, enabledEnvironments: Set(AppEnvironment.allCases).subtracting([.testFlight])),
            userID: "user-1", isNewInstall: true, session: session)
        await guessing.recordInstallIfNeeded()
        let underTheGuess = await guessing.pendingSignals()
        XCTAssertEqual(underTheGuess, [Signal.install], "the guess collects, so this launch records it")

        await guessing.adoptEnvironment(.testFlight)

        let afterTheClose = await guessing.pendingSignals()
        XCTAssertEqual(afterTheClose, [], "and the answer takes it: this build was never meant to send")
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "app.appglance.installPending.\(appID)"),
            "so the install is owed again, exactly as if the gate had been closed from the start")
        await guessing.shutdown()

        // The next launch is the shipped build: the id is stored, so `isNewInstall` is false, and
        // only the note on disk can say that an install is still owed.
        let sending = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1", session: session)
        await sending.recordInstallIfNeeded()
        let paid = await sending.pendingSignals()
        XCTAssertEqual(paid, [Signal.install], "and the first launch that really collects pays it")
    }

    /// A gate that opens late must not inherit a session that is long over: init would have
    /// minted a new id for this launch, and only the `collecting` test kept it from doing so.
    func testAGateThatOpensLateDoesNotAdoptASessionThatEnded() async throws {
        let appID = "env.gated.stale.session"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        defaults.set("stale-session-id", forKey: "app.appglance.session.\(appID)")
        defaults.set(
            Date().addingTimeInterval(-86_400).timeIntervalSince1970, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())
        let atStartup = await client.currentSessionID()
        XCTAssertEqual(atStartup, "stale-session-id", "a gated client starts from whatever the last run left")

        await client.adoptEnvironment(.appStore)

        let adopted = await client.currentSessionID()
        XCTAssertNotNil(adopted)
        XCTAssertNotEqual(adopted, "stale-session-id", "a day-old session is over: the gate opening starts a new one")
        let unadopted = await client.currentSessionIsUnadopted()
        XCTAssertTrue(unadopted, "and it is owed a session.start")
        XCTAssertEqual(defaults.string(forKey: "app.appglance.session.\(appID)"), adopted, "written for the next run")
    }

    /// The other half of init's test: an id a previous run pre-minted and never opened is still
    /// owed its `session.start`, so a gate that opens late reuses it rather than minting a second.
    func testAGateThatOpensLateReusesAPreMintedSession() async throws {
        let appID = "env.gated.premint.session"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        // A run that died between minting and its first foreground leaves the id and the marker,
        // and no last-active stamp: nothing ever reached the foreground.
        defaults.set("premint-session-id", forKey: "app.appglance.session.\(appID)")
        defaults.set(true, forKey: "app.appglance.sessionUnadopted.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())
        let atStartup = await client.currentSessionID()
        XCTAssertNil(atStartup, "a gated client mints nothing and reads no marker")

        await client.adoptEnvironment(.appStore)

        let adopted = await client.currentSessionID()
        XCTAssertEqual(adopted, "premint-session-id", "the same id is still owed its session.start")
        let unadopted = await client.currentSessionIsUnadopted()
        XCTAssertTrue(unadopted)
    }

    /// And the third answer: a session that has not ended yet. The gate opens two seconds into a
    /// visit the last run was in the middle of, so the id the run left behind is the one this
    /// visit belongs to. Minting here would send a second `session.start` for a visit that never
    /// ended - one visit charted and billed as two - and would strand the events the earlier run
    /// queued under an id the server is never told about.
    func testAGateThatOpensLateKeepsASessionThatCanStillBeResumed() async throws {
        let appID = "env.gated.resumable.session"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        defaults.set("resumable-session-id", forKey: "app.appglance.session.\(appID)")
        // Well inside the 300 s timeout, and adopted: the last run reached the foreground.
        defaults.set(
            Date().addingTimeInterval(-30).timeIntervalSince1970, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.appStore]),
            userID: "user-1", session: TestSupport.recordingSession())

        await client.adoptEnvironment(.appStore)

        let adopted = await client.currentSessionID()
        XCTAssertEqual(adopted, "resumable-session-id", "the visit is still going: this is its session")
        let unadopted = await client.currentSessionIsUnadopted()
        XCTAssertFalse(unadopted, "and it has had its session.start, so the first foreground resumes it")
        XCTAssertEqual(
            defaults.string(forKey: "app.appglance.session.\(appID)"), "resumable-session-id",
            "nothing renumbered on disk either")
    }

    /// A late answer that closes the gate stops this client, but the queue file is not its to
    /// destroy: init keeps it for the build that wrote it (a debuggable build run over an
    /// installed release copy), and the answer arriving late does not change that. What this run
    /// recorded under the guess goes, because that is the environment the app gated out.
    func testALateGateCloseKeepsTheQueueAnEarlierBuildLeft() async throws {
        let appID = "env.gate.closes.disk"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let earlier = (0..<2).map { i in
            Event(
                event_id: "eeeeeeee-0000-0000-0000-00000000000\(i)", session_id: nil, app_id: appID,
                user_id: "user-1", signal: "earlier.\(i)", app_version: "1.0", os_name: "iOS",
                os_version: "26.0", environment: "appstore", country: nil,
                client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        }
        let data = try EventCoding.makeEncoder().encode(earlier)
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "this.run", metadata: nil)

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingSignals()
        XCTAssertTrue(queued.isEmpty, "this client sends nothing more")
        XCTAssertEqual(
            try TestSupport.persistedSignals(appID), ["earlier.0", "earlier.1"],
            "the earlier build's queue survives; what this run recorded under the guess does not")
    }

    /// The presence stamps are the install's, shared by every build in the container, and a run
    /// the answer gates out has to leave them where it found them. `track` moves the last-event
    /// stamp on every call, and the events themselves are dropped, so a Release build run from
    /// Xcode over the App Store copy would otherwise leave the shipped build owing no ping until
    /// a whole interval after a moment it had nothing to do with.
    func testALateGateCloseGivesBackThePresenceStampsThisRunMoved() async throws {
        let appID = "env.gate.closes.stamps"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let clock = TestClock()
        let defaults = UserDefaults.standard
        let beforeThisRun = clock.now.timeIntervalSince1970 - 600
        defaults.set(beforeThisRun, forKey: "app.appglance.lastEvent.\(appID)")
        defaults.set(clock.now.timeIntervalSince1970 - 30, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession(), now: { clock.now })
        await client.track(signal: "this.run", metadata: nil)
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastEvent.\(appID)") as? Double, clock.now.timeIntervalSince1970,
            "under the guess this run is collecting, so it stamps like any other")

        await client.adoptEnvironment(.testFlight)

        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastEvent.\(appID)") as? Double, beforeThisRun,
            "and the answer says it never should have: the install's stamp is the one it found")
    }

    /// The session state goes back with the stamps. An earlier build that died between minting a
    /// session id and its first foreground leaves the id, the marker that says it is still owed
    /// its `session.start`, and events on disk carrying it. This run's first foreground adopts
    /// that id and clears the marker, and then the answer closes the gate: the events are written
    /// back, so the marker has to be too. Without it the shipped build's next launch sees no
    /// session pending, mints a fresh id, and those events stay filed under a session the server
    /// is never told about.
    func testALateGateCloseGivesBackTheSessionStateThisRunAdopted() async throws {
        let appID = "env.gate.closes.session"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        defaults.set("premint-session-id", forKey: "app.appglance.session.\(appID)")
        defaults.set(true, forKey: "app.appglance.sessionUnadopted.\(appID)")
        defaults.set(
            Date().addingTimeInterval(-10_000).timeIntervalSince1970, forKey: "app.appglance.lastActive.\(appID)")
        let owed = Event(
            event_id: "eeeeeeee-0000-0000-0000-000000000005", session_id: "premint-session-id", app_id: appID,
            user_id: "user-1", signal: Signal.install, app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        try EventCoding.makeEncoder().encode([owed]).write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.setActive(true)  // adopts the pre-minted id and clears the marker
        XCTAssertFalse(defaults.bool(forKey: "app.appglance.sessionUnadopted.\(appID)"))

        await client.adoptEnvironment(.testFlight)

        XCTAssertEqual(
            try TestSupport.persistedSignals(appID), [Signal.install],
            "the earlier build's event is kept, as the close is meant to keep it")
        XCTAssertEqual(
            defaults.string(forKey: "app.appglance.session.\(appID)"), "premint-session-id",
            "under the id it was recorded with")
        XCTAssertTrue(
            defaults.bool(forKey: "app.appglance.sessionUnadopted.\(appID)"),
            "and that session is still owed its session.start, which this run was never entitled to send")
    }

    /// A gate that opens late reads the queue file its client was not allowed to read at init,
    /// rather than writing an empty one over it.
    func testAGateThatOpensLateTakesOverTheQueueItSkipped() async throws {
        let appID = "env.gate.opens.disk"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let earlier = Event(
            event_id: "eeeeeeee-0000-0000-0000-000000000002", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "from.the.last.run", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "testflight", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([earlier])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.testFlight]),
            userID: "user-1", session: TestSupport.recordingSession())
        let atStartup = await client.pendingSignals()
        XCTAssertTrue(atStartup.isEmpty, "a gated client does not read the file")

        await client.adoptEnvironment(.testFlight)

        let queued = await client.pendingSignals()
        XCTAssertEqual(queued, ["from.the.last.run"], "the gate opened: those events are this client's to deliver")
        XCTAssertEqual(
            try TestSupport.persistedSignals(appID), ["from.the.last.run"], "and they are still owed on disk")
    }

    /// The correction reaches the slice on the wire too. Those events are gone as sent, but the
    /// copy `persist` keeps for a killed process is not: a next launch that never gets an answer
    /// of its own would deliver them under the guess, putting beta or development traffic into
    /// the dashboard's Live scope.
    func testTheCorrectionRestampsTheSliceOnTheWireAndNotOnlyTheQueue() async throws {
        let appID = "env.restamp.inflight"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID), userID: "user-1",
            session: TestSupport.recordingSession())
        await client.track(signal: "on.the.wire", metadata: nil)

        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        let deadline = Date().addingTimeInterval(5)
        while !hold.isStarted, Date() < deadline { await TestSupport.settle(0.01) }
        XCTAssertTrue(hold.isStarted, "the batch is on the wire, and in the crash record")

        await client.adoptEnvironment(.testFlight)

        let recorded = try Data(contentsOf: Client.makeStoreURL(appID: appID))
        let owed = try EventCoding.makeDecoder().decode([Event].self, from: recorded)
        XCTAssertEqual(
            owed.map(\.environment), ["testflight"],
            "the copy a killed process would re-send carries the corrected label, not the guess")
        hold.proceed()
        await flushing.value
    }

    /// The missing-lifecycle line is the one integration mistake a customer cannot debug from the
    /// console, and the build most likely to be making it is the one the startup guess gated out
    /// and the store's answer let through: it is shipping, and it is sending.
    func testAGateThatOpensArmsTheMissingLifecycleCheckItsClientRefused() async throws {
        let appID = "env.gate.lifecycle"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [.testFlight]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.armLifecycleCheck(after: 0.05)  // the facade arms it at configure: a no-op while gated
        await TestSupport.settle(0.2)
        var reported = await client.reportedMissingLifecycleForTesting()
        XCTAssertFalse(reported, "a gated client says nothing, because it is not sending anything either")

        await client.adoptEnvironment(.testFlight)

        // The line is printed by the task the gate opening arms, so the wait is on the report
        // itself: a fixed sleep here is a race with a 0.05 s timer on a loaded machine.
        reported = await TestSupport.waitUntilAsync(timeout: 3) { await client.reportedMissingLifecycleForTesting() }
        XCTAssertTrue(reported, "this build sends after all, so an app that never reports a foreground is told")
    }

    /// The gate can close while a batch is on the wire. The slice is judged with the queue and by
    /// the same rule, and the failure that follows must not put any of it back.
    func testAGateThatClosesMidSendKeepsOnlyTheEarlierBuildsEvents() async throws {
        let appID = "env.gate.closes.midsend"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let earlier = Event(
            event_id: "eeeeeeee-0000-0000-0000-000000000003", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "earlier", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([earlier])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "this.run", metadata: nil)

        RecordingProtocol.script([503])
        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        let deadline = Date().addingTimeInterval(5)
        while !hold.isStarted, Date() < deadline { await TestSupport.settle(0.01) }
        XCTAssertTrue(hold.isStarted, "the batch is on the wire")

        await client.adoptEnvironment(.testFlight)
        hold.proceed()
        await flushing.value

        let queued = await client.pendingSignals()
        XCTAssertTrue(queued.isEmpty, "a failed batch is not put back into a queue the gate has closed")
        XCTAssertEqual(
            try TestSupport.persistedSignals(appID), ["earlier"],
            "the earlier build's event is still owed; nothing this run recorded survives the close")
    }

    /// The same close, but the send on the wire succeeds. The drain's own bookkeeping writes the
    /// queue file on the way back, and by then the file belongs to the build that wrote it: a
    /// client that is no longer collecting must not put an empty queue over what the close saved.
    func testAGateThatClosesWhileASendSucceedsLeavesTheEarlierBuildsEventsOnDisk() async throws {
        let appID = "env.gate.closes.midsend.ok"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let earlier = Event(
            event_id: "eeeeeeee-0000-0000-0000-000000000004", session_id: nil, app_id: appID,
            user_id: "user-1", signal: "earlier", app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: "appstore", country: nil,
            client_ts: Date(timeIntervalSince1970: 1_700_000_000), metadata: nil)
        let data = try EventCoding.makeEncoder().encode([earlier])
        try data.write(to: Client.makeStoreURL(appID: appID), options: .atomic)

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "this.run", metadata: nil)

        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        let deadline = Date().addingTimeInterval(5)
        while !hold.isStarted, Date() < deadline { await TestSupport.settle(0.01) }
        XCTAssertTrue(hold.isStarted, "the batch is on the wire")

        await client.adoptEnvironment(.testFlight)
        hold.proceed()  // 202: the drain persists on its way out
        await flushing.value

        XCTAssertEqual(
            try TestSupport.persistedSignals(appID), ["earlier"],
            "a client the gate has closed writes nothing over the file it preserved")
    }

    /// The close hands the install's presence stamps back the way it found them, and a stamp the
    /// clock has not reached yet is not something it found: those are discarded at startup, because
    /// a device whose clock was hours ahead when they were written would otherwise carry impossible
    /// stamps into every launch after. Handing one back writes it to disk for the sibling build to
    /// inherit, which is the one place that startup guard has a lasting consequence.
    func testALateGateCloseDoesNotHandBackPresenceStampsFromTheFuture() async throws {
        let appID = "env.gate.closes.futurestamps"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        let ahead = Date().addingTimeInterval(7200).timeIntervalSince1970
        defaults.set(ahead, forKey: "app.appglance.lastHeartbeat.\(appID)")
        defaults.set(ahead, forKey: "app.appglance.lastEvent.\(appID)")
        defaults.set(ahead, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.track(signal: "under the guess", metadata: nil)  // moves the install's event stamp
        await client.adoptEnvironment(.testFlight)

        XCTAssertNil(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(appID)"),
            "a stamp two hours ahead of the clock was never this run's to give back")
        XCTAssertNil(defaults.object(forKey: "app.appglance.lastEvent.\(appID)"))
        XCTAssertNil(defaults.object(forKey: "app.appglance.lastActive.\(appID)"))
        await client.shutdown()
    }

    /// The close gives back the session state this run found, and an absent key is what "never
    /// happened" looks like for that pair as much as for the stamps. Left in place, this run's
    /// minted id sits in `UserDefaults` with the pre-mint marker cleared, and the next launch of
    /// the sending build reads it as a session it may resume - filing the whole visit under one
    /// whose `session.start` this very close discarded.
    func testALateGateCloseRemovesTheSessionItMintedWhenThereWasNoneToGiveBack() async throws {
        let appID = "env.gate.closes.nosession"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        let mintedID = await client.currentSessionID()
        let minted = try XCTUnwrap(mintedID)
        await client.setActive(true)  // adopts it, and clears the marker that says it is still owed
        XCTAssertEqual(defaults.string(forKey: "app.appglance.session.\(appID)"), minted)

        await client.adoptEnvironment(.testFlight)

        XCTAssertNil(
            defaults.string(forKey: "app.appglance.session.\(appID)"),
            "there was no session on disk when this run started, so none is left behind")
        XCTAssertNil(defaults.object(forKey: "app.appglance.sessionUnadopted.\(appID)"))
        await client.shutdown()
    }

    /// A gated client never stamps the install's presence. The two stamps a ping writes before it
    /// records anything are the install's - every build sharing the container reads them - so a
    /// client the store's answer has just closed would prove a presence the shipped build has not
    /// proved, and move the stamp that build's next launch judges resume-or-new-session by. The
    /// `track` inside a tick is a no-op on such a client; the stamps above it are not, which is
    /// why the tick has a guard of its own.
    func testAClientTheGateHasClosedStampsNoPresenceEvenIfATickReachesIt() async throws {
        let appID = "env.gate.closes.tick"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        // The shipped build's stamps, from a visit hours ago.
        let shipped = Date().addingTimeInterval(-10_000).timeIntervalSince1970
        defaults.set(shipped, forKey: "app.appglance.lastHeartbeat.\(appID)")
        defaults.set(shipped, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(appID: appID, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession())
        await client.setActive(true)
        await client.adoptEnvironment(.testFlight)
        var loopArmed = await client.presenceLoopIsArmedForTesting()
        XCTAssertFalse(loopArmed, "the close takes the loop down")

        let ticked = await client.heartbeatForTesting()

        loopArmed = await client.presenceLoopIsArmedForTesting()
        XCTAssertFalse(loopArmed, "and a refused tick does not arm one either")
        XCTAssertFalse(ticked, "a tick that reaches a client which is no longer collecting does nothing at all")
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(appID)") as? Double, shipped,
            "the ping stamp is the install's, and this run has been told it should never have been sending")
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastActive.\(appID)") as? Double, shipped,
            "nor may it move the stamp the shipped build's next launch judges its session by")
        await client.shutdown()
    }

    /// The same close, and the batch on the wire comes back with a permanent 4xx - a rotated write
    /// key, the ordinary way a Release build run from Xcode meets one. Dropping that slice re-arms
    /// the presence loop, and the loop has to stay down: the stamps it writes are the install's,
    /// every build sharing the container reads them, and this run has just been told it should
    /// never have been sending. A loop that ticks on regardless proves presence the shipped build
    /// has not proved and renumbers the session state it left behind.
    func testAPermanentFailureDoesNotRestartThePresenceLoopOnAClosedGate() async throws {
        let appID = "env.gate.closes.4xx.presence"
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
        let defaults = UserDefaults.standard
        // The shipped build's stamps, from a visit hours ago.
        let shipped = Date().addingTimeInterval(-10_000).timeIntervalSince1970
        defaults.set(shipped, forKey: "app.appglance.lastHeartbeat.\(appID)")
        defaults.set(shipped, forKey: "app.appglance.lastActive.\(appID)")

        let client = Client(
            config: TestSupport.configuration(
                appID: appID, heartbeatInterval: 0.05, enabledEnvironments: [AppEnvironment.current]),
            userID: "user-1", session: TestSupport.recordingSession(), minHeartbeatRetry: 0.05)
        await client.setActive(true)
        let ticked = await TestSupport.waitForHeartbeats(1, from: client)
        XCTAssertTrue(ticked, "the loop is running under the guess")

        RecordingProtocol.script([401])
        let hold = RecordingProtocol.holdNextRequest()
        let flushing = Task { await client.flush() }
        let deadline = Date().addingTimeInterval(5)
        while !hold.isStarted, Date() < deadline { await TestSupport.settle(0.01) }
        XCTAssertTrue(hold.isStarted, "the pings are on the wire")

        await client.adoptEnvironment(.testFlight)
        hold.proceed()  // 401: the slice is dropped, and its pings with it
        await flushing.value

        let loopArmed = await client.presenceLoopIsArmedForTesting()
        XCTAssertFalse(
            loopArmed,
            "the close took the loop down, and the roll-back that drop performs must not put it back up")
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(appID)") as? Double, shipped,
            "the close put the install's ping stamp back")

        // A whole handful of the 0.05 s intervals the loop was running at.
        await TestSupport.settle(0.6)

        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastHeartbeat.\(appID)") as? Double, shipped,
            "and nothing ticks on afterwards to move it again")
        XCTAssertEqual(
            defaults.object(forKey: "app.appglance.lastActive.\(appID)") as? Double, shipped,
            "nor to move the stamp the next launch judges resume-or-new-session by")
    }
}
