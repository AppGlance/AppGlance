import StoreKit
import XCTest

@testable import AppGlance

/// Telling a genuinely new user from one who has had the app for years and only just met the SDK.
/// The evidence rides one SDK-owned event per install; the server decides what it means.
final class InstallOriginTests: XCTestCase {

    private func makeClient(
        appID: String, clock: TestClock, firstInstalledAt: Date? = nil,
        storeAnswer: (@Sendable () async -> StoreAnswer)? = nil,
        environmentAnswerGrace: TimeInterval = 3
    ) -> Client {
        var config = TestSupport.configuration(appID: appID)
        config.firstInstalledAt = firstInstalledAt
        return Client(
            config: config.withinBounds(), userID: "u-\(appID)", isNewInstall: true, installAt: clock.now,
            session: TestSupport.recordingSession(), now: { clock.now },
            asksTheStore: storeAnswer != nil,
            storeAnswer: storeAnswer ?? { await AppEnvironment.storeAnswer() },
            environmentAnswerGrace: environmentAnswerGrace)
    }

    private func isolate(_ appID: String) {
        TestSupport.fresh(appID)
        addTeardownBlock { TestSupport.fresh(appID) }
    }

    private func origins(_ events: [Event]) -> [[String: String]] {
        events.compactMap { event in
            let fields = (event.metadata ?? [:]).filter { $0.key.hasPrefix("$install") }
            return fields.isEmpty ? nil : fields
        }
    }

    // MARK: - The app's own answer

    /// An app that keeps its own signup date knows things no platform API can see, so its date
    /// needs no ask and rides this install's own `install` event.
    func testAppSuppliedDateRidesTheInstallEvent() async throws {
        let id = "test.origin.supplied"; isolate(id)
        let clock = TestClock()
        let signup = clock.now.addingTimeInterval(-400 * 24 * 3600)
        let client = makeClient(appID: id, clock: clock, firstInstalledAt: signup)

        await client.recordInstallIfNeeded()
        let queued = await client.pendingEvents()

        XCTAssertEqual(queued.map(\.signal), [Signal.install])
        XCTAssertEqual(
            queued[0].metadata?[InstallOrigin.Key.installedAt], EventCoding.timestamp(signup),
            "the app's date travels verbatim: the server compares it against first sight")
        XCTAssertEqual(queued[0].metadata?[InstallOrigin.Key.evidence], "app")
    }

    /// Sent once per install and never again: a second answer for the same fact is one the server
    /// would have to reconcile against the first.
    func testOriginRidesOneEventOnly() async throws {
        let id = "test.origin.once"; isolate(id)
        let clock = TestClock()
        let client = makeClient(
            appID: id, clock: clock, firstInstalledAt: clock.now.addingTimeInterval(-90 * 24 * 3600))

        await client.recordInstallIfNeeded()
        await client.setActive(true)
        await TestSupport.settle(0.3)

        let queued = await client.pendingEvents()
        XCTAssertTrue(
            queued.map(\.signal).contains(Signal.sessionStart), "the session opened, so there was a second carrier")
        XCTAssertEqual(origins(queued).count, 1, "one carrier holds it, whatever else goes out")
    }

    /// A date nothing could have produced is not evidence. Dropped rather than clamped: no
    /// evidence is a state the server already handles, a date in the future is a user who
    /// arrives tomorrow.
    func testImplausibleDatesAreIgnored() async throws {
        for (name, date) in [
            ("future", Date().addingTimeInterval(60 * 60 * 24 * 30)),
            ("prehistoric", Date(timeIntervalSince1970: 0)),
        ] {
            let id = "test.origin.implausible.\(name)"; isolate(id)
            let clock = TestClock()
            let client = makeClient(appID: id, clock: clock, firstInstalledAt: date)

            await client.recordInstallIfNeeded()
            let queued = await client.pendingEvents()
            XCTAssertEqual(origins(queued).count, 0, "\(name): no origin should travel")
        }
    }

    // MARK: - The store's answer

    /// The common case for an app adopting the SDK: nobody supplies a date, the store answers a
    /// moment after `install` is queued, and the first flush is still waiting for the environment
    /// label - so `install` is right there to carry it.
    func testStoreAnswerStampsTheQueuedInstall() async throws {
        let id = "test.origin.store"; isolate(id)
        let clock = TestClock()
        let gate = StoreAnswerGate()
        let client = makeClient(appID: id, clock: clock, storeAnswer: { await gate.ask() })

        await client.recordInstallIfNeeded()
        let beforeAnswer = origins(await client.pendingEvents())
        XCTAssertEqual(beforeAnswer.count, 0, "nothing has answered yet")

        await client.beginEnvironmentRefinement()
        let asked = await gate.waitUntilAsked()
        XCTAssertTrue(asked)
        let purchased = clock.now.addingTimeInterval(-3 * 365 * 24 * 3600)
        gate.answer(
            .appStore,
            origin: InstallOrigin(firstInstalledAt: purchased, evidence: .store, originalAppVersion: "42"))

        let landed = await TestSupport.waitUntilAsync { await !self.origins(client.pendingEvents()).isEmpty }
        XCTAssertTrue(landed, "the answer should have been stamped onto the queued install")

        let queued = await client.pendingEvents()
        let stamped = try XCTUnwrap(queued.first { $0.signal == Signal.install })
        XCTAssertEqual(stamped.metadata?[InstallOrigin.Key.installedAt], EventCoding.timestamp(purchased))
        XCTAssertEqual(stamped.metadata?[InstallOrigin.Key.evidence], "store")
        XCTAssertEqual(stamped.metadata?[InstallOrigin.Key.originalVersion], "42")
    }

    /// An event an earlier run left on disk is not a carrier. It may be sitting there because its
    /// acknowledgement was lost rather than its send, in which case the server already holds that
    /// event id and ignores a replay of it - so metadata added to it now would be thrown away on
    /// arrival, silently, while the SDK marked the origin sent and never offered it again.
    func testAnInheritedEventIsNeverStamped() async throws {
        let id = "test.origin.inherited"; isolate(id)
        let clock = TestClock()
        let owed = Event(
            event_id: "eeeeeeee-0000-0000-0000-0000000000aa", session_id: nil, app_id: id,
            user_id: "u-\(id)", signal: Signal.install, app_version: "1.0", os_name: "iOS",
            os_version: "26.0", environment: AppEnvironment.current.rawValue, country: nil,
            client_ts: clock.now, metadata: nil)
        try EventCoding.makeEncoder().encode([owed]).write(to: Client.makeStoreURL(appID: id), options: .atomic)

        let gate = StoreAnswerGate()
        let client = Client(
            config: TestSupport.configuration(appID: id).withinBounds(), userID: "u-\(id)",
            isNewInstall: false, installAt: clock.now, session: TestSupport.recordingSession(),
            now: { clock.now }, asksTheStore: true, storeAnswer: { await gate.ask() })

        await client.beginEnvironmentRefinement()
        let asked = await gate.waitUntilAsked()
        XCTAssertTrue(asked)
        gate.answer(
            AppEnvironment.current,
            origin: InstallOrigin(firstInstalledAt: clock.now.addingTimeInterval(-500 * 24 * 3600), evidence: .store))
        await TestSupport.settle(0.3)

        let inherited = await client.pendingEvents().first { $0.event_id == owed.event_id }
        XCTAssertNotNil(inherited, "the inherited event should still be queued")
        XCTAssertNil(inherited?.metadata, "an event the server may already hold must not be rewritten")

        // Still owed, so the next event this run records carries it instead.
        await client.setActive(true)
        await TestSupport.settle(0.3)
        let carried = origins(await client.pendingEvents())
        XCTAssertEqual(carried.count, 1, "the origin waits for a carrier this run recorded")
    }

    /// An event this run put back after a failure the server may have applied is in the same
    /// position as an inherited one: a 5xx or a timeout says nothing about whether the batch was
    /// stored, and a replay of an id the server holds is ignored, metadata and all. The origin
    /// waits for the next carrier instead.
    func testACarrierTheServerMayAlreadyHoldIsNeverStamped() async throws {
        let id = "test.origin.maybedelivered"; isolate(id)
        let clock = TestClock()
        let gate = StoreAnswerGate()
        let client = makeClient(
            appID: id, clock: clock, storeAnswer: { await gate.ask() }, environmentAnswerGrace: 0.2)

        await client.recordInstallIfNeeded()
        RecordingProtocol.script([503])
        await client.flush()  // the grace runs out before the store answers; the send fails after the server saw it
        let attempted = try XCTUnwrap(
            RecordingProtocol.receivedBatches().first?.first { $0.signal == Signal.install })
        let putBack = await client.pendingSignals()
        XCTAssertEqual(putBack, [Signal.install], "put back for a retry")

        gate.answer(
            .appStore,
            origin: InstallOrigin(firstInstalledAt: clock.now.addingTimeInterval(-500 * 24 * 3600), evidence: .store))
        await TestSupport.settle(0.3)
        let afterAnswer = await client.pendingEvents()
        let requeued = try XCTUnwrap(afterAnswer.first { $0.event_id == attempted.event_id })
        XCTAssertNil(requeued.metadata, "an id the server may hold is not rewritten")

        await client.setActive(true)
        await TestSupport.settle(0.2)
        let queued = await client.pendingEvents()
        let carrier = try XCTUnwrap(queued.first { $0.metadata?[InstallOrigin.Key.installedAt] != nil })
        XCTAssertEqual(carrier.signal, Signal.sessionStart, "the origin rides the next carrier the server cannot hold")
        XCTAssertEqual(origins(queued).count, 1)
    }

    /// The other half: a request that never left the device is one the server provably never saw,
    /// so the event it carried is put back as good as new and a late answer may still ride it.
    func testACarrierTheServerNeverSawIsStillStamped() async throws {
        let id = "test.origin.neverconnected"; isolate(id)
        let clock = TestClock()
        let gate = StoreAnswerGate()
        let client = makeClient(
            appID: id, clock: clock, storeAnswer: { await gate.ask() }, environmentAnswerGrace: 0.2)

        await client.recordInstallIfNeeded()
        RecordingProtocol.scriptFailure(.notConnectedToInternet)
        await client.flush()
        let attempted = try XCTUnwrap(
            RecordingProtocol.receivedBatches().first?.first { $0.signal == Signal.install })
        let putBack = await client.pendingSignals()
        XCTAssertEqual(putBack, [Signal.install])

        gate.answer(
            .appStore,
            origin: InstallOrigin(firstInstalledAt: clock.now.addingTimeInterval(-500 * 24 * 3600), evidence: .store))
        let landed = await TestSupport.waitUntilAsync { await !self.origins(client.pendingEvents()).isEmpty }
        XCTAssertTrue(landed, "nothing on the server could have this id, so the install carries the origin")
        let afterAnswer = await client.pendingEvents()
        let stamped = try XCTUnwrap(afterAnswer.first { $0.signal == Signal.install })
        XCTAssertEqual(stamped.event_id, attempted.event_id)
    }

    /// A gate that closes late drops this run's queue, `install` included, and writes that debt
    /// back for the next collecting launch to pay. The origin on it goes back the same way: marked
    /// sent at queue time, it would otherwise count as delivered by a run that delivered nothing,
    /// and the re-recorded `install` would travel without it for good.
    func testAGateThatClosesGivesTheOriginBack() async throws {
        let id = "test.origin.gateclose"; isolate(id)
        let clock = TestClock()
        let gate = StoreAnswerGate()
        var config = TestSupport.configuration(appID: id, enabledEnvironments: [AppEnvironment.current])
        config.firstInstalledAt = clock.now.addingTimeInterval(-300 * 24 * 3600)
        let client = Client(
            config: config.withinBounds(), userID: "u-\(id)", isNewInstall: true, installAt: clock.now,
            session: TestSupport.recordingSession(), now: { clock.now }, asksTheStore: true,
            storeAnswer: { await gate.ask() })

        await client.recordInstallIfNeeded()
        let recorded = await client.pendingEvents()
        XCTAssertEqual(origins(recorded).count, 1, "the app's date rode this run's install")
        await client.beginEnvironmentRefinement()
        let asked = await gate.waitUntilAsked()
        XCTAssertTrue(asked)
        gate.answer(.testFlight)  // not in enabledEnvironments: the gate closes on this run
        await TestSupport.settle(0.3)
        let dropped = await client.pendingEvents()
        XCTAssertTrue(dropped.isEmpty, "the close dropped the queue")

        let next = Client(
            config: config.withinBounds(), userID: "u-\(id)", isNewInstall: false, installAt: clock.now,
            session: TestSupport.recordingSession(), now: { clock.now }, asksTheStore: false)
        await next.recordInstallIfNeeded()
        let queued = await next.pendingEvents()
        XCTAssertEqual(queued.map(\.signal), [Signal.install], "the next collecting launch pays the install debt")
        XCTAssertEqual(origins(queued).count, 1, "and the origin travels with it")
    }

    /// Only a production transaction says when this Apple ID first got the app. The sandbox, which
    /// TestFlight and StoreKit testing both run in, answers every account with one placeholder
    /// purchase date and version, and a placeholder is not evidence.
    func testOnlyAProductionTransactionCarriesTheStoreDate() {
        let purchased = Date(timeIntervalSince1970: 1_375_340_400)
        XCTAssertNil(AppEnvironment.storeOrigin(from: .sandbox, purchased: purchased, originalAppVersion: "1.0"))
        XCTAssertNil(AppEnvironment.storeOrigin(from: .xcode, purchased: purchased, originalAppVersion: "1.0"))
        let real = AppEnvironment.storeOrigin(from: .production, purchased: purchased, originalAppVersion: "312")
        XCTAssertEqual(real?.firstInstalledAt, purchased)
        XCTAssertEqual(real?.evidence, .store)
        XCTAssertEqual(real?.originalAppVersion, "312")
    }

    /// The app's record outranks the store's: the store knows when this Apple ID first downloaded
    /// the app, the app may know the person had an account long before that.
    func testAppSuppliedDateOutranksTheStore() async throws {
        let id = "test.origin.precedence"; isolate(id)
        let clock = TestClock()
        let signup = clock.now.addingTimeInterval(-1000 * 24 * 3600)
        let gate = StoreAnswerGate()
        let client = makeClient(
            appID: id, clock: clock, firstInstalledAt: signup, storeAnswer: { await gate.ask() })

        await client.recordInstallIfNeeded()
        await client.beginEnvironmentRefinement()
        let asked = await gate.waitUntilAsked()
        XCTAssertTrue(asked)
        gate.answer(
            .appStore,
            origin: InstallOrigin(firstInstalledAt: clock.now.addingTimeInterval(-10 * 24 * 3600), evidence: .store))
        await TestSupport.settle(0.3)

        let carried = origins(await client.pendingEvents())
        XCTAssertEqual(carried.count, 1)
        XCTAssertEqual(carried[0][InstallOrigin.Key.evidence], "app")
        XCTAssertEqual(carried[0][InstallOrigin.Key.installedAt], EventCoding.timestamp(signup))
    }

    /// The whole point of the feature, for the installs that need it most: an app already running
    /// an older SDK has a user base counted as new on adoption day. Those installs have nothing
    /// written for the origin, so the first carrier after the upgrade backfills them - no
    /// `install` event is owed or sent, because they had theirs long ago.
    func testExistingInstallBackfillsOnItsNextSession() async throws {
        let id = "test.origin.backfill"; isolate(id)
        let clock = TestClock()
        var config = TestSupport.configuration(appID: id)
        config.firstInstalledAt = clock.now.addingTimeInterval(-200 * 24 * 3600)
        // isNewInstall false: the id was minted by a build that shipped before any of this.
        let client = Client(
            config: config.withinBounds(), userID: "u-\(id)", isNewInstall: false, installAt: clock.now,
            session: TestSupport.recordingSession(), now: { clock.now })

        await client.recordInstallIfNeeded()
        await client.setActive(true)
        await TestSupport.settle(0.3)

        let queued = await client.pendingEvents()
        XCTAssertFalse(queued.map(\.signal).contains(Signal.install), "an old install owes no install event")
        let carried = origins(queued)
        XCTAssertEqual(carried.count, 1, "session.start backfills the origin")
        XCTAssertEqual(carried[0][InstallOrigin.Key.evidence], "app")
    }

    /// A restored handset mints its own install id, and everything under that id in UserDefaults
    /// came off the old device - including the note that says the origin was already sent. The new
    /// install has to send its own or it never gets one.
    func testANewInstallReEarnsItsOrigin() async throws {
        let id = "test.origin.restore"; isolate(id)
        UserDefaults.standard.set(true, forKey: "app.appglance.originSent.\(id)")
        let clock = TestClock()
        let client = makeClient(
            appID: id, clock: clock, firstInstalledAt: clock.now.addingTimeInterval(-30 * 24 * 3600))

        await client.recordInstallIfNeeded()
        let carried = origins(await client.pendingEvents())
        XCTAssertEqual(carried.count, 1, "the old device's note must not silence the new install")
    }

    /// The origin never reaches a signal whose metadata belongs to somebody else: `user.identify`
    /// carries the user's whole property set and the server stores it as sent.
    func testOriginNeverRidesIdentify() async throws {
        let id = "test.origin.identify"; isolate(id)
        let clock = TestClock()
        let client = makeClient(
            appID: id, clock: clock, firstInstalledAt: clock.now.addingTimeInterval(-30 * 24 * 3600))

        await client.identify(["plan": "pro"])
        await TestSupport.settle(0.2)

        let queued = await client.pendingEvents()
        XCTAssertEqual(queued.map(\.signal), [Signal.identify])
        XCTAssertEqual(queued[0].metadata, ["plan": "pro"], "the traits set travels exactly as the app sent it")
    }

    /// An app's own metadata key wins over one the SDK would attach, always.
    func testAppMetadataIsNeverOverwritten() {
        let origin = InstallOrigin(firstInstalledAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: .store)
        let event = Event(
            event_id: "e", session_id: nil, app_id: "a", user_id: "u", signal: Signal.install,
            app_version: "1", os_name: "iOS", os_version: "18", environment: "appstore", country: nil,
            client_ts: Date(), metadata: [InstallOrigin.Key.evidence: "mine"])

        let carried = event.carrying(origin.metadata)
        XCTAssertEqual(carried.metadata?[InstallOrigin.Key.evidence], "mine")
        XCTAssertEqual(
            carried.metadata?[InstallOrigin.Key.installedAt], EventCoding.timestamp(origin.firstInstalledAt),
            "the keys it does not already hold still arrive")
    }
}
