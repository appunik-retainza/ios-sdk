import Foundation

/// How the client is configured at init.
///
/// Only `publicKey` is required. Every other default is chosen so that an
/// integration that passes nothing else still behaves correctly in production:
/// persistence on, consent gating off, runtime base-URL overrides off.
public struct RetainzaConfig: Sendable {
    /// The project's PUBLIC key. Must start with `pk_`.
    ///
    /// A secret (`sk_`) key reaches the campaign/segment/send management API.
    /// Shipping one inside an app binary — where anyone can unzip the IPA and
    /// read it — hands a project's entire messaging surface to whoever
    /// bothered, so the client refuses to initialise with one.
    public var publicKey: String

    /// Ingest API base URL. Must end in `/v1`.
    public var baseURL: String

    /// Supplies the current user id, e.g. from your auth layer.
    ///
    /// Authoritative when it returns a value: the id cached by `identify` is
    /// only a fallback. Note that on logout the SDK cannot know your provider
    /// changed — call `reset()`.
    public var userProvider: (@Sendable () -> String?)?

    /// Log every request and swallowed error. Off by default, and when off the
    /// SDK writes nothing to the console.
    public var debug: Bool

    /// Receive log lines instead of the console. See `RetainzaLogSink`.
    public var logger: RetainzaLogSink?

    /// Extra attributes merged into every `identify`. App values win over SDK
    /// ones, and explicit call-site values win over both.
    public var defaultAttributes: (@Sendable () -> [String: AttrValue])?

    /// Persistence for the offline queue, session state and base-URL override.
    ///
    /// Defaults to `UserDefaults`, unlike `sdk-core`, which defaults to
    /// memory-only because it cannot assume a platform. Here we can, and an
    /// offline queue that silently does not survive an app restart is a
    /// footgun rather than a sensible default.
    public var storage: RetainzaStorage?

    /// Offline queue capacity. Oldest events are dropped past this.
    public var maxQueuedEvents: Int

    /// Allow a stored base-URL override to take effect.
    ///
    /// Defaults to the value of `debug`. A production build must never let
    /// stored state redirect telemetry to another host, so leave this off
    /// outside dev builds.
    public var allowRuntimeBaseURL: Bool?

    /// Hold ALL network calls until `setConsent(analytics: true)`.
    ///
    /// Off by default, because turning it on silently would break every
    /// existing integration by dropping their data. On, nothing leaves the
    /// device — not even an identify — which is what a GDPR/CCPA flow needs.
    /// Calls made before consent are dropped, not queued: replaying them later
    /// is the thing consent forbids.
    public var requireConsent: Bool

    /// Background time before the next foreground counts as a new session.
    public var sessionTimeoutMs: Int64

    public init(
        publicKey: String,
        baseURL: String = Retainza.defaultBaseURL,
        userProvider: (@Sendable () -> String?)? = nil,
        debug: Bool = false,
        logger: RetainzaLogSink? = nil,
        defaultAttributes: (@Sendable () -> [String: AttrValue])? = nil,
        storage: RetainzaStorage? = UserDefaultsStorage(),
        maxQueuedEvents: Int = OfflineQueue.defaultMaxItems,
        allowRuntimeBaseURL: Bool? = nil,
        requireConsent: Bool = false,
        sessionTimeoutMs: Int64 = defaultSessionTimeoutMs
    ) {
        self.publicKey = publicKey
        self.baseURL = baseURL
        self.userProvider = userProvider
        self.debug = debug
        self.logger = logger
        self.defaultAttributes = defaultAttributes
        self.storage = storage
        self.maxQueuedEvents = maxQueuedEvents
        self.allowRuntimeBaseURL = allowRuntimeBaseURL
        self.requireConsent = requireConsent
        self.sessionTimeoutMs = sessionTimeoutMs
    }
}
