#if canImport(SwiftUI) && canImport(UIKit)

import SwiftUI

/// Turning campaign JSON into SwiftUI values.
///
/// Everything here is *forgiving on purpose*. These values were produced by a
/// marketer moving sliders and pasting colours in a web dashboard, and they are
/// applied on a device nobody can inspect. A malformed value must degrade to a
/// sensible default, never throw and never collapse a layout to zero — a
/// campaign that renders slightly wrong is recoverable, one that renders as a
/// blank rectangle is a support ticket.
enum InAppStyleKit {

    /// Parse `#rrggbb` (or `#rgb`, or with an alpha pair) into a Color.
    ///
    /// Returns nil rather than a default so callers can distinguish "the author
    /// chose nothing" from "the author chose something unparseable" — only the
    /// former should fall back silently.
    static func color(_ hex: String?) -> Color? {
        guard var raw = hex?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }

        // #rgb is a legal CSS shorthand a dashboard may well emit.
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }
        guard raw.count == 6 || raw.count == 8, let value = UInt64(raw, radix: 16) else {
            return nil
        }

        let r, g, b, a: Double
        if raw.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Clamp a dashboard number into something a layout can survive.
    ///
    /// Clamped rather than rejected: a slider that produced a silly value
    /// should degrade, not break a campaign the marketer has finished writing.
    static func clamp(_ value: Double?, _ range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    static func cornerRadius(_ style: InAppStyle) -> CGFloat {
        CGFloat(clamp(style.borderRadius, 0...48, default: 14))
    }

    static func padding(_ style: InAppStyle) -> CGFloat {
        CGFloat(clamp(style.padding, 0...48, default: 20))
    }

    static func margin(_ style: InAppStyle) -> CGFloat {
        CGFloat(clamp(style.margin, 0...48, default: 12))
    }

    static func titleFont(_ style: InAppStyle) -> Font {
        .system(size: clamp(style.titleFontSize, 12...40, default: 18), weight: .semibold)
    }

    static func bodyFont(_ style: InAppStyle) -> Font {
        .system(size: clamp(style.bodyFontSize, 10...32, default: 15))
    }

    static func opacity(_ style: InAppStyle) -> Double {
        clamp(style.opacity, 0...1, default: 1)
    }

    static func background(_ style: InAppStyle) -> Color {
        color(style.backgroundColor) ?? Color(uiColor: .systemBackground)
    }

    static func titleColor(_ style: InAppStyle) -> Color {
        color(style.titleColor) ?? Color(uiColor: .label)
    }

    static func bodyColor(_ style: InAppStyle) -> Color {
        color(style.bodyColor) ?? Color(uiColor: .secondaryLabel)
    }

    static func headerColor(_ style: InAppStyle) -> Color {
        color(style.headerColor) ?? Color(uiColor: .secondaryLabel)
    }

    /// The SwiftUI transition for an entry/exit animation.
    static func transition(_ style: InAppStyle, edge: Edge) -> AnyTransition {
        switch style.animation ?? .slide {
        case .slide: return .move(edge: edge).combined(with: .opacity)
        case .fade: return .opacity
        case .scale: return .scale(scale: 0.92).combined(with: .opacity)
        case .none: return .identity
        }
    }
}

#endif
