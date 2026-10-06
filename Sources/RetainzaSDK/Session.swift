import Foundation

public let defaultSessionTimeoutMs: Int64 = 30 * 60_000

/// Session accounting state, persisted between launches.
public struct SessionState: Codable, Sendable, Equatable {
    /// Opaque id for the current session, for correlating events later.
    public var id: String
    public var count: Int
    public var firstAt: Int64
    public var startedAt: Int64
    /// Last moment the app was known to be in the foreground.
    public var lastSeenAt: Int64
    /// Total foreground time across all sessions, ms.
    public var durationTotal: Int64
}

/// The attributes a session state contributes to a profile.
///
/// `last_session_at` is `startedAt`, not `lastSeenAt`: the question a churn
/// segment asks is "when did they last open the app", and `lastSeenAt` moves
/// every time the app is merely resumed within the timeout window.
public func sessionAttributes(_ state: SessionState) -> [String: AttrValue] {
    [
        AutoAttribute.sessionCount: .int(state.count),
        AutoAttribute.firstSessionAt: .number(Double(state.firstAt)),
        AutoAttribute.lastSessionAt: .number(Double(state.startedAt)),
        AutoAttribute.sessionDurationTotal: .number(Double(state.durationTotal)),
    ]
}

/// Tracks "how many times has this person opened the app, and when".
///
/// It is the single most-asked question in an engagement tool — it drives
/// onboarding campaigns, churn segments and every "power user" audience — and
/// the thing no integration could answer, because each app defined a session
/// differently or not at all.
///
/// Definition used here: a session starts when the app becomes active and ends
/// after `timeoutMs` in the background. Coming back inside the timeout
/// **resumes** the same session rather than inflating the count — the
/// industry-standard 30-minute rule, and the reason a user who checks a push
/// and returns is not counted twice.
///
/// State lives in the injected storage so it survives a process kill. With no
/// adapter it degrades to memory and simply undercounts across restarts, which
/// is better than double-counting.
actor SessionTracker {
    static let storageKey = "engage.session.v1"

    private var state: SessionState?
    private var loaded = false

    private let storage: RetainzaStorage?
    private let timeoutMs: Int64
    private let now: @Sendable () -> Int64

    init(
        storage: RetainzaStorage?,
        timeoutMs: Int64 = defaultSessionTimeoutMs,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.storage = storage
        self.timeoutMs = timeoutMs
        self.now = now
    }

    private func load() async {
        if loaded { return }
        loaded = true
        guard let storage, let raw = await storage.getItem(Self.storageKey), !raw.isEmpty else { return }
        // Corrupt or unreadable state starts fresh rather than throwing during
        // app startup, which is where this runs.
        state = try? JSONDecoder().decode(SessionState.self, from: Data(raw.utf8))
    }

    private func persist() async {
        guard let storage, let state else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        await storage.setItem(Self.storageKey, value: String(decoding: data, as: UTF8.self))
    }

    /// The app came to the foreground.
    ///
    /// Returns the session and whether it is a NEW one — callers use that to
    /// decide whether to emit a `session_start` event, so a resume inside the
    /// timeout stays silent.
    func start() async -> (state: SessionState, isNew: Bool) {
        await load()
        let t = now()

        if var previous = state, t - previous.lastSeenAt < timeoutMs {
            previous.lastSeenAt = t
            state = previous
            await persist()
            return (previous, false)
        }

        let fresh = SessionState(
            id: Self.newId(t),
            count: (state?.count ?? 0) + 1,
            firstAt: state?.firstAt ?? t,
            startedAt: t,
            lastSeenAt: t,
            durationTotal: state?.durationTotal ?? 0
        )
        state = fresh
        await persist()
        return (fresh, true)
    }

    /// The app went to the background. Banks the foreground time.
    func pause() async -> SessionState? {
        await load()
        guard var current = state else { return nil }
        let t = now()
        current.durationTotal += Swift.max(0, t - current.lastSeenAt)
        current.lastSeenAt = t
        state = current
        await persist()
        return current
    }

    func current() async -> SessionState? {
        await load()
        return state
    }

    /// Logout: the next foreground is a new person's first session.
    func reset() async {
        state = nil
        loaded = true
        await storage?.removeItem(Self.storageKey)
    }

    private static func newId(_ now: Int64) -> String {
        // Not cryptographic: this only has to distinguish one session from the
        // next on the same device. Base-36 keeps it short in log output.
        let stamp = String(now, radix: 36)
        let salt = String(Int.random(in: 0..<1_000_000), radix: 36)
        return "\(stamp)-\(salt)"
    }
}
