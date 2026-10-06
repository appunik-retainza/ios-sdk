#if canImport(UIKit) && !os(watchOS)

import Foundation
import UIKit
import UserNotifications

/// APNs plumbing: permission, token capture, and notification acks.
///
/// This is the part `@retainza/react-native` deliberately does not do — a JS SDK
/// cannot reach `UNUserNotificationCenter`, so it leaves every step to the host
/// app and hopes the integration guide is followed exactly. Here the SDK owns
/// it, which removes the most common source of "push doesn't work" tickets:
/// tokens registered without permission, permission granted without a token,
/// and acks nobody remembered to send.
///
/// Retainza sends through FCM, so the token it needs is the **FCM** token, not
/// the APNs one. The SDK stays free of a Firebase dependency; Firebase
/// Messaging in the app converts one into the other:
///
/// ```swift
/// func application(_ app: UIApplication, didFinishLaunchingWithOptions _: ...) -> Bool {
///     FirebaseApp.configure()
///     Messaging.messaging().delegate = self
///     UNUserNotificationCenter.current().delegate = self
///     return true
/// }
///
/// func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///     Messaging.messaging().apnsToken = token   // APNs token goes to Firebase…
/// }
///
/// func messaging(_: Messaging, didReceiveRegistrationToken fcmToken: String?) {
///     guard let fcmToken else { return }
///     Task { try? await RetainzaPush.handleFCMToken(fcmToken) }   // …FCM token to Retainza
/// }
///
/// func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError e: Error) {
///     RetainzaPush.handleRegistrationFailure(e)
/// }
/// ```
///
/// Plus, in your `UNUserNotificationCenterDelegate`:
/// `RetainzaPush.handleForeground(notification)` and
/// `RetainzaPush.handleOpen(response)`.
///
/// Xcode project setup the SDK cannot do for you — it cannot edit your project
/// file — is in `docs/SDK-INTEGRATION-GUIDE-IOS.md`: the `aps-environment`
/// entitlement and the `remote-notification` background mode. Without the
/// entitlement iOS never issues a token at all, and the failure is silent.
public enum RetainzaPush {

    /// The client these helpers act on. Defaults to the shared one.
    ///
    /// Every entry point resolves this lazily rather than capturing a client at
    /// setup time, so `Retainza.start` and the AppDelegate callbacks can happen
    /// in either order — which, given iOS may deliver a launch notification
    /// before your setup code runs, they genuinely do.
    private static func client() -> RetainzaClient? {
        Retainza.shared
    }

    // MARK: - Permission

    /// Ask for notification permission, then register with APNs if granted.
    ///
    /// Reports the outcome to Retainza as `push_permission` either way — a denial
    /// is the more valuable of the two facts, because it is what stops a
    /// campaign wasting sends on a device that can never display them.
    ///
    /// Call this when your app has *explained why* it wants notifications. iOS
    /// gives you exactly one system prompt per install: if the user denies it,
    /// nothing in this SDK or any other can ask again, and only a trip to
    /// Settings recovers it. That is a product decision, which is why the SDK
    /// never calls this for you.
    @discardableResult
    public static func requestAuthorization(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) async throws -> PushPermission {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: options)) ?? false

        // Re-read rather than trusting `granted`: the user may have decided
        // earlier, in which case the prompt never appeared and `granted`
        // reflects the stored answer, and `provisional` is a state a boolean
        // cannot express at all.
        let permission = await currentPermission()

        if granted {
            await registerForRemoteNotifications()
        }

        // Never fatal: telling Retainza about the permission is bookkeeping, and
        // a network blip here must not look to the app like the prompt failed.
        try? await client()?.setPushPermission(permission)
        return permission
    }

    /// The current notification permission, without prompting.
    ///
    /// Worth calling on every launch: permission can be revoked in Settings at
    /// any time, and nothing notifies the app when it happens. Without a
    /// refresh, Retainza keeps targeting a device that stopped being reachable
    /// months ago.
    public static func currentPermission() async -> PushPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            return .authorized
        case .provisional:
            return .provisional
        case .denied:
            return .denied
        case .notDetermined:
            return .undetermined
        @unknown default:
            // A future status is more like "we do not know" than "denied", and
            // guessing denied would drop a reachable device out of campaigns.
            return .undetermined
        }
    }

    /// Refresh the stored `push_permission` attribute from the OS.
    public static func syncPermission() async {
        let permission = await currentPermission()
        try? await client()?.setPushPermission(permission)
    }

    /// Ask iOS for an APNs token.
    ///
    /// Must run on the main thread — UIKit requires it, and calling it from a
    /// background queue is undefined behaviour rather than an error you would
    /// see in testing.
    @MainActor
    public static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Token

    /// Register the device's FCM registration token with Retainza.
    ///
    /// Call from `MessagingDelegate.messaging(_:didReceiveRegistrationToken:)`,
    /// which fires on first launch and whenever FCM rotates the token. Safe to
    /// call on every launch: an unchanged token is re-sent at most once a day
    /// unless `force` is set.
    ///
    /// Throws `RetainzaError.missingUserId` before a user is known — call it
    /// again (or `Messaging.messaging().token`) after `identify`.
    public static func handleFCMToken(_ fcmToken: String, force: Bool = false) async throws {
        guard !fcmToken.isEmpty else { return }
        try await client()?.registerPush(token: fcmToken, force: force)
    }

    /// Formerly registered the raw APNs token. It no longer does.
    ///
    /// Retainza delivers through FCM, which rejects a raw APNs token as an
    /// invalid registration token — the server then prunes the device as dead,
    /// so every registration made this way silently never received a push.
    /// Hand the APNs token to Firebase (`Messaging.messaging().apnsToken`) and
    /// register the resulting FCM token with `handleFCMToken(_:)`.
    ///
    /// Kept so existing call sites compile; it logs a warning and returns the
    /// hex token without sending anything.
    @available(*, deprecated, message: "Retainza sends via FCM. Set Messaging.messaging().apnsToken and call RetainzaPush.handleFCMToken(_:) from MessagingDelegate.")
    @discardableResult
    public static func handleDeviceToken(_ deviceToken: Data) async throws -> String {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        await client()?.logPublic(
            .warn,
            "handleDeviceToken no longer registers the APNs token — FCM cannot deliver to it. "
                + "Set Messaging.messaging().apnsToken = deviceToken and call RetainzaPush.handleFCMToken(_:)."
        )
        return token
    }

    /// Log a failed APNs registration.
    ///
    /// Almost always a missing `aps-environment` entitlement or a Simulator
    /// without a paired push-capable environment. Surfaced through the SDK's
    /// own logger so it lands wherever the host routes Retainza diagnostics
    /// instead of vanishing into an empty AppDelegate stub.
    public static func handleRegistrationFailure(_ error: Error) {
        Task {
            await client()?.logPublic(
                .warn,
                "APNs registration failed — check the aps-environment entitlement: \(error)"
            )
        }
    }

    // MARK: - Notifications

    /// A push arrived while the app was in the foreground.
    ///
    /// Call from `userNotificationCenter(_:willPresent:withCompletionHandler:)`.
    /// Returns `true` if it was an Retainza push, so a host running a second push
    /// SDK can tell whether to keep processing.
    @discardableResult
    public static func handleForeground(_ notification: UNNotification) async -> Bool {
        await ack(notification.request.content.userInfo, action: .delivered, navigate: false)
    }

    /// A silent or background push arrived.
    ///
    /// Call from `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    @discardableResult
    public static func handleBackground(_ userInfo: [AnyHashable: Any]) async -> Bool {
        await ack(userInfo, action: .delivered, navigate: false)
    }

    /// The user tapped a notification.
    ///
    /// Call from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// Acks `opened` and then routes, in that order — the ack is what the
    /// campaign's open rate counts, and doing it after navigation risks losing
    /// it if the app is killed mid-transition.
    @discardableResult
    public static func handleOpen(_ response: UNNotificationResponse) async -> Bool {
        await ack(response.notification.request.content.userInfo, action: .opened, navigate: true)
    }

    /// The app was launched from a notification tap.
    ///
    /// Call from `didFinishLaunchingWithOptions` with
    /// `launchOptions?[.remoteNotification]`. Without this, a cold-start open
    /// is never counted — the delegate callback that would have caught it fires
    /// before the app exists.
    @discardableResult
    public static func handleLaunchOptions(
        _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) async -> Bool {
        guard let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] else {
            return false
        }
        return await ack(userInfo, action: .opened, navigate: true)
    }

    private static func ack(
        _ userInfo: [AnyHashable: Any],
        action: PushAction,
        navigate: Bool
    ) async -> Bool {
        // Not ours: return without touching it. A host app may well be running
        // another push SDK whose message this is.
        guard let payload = parseRetainzaPush(userInfo) else { return false }
        guard let client = client() else { return true }

        // Telemetry must never break a notification tap, so failures here are
        // logged and swallowed rather than propagated to the delegate.
        try? await client.ackPush(msgId: payload.msgId, action: action)

        if navigate, let route = payload.route {
            await client.resolveRoute(route)
        }
        return true
    }
}

#endif
