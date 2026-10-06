import XCTest

@testable import RetainzaSDK

/// Payload parsing is the part of push that has real logic and no device
/// dependency, so it carries the tests. The registrar around it is UIKit
/// plumbing that can only be exercised on a device.
final class RetainzaPushParsingTests: XCTestCase {

    /// The single most important behaviour here. Host apps routinely run a
    /// second push SDK — MoEngage, for example, alongside this one — and an
    /// Retainza handler that claims someone else's notification breaks *their*
    /// campaigns, which is far worse than missing one of ours.
    func testReturnsNilForAForeignPush() {
        XCTAssertNil(parseRetainzaPush(["moe_msg_id": "abc", "title": "Hello"]))
        XCTAssertNil(parseRetainzaPush([:]))
        XCTAssertNil(parseRetainzaPush(nil))
    }

    /// An empty id is not an id. Treating it as one would ack a message the
    /// server cannot attribute, quietly inflating a campaign's delivery count.
    func testReturnsNilForAnEmptyMessageId() {
        XCTAssertNil(parseRetainzaPush(["engage_msg_id": ""]))
    }

    func testParsesTheMinimalPayload() {
        let payload = parseRetainzaPush(["engage_msg_id": "m1"])

        XCTAssertEqual(payload?.msgId, "m1")
        XCTAssertNil(payload?.campaignId)
        XCTAssertNil(payload?.route)
    }

    func testParsesCampaignAndRoute() {
        let payload = parseRetainzaPush([
            "engage_msg_id": "m1",
            "engage_campaign": "c9",
            "engage_route": "order_detail",
        ])

        XCTAssertEqual(payload?.campaignId, "c9")
        XCTAssertEqual(payload?.route, Route(screen: "order_detail", kv: nil))
    }

    func testParsesRouteParameters() {
        let payload = parseRetainzaPush([
            "engage_msg_id": "m1",
            "engage_route": "order_detail",
            "engage_params": #"{"orderId":"A123","tab":"items"}"#,
        ])

        XCTAssertEqual(payload?.route?.kv, ["orderId": "A123", "tab": "items"])
    }

    /// A campaign author can put a number or a boolean in the params JSON. The
    /// app's router expects strings, so these must be coerced rather than
    /// dropped — and must certainly not crash a notification tap.
    ///
    /// The boolean case is the one that bites: `JSONSerialization` boxes both
    /// numbers and booleans as `NSNumber`, so the obvious
    /// `String(describing:)` renders `true` as `"1"` and a router asked for
    /// `promo=1` quietly takes the wrong branch. Integers must likewise not
    /// arrive as `"3.0"`.
    func testCoercesNonStringParametersToStrings() {
        let payload = parseRetainzaPush([
            "engage_msg_id": "m1",
            "engage_route": "cart",
            "engage_params": #"{"count":3,"promo":true,"off":false,"rate":1.5}"#,
        ])

        XCTAssertEqual(payload?.route?.kv?["count"], "3")
        XCTAssertEqual(payload?.route?.kv?["promo"], "true")
        XCTAssertEqual(payload?.route?.kv?["off"], "false")
        XCTAssertEqual(payload?.route?.kv?["rate"], "1.5")
    }

    /// A corrupt params blob must not lose the tap: the user still lands on
    /// the right screen, just without its parameters.
    func testMalformedParametersStillYieldTheRoute() {
        let payload = parseRetainzaPush([
            "engage_msg_id": "m1",
            "engage_route": "cart",
            "engage_params": "{not json",
        ])

        XCTAssertEqual(payload?.route?.screen, "cart")
        XCTAssertNil(payload?.route?.kv)
    }

    /// Params without a route are meaningless — there is no screen to give
    /// them to — and must not produce a route out of thin air.
    func testParametersWithoutARouteProduceNoRoute() {
        let payload = parseRetainzaPush([
            "engage_msg_id": "m1",
            "engage_params": #"{"orderId":"A123"}"#,
        ])

        XCTAssertNil(payload?.route)
    }
}

final class PushAckTests: XCTestCase {
    private func makeClient(
        transport: MockTransport
    ) throws -> RetainzaClient {
        try RetainzaClient(config: .test(), transport: transport, now: TestClock().source)
    }

    func testAckPushPostsToPushAck() async throws {
        let transport = MockTransport()
        let client = try makeClient(transport: transport)

        try await client.ackPush(msgId: "m1", action: .opened)

        let records = await transport.records
        XCTAssertEqual(records.first?.path, "/v1/push/ack")
        XCTAssertTrue(records.first!.body.contains("\"action\":\"opened\""))
        XCTAssertTrue(records.first!.body.contains("\"msgId\":\"m1\""))
    }

    /// A delivery replayed hours later lands in the wrong reporting window and
    /// skews the campaign it belongs to, so acks are never queued — the same
    /// rule that keeps `/token` out of the queue.
    func testAckPushIsNeverQueued() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(transport: transport)

        do {
            try await client.ackPush(msgId: "m1", action: .delivered)
            XCTFail("expected the offline error to surface")
        } catch {
            // expected
        }

        expectEqual(await client.queueSize(), 0)
    }

    func testResolveRouteReachesTheRegisteredNavigator() async throws {
        let client = try makeClient(transport: MockTransport())
        let seen = RouteBox()

        await client.onNavigate { route in
            Task { await seen.set(route) }
        }
        await client.resolveRoute(Route(screen: "order_detail", kv: ["id": "1"]))

        // The handler hops through a Task, so give it a turn to land.
        try await Task.sleep(nanoseconds: 50_000_000)
        let captured = await seen.value
        XCTAssertEqual(captured?.screen, "order_detail")
        XCTAssertEqual(captured?.kv, ["id": "1"])
    }

    /// A tap that goes nowhere is a broken campaign, and the cause — nobody
    /// called `onNavigate` — is invisible without this. It must warn rather
    /// than fail silently, and must never crash the tap.
    func testResolveRouteWithoutANavigatorIsSafe() async throws {
        let client = try makeClient(transport: MockTransport())
        await client.resolveRoute(Route(screen: "nowhere"))
    }
}

private actor RouteBox {
    private(set) var value: Route?
    func set(_ route: Route) { value = route }
}
