import XCTest

@testable import RetainzaSDK

final class RetainzaClientTests: XCTestCase {
    private func makeClient(
        config: RetainzaConfig = .test(),
        transport: MockTransport = MockTransport(),
        clock: TestClock = TestClock()
    ) throws -> RetainzaClient {
        try RetainzaClient(config: config, transport: transport, now: clock.source)
    }

    // MARK: - Key safety

    /// The one thing that must never work. A secret key in an app binary is
    /// extractable by anyone who unzips the IPA, and it reaches the campaign,
    /// segment and send-now APIs.
    func testRefusesASecretKey() {
        XCTAssertThrowsError(try RetainzaClient(config: .test(publicKey: "sk_live_abc"))) { error in
            guard case RetainzaError.configuration = error as? RetainzaError ?? .missingUserId else {
                return XCTFail("expected a configuration error, got \(error)")
            }
        }
    }

    func testAcceptsAPublicKey() throws {
        XCTAssertNoThrow(try makeClient())
    }

    // MARK: - Transport

    func testTrackPostsToTrackWithBearerAuth() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.track("order_placed", properties: ["total": 42.5])

        let records = await transport.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].method, "POST")
        XCTAssertEqual(records[0].path, "/v1/track")
        XCTAssertEqual(records[0].authorization, "Bearer pk_test_abc123")
        XCTAssertTrue(records[0].body.contains("\"event\":\"order_placed\""))
        XCTAssertTrue(records[0].body.contains("\"userId\":\"u1\""))
    }

    /// The timestamp is stamped at call time, not at send time, so an event
    /// that waits in the queue for an hour still records when it happened.
    func testTrackStampsTheCallTimeNotTheSendTime() async throws {
        let clock = TestClock()
        let transport = MockTransport(outcomes: [.offline, .ok])
        let client = try makeClient(transport: transport, clock: clock)

        let stampedAt = clock.now
        try await client.track("offline_event")
        expectEqual(await client.queueSize(), 1)

        clock.advance(ms: 3_600_000)
        _ = await client.flushQueue()

        let bodies = await transport.bodies(forPath: "/v1/track")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(
            bodies[1].contains("\"ts\":\(stampedAt)"),
            "flushed body should carry the original timestamp, got \(bodies[1])"
        )
    }

    func testIdentifyAttachesAutoAttributes() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.identify("u1", attributes: ["plan": "pro"])

        let body = await transport.bodies(forPath: "/v1/identify").first ?? ""
        XCTAssertTrue(body.contains("\"plan\":\"pro\""))
        XCTAssertTrue(body.contains("\"sdk_version\""))
        XCTAssertTrue(body.contains("\"platform\":\"ios\""))
        XCTAssertTrue(body.contains("\"tz\""))
    }

    /// The app always wins. If an integration sets its own `country` from a
    /// billing address, that is a deliberate choice the SDK must not overwrite.
    func testCallSiteAttributesBeatCollectedOnes() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.identify("u1", attributes: [AutoAttribute.country: "JP"])

        let body = await transport.bodies(forPath: "/v1/identify").first ?? ""
        XCTAssertTrue(body.contains("\"country\":\"JP\""))
    }

    /// `setAttributes` is a patch, not a re-statement — it must NOT drag the
    /// whole auto-attribute bag along, or every partial update becomes a full
    /// profile rewrite.
    func testSetAttributesSendsOnlyWhatWasPassed() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.setAttributes(["plan": "pro"])

        let body = await transport.bodies(forPath: "/v1/identify").first ?? ""
        XCTAssertTrue(body.contains("\"plan\":\"pro\""))
        XCTAssertFalse(body.contains("sdk_version"))
        XCTAssertFalse(body.contains("\"tz\""))
    }

    func testProfileFieldsBecomeSnakeCaseAttributesAndColumns() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.identify(
            "u1",
            profile: RetainzaProfile(firstName: "Ada", email: "ada@example.com", locale: "en-IN")
        )

        let body = await transport.bodies(forPath: "/v1/identify").first ?? ""
        XCTAssertTrue(body.contains("\"first_name\":\"Ada\""))
        // email is both an attribute (so filters see it) and a column (so the
        // audience list can show it without unpacking JSON per row).
        XCTAssertTrue(body.contains("\"email\":\"ada@example.com\""))
        XCTAssertTrue(body.contains("\"locale\":\"en-IN\""))
        XCTAssertFalse(body.contains("firstName"))
    }

    // MARK: - Queueing

    func testNetworkFailureQueuesTheCall() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(transport: transport)

        try await client.track("queued_event")

        expectEqual(await client.queueSize(), 1)
    }

    func testServerErrorQueuesTheCall() async throws {
        let transport = MockTransport(outcomes: [.httpError(status: 503)])
        let client = try makeClient(transport: transport)

        try await client.track("queued_event")

        expectEqual(await client.queueSize(), 1)
    }

    /// A 4xx will fail identically forever — a malformed body or a revoked key.
    /// Queueing it would block every event behind it for the life of the app.
    func testClientErrorThrowsAndIsNotQueued() async throws {
        let transport = MockTransport(outcomes: [.httpError(status: 400)])
        let client = try makeClient(transport: transport)

        do {
            try await client.track("bad_event")
            XCTFail("expected a 400 to throw")
        } catch let error as RetainzaError {
            guard case .http(let status, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(status, 400)
        }

        expectEqual(await client.queueSize(), 0)
    }

    /// A stale token is worse than a missing one, so `/token` is never queued —
    /// a token that arrives an hour late may already have been rotated.
    func testRegisterPushIsNeverQueued() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(transport: transport)

        do {
            try await client.registerPush(token: "apns-token")
            XCTFail("expected the offline error to surface")
        } catch {
            // expected
        }

        expectEqual(await client.queueSize(), 0)
    }

    func testFlushSendsQueuedCallsOnceTheNetworkReturns() async throws {
        let transport = MockTransport(outcomes: [.offline, .offline, .ok])
        let client = try makeClient(transport: transport)

        try await client.track("first")
        try await client.track("second")
        expectEqual(await client.queueSize(), 2)

        let result = await client.flushQueue()

        XCTAssertEqual(result.sent, 2)
        XCTAssertEqual(result.remaining, 0)
        expectEqual(await client.queueSize(), 0)
    }

    /// `flushQueue()` as the very FIRST call on a fresh client.
    ///
    /// Initialisation loads the queue, and flushing holds the queue actor
    /// while its send callback runs. Swift survives this because actors are
    /// reentrant; the Kotlin port did NOT — its `Mutex` is not reentrant and
    /// the same code hung outright. Keeping the test on both sides means the
    /// two implementations are held to one behaviour rather than one of them
    /// quietly depending on a language guarantee the other lacks.
    func testFlushQueueAsTheFirstCallDoesNotDeadlock() async throws {
        let client = try makeClient()
        let result = await client.flushQueue()
        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(result.remaining, 0)
    }

    func testQueuedCallsFlushOldestFirst() async throws {
        let transport = MockTransport(outcomes: [.offline, .offline, .ok])
        let client = try makeClient(transport: transport)

        try await client.track("first")
        try await client.track("second")
        _ = await client.flushQueue()

        let bodies = await transport.bodies(forPath: "/v1/track")
        // [0] and [1] are the original failed attempts; the flush follows.
        let flushed = bodies.suffix(2)
        XCTAssertTrue(flushed.first!.contains("\"event\":\"first\""))
        XCTAssertTrue(flushed.last!.contains("\"event\":\"second\""))
    }

    // MARK: - Consent

    /// With `requireConsent` on, nothing leaves the device — not even an
    /// identify — until analytics consent is granted.
    func testRequireConsentBlocksEverythingUntilGranted() async throws {
        let transport = MockTransport()
        let client = try makeClient(config: .test(requireConsent: true), transport: transport)

        try await client.track("too_early")
        try await client.identify("u1")

        expectEqual(await transport.callCount, 0)
    }

    /// Pre-consent calls are DROPPED, not queued. Replaying them once consent
    /// arrives is precisely the thing consent forbids.
    func testPreConsentCallsAreNotQueued() async throws {
        let transport = MockTransport()
        let client = try makeClient(config: .test(requireConsent: true), transport: transport)

        try await client.track("too_early")

        expectEqual(await client.queueSize(), 0)
    }

    func testGrantingConsentAllowsTrafficAndRecordsTheFlag() async throws {
        let transport = MockTransport()
        let client = try makeClient(config: .test(requireConsent: true), transport: transport)

        await client.setConsent(analytics: true)
        try await client.track("now_allowed")

        let paths = await transport.records.map(\.path)
        XCTAssertTrue(paths.contains("/v1/track"))
        let identify = await transport.bodies(forPath: "/v1/identify").first ?? ""
        XCTAssertTrue(identify.contains("\"consent_analytics\":true"))
    }

    /// Marketing consent tags the profile so campaigns can target on it, but
    /// must NOT gate transport — someone can accept product analytics and
    /// refuse promotions, and collapsing the two makes that unrepresentable.
    func testMarketingConsentDoesNotGateTransport() async throws {
        let transport = MockTransport()
        let client = try makeClient(config: .test(requireConsent: true), transport: transport)

        await client.setConsent(marketing: true)
        try await client.track("still_blocked")

        let paths = await transport.records.map(\.path)
        XCTAssertFalse(paths.contains("/v1/track"))
    }

    func testOptOutStopsCollectionAndClearsTheQueue() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(transport: transport)

        try await client.track("queued")
        expectEqual(await client.queueSize(), 1)

        await client.optOut()
        expectEqual(await client.queueSize(), 0)

        await transport.setOutcomes([.ok])
        let before = await transport.callCount
        try await client.track("suppressed")
        expectEqual(await transport.callCount, before)
    }

    func testOptInResumesCollection() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        await client.optOut()
        await client.optIn()
        try await client.track("allowed_again")

        let paths = await transport.records.map(\.path)
        XCTAssertTrue(paths.contains("/v1/track"))
    }

    // MARK: - Identity

    func testResolvesUserFromProviderThenExplicitArgument() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.track("event", userId: "explicit")

        let body = await transport.bodies(forPath: "/v1/track").first ?? ""
        XCTAssertTrue(body.contains("\"userId\":\"explicit\""))
    }

    func testThrowsWhenNoUserIdIsAvailable() async throws {
        let client = try makeClient(config: .test(userId: nil))

        do {
            try await client.track("nobody")
            XCTFail("expected missingUserId")
        } catch let error as RetainzaError {
            guard case .missingUserId = error else { return XCTFail("wrong error \(error)") }
        }
    }

    /// Without this on logout, the next person to use the device inherits the
    /// previous user's identity, queued events and session counters.
    func testResetClearsQueueAndCachedIdentity() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(config: .test(userId: nil), transport: transport)

        try await client.identify("u1")
        expectEqual(await client.queueSize(), 1)

        await client.reset()
        expectEqual(await client.queueSize(), 0)

        // The cached id is gone, so with no provider there is nobody to track.
        do {
            try await client.track("after_logout")
            XCTFail("expected missingUserId after reset")
        } catch let error as RetainzaError {
            guard case .missingUserId = error else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: - Sessions

    func testStartSessionEmitsSessionStartOnceThenResumesSilently() async throws {
        let clock = TestClock()
        let transport = MockTransport()
        let client = try makeClient(
            config: .test(sessionTimeoutMs: 30 * 60_000),
            transport: transport,
            clock: clock
        )

        await client.startSession()
        await client.endSession()
        clock.advance(ms: 60_000)
        await client.startSession()

        let starts = await transport.bodies(forPath: "/v1/track")
            .filter { $0.contains("\"event\":\"session_start\"") }
        XCTAssertEqual(starts.count, 1, "a resume inside the timeout must not emit session_start")
    }

    func testSessionStartAfterTimeoutEmitsASecondEvent() async throws {
        let clock = TestClock()
        let transport = MockTransport()
        let client = try makeClient(
            config: .test(sessionTimeoutMs: 30 * 60_000),
            transport: transport,
            clock: clock
        )

        await client.startSession()
        await client.endSession()
        clock.advance(ms: 31 * 60_000)
        await client.startSession()

        let starts = await transport.bodies(forPath: "/v1/track")
            .filter { $0.contains("\"event\":\"session_start\"") }
        XCTAssertEqual(starts.count, 2)
    }

    /// Session bookkeeping fires from a lifecycle callback the app did not ask
    /// for. A throw there would be an unhandled error in someone else's code,
    /// so these must swallow failures.
    func testSessionCallsDoNotThrowWhenThereIsNoUser() async throws {
        let client = try makeClient(config: .test(userId: nil))

        await client.startSession()
        await client.endSession()
    }

    // MARK: - Base URL

    func testRuntimeBaseURLOverrideIsRefusedByDefault() async throws {
        let client = try makeClient()

        do {
            try await client.setBaseURL("https://evil.example")
            XCTFail("a production build must not allow stored state to redirect telemetry")
        } catch let error as RetainzaError {
            guard case .configuration = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testHealthCheckStripsTheV1Prefix() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        _ = await client.testConnection()

        let paths = await transport.records.map(\.path)
        XCTAssertEqual(paths, ["/health"])
    }
}
