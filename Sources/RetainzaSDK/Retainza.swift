import Foundation

/// Entry point for the Retainza iOS SDK.
///
/// Most apps want exactly one client for the process lifetime, so this holds a
/// shared instance — mirroring `@retainza/react-native`'s singleton, and for the
/// same reason: the offline queue, session counters and consent state are
/// per-device facts, and two clients would each keep half of them.
///
/// ```swift
/// try Retainza.start(with: RetainzaConfig(
///     publicKey: "pk_live_…",
///     userProvider: { AuthStore.shared.userId }
/// ))
///
/// Task { try await Retainza.shared?.track("order_placed", properties: ["total": 42.5]) }
/// ```
///
/// Constructing `RetainzaClient(config:)` directly is fully supported and is what
/// tests should do — the singleton is a convenience, not a requirement.
public enum Retainza {
    /// The base URL used when a host app does not supply one.
    ///
    /// Must end in `/v1`: every endpoint the SDK calls is defined relative to
    /// that prefix, and the one exception (`GET /health`) is resolved against
    /// the origin explicitly rather than by trimming a suffix at call time.
    public static let defaultBaseURL = "https://api.retainza.com/v1"

    /// The prefix every publishable Retainza API key carries.
    ///
    /// A mobile SDK must only ever hold a *public* key. Secret (`sk_`) keys
    /// reach the campaign/segment/send management API, so shipping one inside
    /// an app binary — where anyone can extract it — would hand a project's
    /// entire messaging surface to whoever unzips the IPA. `RetainzaClient`
    /// refuses to initialise with one.
    public static let publicKeyPrefix = "pk_"

    /// The version reported as the `sdk_version` attribute.
    public static var version: String { RetainzaVersion.current }

    /// The shared client, or `nil` before `start(with:)` has been called.
    public private(set) static var shared: RetainzaClient?

    /// Create the shared client.
    ///
    /// Calling this twice replaces the previous client, which is almost always
    /// a mistake — two clients would compete over the same queue and session
    /// keys in storage — so the second call logs a warning. It is not made a
    /// hard error because SwiftUI previews and hot-reload legitimately re-run
    /// app setup.
    @discardableResult
    public static func start(with config: RetainzaConfig) throws -> RetainzaClient {
        if shared != nil {
            RetainzaLog(debugEnabled: config.debug, sink: config.logger)
                .warn("Retainza.start called twice — replacing the existing shared client")
        }
        let client = try RetainzaClient(config: config)
        shared = client
        return client
    }

    /// Drop the shared client. Intended for tests.
    public static func tearDown() {
        shared = nil
    }
}
