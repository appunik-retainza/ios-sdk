import Foundation

/// Where a notification tap or an in-app button should take the user.
///
/// Deliberately not a `URL`: campaigns are authored against the app's own
/// screen names ("order_detail"), not against a URL scheme the marketing team
/// would have to know. Mapping a screen name to an actual navigation action is
/// the app's job, via `onNavigate`.
public struct Route: Equatable, Sendable {
    public let screen: String
    /// Screen parameters. Always strings — see the note in `parseRetainzaPush`.
    public let kv: [String: String]?

    public init(screen: String, kv: [String: String]? = nil) {
        self.screen = screen
        self.kv = kv
    }
}

/// What an Retainza push carries in its payload.
public struct RetainzaPushPayload: Equatable, Sendable {
    public let msgId: String
    public let campaignId: String?
    public let route: Route?
}

/// Keys Retainza puts in the notification payload.
///
/// Namespaced with `engage_` precisely so a payload can be identified as ours
/// without a false positive on someone else's `msg_id`.
enum RetainzaPushKey {
    static let msgId = "engage_msg_id"
    static let route = "engage_route"
    static let campaign = "engage_campaign"
    static let params = "engage_params"
}

/// Parse a notification payload. Returns `nil` when the push is not an Retainza one.
///
/// Host apps run more than one push SDK — MoEngage, for example, alongside this
/// — so every notification handler must be able to ask "is this mine?" and bail
/// without disturbing the other SDK's message. Keeping the key convention here
/// means no host app re-implements it and gets it subtly wrong.
///
/// Takes `[AnyHashable: Any]` because that is exactly what UNNotification and
/// the AppDelegate callbacks hand over; the awkward type is the OS's, not ours.
public func parseRetainzaPush(_ userInfo: [AnyHashable: Any]?) -> RetainzaPushPayload? {
    guard let userInfo else { return nil }
    guard let msgId = userInfo[RetainzaPushKey.msgId] as? String, !msgId.isEmpty else { return nil }

    let campaignId = (userInfo[RetainzaPushKey.campaign] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let screen = (userInfo[RetainzaPushKey.route] as? String).flatMap { $0.isEmpty ? nil : $0 }

    var kv: [String: String]?
    if let raw = userInfo[RetainzaPushKey.params] as? String, !raw.isEmpty {
        // A corrupt params blob must not lose the notification tap: the user
        // still lands on the right screen, just without its parameters.
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // APNs and FCM values are strings, but a campaign author can put a
            // number or a boolean in the params JSON. Coerce defensively so a
            // payload can never hand the app's router a non-string parameter.
            kv = parsed.reduce(into: [String: String]()) { out, pair in
                out[pair.key] = stringifyParam(pair.value)
            }
        }
    }

    return RetainzaPushPayload(
        msgId: msgId,
        campaignId: campaignId,
        route: screen.map { Route(screen: $0, kv: kv) }
    )
}

/// Render one decoded JSON value as the string a router expects.
///
/// `String(describing:)` is NOT good enough here, which is easy to miss.
/// `JSONSerialization` boxes both numbers and booleans as `NSNumber`, so
/// `String(describing:)` renders `true` as `"1"` — a router asked for
/// `promo=1` instead of `promo=true` silently takes the wrong branch, and
/// nothing about it looks like a bug at the call site.
///
/// Output matches what the JS SDK's `String(v)` produces for the same payload,
/// so a campaign behaves identically whichever SDK receives it.
private func stringifyParam(_ value: Any) -> String {
    if value is NSNull { return "null" }

    if let number = value as? NSNumber {
        // The only reliable way to tell a JSON boolean from the number 1.
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        // Integers must not arrive as "3.0" — a router comparing against "3"
        // would miss.
        if CFNumberIsFloatType(number as CFNumber) {
            return String(number.doubleValue)
        }
        return String(number.int64Value)
    }

    if let string = value as? String { return string }
    return String(describing: value)
}
