import Foundation

/// Which presentation an in-app message uses.
public enum InAppTemplate: String, Codable, Sendable {
    case modal, banner, fullscreen, bottomsheet, html

    /// The SDK renders nothing and hands the payload to a handler the host app
    /// registered. The escape hatch for a design the catalogue cannot express;
    /// the app owns the acks, so analytics only stays honest if it sends them.
    case selfhandled
}

/// The atoms every native layout is built from.
///
/// Layout is modelled as *which slots are present and in what order*, not as an
/// enum of named combinations. Ten names today is thirty within a year, each
/// one a branch in every renderer — and "image + text + button" differs from
/// "image + header + text + button" by exactly one slot. Naming the atoms means
/// a new variant is data, never a code change.
public enum InAppSlot: String, Codable, Sendable, CaseIterable {
    case media, header, title, body, buttons
}

/// Aspect ratios the media box supports.
///
/// A fixed list rather than a free string: the renderer turns these into a
/// numeric ratio, and an unparseable one would collapse the image box to zero
/// height on a device we cannot see.
public enum InAppAspect: String, Codable, Sendable {
    case oneToOne = "1:1"
    case threeToTwo = "3:2"
    case twoToOne = "2:1"
    case threeToFour = "3:4"
    case threeToFive = "3:5"
    case fiveToOne = "5:1"
    case sixToOne = "6:1"

    /// Width ÷ height, for the renderer.
    public var ratio: Double {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return 1 }
        return parts[0] / parts[1]
    }
}

/// The picture, GIF or video in the `media` slot.
public struct InAppMedia: Codable, Sendable, Equatable {
    /// Must be https — this URL is fetched by every recipient's device.
    public var url: String
    public var kind: Kind?
    public var fit: Fit?
    public var aspect: InAppAspect?
    /// Screen-reader description. Personalisable, like any other text.
    public var alt: String?

    public enum Kind: String, Codable, Sendable { case image, gif, video }
    public enum Fit: String, Codable, Sendable { case cover, contain }

    public init(
        url: String,
        kind: Kind? = nil,
        fit: Fit? = nil,
        aspect: InAppAspect? = nil,
        alt: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.fit = fit
        self.aspect = aspect
        self.alt = alt
    }
}

public enum InAppButtonKind: String, Codable, Sendable {
    case filled, outlined, text
}

/// One action button. Up to `maxInAppButtons` per message.
///
/// A button with no `route` dismisses without navigating — which is exactly
/// what the pre-slot-model `secondaryCtaText` meant, and why the normaliser can
/// express the old two-CTA shape as a plain `buttons` array with nothing lost.
public struct InAppButton: Codable, Sendable, Equatable {
    public var text: String
    /// Default: `.filled` for the first button, `.text` for the rest.
    public var kind: InAppButtonKind?
    /// Omit to dismiss without navigating.
    public var route: InAppRoute?
    public var backgroundColor: String?
    public var textColor: String?
    public var borderColor: String?
    public var borderRadius: Double?
    public var fontSize: Double?

    public init(
        text: String,
        kind: InAppButtonKind? = nil,
        route: InAppRoute? = nil,
        backgroundColor: String? = nil,
        textColor: String? = nil,
        borderColor: String? = nil,
        borderRadius: Double? = nil,
        fontSize: Double? = nil
    ) {
        self.text = text
        self.kind = kind
        self.route = route
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.borderColor = borderColor
        self.borderRadius = borderRadius
        self.fontSize = fontSize
    }
}

/// More than three buttons stops being a message and starts being a menu.
public let maxInAppButtons = 3

/// `Route` in its decodable form.
///
/// A separate type from `Route` only because `Route` is hand-built by the push
/// parser from string keys, while this one comes off the wire as JSON. They
/// carry the same two fields and `asRoute` bridges them.
public struct InAppRoute: Codable, Sendable, Equatable {
    public var screen: String
    public var kv: [String: String]?

    public init(screen: String, kv: [String: String]? = nil) {
        self.screen = screen
        self.kv = kv
    }

    public var asRoute: Route { Route(screen: screen, kv: kv) }
}

public enum InAppAnimation: String, Codable, Sendable {
    case slide, fade, scale, none
}

/// Optional per-message styling.
///
/// Colours are `#rrggbb`, validated at the API boundary since these strings are
/// handed to a mobile renderer. Numbers are *clamped* by the renderer rather
/// than rejected: a slider that produced a silly value should degrade, not
/// break a campaign the marketer has finished writing.
public struct InAppStyle: Codable, Sendable, Equatable {
    public var backgroundColor: String?
    public var titleColor: String?
    public var bodyColor: String?
    /// Still honoured: seeds the first button when it has no colours of its own.
    public var ctaBackgroundColor: String?
    public var ctaTextColor: String?
    /// Banner only: which edge it docks to. Default `.top`.
    public var position: Position?
    /// Must be https, same reasoning as `InAppMedia.url`.
    public var backgroundImageUrl: String?
    /// 0–1, applied to the card. The backdrop dim is separate and fixed.
    public var opacity: Double?
    public var borderWidth: Double?
    public var borderRadius: Double?
    public var borderColor: String?
    /// Outer gap from the screen edge — mainly banners.
    public var margin: Double?
    /// Inner gap around the content.
    public var padding: Double?
    public var headerColor: String?
    public var titleFontSize: Double?
    public var bodyFontSize: Double?
    public var animation: InAppAnimation?
    /// Which corner the ✕ sits in. Default `.right`.
    public var closePosition: ClosePosition?

    public enum Position: String, Codable, Sendable { case top, bottom }
    public enum ClosePosition: String, Codable, Sendable { case left, right }

    public init() {}
}

/// Which shell an HTML message's WebView fills.
public enum InAppHtmlFrame: String, Codable, Sendable {
    case modal, fullscreen, bottomsheet
}

/// An in-app message exactly as the server sent it.
///
/// Every optional field here is a *possibility*, not a guarantee — which is why
/// nothing renders from this type directly. `normalizeInApp` turns it into a
/// `ResolvedInApp` where each field is either resolved or absent, and the
/// renderers only ever see that.
public struct InAppContent: Decodable, Sendable {
    public var template: InAppTemplate
    public var title: String
    public var body: String

    /// Slot order. Omitted = derived from which fields are set.
    public var layout: [InAppSlot]?
    /// A small eyebrow line above the title.
    public var header: String?
    /// Supersedes `imageUrl`, which stays readable for older campaigns.
    public var media: InAppMedia?
    /// Supersedes `ctaText` / `secondaryCtaText`. Capped at `maxInAppButtons`.
    public var buttons: [InAppButton]?

    /// Deprecated — normalised into `buttons[0]`.
    public var ctaText: String?
    /// Deprecated — normalised into `media`.
    public var imageUrl: String?
    /// Deprecated — normalised into a route-less trailing button.
    public var secondaryCtaText: String?

    /// Show a close (✕) control. Defaults to true except for banners.
    public var dismissible: Bool?
    /// Banner: auto-dismiss after this many ms. 0/nil = stays until acted on.
    public var autoDismissMs: Double?
    public var style: InAppStyle?

    /// `template == .html`: the document rendered in a sandboxed WebView.
    ///
    /// `title`, `body` and the buttons stay meaningful even for an HTML
    /// message: they are what the notifications log shows, and what the SDK
    /// falls back to when the document fails to load. An HTML-only campaign
    /// would otherwise vanish on those devices.
    public var html: String?
    public var htmlFrame: InAppHtmlFrame?

    /// Decoding never throws on an unknown template.
    ///
    /// A newer dashboard can author a template this build has never heard of,
    /// and the whole poll response must not fail to parse because of one
    /// message. Unknown templates decode as `.selfhandled`, which the SDK
    /// already knows how to leave alone — it stays pending rather than being
    /// consumed and lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTemplate = try c.decode(String.self, forKey: .template)
        template = InAppTemplate(rawValue: rawTemplate) ?? .selfhandled
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        layout = try? c.decodeIfPresent([InAppSlot].self, forKey: .layout)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        media = try? c.decodeIfPresent(InAppMedia.self, forKey: .media)
        buttons = try? c.decodeIfPresent([InAppButton].self, forKey: .buttons)
        ctaText = try c.decodeIfPresent(String.self, forKey: .ctaText)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        secondaryCtaText = try c.decodeIfPresent(String.self, forKey: .secondaryCtaText)
        dismissible = try c.decodeIfPresent(Bool.self, forKey: .dismissible)
        autoDismissMs = try c.decodeIfPresent(Double.self, forKey: .autoDismissMs)
        style = try? c.decodeIfPresent(InAppStyle.self, forKey: .style)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        htmlFrame = try? c.decodeIfPresent(InAppHtmlFrame.self, forKey: .htmlFrame)
    }

    private enum CodingKeys: String, CodingKey {
        case template, title, body, layout, header, media, buttons
        case ctaText, imageUrl, secondaryCtaText, dismissible, autoDismissMs
        case style, html, htmlFrame
    }
}

/// One pending message: its content, plus who it is and where it goes.
public struct InAppMessage: Decodable, Sendable {
    public let msgId: String
    public let route: InAppRoute?
    public let content: InAppContent

    public var template: InAppTemplate { content.template }

    public init(from decoder: Decoder) throws {
        // msgId and route ride at the same level as the content fields on the
        // wire, so both decode from the same container rather than a nested one.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        msgId = try c.decode(String.self, forKey: .msgId)
        route = try? c.decodeIfPresent(InAppRoute.self, forKey: .route)
        content = try InAppContent(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case msgId, route
    }
}

/// What the user did with a message.
///
/// `shown` is what the funnel counts as delivered — a message the app chose not
/// to draw was not shown, which is why the SDK never acks it on the app's
/// behalf.
public enum InAppAction: String, Sendable {
    case shown, clicked, dismissed
}
