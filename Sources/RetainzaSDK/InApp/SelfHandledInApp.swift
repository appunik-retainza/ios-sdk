import Foundation

/// A `selfhandled` message plus the acks its renderer must send.
///
/// The SDK cannot know when the app's own view appeared, was tapped, or was
/// closed, so these are the app's to call. Skipping them does not break
/// rendering — it silently empties that campaign's funnel, which is the failure
/// mode worth naming here, because nothing else will report it.
public struct SelfHandledInApp: Sendable {
    public let message: InAppMessage

    /// Call when your view becomes visible. Counts as delivered.
    public let markShown: @Sendable () -> Void

    /// Call on your primary action. Acks `clicked`, then navigates.
    ///
    /// Pass a route to override the message's own; omit it to use whatever the
    /// campaign specified.
    public let markClicked: @Sendable (Route?) -> Void

    /// Call when the user closes it without acting.
    public let markDismissed: @Sendable () -> Void

    public var msgId: String { message.msgId }
    public var content: InAppContent { message.content }
}
