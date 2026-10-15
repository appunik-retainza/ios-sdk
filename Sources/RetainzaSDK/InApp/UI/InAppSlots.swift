#if canImport(SwiftUI) && canImport(UIKit)

import SwiftUI

/// What a rendered message can report back.
///
/// One type shared by all five presentations, so the ack lifecycle is written
/// once. A renderer that invented its own callbacks would be a renderer that
/// eventually forgets to ack.
struct InAppCallbacks {
    let onButton: (InAppButton) -> Void
    let onDismiss: () -> Void
    /// `engage.track(...)` from an HTML document. The native templates never call it.
    var onTrack: (String, [String: AttrValue]) -> Void = { _, _ in }
}

/// The slot renderer.
///
/// Every presentation is the same slots in the order `normalizeInApp` resolved,
/// wrapped in a different shell. That is the whole point of the slot model: a
/// new variant is data, and no renderer grows a branch for it.
struct InAppSlotsView: View {
    let resolved: ResolvedInApp
    let callbacks: InAppCallbacks

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(resolved.layout.enumerated()), id: \.offset) { _, slot in
                switch slot {
                case .media:
                    if let media = resolved.media { InAppMediaView(media: media) }
                case .header:
                    if let header = resolved.header {
                        Text(header)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(InAppStyleKit.headerColor(resolved.style))
                    }
                case .title:
                    Text(resolved.title)
                        .font(InAppStyleKit.titleFont(resolved.style))
                        .foregroundStyle(InAppStyleKit.titleColor(resolved.style))
                        .fixedSize(horizontal: false, vertical: true)
                case .body:
                    Text(resolved.body)
                        .font(InAppStyleKit.bodyFont(resolved.style))
                        .foregroundStyle(InAppStyleKit.bodyColor(resolved.style))
                        .fixedSize(horizontal: false, vertical: true)
                case .buttons:
                    InAppButtonsView(buttons: resolved.buttons, onTap: callbacks.onButton)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The media slot.
///
/// `AsyncImage` rather than a bundled image loader: the SDK has no
/// dependencies, and adding one for this would force a caching library on every
/// consumer. A failed load renders nothing rather than a broken-image glyph —
/// the message still has its title, body and buttons.
struct InAppMediaView: View {
    let media: InAppMedia

    var body: some View {
        // A reserved aspect ratio matters more than it looks: without one the
        // card resizes the instant the image arrives, which on a modal means
        // the buttons move out from under a finger already on the way down.
        let ratio = media.aspect?.ratio ?? 16.0 / 9.0

        Group {
            if let url = URL(string: media.url), media.kind != .video {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: media.fit == .contain ? .fit : .fill)
                    case .failure:
                        Color.clear
                    case .empty:
                        // A tinted placeholder rather than a spinner: a spinner
                        // on a marketing card reads as "the app is broken".
                        Color(uiColor: .secondarySystemBackground)
                    @unknown default:
                        Color.clear
                    }
                }
            } else {
                // Video is deliberately not rendered. AVKit would work, but a
                // video autoplaying inside an interstitial is a product
                // decision, not a default — and the message reads fine without
                // it. Documented in the integration guide.
                Color(uiColor: .secondarySystemBackground)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityLabel(media.alt ?? "")
        .accessibilityHidden(media.alt == nil)
    }
}

/// The buttons slot.
struct InAppButtonsView: View {
    let buttons: [InAppButton]
    let onTap: (InAppButton) -> Void

    var body: some View {
        // Side by side for two short labels, stacked otherwise. Two buttons
        // with long labels squeezed onto one line is where campaign text gets
        // truncated into nonsense.
        let sideBySide = buttons.count == 2 && buttons.allSatisfy { $0.text.count <= 14 }

        if sideBySide {
            HStack(spacing: 10) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    InAppButtonView(button: button, onTap: onTap)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    InAppButtonView(button: button, onTap: onTap)
                }
            }
        }
    }
}

struct InAppButtonView: View {
    let button: InAppButton
    let onTap: (InAppButton) -> Void

    var body: some View {
        let kind = button.kind ?? .filled
        let radius = CGFloat(InAppStyleKit.clamp(button.borderRadius, 0...32, default: 10))
        let font = Font.system(
            size: InAppStyleKit.clamp(button.fontSize, 10...24, default: 15),
            weight: .semibold
        )

        Button(action: { onTap(button) }) {
            Text(button.text)
                .font(font)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
        }
        .foregroundStyle(foreground(kind))
        .background(background(kind))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    InAppStyleKit.color(button.borderColor) ?? borderFallback(kind),
                    lineWidth: kind == .outlined ? 1 : 0
                )
        )
        // 44pt is Apple's minimum touch target. A dashboard font-size slider
        // can otherwise produce a button too small to reliably hit.
        .frame(minHeight: 44)
    }

    private func foreground(_ kind: InAppButtonKind) -> Color {
        if let explicit = InAppStyleKit.color(button.textColor) { return explicit }
        return kind == .filled ? .white : .accentColor
    }

    private func background(_ kind: InAppButtonKind) -> Color {
        guard kind == .filled else { return .clear }
        return InAppStyleKit.color(button.backgroundColor) ?? .accentColor
    }

    private func borderFallback(_ kind: InAppButtonKind) -> Color {
        kind == .outlined ? .accentColor : .clear
    }
}

/// A rectangle rounded at the top corners only.
///
/// Hand-rolled because `UnevenRoundedRectangle` is iOS 16+ and this package
/// supports 15. A bottom sheet with all four corners rounded looks detached
/// from the screen edge, so this is not a detail worth dropping to save a type.
struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Clamped so a dashboard radius larger than the sheet cannot produce a
        // self-intersecting path, which renders as a torn shape.
        let r = min(radius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The ✕ control.
struct InAppCloseButton: View {
    let position: InAppStyle.ClosePosition
    let action: () -> Void

    var body: some View {
        HStack {
            if position == .right { Spacer() }
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .accessibilityLabel("Close")
            .frame(minWidth: 44, minHeight: 44)
            if position == .left { Spacer() }
        }
    }
}

#endif
