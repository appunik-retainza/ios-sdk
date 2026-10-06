#if canImport(SwiftUI) && canImport(UIKit)

import SwiftUI
import WebKit

/// The five presentations.
///
/// Each is a *shell* around the same `InAppSlotsView`: only the framing differs
/// — where it sits, whether there is a backdrop, how it animates in. Keeping the
/// content rendering in one place is why adding a sixth presentation later does
/// not mean re-testing button styling five times.

// MARK: - Banner

/// Docks to the top or bottom edge. The only presentation with no backdrop —
/// a banner is meant to be ignorable, which is also why it is the only one that
/// is not dismissible by default and auto-dismisses instead.
struct InAppBannerView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        let style = resolved.style
        let edge: Edge = (style.position ?? .top) == .top ? .top : .bottom

        VStack {
            if edge == .bottom { Spacer() }

            InAppSlotsView(resolved: resolved, callbacks: callbacks)
                .padding(InAppStyleKit.padding(style))
                .background(InAppStyleKit.background(style))
                .clipShape(
                    RoundedRectangle(cornerRadius: InAppStyleKit.cornerRadius(style), style: .continuous)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .opacity(InAppStyleKit.opacity(style))
                .padding(.horizontal, InAppStyleKit.margin(style))
                .overlay(alignment: .topTrailing) {
                    if resolved.dismissible {
                        InAppCloseButton(
                            position: style.closePosition ?? .right,
                            action: callbacks.onDismiss
                        )
                        .padding(.trailing, InAppStyleKit.margin(style))
                    }
                }

            if edge == .top { Spacer() }
        }
        .padding(.vertical, InAppStyleKit.margin(style))
        .transition(InAppStyleKit.transition(style, edge: edge))
    }
}

// MARK: - Modal

/// Centred card over a dimmed backdrop. The default presentation.
struct InAppModalView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        let style = resolved.style

        ZStack {
            InAppBackdrop(dismissible: resolved.dismissible, onDismiss: callbacks.onDismiss)

            VStack(spacing: 0) {
                if resolved.dismissible {
                    InAppCloseButton(
                        position: style.closePosition ?? .right,
                        action: callbacks.onDismiss
                    )
                }
                InAppSlotsView(resolved: resolved, callbacks: callbacks)
            }
            .padding(InAppStyleKit.padding(style))
            .background(InAppStyleKit.background(style))
            .clipShape(
                RoundedRectangle(cornerRadius: InAppStyleKit.cornerRadius(style), style: .continuous)
            )
            .opacity(InAppStyleKit.opacity(style))
            .padding(.horizontal, 24)
            // Cap the width on iPad, where a modal stretched edge to edge reads
            // as a broken layout rather than a designed one.
            .frame(maxWidth: 420)
            .transition(InAppStyleKit.transition(style, edge: .bottom))
        }
    }
}

// MARK: - Bottom sheet

/// Rises from the bottom edge, corners rounded at the top only.
struct InAppBottomSheetView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        let style = resolved.style

        ZStack {
            InAppBackdrop(dismissible: resolved.dismissible, onDismiss: callbacks.onDismiss)

            VStack {
                Spacer()
                VStack(spacing: 14) {
                    // The grabber is the affordance that says "this can be
                    // dismissed"; without it a sheet with no ✕ looks stuck.
                    Capsule()
                        .fill(Color(uiColor: .tertiaryLabel))
                        .frame(width: 36, height: 5)

                    InAppSlotsView(resolved: resolved, callbacks: callbacks)
                }
                .padding(InAppStyleKit.padding(style))
                // Extra bottom padding clears the home indicator; without it
                // the last button sits under the system gesture area.
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
                .background(InAppStyleKit.background(style))
                .clipShape(TopRoundedRectangle(radius: InAppStyleKit.cornerRadius(style)))
                .opacity(InAppStyleKit.opacity(style))
            }
            .transition(InAppStyleKit.transition(style, edge: .bottom))
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - Full screen

/// Covers everything. Content is scrollable — a full-screen message is the one
/// presentation whose body can genuinely exceed the viewport.
struct InAppFullScreenView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        let style = resolved.style

        ZStack(alignment: .top) {
            InAppStyleKit.background(style).ignoresSafeArea()

            ScrollView {
                InAppSlotsView(resolved: resolved, callbacks: callbacks)
                    .padding(InAppStyleKit.padding(style))
                    // Clears the close button, which floats above the scroll
                    // view rather than scrolling away with the content.
                    .padding(.top, resolved.dismissible ? 44 : 0)
            }

            if resolved.dismissible {
                InAppCloseButton(
                    position: style.closePosition ?? .right,
                    action: callbacks.onDismiss
                )
                .padding(.horizontal, 12)
            }
        }
        .opacity(InAppStyleKit.opacity(style))
        .transition(InAppStyleKit.transition(style, edge: .bottom))
    }
}

// MARK: - HTML

/// An author-supplied document in a sandboxed WebView.
///
/// The sandboxing is the interesting part: this HTML was written in a web
/// dashboard by someone who is not the app's developer, and it runs inside the
/// app. So the WebView gets no persistent data store, no back-forward
/// navigation, and — critically — cannot navigate away from the document it was
/// handed. A campaign that tried to would otherwise become an unbranded browser
/// embedded in the app with no address bar.
struct InAppHtmlView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        let style = resolved.style
        let frame = resolved.htmlFrame ?? .modal

        ZStack {
            if frame != .fullscreen {
                InAppBackdrop(dismissible: resolved.dismissible, onDismiss: callbacks.onDismiss)
            }

            VStack {
                if frame == .bottomsheet { Spacer() }

                ZStack(alignment: .topTrailing) {
                    HtmlWebView(
                        html: resolved.html ?? "",
                        onClose: callbacks.onDismiss,
                        onRoute: { screen in
                            // A document can ask for navigation via
                            // engage://route/<screen>. Expressed as a button so
                            // it goes through the same click-ack path as a
                            // native button — otherwise HTML campaigns would
                            // report no clicks at all.
                            callbacks.onButton(
                                InAppButton(text: "", route: InAppRoute(screen: screen))
                            )
                        }
                    )
                    .frame(height: frame == .fullscreen ? nil : 420)

                    if resolved.dismissible {
                        InAppCloseButton(
                            position: style.closePosition ?? .right,
                            action: callbacks.onDismiss
                        )
                    }
                }
                .background(InAppStyleKit.background(style))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: frame == .fullscreen ? 0 : InAppStyleKit.cornerRadius(style),
                        style: .continuous
                    )
                )
                .padding(.horizontal, frame == .fullscreen ? 0 : 20)

                if frame == .modal { Spacer().frame(height: 0) }
            }
        }
        .ignoresSafeArea(edges: frame == .fullscreen ? .all : [])
        .transition(InAppStyleKit.transition(style, edge: .bottom))
    }
}

/// `@MainActor` is required, not stylistic: `UIViewRepresentable`'s methods are
/// declared `@MainActor @preconcurrency`, and without matching isolation the
/// conformance fails with a "non-matching type" error that points at the return
/// type rather than at the actor mismatch actually causing it.
@MainActor
private struct HtmlWebView: UIViewRepresentable {
    typealias UIViewType = WKWebView

    let html: String
    let onClose: () -> Void
    let onRoute: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose, onRoute: onRoute)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent: campaign HTML must not be able to write cookies or
        // local storage that outlive the message.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false
        // The document is trusted only to render itself, so no base URL is
        // given — relative requests resolve to nothing rather than to a host.
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onClose: () -> Void
        private let onRoute: (String) -> Void

        init(onClose: @escaping () -> Void, onRoute: @escaping (String) -> Void) {
            self.onClose = onClose
            self.onRoute = onRoute
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                return decisionHandler(.allow)
            }

            // The initial loadHTMLString has no scheme worth inspecting.
            if url.absoluteString == "about:blank" {
                return decisionHandler(.allow)
            }

            if url.scheme == "engage" {
                if url.host == "close" {
                    onClose()
                } else if url.host == "route" {
                    let screen = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if !screen.isEmpty { onRoute(screen) }
                }
                return decisionHandler(.cancel)
            }

            // Everything else is refused. A campaign document that navigated to
            // an arbitrary URL would turn an in-app message into a browser with
            // no address bar — the user would have no way to tell whose page
            // they were looking at.
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Shared backdrop

private struct InAppBackdrop: View {
    let dismissible: Bool
    let onDismiss: () -> Void

    var body: some View {
        Color.black.opacity(0.45)
            .ignoresSafeArea()
            // Tap-outside-to-dismiss only when the message is dismissible.
            // Otherwise a non-dismissible message would still be closable,
            // which defeats the campaign setting entirely.
            .onTapGesture { if dismissible { onDismiss() } }
            .accessibilityHidden(true)
    }
}

#endif
