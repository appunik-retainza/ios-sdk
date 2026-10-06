import Foundation
import XCTest

@testable import RetainzaSDK

/// A transport whose every response the test decides.
///
/// The offline queue's contract is entirely about *failure ordering* — what is
/// retried, in what order, and what is dropped instead. Expressing that against
/// a real socket is slow and flaky; here "offline, then 503, then success" is
/// three appended values.
actor MockTransport: HTTPTransport {
    enum Outcome {
        case success(status: Int, body: String)
        case httpError(status: Int)
        case offline

        static let ok = Outcome.success(status: 200, body: "{}")
    }

    struct Record: Sendable {
        let method: String
        let path: String
        let body: String
        let authorization: String?
    }

    /// Consumed one per call; the last one repeats once exhausted, so a test
    /// that only cares about the first few calls does not have to pad.
    private var outcomes: [Outcome]
    private(set) var records: [Record] = []

    init(outcomes: [Outcome] = [.ok]) {
        self.outcomes = outcomes
    }

    func setOutcomes(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var callCount: Int { records.count }

    /// Bodies of the calls made to one path, oldest first — the assertion most
    /// queue-ordering tests actually want.
    func bodies(forPath path: String) -> [String] {
        records.filter { $0.path == path }.map(\.body)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        records.append(
            Record(
                method: request.httpMethod ?? "GET",
                path: url.path,
                body: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
        )

        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .ok)

        switch outcome {
        case .offline:
            throw RetainzaError.network(underlying: "test offline")
        case .httpError(let status):
            return (Data("{}".utf8), Self.response(url: url, status: status))
        case .success(let status, let body):
            return (Data(body.utf8), Self.response(url: url, status: status))
        }
    }

    private static func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// A clock the test moves by hand.
///
/// Session rules are defined in terms of *elapsed background time*, so testing
/// them against the real clock would mean either sleeping for 30 minutes or
/// asserting nothing. This makes the 30-minute boundary a single assignment.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var millis: Int64

    init(_ start: Int64 = 1_700_000_000_000) {
        millis = start
    }

    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return millis
    }

    func advance(ms: Int64) {
        lock.lock()
        millis += ms
        lock.unlock()
    }

    /// Passed to the SDK as its time source.
    var source: @Sendable () -> Int64 {
        { [self] in self.now }
    }
}

/// `XCTAssertEqual` takes autoclosures, which cannot contain `await` — so
/// `XCTAssertEqual(await client.queueSize(), 1)` does not compile. This is the
/// same assertion with eagerly-evaluated arguments, so the `await` happens at
/// the call site where it is allowed.
///
/// The alternative is binding every actor read to a local first, which turns
/// each one-line assertion into two and buries what is being checked.
func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

extension RetainzaConfig {
    /// A config with the noise turned off: no console output, memory storage,
    /// and a fixed user so tests do not repeat a `userProvider` closure.
    static func test(
        publicKey: String = "pk_test_abc123",
        storage: RetainzaStorage? = InMemoryStorage(),
        userId: String? = "u1",
        requireConsent: Bool = false,
        maxQueuedEvents: Int = OfflineQueue.defaultMaxItems,
        sessionTimeoutMs: Int64 = defaultSessionTimeoutMs
    ) -> RetainzaConfig {
        RetainzaConfig(
            publicKey: publicKey,
            baseURL: "https://example.test/v1",
            userProvider: userId.map { id in { id } },
            debug: false,
            storage: storage,
            maxQueuedEvents: maxQueuedEvents,
            requireConsent: requireConsent,
            sessionTimeoutMs: sessionTimeoutMs
        )
    }
}
