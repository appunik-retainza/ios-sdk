import Foundation

/// A device whose token has not changed re-registers at most this often.
public let registrationRefreshMs: Int64 = 24 * 60 * 60 * 1000

/// Install identity — the stable id that says "these registrations are the same
/// device".
///
/// WHY
/// ---
/// Without it the only key a device registration has is the APNs/FCM token
/// string, and those rotate on the platform's schedule. Every rotation
/// therefore looked like a brand new device: the profile's token list grew
/// forever and shrank only when a send failed, so a device count was an upper
/// bound on handsets the person had ever owned rather than a count of the ones
/// they have.
///
/// WHAT IT IS NOT
/// --------------
/// Not `identifierForVendor`, not an advertising id, not a fingerprint. It is a
/// random value this SDK generates and keeps in the host's own
/// `RetainzaStorage`, which defaults to `UserDefaults` — deliberately, because
/// `UserDefaults` is wiped by an uninstall and the Keychain is not. A reinstall
/// therefore gets a NEW id, which is correct: APNs hands a reinstalled app a
/// new token anyway, so it is a new device by every observable measure.
///
/// `reset()` MUST NOT CLEAR IT
/// ---------------------------
/// Session counters are cleared on logout because they describe the PERSON. An
/// install id describes the DEVICE, which is the same device after a logout.
/// Clearing it would make every sign-in look like a new phone — the exact
/// duplication it exists to prevent.
actor InstallId {
    private let storage: RetainzaStorage?
    private let now: @Sendable () -> Int64

    private var cached: String?
    private var loaded = false

    private static let key = "engage.install.v1"
    private static let pushKey = "engage.push.v1"

    init(storage: RetainzaStorage?, now: @escaping @Sendable () -> Int64) {
        self.storage = storage
        self.now = now
    }

    /// `nil` when there is no storage to keep an id in — never an error. The
    /// caller degrades to the server's merge-by-token-string, which is exactly
    /// what a build from before device identity does.
    func get() async -> String? {
        if loaded { return cached }
        loaded = true
        guard let storage else { return nil }
        if let existing = await storage.getItem(Self.key), !existing.isEmpty {
            cached = existing
            return existing
        }
        // Same spirit as a session id: unique among the installs of one app is
        // all this has to be.
        let created = "inst_\(String(now(), radix: 36))-\(String(UInt64.random(in: 0..<(1 << 40)), radix: 36))"
        await storage.setItem(Self.key, value: created)
        cached = created
        return created
    }

    /// Should this token be sent to the server?
    ///
    /// False for an unchanged token registered less than a day ago. Apps are
    /// told to call `registerPush` on every launch — without this that is a
    /// network write per launch, per user, forever, to say nothing new.
    func shouldRegister(_ token: String) async -> Bool {
        guard let storage else { return true }
        guard
            let raw = await storage.getItem(Self.pushKey),
            let data = raw.data(using: .utf8),
            let state = try? JSONDecoder().decode(PushState.self, from: data)
        else { return true }
        if state.token != token { return true }
        return now() - state.at >= registrationRefreshMs
    }

    /// Remember an accepted registration. Failure here only costs a resend.
    func markRegistered(_ token: String) async {
        guard let storage else { return }
        let state = PushState(token: token, at: now())
        guard let data = try? JSONEncoder().encode(state), let raw = String(data: data, encoding: .utf8) else { return }
        await storage.setItem(Self.pushKey, value: raw)
    }

    /// Forget the cached registration on logout, so the next user's first
    /// `registerPush` reaches the server even with the same token.
    ///
    /// Note what this does NOT touch: the install id itself.
    func clearRegistration() async {
        await storage?.removeItem(Self.pushKey)
    }

    private struct PushState: Codable {
        let token: String
        /// When this exact token was last accepted by the server.
        let at: Int64
    }
}
