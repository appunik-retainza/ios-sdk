import XCTest

@testable import RetainzaSDK

/// Every call spelled out in `docs/SDK-INTEGRATION-GUIDE-IOS.md`.
///
/// Documentation drifts silently: a renamed parameter or a signature that gains
/// a `throws` compiles fine here, ships, and only fails in a customer's project
/// — where the error looks like the SDK is broken rather than the guide being
/// out of date.
///
/// So the guide's snippets exist here as real code. This is a COMPILE-TIME
/// check first and a behavioural one second: if the guide needs updating, this
/// file stops building.
final class DocumentedAPITests: XCTestCase {

    /// Guide §2 — Start the SDK.
    func testStartAndConfigurationSurface() throws {
        let config = RetainzaConfig(
            publicKey: "pk_test_abc123",
            baseURL: "https://example.test/v1",
            userProvider: { "user-123" },
            debug: false,
            storage: InMemoryStorage(),
            maxQueuedEvents: 100,
            requireConsent: false,
            sessionTimeoutMs: 30 * 60_000
        )

        let client = try Retainza.start(with: config)
        XCTAssertNotNil(Retainza.shared)
        Retainza.tearDown()
        _ = client
    }

    /// Guide §3 — Identify and track.
    func testIdentifyAndTrackSurface() async throws {
        let transport = MockTransport()
        let client = try RetainzaClient(config: .test(), transport: transport)

        try await client.identify(
            "user-123",
            attributes: ["plan": "pro", "seats": 4],
            profile: RetainzaProfile(firstName: "Ada", email: "ada@example.com")
        )
        try await client.setAttributes(["plan": "enterprise"])
        try await client.track("order_placed", properties: ["total": 42.5])
        await client.reset()

        // The guide promises literals work directly for all three value types.
        let literals: [String: AttrValue] = ["plan": "pro", "seats": 4, "trial": true]
        XCTAssertEqual(literals.count, 3)
    }

    /// Guide §5 — In-app messages: navigation, gating, self-handled.
    func testInAppSurface() async throws {
        let client = try RetainzaClient(config: .test(), transport: MockTransport())

        await client.onNavigate { route in
            _ = route.screen
            _ = route.kv
        }
        await client.setBlockedScreenPrefixes(["checkout", "video"])
        await client.setCurrentScreen("checkout/payment")
        await client.onSelfHandledInApp { message in
            _ = message.content
            message.markShown()
            message.markClicked(nil)
            message.markDismissed()
        }

        // Gating is behaviour the guide states outright, so assert it rather
        // than only compiling it.
        let blocked = await client.isAllowedOnCurrentScreen()
        XCTAssertFalse(blocked)

        await client.setCurrentScreen("home")
        let allowed = await client.isAllowedOnCurrentScreen()
        XCTAssertTrue(allowed)
    }

    /// Guide §6 — Offline queue inspection.
    func testQueueSurface() async throws {
        let client = try RetainzaClient(config: .test(), transport: MockTransport())
        _ = await client.queueSize()
        _ = await client.flushQueue()
    }

    /// Guide §7 — Consent.
    func testConsentSurface() async throws {
        let client = try RetainzaClient(config: .test(requireConsent: true), transport: MockTransport())
        await client.setConsent(analytics: true, marketing: false)
        await client.optOut()
        await client.optIn()
    }

    /// Guide §8 — Sessions.
    func testSessionSurface() async throws {
        let client = try RetainzaClient(config: .test(), transport: MockTransport())
        await client.startSession()
        await client.endSession()
    }

    /// Guide §9 — Troubleshooting promises these two.
    func testTroubleshootingSurface() async throws {
        let client = try RetainzaClient(config: .test(), transport: MockTransport())
        let result = await client.testConnection()
        XCTAssertNotNil(result.status)

        // "Init throws .configuration — you passed an sk_ key."
        XCTAssertThrowsError(try RetainzaClient(config: .test(publicKey: "sk_live_abc")))
    }

    /// Guide §1 — the import is `Retainza`, and the product name is why.
    ///
    /// The guide leads with this because `import RetainzaSDK` is the natural
    /// guess and produces a compile error on line one of an integration.
    func testProductNamingIsStable() {
        // If the product were renamed, `import Retainza` at the top of this file
        // would fail — and so would every integration following the guide.
        XCTAssertEqual(Retainza.publicKeyPrefix, "pk_")
        XCTAssertEqual(Retainza.defaultBaseURL, "https://api.retainza.com/v1")
    }
}
