import XCTest

@testable import RetainzaSDK

final class SessionTests: XCTestCase {
    func testFirstStartCreatesSessionOne() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        let (state, isNew) = await tracker.start()

        XCTAssertTrue(isNew)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.firstAt, clock.now)
        XCTAssertEqual(state.startedAt, clock.now)
        XCTAssertEqual(state.durationTotal, 0)
        XCTAssertFalse(state.id.isEmpty)
    }

    /// The 30-minute rule. A user who taps a push, reads it, and comes back has
    /// not opened the app twice — counting them twice inflates every engagement
    /// metric and silently corrupts "power user" segments.
    func testReturningInsideTheTimeoutResumesTheSameSession() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        let (first, _) = await tracker.start()
        _ = await tracker.pause()
        clock.advance(ms: 29 * 60_000)
        let (second, isNew) = await tracker.start()

        XCTAssertFalse(isNew)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.count, 1)
    }

    func testReturningAfterTheTimeoutStartsANewSession() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        let (first, _) = await tracker.start()
        _ = await tracker.pause()
        clock.advance(ms: 31 * 60_000)
        let (second, isNew) = await tracker.start()

        XCTAssertTrue(isNew)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.count, 2)
        // firstAt is the FIRST session ever, not the current one — it is what
        // "user since" reads from.
        XCTAssertEqual(second.firstAt, first.firstAt)
    }

    func testPauseBanksForegroundTime() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        _ = await tracker.start()
        clock.advance(ms: 5_000)
        let paused = await tracker.pause()

        XCTAssertEqual(paused?.durationTotal, 5_000)
    }

    func testDurationAccumulatesAcrossSessions() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        _ = await tracker.start()
        clock.advance(ms: 5_000)
        _ = await tracker.pause()

        clock.advance(ms: 31 * 60_000)
        _ = await tracker.start()
        clock.advance(ms: 3_000)
        let paused = await tracker.pause()

        XCTAssertEqual(paused?.durationTotal, 8_000)
    }

    func testStateSurvivesARestart() async {
        let clock = TestClock()
        let storage = InMemoryStorage()

        let first = SessionTracker(storage: storage, now: clock.source)
        _ = await first.start()
        _ = await first.pause()

        clock.advance(ms: 31 * 60_000)

        // A fresh tracker over the same storage is what a process kill and
        // relaunch looks like. Without persistence this would report session 1
        // forever, which is the failure the storage adapter exists to prevent.
        let second = SessionTracker(storage: storage, now: clock.source)
        let (state, isNew) = await second.start()

        XCTAssertTrue(isNew)
        XCTAssertEqual(state.count, 2)
    }

    /// Session counters describe the PERSON, not the device. Leaving them
    /// behind on logout would tell the next user they have opened the app 40
    /// times, and would target them with the previous user's lifecycle
    /// campaigns.
    func testResetClearsEverything() async {
        let clock = TestClock()
        let storage = InMemoryStorage()
        let tracker = SessionTracker(storage: storage, now: clock.source)

        _ = await tracker.start()
        await tracker.reset()

        let current = await tracker.current()
        XCTAssertNil(current)

        let fresh = SessionTracker(storage: storage, now: clock.source)
        let (state, _) = await fresh.start()
        XCTAssertEqual(state.count, 1)
    }

    /// `last_session_at` must be `startedAt`, not `lastSeenAt`: a churn segment
    /// asks "when did they last OPEN the app", and `lastSeenAt` moves on every
    /// resume within the timeout window.
    func testSessionAttributesReportStartedAtNotLastSeen() async {
        let clock = TestClock()
        let tracker = SessionTracker(storage: InMemoryStorage(), now: clock.source)

        let (started, _) = await tracker.start()
        clock.advance(ms: 60_000)
        _ = await tracker.pause()
        let state = await tracker.current()!

        let attributes = sessionAttributes(state)
        XCTAssertEqual(attributes[AutoAttribute.lastSessionAt], .number(Double(started.startedAt)))
        XCTAssertEqual(attributes[AutoAttribute.sessionCount], .int(1))
        XCTAssertEqual(attributes[AutoAttribute.sessionDurationTotal], .number(60_000))
    }
}
