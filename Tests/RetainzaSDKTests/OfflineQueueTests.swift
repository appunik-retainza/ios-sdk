import XCTest

@testable import RetainzaSDK

final class BackoffTests: XCTestCase {
    func testBackoffGrowsExponentiallyAndCaps() {
        XCTAssertEqual(backoffMs(0), 1_000)
        XCTAssertEqual(backoffMs(1), 2_000)
        XCTAssertEqual(backoffMs(2), 4_000)
        XCTAssertEqual(backoffMs(8), 256_000)
        // Ceiling, not unbounded growth.
        XCTAssertEqual(backoffMs(9), 300_000)
        XCTAssertEqual(backoffMs(50), 300_000)
    }

    /// A device offline for days reaches a high attempt count. `1000 * 2^62`
    /// overflows Int64 and would trap at runtime, taking the host app with it,
    /// so the exponent is clamped before the shift.
    func testBackoffDoesNotOverflowAtLargeAttemptCounts() {
        XCTAssertEqual(backoffMs(10_000), 300_000)
    }

    func testNegativeAttemptReturnsBase() {
        XCTAssertEqual(backoffMs(-1), 1_000)
    }
}

final class OfflineQueueTests: XCTestCase {
    private func makeCall(_ n: Int, path: QueuePath = .track) -> QueuedCall {
        QueuedCall(path: path, body: "{\"n\":\(n)}", queuedAt: Int64(n), attempts: 0)
    }

    func testEnqueueAndSizeInOrder() async {
        let queue = OfflineQueue(storage: InMemoryStorage(), log: .silent)
        for n in 1...3 { await queue.enqueue(makeCall(n)) }

        let size = await queue.size()
        XCTAssertEqual(size, 3)
        let bodies = await queue.snapshot().map(\.body)
        XCTAssertEqual(bodies, ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"])
    }

    /// Recent behaviour is what triggers campaigns, so a device that has been
    /// offline for a week should send this morning's events, not last week's.
    func testOverflowDropsTheOldest() async {
        let queue = OfflineQueue(max: 3, storage: InMemoryStorage(), log: .silent)
        for n in 1...5 { await queue.enqueue(makeCall(n)) }

        let bodies = await queue.snapshot().map(\.body)
        XCTAssertEqual(bodies, ["{\"n\":3}", "{\"n\":4}", "{\"n\":5}"])
    }

    func testFlushDrainsEverythingWhenSendSucceeds() async {
        let queue = OfflineQueue(storage: InMemoryStorage(), log: .silent)
        for n in 1...3 { await queue.enqueue(makeCall(n)) }

        let sentBodies = SentBodies()
        let result = await queue.flush { call in await sentBodies.append(call.body) }

        XCTAssertEqual(result.sent, 3)
        XCTAssertEqual(result.remaining, 0)
        let recorded = await sentBodies.values
        XCTAssertEqual(recorded, ["{\"n\":1}", "{\"n\":2}", "{\"n\":3}"])
    }

    /// The central ordering guarantee: a mid-flush failure must leave the
    /// failing item at the HEAD. Skipping it and continuing would deliver
    /// event 3 before event 2, and a funnel built on that order is wrong in a
    /// way nobody notices until the numbers are questioned.
    func testFlushStopsAtFirstFailureAndPreservesOrder() async {
        let queue = OfflineQueue(storage: InMemoryStorage(), log: .silent)
        for n in 1...4 { await queue.enqueue(makeCall(n)) }

        struct Boom: Error {}
        let sentBodies = SentBodies()
        let result = await queue.flush { call in
            if call.body == "{\"n\":2}" { throw Boom() }
            await sentBodies.append(call.body)
        }

        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.remaining, 3)
        let remaining = await queue.snapshot().map(\.body)
        XCTAssertEqual(remaining, ["{\"n\":2}", "{\"n\":3}", "{\"n\":4}"])
    }

    func testFailedItemRecordsAnAttempt() async {
        let queue = OfflineQueue(storage: InMemoryStorage(), log: .silent)
        await queue.enqueue(makeCall(1))

        struct Boom: Error {}
        _ = await queue.flush { _ in throw Boom() }
        _ = await queue.flush { _ in throw Boom() }

        let attempts = await queue.snapshot().first?.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testQueueSurvivesARestartWhenStorageIsSupplied() async {
        let storage = InMemoryStorage()
        let first = OfflineQueue(storage: storage, log: .silent)
        await first.enqueue(makeCall(1))
        await first.enqueue(makeCall(2))

        // A fresh queue over the same storage is what an app relaunch looks
        // like — the whole reason persistence exists.
        let second = OfflineQueue(storage: storage, log: .silent)
        await second.load()

        let bodies = await second.snapshot().map(\.body)
        XCTAssertEqual(bodies, ["{\"n\":1}", "{\"n\":2}"])
    }

    func testWithoutStorageTheQueueIsMemoryOnly() async {
        let first = OfflineQueue(storage: nil, log: .silent)
        await first.enqueue(makeCall(1))

        let second = OfflineQueue(storage: nil, log: .silent)
        await second.load()

        let size = await second.size()
        XCTAssertEqual(size, 0)
    }

    /// A partial write or a queue written by an older schema must not crash app
    /// startup, which is exactly where `load()` runs.
    func testCorruptStoredQueueStartsEmptyRatherThanThrowing() async {
        let storage = InMemoryStorage()
        await storage.setItem(OfflineQueue.storageKey, value: "{not json at all")

        let queue = OfflineQueue(storage: storage, log: .silent)
        await queue.load()

        let size = await queue.size()
        XCTAssertEqual(size, 0)
    }

    func testClearEmptiesMemoryAndStorage() async {
        let storage = InMemoryStorage()
        let queue = OfflineQueue(storage: storage, log: .silent)
        await queue.enqueue(makeCall(1))
        await queue.clear()

        expectEqual(await queue.size(), 0)
        let stored = await storage.getItem(OfflineQueue.storageKey)
        XCTAssertNil(stored)
    }
}

/// Collects what a flush handed to the transport, in order.
private actor SentBodies {
    private(set) var values: [String] = []
    func append(_ body: String) { values.append(body) }
}
