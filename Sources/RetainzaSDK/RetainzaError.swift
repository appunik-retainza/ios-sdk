import Foundation

/// Everything the SDK throws.
///
/// The three cases exist to answer one question at the transport layer: may
/// this call be queued and retried?
///
///  - `network` — never reached the server. Retryable.
///  - `http`    — the server answered. Retryable only for 5xx: a 4xx means a
///                malformed body or a bad key, which will fail identically
///                forever, and queueing it would block every event behind it.
///  - `consent` — suppressed on purpose. Never retryable, because replaying it
///                later is precisely what consent forbids.
///
/// The consent case being an *error* rather than a silent no-op is deliberate:
/// `request` is the single choke point that enforces the gate, and returning
/// normally would make a suppressed call indistinguishable from a delivered
/// one to everything upstream. `postOrQueue` swallows it so host apps never
/// have to catch it on an ordinary `track`.
public enum RetainzaError: Error, Sendable {
    /// The request never reached the server (offline, DNS, TLS, timeout).
    case network(underlying: String)
    /// The server answered with a non-2xx status.
    case http(status: Int, body: String)
    /// Suppressed because analytics consent has not been granted.
    case consent(path: String)
    /// The call needs a user id and none could be resolved.
    case missingUserId
    /// A public key that is not a `pk_` key, or a malformed base URL.
    case configuration(String)

    /// Whether the offline queue should hold this call and try again later.
    public var isRetryable: Bool {
        switch self {
        case .network:
            return true
        case .http(let status, _):
            return status >= 500
        case .consent, .missingUserId, .configuration:
            return false
        }
    }
}

extension RetainzaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network(let underlying):
            return "Retainza: network request failed (\(underlying))"
        case .http(let status, let body):
            return "Retainza: request failed with \(status) \(body)"
        case .consent(let path):
            return "Retainza: \(path) suppressed — analytics consent not granted"
        case .missingUserId:
            return "Retainza: no userId (pass one, call identify, or set userProvider)."
        case .configuration(let message):
            return "Retainza: \(message)"
        }
    }
}
