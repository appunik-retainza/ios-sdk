#if canImport(SwiftUI) && canImport(UIKit)

import SwiftUI

/// Mount once, near the root of your view hierarchy, and in-app messages work.
///
/// ```swift
/// var body: some Scene {
///     WindowGroup {
///         ContentView()
///             .engageInApp()
///     }
/// }
/// ```
///
/// It owns the poll loop, the one-at-a-time queue, screen gating and the full
/// ack lifecycle. The host app supplies nothing except — if it wants gating —
/// the current screen name.
///
/// WHY ONE MOUNT POINT AND NOT A MODIFIER PER SCREEN
/// -------------------------------------------------
/// Messages arrive on a timer, not in response to navigation, so a per-screen
/// mount would poll N times over and race to display the same campaign twice.
/// One host at the root also means the presentation sits above whatever is on
/// screen, which is what a modal or banner has to do.
public struct RetainzaInAppHost<Content: View>: View {
    private let content: Content
    private let client: RetainzaClient?
    private let intervalMs: Int

    @State private var current: InAppMessage?
    @State private var resolved: ResolvedInApp?
    @State private var stopPolling: (@Sendable () -> Void)?

    public init(
        client: RetainzaClient? = nil,
        intervalMs: Int = 15_000,
        @ViewBuilder content: () -> Content
    ) {
        self.client = client
        self.intervalMs = intervalMs
        self.content = content()
    }

    public var body: some View {
        content
            .overlay {
                if let resolved, let current {
                    presentation(resolved)
                        .zIndex(1)
                        .task(id: current.msgId) {
                            // Banner auto-dismiss. Cancelled automatically when
                            // the message changes, because `task(id:)` restarts
                            // — so a rapid second message cannot dismiss the
                            // first one's replacement.
                            guard let ms = resolved.autoDismissMs, ms > 0 else { return }
                            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                            if !Task.isCancelled { dismiss(current) }
                        }
                }
            }
            .animation(.snappy(duration: 0.28), value: current?.msgId)
            .task { await start() }
            .onDisappear { stopPolling?() }
    }

    private var resolvedClient: RetainzaClient? { client ?? Retainza.shared }

    private func start() async {
        guard let client = resolvedClient else {
            // Not an error worth crashing over: a preview or a test harness
            // legitimately renders this before Retainza.start has run.
            return
        }

        await client.onInApp { message in
            Task { @MainActor in
                // One at a time. A second message arriving while one is on
                // screen is ignored rather than queued in the view — it stays
                // pending server-side and the next poll offers it again, which
                // keeps the "what is pending" answer in exactly one place.
                guard current == nil else { return }
                current = message
                resolved = normalizeInApp(message.content)
                if let warnings = resolved?.warnings, !warnings.isEmpty {
                    for warning in warnings {
                        await client.logPublic(.warn, "in-app \(message.msgId): \(warning)")
                    }
                }
            }
        }

        stopPolling = await client.startInAppPolling(intervalMs: intervalMs)
    }

    @ViewBuilder
    private func presentation(_ resolved: ResolvedInApp) -> some View {
        let callbacks = InAppCallbacks(
            onButton: { button in handleButton(button) },
            onDismiss: { if let current { dismiss(current) } },
            onTrack: { event, properties in
                guard let client = resolvedClient else { return }
                // Not tied to the message: it may be gone before this finishes.
                Task { try? await client.track(event, properties: properties) }
            }
        )

        switch resolved.template {
        case .banner:
            InAppBannerView(resolved: resolved, callbacks: callbacks)
        case .bottomsheet:
            InAppBottomSheetView(resolved: resolved, callbacks: callbacks)
        case .fullscreen:
            InAppFullScreenView(resolved: resolved, callbacks: callbacks)
        case .html:
            InAppHtmlView(resolved: resolved, callbacks: callbacks)
        case .modal:
            InAppModalView(resolved: resolved, callbacks: callbacks)
        case .selfhandled:
            // Never reached — `deliverInApp` routes these to the self-handled
            // handler and never to a renderer. Drawing nothing is the correct
            // fallback if that ever changes.
            EmptyView()
        }
    }

    private func handleButton(_ button: InAppButton) {
        guard let message = current, let client = resolvedClient else { return }
        clear()

        Task {
            // Ack before navigating: the click is what the campaign's
            // conversion rate counts, and navigation may tear this view down
            // mid-flight.
            try? await client.ackInApp(msgId: message.msgId, action: .clicked)

            // A button with no route dismisses without navigating — which is
            // exactly what the old `secondaryCtaText` meant.
            if let route = button.route ?? message.route {
                await client.resolveRoute(route.asRoute)
            }
        }
    }

    private func dismiss(_ message: InAppMessage) {
        guard let client = resolvedClient else { return }
        clear()
        Task { try? await client.ackInApp(msgId: message.msgId, action: .dismissed) }
    }

    private func clear() {
        current = nil
        resolved = nil
    }
}

extension View {
    /// Mount the in-app message host above this view.
    ///
    /// Apply once, at the root. See `RetainzaInAppHost` for why.
    public func engageInApp(client: RetainzaClient? = nil, intervalMs: Int = 15_000) -> some View {
        RetainzaInAppHost(client: client, intervalMs: intervalMs) { self }
    }
}

#endif
