import Foundation

public enum RetainzaLogLevel: String, Sendable {
    case debug, warn, error
}

/// Receives log lines instead of the console.
///
/// When `debug` is on the sink gets everything; when it is off the sink still
/// gets `warn` and `error`, so a host can route failures to its own crash
/// reporter — but the console stays silent either way. An SDK that prints in
/// production is an SDK that gets ripped out.
public typealias RetainzaLogSink = @Sendable (RetainzaLogLevel, String) -> Void

/// Internal logging facade.
///
/// A struct rather than a method on the client so the queue and session actors
/// can log without holding a reference back to the client, which would be a
/// retain cycle and an actor-reentrancy hazard for no benefit.
///
/// **Never logs attribute or property values** — they are user data — and never
/// the full public key. Key names and a key prefix only.
struct RetainzaLog: Sendable {
    let debugEnabled: Bool
    let sink: RetainzaLogSink?

    static let silent = RetainzaLog(debugEnabled: false, sink: nil)

    func debug(_ message: String) { emit(.debug, message) }

    func warn(_ message: String, _ error: Error? = nil) {
        emit(.warn, error.map { "\(message): \($0)" } ?? message)
    }

    func error(_ message: String, _ error: Error? = nil) {
        emit(.error, error.map { "\(message): \($0)" } ?? message)
    }

    private func emit(_ level: RetainzaLogLevel, _ message: String) {
        if let sink {
            if debugEnabled || level != .debug { sink(level, "[Retainza] \(message)") }
            return
        }
        guard debugEnabled else { return }
        print("[Retainza] \(message)")
    }
}
