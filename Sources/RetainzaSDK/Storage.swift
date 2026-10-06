import Foundation

/// The minimal persistence contract the SDK needs.
///
/// Injected rather than assumed so tests can run against memory and a host app
/// can substitute its own store. Three separate namespaces ride on one adapter:
/// the offline queue, session state, and the first-run install date.
public protocol RetainzaStorage: Sendable {
    func getItem(_ key: String) async -> String?
    func setItem(_ key: String, value: String) async
    func removeItem(_ key: String) async
}

/// The default store: `UserDefaults`.
///
/// WHY NOT THE KEYCHAIN
/// --------------------
/// None of what the SDK persists is a secret — a queued analytics event, a
/// session counter, an install timestamp. More importantly the Keychain
/// *survives app deletion*, which would actively corrupt two of those three:
/// a reinstalled app would report an `install_date` from the previous install
/// and continue a session count that should have started over. UserDefaults
/// being wiped on uninstall is the correct behaviour here, not a limitation.
///
/// Values are namespaced under an `engage.` prefix so the SDK can never collide
/// with a host app's own defaults.
/// `@unchecked Sendable` because `UserDefaults` is not annotated `Sendable`
/// even though Apple documents it as thread-safe — it is explicitly safe to
/// use from any thread. Without the override this becomes a hard error under
/// the Swift 6 language mode, and the alternative (serialising every read
/// through an actor) would add a hop to protect state that is already
/// protected.
public struct UserDefaultsStorage: RetainzaStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func getItem(_ key: String) async -> String? {
        defaults.string(forKey: key)
    }

    public func setItem(_ key: String, value: String) async {
        defaults.set(value, forKey: key)
    }

    public func removeItem(_ key: String) async {
        defaults.removeObject(forKey: key)
    }
}

/// Memory-only storage. Used by tests, and as the fallback when a host app
/// supplies no adapter — the queue then survives a network blip but not an app
/// restart, which is documented rather than silently assumed.
public actor InMemoryStorage: RetainzaStorage {
    private var values: [String: String] = [:]

    public init() {}

    public func getItem(_ key: String) async -> String? { values[key] }
    public func setItem(_ key: String, value: String) async { values[key] = value }
    public func removeItem(_ key: String) async { values.removeValue(forKey: key) }
}
