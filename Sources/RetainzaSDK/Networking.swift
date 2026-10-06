import Foundation

/// The HTTP dependency, behind a protocol purely so tests can drive failures.
///
/// Reproducing "offline, then a 503, then success" against a real socket is
/// slow and flaky; against this it is three lines. The offline queue's whole
/// contract is about failure ordering, so that has to be cheap to express.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport.
///
/// `waitsForConnectivity = false` is deliberate: URLSession would otherwise
/// hold a request open for minutes on a flaky connection, which is exactly the
/// case the offline queue exists to handle. Failing fast and queueing preserves
/// event ordering; a long-held request does not.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RetainzaError.network(underlying: "non-HTTP response")
        }
        return (data, http)
    }
}
