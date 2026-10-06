import Foundation

/// What a renderer consumes. Every optional field is resolved or absent.
public struct ResolvedInApp: Sendable {
    public let template: InAppTemplate
    public let layout: [InAppSlot]
    public let title: String
    public let body: String
    public let header: String?
    public let media: InAppMedia?
    public let buttons: [InAppButton]
    public let dismissible: Bool
    public let autoDismissMs: Double?
    public let style: InAppStyle
    public let html: String?
    public let htmlFrame: InAppHtmlFrame?
    /// Anything dropped on the way through, for the SDK's debug log.
    public let warnings: [String]
}

/// Slot order used when a message does not name one.
///
/// Not an arbitrary default — it is the order the original renderers hardcoded.
/// Changing it changes how every campaign authored before the slot model looks.
private let derivedOrder: [InAppSlot] = [.media, .header, .title, .body, .buttons]

/// One shape for every in-app message, whenever it was authored.
///
/// Before the slot model, an in-app message was title + body + one `imageUrl` +
/// `ctaText` + `secondaryCtaText`, and each renderer read those fields
/// directly. Adding `layout` / `media` / `buttons` would mean every renderer
/// carrying "new field, else old field" branches — in four codebases that must
/// agree. So the compatibility lives here, as a pure function, and the
/// renderers only ever see `ResolvedInApp`.
///
/// That has a useful consequence worth stating: **an old campaign and its
/// hand-written modern equivalent normalise to the same object**, which is what
/// "renders byte-identically" actually means.
///
/// PORT NOTE — there are now FOUR copies of this logic:
/// `backend/packages/core/src/inapp-normalize.ts`,
/// `sdk/packages/core/src/inapp-normalize.ts`, this file, and its Kotlin twin.
/// The TypeScript pair is kept byte-identical by hand. These two cannot be, so
/// the tests carry the contract instead: `InAppNormalizeTests` encodes the same
/// cases as `inapp-normalize.test.ts`, and a divergence should fail there
/// rather than surface as a campaign that looks different on one platform.
public func normalizeInApp(_ content: InAppContent) -> ResolvedInApp {
    var warnings: [String] = []
    let media = resolveMedia(content)
    let buttons = resolveButtons(content, warnings: &warnings)
    let header = content.header?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? content.header
        : nil

    let present: [InAppSlot: Bool] = [
        .media: media != nil,
        .header: header != nil,
        .title: !content.title.isEmpty,
        .body: !content.body.isEmpty,
        .buttons: !buttons.isEmpty,
    ]

    // A named layout still drops empty slots: a template reused with a shorter
    // body should close the gap, not render a blank band where text used to be.
    let requested = content.layout ?? derivedOrder
    let layout = requested.filter { present[$0] == true }

    return ResolvedInApp(
        template: content.template,
        layout: layout,
        title: content.title,
        body: content.body,
        header: header,
        media: media,
        buttons: buttons,
        // Unchanged rule: everything is dismissible except a banner, which
        // auto-dismisses instead of carrying an ✕.
        dismissible: content.dismissible ?? (content.template != .banner),
        autoDismissMs: content.autoDismissMs,
        style: content.style ?? InAppStyle(),
        html: content.html,
        htmlFrame: content.htmlFrame,
        warnings: warnings
    )
}

/// `media` wins; `imageUrl` is the older spelling of the same thing.
private func resolveMedia(_ content: InAppContent) -> InAppMedia? {
    if let media = content.media, !media.url.isEmpty { return media }
    if let imageUrl = content.imageUrl, !imageUrl.isEmpty {
        return InAppMedia(url: imageUrl, kind: .image)
    }
    return nil
}

/// `buttons` wins; otherwise rebuild the old two-CTA pair.
///
/// The old pair maps exactly: `ctaText` was filled and carried the campaign's
/// route, `secondaryCtaText` was plain text that dismissed. Expressing that as
/// `buttons` loses nothing, which is why the deprecated fields can stay
/// readable forever without a second rendering path.
private func resolveButtons(_ content: InAppContent, warnings: inout [String]) -> [InAppButton] {
    if let authored = content.buttons, !authored.isEmpty {
        let kept = authored.prefix(maxInAppButtons).filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if authored.count > maxInAppButtons {
            warnings.append(
                "in-app message has \(authored.count) buttons; only the first \(maxInAppButtons) are shown"
            )
        }
        return kept.enumerated().map { withDefaults($1, index: $0, style: content.style) }
    }

    var legacy: [InAppButton] = []
    if let cta = content.ctaText, !cta.isEmpty { legacy.append(InAppButton(text: cta)) }
    if let secondary = content.secondaryCtaText, !secondary.isEmpty {
        legacy.append(InAppButton(text: secondary))
    }
    return legacy.enumerated().map { withDefaults($1, index: $0, style: content.style) }
}

/// Fill in what the author did not say.
///
/// The first button inherits `style.ctaBackgroundColor` / `ctaTextColor` so a
/// campaign styled before the slot model keeps its colours once its CTA has
/// become a `buttons[0]`. Later buttons deliberately do NOT inherit them: those
/// colours described *the* CTA, and painting three identical filled buttons is
/// not what the author asked for.
private func withDefaults(_ button: InAppButton, index: Int, style: InAppStyle?) -> InAppButton {
    var out = button
    out.kind = button.kind ?? (index == 0 ? .filled : .text)
    if index == 0 {
        if out.backgroundColor == nil { out.backgroundColor = style?.ctaBackgroundColor }
        if out.textColor == nil { out.textColor = style?.ctaTextColor }
    }
    return out
}
