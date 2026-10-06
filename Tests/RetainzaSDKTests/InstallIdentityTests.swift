import XCTest

@testable import RetainzaSDK

/// Device identity — the contract the dashboard's device list depends on.
///
/// The bug being pinned: before an install id existed the merge key was the
/// APNs/FCM token string, so every rotation looked like a new device and the
/// list only ever grew.
final class InstallIdentityTests: XCTestCase {
    private func makeClient(
        storage: RetainzaStorage?,
        transport: MockTransport,
        clock: TestClock = TestClock()
    ) throws -> RetainzaClient {
        try RetainzaClient(
            config: .test(storage: storage),
            transport: transport,
            now: clock.source
        )
    }

    private func installIds(in records: [MockTransport.Record]) -> [String] {
        records
            .filter { $0.method == "POST" && $0.path.hasSuffix("/token") }
            .compactMap { record in
                guard
                    let data = record.body.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json["installId"] as? String
            }
    }

    func testARotatedTokenKeepsTheSameInstallId() async throws {
        let transport = MockTransport()
        let client = try makeClient(storage: InMemoryStorage(), transport: transport)

        try await client.registerPush(token: "apns_1")
        try await client.registerPush(token: "apns_2")

        let ids = installIds(in: await transport.records)
        expectEqual(ids.count, 2)
        XCTAssertTrue(ids[0].hasPrefix("inst_"))
        XCTAssertEqual(ids[0], ids[1], "a rotation is the same device")
    }

    func testAnUnchangedTokenDoesNotReRegisterEveryLaunch() async throws {
        let transport = MockTransport()
        let client = try makeClient(storage: InMemoryStorage(), transport: transport)

        try await client.registerPush(token: "apns_1")
        try await client.registerPush(token: "apns_1")
        try await client.registerPush(token: "apns_1")
        expectEqual(await transport.callCount, 1, "apps are told to call this on every launch")

        try await client.registerPush(token: "apns_1", force: true)
        expectEqual(await transport.callCount, 2)
    }

    func testTheInstallIdSurvivesReset() async throws {
        let transport = MockTransport()
        let storage = InMemoryStorage()
        let client = try makeClient(storage: storage, transport: transport)

        try await client.registerPush(token: "apns_1")
        await client.reset()
        try await client.registerPush(token: "apns_1")

        let ids = installIds(in: await transport.records)
        expectEqual(ids.count, 2)
        XCTAssertEqual(
            ids[0],
            ids[1],
            "it describes the device, and clearing it would make every sign-in a new phone"
        )
    }

    func testResetUnregistersThisDevice() async throws {
        let transport = MockTransport()
        let client = try makeClient(storage: InMemoryStorage(), transport: transport)

        try await client.registerPush(token: "apns_1")
        await client.reset()

        let deletes = await transport.records.filter { $0.method == "DELETE" }
        XCTAssertEqual(
            deletes.count,
            1,
            "otherwise the next user on this handset inherits the last one's push"
        )
        XCTAssertTrue(deletes[0].path.hasSuffix("/token"))
    }

    func testAFailedUnregisterNeverBreaksLogout() async throws {
        let transport = MockTransport(outcomes: [.offline])
        let client = try makeClient(storage: InMemoryStorage(), transport: transport)
        await client.reset()  // must not throw
    }

    func testWithoutStorageItStillRegisters() async throws {
        let transport = MockTransport()
        let client = try makeClient(storage: nil, transport: transport)

        try await client.registerPush(token: "apns_1")

        expectEqual(await transport.callCount, 1)
        expectEqual(installIds(in: await transport.records), [], "degrades to the old behaviour")
    }
}
