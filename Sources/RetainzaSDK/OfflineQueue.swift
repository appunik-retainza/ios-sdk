import Foundation

/// Exponential backoff with a ceiling.
///
/// Free function and pure, so the retry policy is testable without waiting on
/// real timers — `backoffMs(5)` is an assertion, not a five-minute test.
public func backoffMs(_ attempt: Int, baseMs: Int = 1_000, maxMs: Int = 5 * 60_000) -> Int {
    if attempt <= 0 { return baseMs }
    // Cap the exponent before shifting: `1000 * 2^62` overflows Int, and an
    // attempt count that high is reachable if a device stays offline for days.
    let exponent = min(attempt, 20)
    return min(maxMs, baseMs * (1 << exponent))
}

/// The two ingest paths that may be deferred.
///
/// Deliberately not "any path". `/token` is excluded because a token that
/// arrives late may already have been rotated, and pushing to a stale token is
/// worse than not registering at all; the ack endpoints are excluded because a
/// replayed ack corrupts a campaign funnel after the fact.
public enum QueuePath: String, Codable, Sendable {
    case track = "/track"
    case identify = "/identify"
    case collections = "/collections"
}

/// One deferred ingest call.
///
/// The body is stored as the JSON text that would have been sent, not as a
/// re-encodable model. That keeps the original `ts` welded to the payload — a
/// flush an hour later still records when the event actually happened — and it
/// means a schema change in a later SDK version cannot silently rewrite a call
/// that was queued by an earlier one.
public struct QueuedCall: Codable, Sendable, Equatable {
    public let path: QueuePath
    public let body: String
    /// When the call was first attempted (epoch ms).
    public let queuedAt: Int64
    /// How many flush attempts this item has survived.
    public var attempts: Int
    /// The signed identity that was current for this call's user when it was
    /// made (see `RetainzaClient.setUserHash`). Kept with the item because a
    /// queued call can outlive the app session that knew the hash, and a
    /// project that enforces signed identity would refuse the replay without
    /// it. Optional, so items queued by an earlier SDK version still decode.
    public var userHash: String? = nil
}

/// Bounded, ordered, persisted offline queue for ingest calls.
///
/// Why this exists: a `track` fired during a network blip would otherwise
/// vanish, and event-triggered campaigns fire off events — so a dropped event
/// is a campaign that silently never sends. The queue turns "lost" into "late".
///
/// Design commitments, all carried over from `sdk-core/src/queue.ts`:
///  - **Order is preserved.** Flushing stops at the first failure and leaves
///    the rest queued, so events never arrive out of sequence.
///  - **Bounded.** The *oldest* item is dropped on overflow: recent behaviour
///    is what triggers campaigns, and an unbounded queue on a long-offline
///    device is a memory leak.
///  - **Storage is injected.** Without an adapter the queue is memory-only.
///
/// An actor because a flush racing an enqueue would otherwise reorder or lose
/// items, and both can be driven from any thread the host app happens to be on.
public actor OfflineQueue {
    public static let defaultMaxItems = 100
    static let storageKey = "engage.queue.v1"

    private var items: [QueuedCall] = []
    private let max: Int
    private let storage: RetainzaStorage?
    private let key: String
    private let log: RetainzaLog
    private var loaded = false

    init(
        max: Int = OfflineQueue.defaultMaxItems,
        storage: RetainzaStorage?,
        key: String = OfflineQueue.storageKey,
        log: RetainzaLog
    ) {
        self.max = Swift.max(1, max)
        self.storage = storage
        self.key = key
        self.log = log
    }

    /// Rehydrate from storage. Safe to call repeatedly; only the first reads.
    func load() async {
        if loaded { return }
        loaded = true
        guard let storage else { return }
        guard let raw = await storage.getItem(key), !raw.isEmpty else { return }
        do {
            // Trust nothing that came off disk: a partial write or a queue
            // written by an older schema must not crash app startup, which is
            // exactly where this runs.
            items = try JSONDecoder().decode([QueuedCall].self, from: Data(raw.utf8))
            log.debug("queue restored \(items.count) item(s)")
        } catch {
            log.warn("queue restore failed; starting empty", error)
            items = []
        }
    }

    public func size() -> Int { items.count }

    /// A copy of the queue, oldest first. For tests and debug output.
    func snapshot() -> [QueuedCall] { items }

    /// Append a call, dropping the oldest on overflow.
    ///
    /// A device offline for a week should send this morning's events, not last
    /// week's — which is why the drop is from the head, not the tail.
    func enqueue(_ call: QueuedCall) async {
        await load()
        items.append(call)
        var dropped = 0
        while items.count > max {
            items.removeFirst()
            dropped += 1
        }
        if dropped > 0 {
            log.warn("queue full (\(max)) — dropped \(dropped) oldest event(s)")
        }
        await persist()
    }

    /// Send queued calls oldest-first via `send`.
    ///
    /// Stops at the first failure and leaves that item at the head, so ordering
    /// is never broken. Returns how many were sent and how many remain.
    func flush(_ send: (QueuedCall) async throws -> Void) async -> (sent: Int, remaining: Int) {
        await load()
        var sent = 0
        while let next = items.first {
            do {
                try await send(next)
                items.removeFirst()
                sent += 1
            } catch {
                items[0].attempts += 1
                log.debug("queue flush stopped after \(sent) item(s): \(error)")
                break
            }
        }
        if sent > 0 || !items.isEmpty { await persist() }
        return (sent, items.count)
    }

    /// Drop everything — used by `reset()` on logout and by `optOut()`.
    func clear() async {
        loaded = true
        items = []
        await storage?.removeItem(key)
    }

    private func persist() async {
        guard let storage else { return }
        do {
            let data = try JSONEncoder().encode(items)
            await storage.setItem(key, value: String(decoding: data, as: UTF8.self))
        } catch {
            // Storage being full or unavailable must never break a track call.
            // The queue simply degrades to memory-only for this session.
            log.warn("queue persist failed", error)
        }
    }
}
