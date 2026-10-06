import Foundation

/// The Retainza client.
///
/// A faithful port of `sdk/packages/sdk-core/src/index.ts`, which stays the
/// behavioural source of truth: where the two would disagree, the JS one is
/// right and this is a bug.
///
/// An `actor` because every piece of mutable state here — the cached user id,
/// the consent flags, the retry timer, the resolved base URL — is reachable
/// from whatever thread the host app calls on. A `track` from a background
/// queue racing a `reset` from the main thread is an ordinary thing for an app
/// to do, and it must not be able to interleave into a corrupt state.
public actor RetainzaClient {
    private let config: RetainzaConfig
    private let publicKey: String
    private let configuredBaseURL: String
    private var baseURL: String
    private let allowRuntimeBaseURL: Bool
    private let requireConsent: Bool
    private let storage: RetainzaStorage?
    private let transport: HTTPTransport
    private let log: RetainzaLog
    private let now: @Sendable () -> Int64

    private let queue: OfflineQueue
    private let sessions: SessionTracker
    /// Device identity. Describes the INSTALL, not the person — which is why
    /// `reset()` clears the session tracker and deliberately leaves this alone.
    private let install: InstallId

    static let baseURLKey = "engage.baseUrl.v1"

    /// Identity learned from `identify()`. Only a fallback — `userProvider` is
    /// authoritative when it returns something. `reset()` clears it, which is
    /// what stops one user's data leaking into the next on logout.
    private var cachedUserId: String?

    /// The last permission the app reported, mirrored so a device registration
    /// can carry it.
    ///
    /// Per DEVICE, not per profile: an iPhone may be denied while an iPad is
    /// authorized, and a profile-level value describes whichever reported last
    /// — the difference between "cannot be reached" and "was not reached".
    private var pushPermission: PushPermission?

    /// `nil` = never asked. Only meaningful when `requireConsent` is on.
    private var consentAnalytics: Bool?
    private var consentMarketing: Bool?

    /// Hard opt-out. Deliberately not persisted — see `optOut()`.
    private var optedOut = false

    /// Maps a campaign `Route` onto the host app's router. See `onNavigate`.
    private var navigateHandler: (@Sendable (Route) -> Void)?

    private var inAppHandler: (@Sendable (InAppMessage) -> Void)?
    private var selfHandledHandler: (@Sendable (SelfHandledInApp) -> Void)?
    private var pollTask: Task<Void, Never>?

    /// Where the user is, and where messages must not appear. See
    /// `setCurrentScreen` / `setBlockedScreenPrefixes`.
    private var currentScreen: String?
    private var blockedScreenPrefixes: [String] = []

    private var ready = false
    private var flushing = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    // MARK: - Init

    public init(config: RetainzaConfig) throws {
        try self.init(config: config, transport: URLSessionTransport())
    }

    init(
        config: RetainzaConfig,
        transport: HTTPTransport,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        guard config.publicKey.hasPrefix(Retainza.publicKeyPrefix) else {
            throw RetainzaError.configuration(
                "expected a public key (pk_...). Never ship a secret key in an app binary."
            )
        }

        self.config = config
        self.publicKey = config.publicKey
        self.configuredBaseURL = Self.trimTrailingSlash(config.baseURL)
        self.baseURL = self.configuredBaseURL
        self.allowRuntimeBaseURL = config.allowRuntimeBaseURL ?? config.debug
        self.requireConsent = config.requireConsent
        self.storage = config.storage
        self.transport = transport
        self.now = now
        self.log = RetainzaLog(debugEnabled: config.debug, sink: config.logger)

        self.queue = OfflineQueue(
            max: config.maxQueuedEvents,
            storage: config.storage,
            log: self.log
        )
        self.sessions = SessionTracker(
            storage: config.storage,
            timeoutMs: config.sessionTimeoutMs,
            now: now
        )
        self.install = InstallId(storage: config.storage, now: now)

        // Key prefix only — never the whole key, which would put a credential
        // into a log file or a crash report.
        self.log.debug(
            "client created (baseURL: \(self.baseURL), key: \(config.publicKey.prefix(11))…, "
                + "storage: \(config.storage != nil), sdk: \(RetainzaVersion.current))"
        )
    }

    // MARK: - Base URL

    /// Resolve the effective base URL and rehydrate the queue.
    ///
    /// Runs once; every public call awaits it, so a stored override applies to
    /// the very first request rather than the second.
    private func ensureReady() async {
        if ready { return }
        ready = true
        await queue.load()
        guard allowRuntimeBaseURL, let storage else { return }
        if let stored = await storage.getItem(Self.baseURLKey), !stored.isEmpty {
            baseURL = Self.trimTrailingSlash(stored)
            log.debug("base URL override in effect: \(baseURL)")
        }
    }

    /// The base URL requests will actually go to (stored > configured).
    public func getBaseURL() async -> String {
        await ensureReady()
        return baseURL
    }

    /// Point the SDK at a different backend at runtime and remember it.
    ///
    /// This exists because the base URL is otherwise baked into the app binary
    /// at build time: when the backend hostname changes, every installed build
    /// silently loses its backend and only a new App Store release recovers it.
    /// With this, that costs typing a URL into a dev screen.
    ///
    /// Refused unless `allowRuntimeBaseURL` (or `debug`) is on — stored state
    /// must never be able to redirect a production app's telemetry elsewhere.
    public func setBaseURL(_ url: String) async throws {
        guard allowRuntimeBaseURL else {
            throw RetainzaError.configuration(
                "base URL overrides are disabled. Set allowRuntimeBaseURL (or debug) in dev builds."
            )
        }
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            throw RetainzaError.configuration("base URL must start with http:// or https://")
        }
        await ensureReady()
        baseURL = Self.trimTrailingSlash(url)
        await storage?.setItem(Self.baseURLKey, value: baseURL)
        log.debug("base URL set to \(baseURL)")
    }

    /// Forget a stored override and fall back to the configured URL.
    public func clearBaseURL() async {
        await ensureReady()
        baseURL = configuredBaseURL
        await storage?.removeItem(Self.baseURLKey)
        log.debug("base URL reset to \(baseURL)")
    }

    /// Is the backend reachable?
    ///
    /// Hits `/health` on the API root, one level above the `/v1` ingest prefix.
    /// For a "test connection" button on a dev screen.
    public func testConnection() async -> (ok: Bool, status: Int?) {
        let base = await getBaseURL()
        let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
        guard let url = URL(string: "\(root)/health") else { return (false, nil) }
        do {
            let (_, response) = try await transport.send(URLRequest(url: url))
            log.debug("health \(response.statusCode)")
            return ((200..<300).contains(response.statusCode), response.statusCode)
        } catch {
            log.warn("health check failed", error)
            return (false, nil)
        }
    }

    // MARK: - Identity

    private func resolveUserId(_ explicit: String?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let provided = config.userProvider?(), !provided.isEmpty { return provided }
        if let cachedUserId, !cachedUserId.isEmpty { return cachedUserId }
        throw RetainzaError.missingUserId
    }

    /// Clear client-side identity: cached user id, queued events, session
    /// counters and the retry timer. **Call this on logout.**
    ///
    /// Without it the next person to use the device inherits the previous
    /// user's identity and messages. This is not a GDPR erasure — the
    /// server-side profile is untouched (that is `DELETE /v1/users/:id`).
    ///
    /// Note that `userProvider` is owned by the host app: if yours still
    /// returns the old id after logout, the SDK will use it.
    public func reset() async {
        // FIRST, while the identity it needs is still here: hand this device
        // back. Without it the profile keeps the push token forever and the
        // next person to sign in on this handset receives the previous user's
        // campaigns — the server-side claim on their first registration is the
        // backstop, not the primary fix.
        await unregisterPush()
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        cachedUserId = nil
        await queue.clear()
        // Session counters describe the PERSON, not the device: leaving them
        // behind would tell the next user they have opened the app 40 times.
        await sessions.reset()
        // The install id is deliberately NOT cleared: it describes the DEVICE,
        // and the device is the same one after a logout.
        log.debug("reset — identity, session and queue cleared")
    }

    // MARK: - Transport

    /// Whether anything may leave the device right now.
    ///
    /// Enforced at the transport, not at each call site — a gate that every new
    /// method has to remember to check is a gate that leaks the first time
    /// someone adds a method.
    private func allowed() -> Bool {
        if optedOut { return false }
        if !requireConsent { return true }
        return consentAnalytics == true
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard allowed() else {
            log.debug("\(method) \(path) suppressed — no consent")
            throw RetainzaError.consent(path: path)
        }
        await ensureReady()

        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw RetainzaError.configuration("could not build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as RetainzaError {
            throw error
        } catch {
            log.warn("\(method) \(path) — network error", error)
            throw RetainzaError.network(underlying: error.localizedDescription)
        }

        log.debug("\(method) \(path) → \(response.statusCode)")
        guard (200..<300).contains(response.statusCode) else {
            throw RetainzaError.http(
                status: response.statusCode,
                body: String(decoding: data.prefix(512), as: UTF8.self)
            )
        }
        return data
    }

    /// Send, or queue for later if the failure looks transient.
    ///
    /// Network errors and 5xx are retried; a 4xx is not — a malformed body or a
    /// bad key will fail the same way forever, and queueing it would block
    /// every event behind it.
    private func postOrQueue(_ path: QueuePath, body: Data) async throws {
        do {
            try await request("POST", path.rawValue, body: body)
            // A successful send is the best possible signal that connectivity
            // is back, so opportunistically drain anything already queued.
            Task { await self.flushQueue() }
        } catch let error as RetainzaError {
            // Suppressed-for-consent is a decision, not a failure: it must not
            // be queued (replaying it later is what consent forbids) and must
            // not surface as an error the host app has to catch on every call.
            if case .consent = error { return }
            guard error.isRetryable else { throw error }
            await queue.enqueue(
                QueuedCall(
                    path: path,
                    body: String(decoding: body, as: UTF8.self),
                    queuedAt: now(),
                    attempts: 0
                )
            )
            log.debug("queued \(path.rawValue) for retry (\(await queue.size()) pending)")
            scheduleRetry()
        }
    }

    /// Drain the offline queue. Safe to call at any time; re-entrancy guarded.
    @discardableResult
    public func flushQueue() async -> (sent: Int, remaining: Int) {
        if flushing { return (0, await queue.size()) }
        flushing = true
        defer { flushing = false }

        let result = await queue.flush { call in
            try await self.request("POST", call.path.rawValue, body: Data(call.body.utf8))
        }
        if result.sent > 0 { log.debug("flushed \(result.sent) queued call(s)") }
        if result.remaining > 0 {
            scheduleRetry()
        } else {
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
        }
        return result
    }

    /// How many calls are waiting to be sent.
    public func queueSize() async -> Int {
        await queue.size()
    }

    private func scheduleRetry() {
        if retryTask != nil { return }
        let delay = backoffMs(retryAttempt)
        retryAttempt += 1
        log.debug("retrying queued calls in \(delay)ms")
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.clearRetryTask()
            await self.flushQueue()
        }
    }

    private func clearRetryTask() {
        retryTask = nil
    }

    // MARK: - Ingest

    /// Everything the SDK knows about the device, merged with what the app
    /// passed. App values always win.
    private func buildAttributes(_ attributes: [String: AttrValue]) -> [String: AttrValue] {
        Attributes.merge(Attributes.collect(), config.defaultAttributes?(), attributes)
    }

    /// Upsert the current user's profile.
    ///
    /// Auto attributes are attached on every call so they never go stale — an
    /// app that upgrades iOS versions reports the new one on its next identify
    /// without the integration doing anything.
    public func identify(
        _ userId: String,
        attributes: [String: AttrValue] = [:],
        profile: RetainzaProfile = RetainzaProfile()
    ) async throws {
        // Reserved identity (first_name, phone, …) folds into the SAME
        // attribute bag as everything else, so a segment on "has a phone
        // number" is written exactly like one on a custom attribute. `email`
        // and `locale` additionally ride as columns, which is what lets the
        // audience list show an address without unpacking JSON per row.
        let (identity, email, locale) = profile.attributesAndColumns()
        let session = await sessions.current()

        var supplied: [String: AttrValue] = [:]
        if let session { supplied = sessionAttributes(session) }
        supplied.merge(identity) { _, new in new }
        supplied.merge(attributes) { _, new in new }

        let merged = buildAttributes(supplied)
        cachedUserId = userId
        // Attribute NAMES only. The values are user data and never logged.
        log.debug("identify \(userId) [\(merged.keys.sorted().joined(separator: ", "))]")

        let payload = IdentifyBody(userId: userId, attributes: merged, email: email, locale: locale)
        try await postOrQueue(.identify, body: try JSONEncoder().encode(payload))
    }

    /// Update some attributes without touching the rest.
    ///
    /// The server merges, so this is a patch, not a re-statement of the
    /// profile — unlike `identify`, it sends ONLY what you pass and does not
    /// attach auto attributes.
    public func setAttributes(_ attributes: [String: AttrValue], userId: String? = nil) async throws {
        let uid = try resolveUserId(userId)
        log.debug("setAttributes \(uid) [\(attributes.keys.sorted().joined(separator: ", "))]")
        let payload = IdentifyBody(userId: uid, attributes: attributes, email: nil, locale: nil)
        try await postOrQueue(.identify, body: try JSONEncoder().encode(payload))
    }

    // MARK: - Collections

    /// Add or update one item in a collection — one-to-many custom data such as
    /// a user's challenges, badges or saved searches.
    ///
    /// The id is the merge key, so a replay from the offline queue upserts the
    /// same item rather than appending a second copy. Fields you do not send
    /// are preserved — this is a patch on the item, not a restatement of it.
    public func addToCollection(
        _ collection: String,
        item: CollectionItem,
        userId: String? = nil
    ) async throws {
        let uid = try resolveUserId(userId)
        log.debug("addToCollection \(collection)/\(item.id)")
        let body = CollectionsBody(userId: uid, ops: [
            .init(collection: collection, action: "upsert", item: item, id: nil),
        ])
        try await postOrQueue(.collections, body: try JSONEncoder().encode(body))
    }

    /// Convenience for an id with no fields.
    public func addToCollection(
        _ collection: String,
        id: String,
        userId: String? = nil
    ) async throws {
        try await addToCollection(collection, item: CollectionItem(id), userId: userId)
    }

    /// Remove one item by id. Removing an id that is not there is a no-op.
    public func removeFromCollection(
        _ collection: String,
        id: String,
        userId: String? = nil
    ) async throws {
        let uid = try resolveUserId(userId)
        log.debug("removeFromCollection \(collection)/\(id)")
        let body = CollectionsBody(userId: uid, ops: [
            .init(collection: collection, action: "remove", item: nil, id: id),
        ])
        try await postOrQueue(.collections, body: try JSONEncoder().encode(body))
    }

    /// Replace a collection wholesale. An empty array clears it.
    ///
    /// Unlike `addToCollection` this is NOT idempotent-by-merge — it states the
    /// entire list, so the last writer wins. Use it when the app already holds
    /// the full list (a sync on launch); use `addToCollection` for incremental
    /// changes.
    public func setCollection(
        _ collection: String,
        items: [CollectionItem],
        userId: String? = nil
    ) async throws {
        let uid = try resolveUserId(userId)
        log.debug("setCollection \(collection) [\(items.count)]")
        // `clear` then one upsert per item, in ONE request: the ops list is
        // applied in order under the profile's row lock server-side, so the
        // collection is never observably half-empty.
        var ops: [CollectionsBody.Op] = [
            .init(collection: collection, action: "clear", item: nil, id: nil),
        ]
        for item in items {
            ops.append(.init(collection: collection, action: "upsert", item: item, id: nil))
        }
        try await postOrQueue(.collections, body: try JSONEncoder().encode(CollectionsBody(userId: uid, ops: ops)))
    }

    /// Record an event; the server evaluates event-triggered campaigns.
    ///
    /// The timestamp is stamped here, not on the server, so an event that has
    /// to wait in the offline queue still records when it actually happened.
    public func track(
        _ event: String,
        properties: [String: AttrValue] = [:],
        userId: String? = nil
    ) async throws {
        let uid = try resolveUserId(userId)
        log.debug("track \(event) [\(properties.keys.sorted().joined(separator: ", "))]")
        let payload = TrackBody(userId: uid, event: event, properties: properties, ts: now())
        try await postOrQueue(.track, body: try JSONEncoder().encode(payload))
    }

    /// Register a device push token.
    ///
    /// Never queued: a token that arrives late may already have been rotated,
    /// and pushing to a stale token is worse than not registering at all.
    ///
    /// Carries this install's id, so the server can tell a ROTATED token (same
    /// device, new string — replace it) from a second device, along with the
    /// device facts the SDK already collects so the dashboard can name a device
    /// rather than show a platform word and a token prefix.
    ///
    /// Safe to call on every launch: an unchanged token is re-sent at most once
    /// a day. Pass `force: true` to override that.
    public func registerPush(token: String, userId: String? = nil, force: Bool = false) async throws {
        let uid = try resolveUserId(userId)
        if !force, await !install.shouldRegister(token) {
            log.debug("registerPush skipped — unchanged token, registered < 24h ago")
            return
        }
        let installId = await install.get()
        log.debug("registerPush \(token.prefix(12))… [install: \(installId ?? "none")]")
        let context = Attributes.collect()
        // Every field past `platform` is optional server-side, and a nil is
        // omitted from the JSON — so a device that knows nothing sends the same
        // three-field body a pre-identity build did.
        let payload = TokenBody(
            userId: uid,
            token: token,
            platform: .ios,
            installId: installId,
            sdkVersion: RetainzaVersion.current,
            appVersion: context.string(AutoAttribute.appVersion),
            deviceModel: context.string(AutoAttribute.deviceModel),
            osName: context.string(AutoAttribute.osName),
            osVersion: context.string(AutoAttribute.osVersion),
            tz: context.string(AutoAttribute.timezone),
            pushPermission: pushPermission?.rawValue
        )
        try await request("POST", "/token", body: try JSONEncoder().encode(payload))
        await install.markRegistered(token)
    }

    /// Unregister this device from the current user — call on logout.
    ///
    /// `reset()` already does this; it is public for an app that tears identity
    /// down its own way. Best-effort by design: a sign-out must not fail
    /// because the network is down or the server has nothing to forget.
    public func unregisterPush(token: String? = nil, userId: String? = nil) async {
        let installId = await install.get()
        if installId == nil, token == nil {
            log.debug("unregisterPush skipped — nothing identifies this device")
            return
        }
        guard let uid = userId ?? cachedUserId ?? config.userProvider?() else {
            log.debug("unregisterPush skipped — no userId")
            return
        }
        // Query params rather than a body: a DELETE carrying one is legal but
        // awkward for enough HTTP stacks that the route accepts either shape.
        var items = [URLQueryItem(name: "userId", value: uid)]
        if let installId { items.append(URLQueryItem(name: "installId", value: installId)) }
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        var components = URLComponents()
        components.queryItems = items
        let query = components.percentEncodedQuery ?? ""
        do {
            _ = try await request("DELETE", "/token?\(query)", body: nil)
            log.debug("unregistered this device")
        } catch {
            // Logging out with no network is normal. The server-side claim on
            // the NEXT user's registration is the backstop that recovers it.
            log.debug("unregisterPush failed (ignored): \(error)")
        }
        await install.clearRegistration()
    }

    /// Report the OS-level notification permission.
    ///
    /// `RetainzaPush.requestAuthorization` reports this for you; call it directly
    /// only if your app prompts through its own code path. This is the
    /// difference between "has a token" and "can actually be reached" — a
    /// revoked permission leaves a perfectly valid token behind that silently
    /// drops every push.
    public func setPushPermission(_ status: PushPermission, userId: String? = nil) async throws {
        log.debug("push permission: \(status.rawValue)")
        // Remembered for the next device registration as well as written to the
        // profile — the profile answers "did this person allow notifications",
        // the device entry answers "can THIS handset be reached".
        pushPermission = status
        try await setAttributes([AutoAttribute.pushPermission: .string(status.rawValue)], userId: userId)
    }

    /// Report a push delivery or open.
    ///
    /// APNs has no delivery receipt and neither does FCM, so this is the only
    /// source of `delivered` / `opened` for push — every campaign open-rate in
    /// the dashboard is built from these calls. Deliberately fire-and-forget:
    /// a failed ack must never delay or block opening the app.
    ///
    /// Not queued, for the same reason the ack endpoints never are: a delivery
    /// replayed hours later would land in the wrong reporting window and skew
    /// the campaign it belongs to.
    public func ackPush(msgId: String, action: PushAction, userId: String? = nil) async throws {
        let uid = try resolveUserId(userId)
        log.debug("ackPush \(action.rawValue) \(msgId)")
        let payload = PushAckBody(userId: uid, msgId: msgId, action: action.rawValue)
        try await request("POST", "/push/ack", body: try JSONEncoder().encode(payload))
    }

    // MARK: - In-app messages

    /// Fetch the messages queued for a user (a single poll).
    public func fetchPendingInApp(userId: String? = nil) async throws -> [InAppMessage] {
        let uid = try resolveUserId(userId)
        let escaped = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uid
        let data = try await request("GET", "/inapp/pending?userId=\(escaped)", body: nil)
        let envelope = try JSONDecoder().decode(PendingInAppResponse.self, from: data)
        return envelope.messages
    }

    /// Report an in-app interaction, for frequency caps and analytics.
    ///
    /// Not queued: a `shown` replayed hours later would tell the server a
    /// message was displayed at a time the user was not even in the app, and
    /// frequency caps read these to decide what to send next.
    public func ackInApp(msgId: String, action: InAppAction, userId: String? = nil) async throws {
        let uid = try resolveUserId(userId)
        log.debug("ackInApp \(action.rawValue) \(msgId)")
        let payload = InAppAckBody(userId: uid, msgId: msgId, action: action.rawValue)
        try await request("POST", "/inapp/ack", body: try JSONEncoder().encode(payload))
    }

    /// Register the renderer for incoming in-app messages.
    ///
    /// `RetainzaInAppHost` calls this for you. Register your own only if you are
    /// replacing the built-in presentation entirely.
    public func onInApp(_ handler: @escaping @Sendable (InAppMessage) -> Void) {
        inAppHandler = handler
    }

    /// Register a handler for `selfhandled` campaigns.
    ///
    /// The SDK draws nothing for these — the app gets the payload and renders
    /// it with its own design system. In exchange the app owns the acks, which
    /// is why the handle carries them: analytics only stays honest if they are
    /// sent.
    public func onSelfHandledInApp(_ handler: @escaping @Sendable (SelfHandledInApp) -> Void) {
        selfHandledHandler = handler
    }

    /// Tell the SDK which screen the user is on, for gating.
    ///
    /// A message that arrives during checkout or a video player should wait,
    /// not interrupt. Blocked messages are left **pending** rather than
    /// consumed, so the campaign shows on the next poll once the user moves on.
    public func setCurrentScreen(_ screen: String?) {
        currentScreen = screen
    }

    /// Screens (by prefix) where no in-app message may appear.
    public func setBlockedScreenPrefixes(_ prefixes: [String]) {
        blockedScreenPrefixes = prefixes
    }

    /// Whether a message may be shown on the current screen right now.
    func isAllowedOnCurrentScreen() -> Bool {
        guard let currentScreen else { return true }
        return !blockedScreenPrefixes.contains { !$0.isEmpty && currentScreen.hasPrefix($0) }
    }

    /// Hand a message to the app's renderer.
    ///
    /// Returns whether the message was consumed. `false` means it stays pending
    /// and the next poll will offer it again — the case for a blocked screen,
    /// and for a `selfhandled` message with no handler registered. A campaign
    /// must not disappear because the integration is half-done.
    @discardableResult
    public func deliverInApp(_ message: InAppMessage) async -> Bool {
        guard isAllowedOnCurrentScreen() else {
            log.debug("in-app \(message.msgId) held — screen \(currentScreen ?? "?") is blocked")
            return false
        }

        if message.template == .selfhandled {
            guard let selfHandledHandler else {
                // No ack, so the message stays pending. The warning names the
                // call that would fix it.
                log.warn(
                    "in-app message \(message.msgId) is self-handled but no handler is registered "
                        + "— call onSelfHandledInApp(_:). The message stays queued."
                )
                return false
            }
            // Deliberately NO auto-ack: a message the app chose not to draw was
            // not shown, and `shown` is what the funnel counts as delivered.
            selfHandledHandler(makeSelfHandled(message))
            return true
        }

        guard let inAppHandler else {
            log.warn(
                "in-app message \(message.msgId) has no renderer — mount RetainzaInAppHost or call "
                    + "onInApp(_:). The message stays queued."
            )
            return false
        }

        inAppHandler(message)
        try? await ackInApp(msgId: message.msgId, action: .shown)
        return true
    }

    /// Poll for in-app messages and hand each to the registered renderer.
    ///
    /// Returns a stop function. Only one poll loop runs at a time — a second
    /// call replaces the first, so a view that mounts twice cannot double the
    /// request rate.
    @discardableResult
    public func startInAppPolling(
        intervalMs: Int = 15_000,
        userId: String? = nil
    ) -> @Sendable () -> Void {
        pollTask?.cancel()

        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let messages = try await self.fetchPendingInApp(userId: userId)
                    await self.logPublic(.debug, "in-app poll → \(messages.count) message(s)")
                    for message in messages {
                        if Task.isCancelled { return }
                        // One at a time: stop at the first message the renderer
                        // actually took, so two campaigns never stack on screen.
                        if await self.deliverInApp(message) { break }
                    }
                } catch {
                    // Transient failures are expected — a poll loop that gave
                    // up on the first network blip would never recover.
                    await self.logPublic(.debug, "in-app poll failed: \(error)")
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
        pollTask = task

        return { task.cancel() }
    }

    /// Stop the poll loop started by `startInAppPolling`.
    public func stopInAppPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Wrap a message with the acks a self-handled renderer must send itself.
    private func makeSelfHandled(_ message: InAppMessage) -> SelfHandledInApp {
        SelfHandledInApp(
            message: message,
            markShown: { [weak self] in
                Task { try? await self?.ackInApp(msgId: message.msgId, action: .shown) }
            },
            markClicked: { [weak self] route in
                Task {
                    try? await self?.ackInApp(msgId: message.msgId, action: .clicked)
                    if let target = route ?? message.route?.asRoute {
                        await self?.resolveRoute(target)
                    }
                }
            },
            markDismissed: { [weak self] in
                Task { try? await self?.ackInApp(msgId: message.msgId, action: .dismissed) }
            }
        )
    }

    /// Emit a line through the SDK's own logger and debug switch.
    ///
    /// For code layered on top of the client — the push registrar, and the
    /// in-app UI in a later phase — so their diagnostics obey `debug` and reach
    /// the host's `logger` instead of inventing a second logging channel that
    /// stays noisy in production.
    public func logPublic(_ level: RetainzaLogLevel, _ message: String) {
        switch level {
        case .debug: log.debug(message)
        case .warn: log.warn(message)
        case .error: log.error(message)
        }
    }

    // MARK: - Navigation

    /// Register a navigator that maps a `Route` to your app's router.
    ///
    /// Without one, a notification tap still acks correctly but goes nowhere —
    /// which is why `resolveRoute` logs when no handler is registered rather
    /// than failing silently.
    public func onNavigate(_ handler: @escaping @Sendable (Route) -> Void) {
        navigateHandler = handler
    }

    /// Hand a route to the registered navigator.
    public func resolveRoute(_ route: Route) {
        guard let navigateHandler else {
            log.warn(
                "route \"\(route.screen)\" has nowhere to go — call onNavigate(_:) to wire your router"
            )
            return
        }
        navigateHandler(route)
    }

    // MARK: - Sessions

    /// The app entered the foreground.
    ///
    /// Emits `session_start` only for a genuinely new session, and refreshes
    /// the session attributes on the profile so "opened the app 12 times" is
    /// queryable without the app tracking anything itself.
    public func startSession(userId: String? = nil) async {
        let (state, isNew) = await sessions.start()
        guard isNew else {
            log.debug("session resumed (\(state.id))")
            return
        }
        log.debug("session \(state.count) started (\(state.id))")
        // Session bookkeeping must never surface as an error to the host app:
        // these fire from a lifecycle callback the app did not ask for, and a
        // throw there would be an unhandled crash in someone else's code.
        try? await setAttributes(sessionAttributes(state), userId: userId)
        try? await track(
            "session_start",
            properties: ["session_id": .string(state.id), "session_number": .int(state.count)],
            userId: userId
        )
    }

    /// The app left the foreground. Banks the elapsed time.
    public func endSession(userId: String? = nil) async {
        guard let state = await sessions.pause() else { return }
        log.debug("session paused (\(state.id))")
        try? await setAttributes(sessionAttributes(state), userId: userId)
    }

    // MARK: - Consent

    /// Record the user's consent.
    ///
    /// With `requireConsent` on, nothing at all is sent until `analytics` is
    /// true. `marketing` does **not** gate transport — it is stored on the
    /// profile as `consent_marketing` so campaigns can target or exclude on it.
    /// That split matters: someone can consent to product analytics and refuse
    /// promotions, and collapsing the two makes that unrepresentable.
    public func setConsent(
        analytics: Bool? = nil,
        marketing: Bool? = nil,
        userId: String? = nil
    ) async {
        let wasAllowed = allowed()
        if let analytics { consentAnalytics = analytics }
        if let marketing { consentMarketing = marketing }
        log.debug("consent updated (analytics: \(analytics as Any), marketing: \(marketing as Any))")

        guard allowed() else { return }

        var attributes: [String: AttrValue] = [:]
        if let marketing { attributes[ConsentAttribute.marketing] = .bool(marketing) }
        if let analytics { attributes[ConsentAttribute.analytics] = .bool(analytics) }
        if !attributes.isEmpty {
            try? await setAttributes(attributes, userId: userId)
        }

        // Consent just turned on: the queue may hold calls from before this
        // build enforced it (an app upgrade), so drain now rather than waiting
        // for the next call to trigger a flush.
        if !wasAllowed { await flushQueue() }
    }

    /// Stop everything until the next launch, and drop whatever is pending.
    ///
    /// Deliberately **not persisted**: an opt-out the SDK remembers is an
    /// opt-out the app cannot see, and the app is the thing with the consent
    /// UI. Re-assert it on each launch from your own stored preference.
    public func optOut() async {
        optedOut = true
        await queue.clear()
        retryTask?.cancel()
        retryTask = nil
        log.debug("opted out — all collection stopped")
    }

    /// Resume after `optOut`.
    public func optIn() {
        optedOut = false
        log.debug("opted back in")
    }

    // MARK: - Helpers

    private static func trimTrailingSlash(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}

// MARK: - Wire bodies

/// `POST /v1/identify`
///
/// `email` and `locale` are omitted entirely when absent rather than sent as
/// null — a null would clear a value the server already holds.
private struct IdentifyBody: Encodable {
    let userId: String
    let attributes: [String: AttrValue]
    let email: String?
    let locale: String?
}

/// `POST /v1/collections`
private struct CollectionsBody: Encodable {
    let userId: String
    let ops: [Op]

    /// One op. `item` and `id` are mutually exclusive by action, and each is
    /// omitted entirely when nil rather than sent as null — the server rejects
    /// a `remove` carrying an `item`.
    struct Op: Encodable {
        let collection: String
        let action: String
        let item: CollectionItem?
        let id: String?

        private enum CodingKeys: String, CodingKey { case collection, action, item, id }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(collection, forKey: .collection)
            try container.encode(action, forKey: .action)
            try container.encodeIfPresent(item, forKey: .item)
            try container.encodeIfPresent(id, forKey: .id)
        }
    }
}

/// `POST /v1/track`
private struct TrackBody: Encodable {
    let userId: String
    let event: String
    let properties: [String: AttrValue]
    /// Epoch milliseconds, stamped at call time.
    let ts: Int64
}

/// `POST /v1/token`
private struct TokenBody: Encodable {
    let userId: String
    let token: String
    let platform: Platform
    /// Everything below is optional and always will be: a `pk_` key ships
    /// inside a binary, so builds that predate device identity keep sending
    /// the three-field shape forever.
    let installId: String?
    let sdkVersion: String?
    let appVersion: String?
    let deviceModel: String?
    let osName: String?
    let osVersion: String?
    let tz: String?
    let pushPermission: String?
}

/// `POST /v1/push/ack`
private struct PushAckBody: Encodable {
    let userId: String
    let msgId: String
    let action: String
}

/// `POST /v1/inapp/ack`
private struct InAppAckBody: Encodable {
    let userId: String
    let msgId: String
    let action: String
}

/// `GET /v1/inapp/pending`
private struct PendingInAppResponse: Decodable {
    let messages: [InAppMessage]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A single malformed message must not lose the whole poll: decode
        // leniently and drop what will not parse, so one bad campaign cannot
        // stop every other campaign from being delivered.
        let lenient = try c.decodeIfPresent([FailableMessage].self, forKey: .messages) ?? []
        messages = lenient.compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case messages }
}

/// Decodes to `nil` instead of throwing, so one bad element cannot fail an array.
private struct FailableMessage: Decodable {
    let value: InAppMessage?

    init(from decoder: Decoder) throws {
        value = try? InAppMessage(from: decoder)
    }
}

/// Read one collected attribute as a plain string.
///
/// The device fields on a registration are strings on the wire, and the
/// collected bag is `AttrValue`; anything non-string there means the SDK
/// collected something unexpected, and omitting it beats guessing.
extension [String: AttrValue] {
    func string(_ key: String) -> String? {
        if case .string(let value) = self[key] { return value }
        return nil
    }
}
