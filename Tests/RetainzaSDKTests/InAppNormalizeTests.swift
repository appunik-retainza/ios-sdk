import XCTest

@testable import RetainzaSDK

/// The contract for `normalizeInApp`.
///
/// This logic now exists in four places — the backend core, the JS SDK core,
/// this package and its Kotlin twin. The TypeScript pair is kept byte-identical
/// by hand; these two cannot be. So the tests carry the contract instead, and a
/// divergence should fail here rather than surface as a campaign that looks
/// different on one platform than the other.
///
/// Every case below mirrors one in `inapp-normalize.test.ts`.
final class InAppNormalizeTests: XCTestCase {

    private func content(_ json: String) throws -> InAppContent {
        try JSONDecoder().decode(InAppContent.self, from: Data(json.utf8))
    }

    // MARK: - Layout derivation

    /// A message authored before the slot model must derive exactly the layout
    /// the original renderers hardcoded. This is what "renders byte-identically"
    /// means in practice.
    func testLegacyMessageDerivesTheHardcodedOrder() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal",
          "title": "Sale",
          "body": "Half price",
          "imageUrl": "https://x.test/a.png",
          "ctaText": "Shop"
        }
        """))

        XCTAssertEqual(resolved.layout, [.media, .title, .body, .buttons])
    }

    /// Empty slots are dropped even from an explicitly named layout: a template
    /// reused with a shorter body should close the gap, not render a blank band
    /// where text used to be.
    func testEmptySlotsAreDroppedFromANamedLayout() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal",
          "title": "Sale",
          "body": "",
          "layout": ["title", "body", "buttons"]
        }
        """))

        XCTAssertEqual(resolved.layout, [.title])
    }

    func testANamedLayoutOverridesTheDerivedOrder() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal",
          "title": "Sale",
          "body": "Half price",
          "header": "Today only",
          "layout": ["title", "header", "body"]
        }
        """))

        XCTAssertEqual(resolved.layout, [.title, .header, .body])
    }

    /// A whitespace-only header is not a header. Rendering it would produce an
    /// empty eyebrow line above the title and an unexplained gap.
    func testWhitespaceOnlyHeaderIsDropped() throws {
        let resolved = normalizeInApp(try content("""
        {"template": "modal", "title": "T", "body": "B", "header": "   "}
        """))

        XCTAssertNil(resolved.header)
        XCTAssertFalse(resolved.layout.contains(.header))
    }

    // MARK: - Media

    func testImageUrlBecomesMedia() throws {
        let resolved = normalizeInApp(try content("""
        {"template": "modal", "title": "T", "body": "B", "imageUrl": "https://x.test/a.png"}
        """))

        XCTAssertEqual(resolved.media?.url, "https://x.test/a.png")
        XCTAssertEqual(resolved.media?.kind, .image)
    }

    /// `media` wins over the older `imageUrl` spelling — a campaign that sets
    /// both meant the newer one.
    func testMediaWinsOverImageUrl() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "imageUrl": "https://x.test/old.png",
          "media": {"url": "https://x.test/new.png", "kind": "gif"}
        }
        """))

        XCTAssertEqual(resolved.media?.url, "https://x.test/new.png")
        XCTAssertEqual(resolved.media?.kind, .gif)
    }

    // MARK: - Buttons

    /// The old two-CTA pair maps exactly onto the buttons array: `ctaText` was
    /// the filled primary, `secondaryCtaText` was plain text that dismissed.
    func testLegacyCtaPairBecomesTwoButtons() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "ctaText": "Shop", "secondaryCtaText": "Later"
        }
        """))

        XCTAssertEqual(resolved.buttons.count, 2)
        XCTAssertEqual(resolved.buttons[0].text, "Shop")
        XCTAssertEqual(resolved.buttons[0].kind, .filled)
        XCTAssertEqual(resolved.buttons[1].text, "Later")
        XCTAssertEqual(resolved.buttons[1].kind, .text)
        XCTAssertNil(resolved.buttons[1].route, "a secondary CTA dismissed without navigating")
    }

    func testAuthoredButtonsWinOverLegacyCtaFields() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "ctaText": "Ignored",
          "buttons": [{"text": "Go"}]
        }
        """))

        XCTAssertEqual(resolved.buttons.map(\.text), ["Go"])
    }

    /// More than three buttons stops being a message and starts being a menu.
    /// The extras are dropped with a warning rather than rejected — a campaign
    /// the marketer has finished writing should degrade, not fail.
    func testButtonsAreCappedWithAWarning() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "buttons": [{"text":"1"},{"text":"2"},{"text":"3"},{"text":"4"}]
        }
        """))

        XCTAssertEqual(resolved.buttons.count, 3)
        XCTAssertEqual(resolved.warnings.count, 1)
        XCTAssertTrue(resolved.warnings[0].contains("only the first 3"))
    }

    func testBlankButtonLabelsAreDropped() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "buttons": [{"text": "Go"}, {"text": "   "}]
        }
        """))

        XCTAssertEqual(resolved.buttons.map(\.text), ["Go"])
    }

    /// Mirrors "blank buttons and whitespace headers do not open a slot".
    /// Dropping the button *content* but keeping the button *slot* would leave
    /// an empty band of padding where the buttons should be.
    func testAllBlankButtonsCloseTheButtonsSlot() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "header": "  ",
          "buttons": [{"text": "   "}]
        }
        """))

        XCTAssertNil(resolved.header)
        XCTAssertEqual(resolved.buttons.count, 0)
        XCTAssertEqual(resolved.layout, [.title, .body])
    }

    /// A campaign styled before the slot model keeps its colours once its CTA
    /// has become `buttons[0]`.
    func testFirstButtonInheritsLegacyCtaColours() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "style": {"ctaBackgroundColor": "#ff0000", "ctaTextColor": "#ffffff"},
          "buttons": [{"text": "One"}, {"text": "Two"}]
        }
        """))

        XCTAssertEqual(resolved.buttons[0].backgroundColor, "#ff0000")
        XCTAssertEqual(resolved.buttons[0].textColor, "#ffffff")
        // Later buttons deliberately do NOT inherit: those colours described
        // *the* CTA, and three identical filled buttons is not what the author
        // asked for.
        XCTAssertNil(resolved.buttons[1].backgroundColor)
        XCTAssertNil(resolved.buttons[1].textColor)
    }

    func testAButtonsOwnColoursWinOverInheritedOnes() throws {
        let resolved = normalizeInApp(try content("""
        {
          "template": "modal", "title": "T", "body": "B",
          "style": {"ctaBackgroundColor": "#ff0000"},
          "buttons": [{"text": "One", "backgroundColor": "#00ff00"}]
        }
        """))

        XCTAssertEqual(resolved.buttons[0].backgroundColor, "#00ff00")
    }

    // MARK: - Dismissible

    /// Everything is dismissible except a banner, which auto-dismisses instead
    /// of carrying an ✕.
    func testBannersAreNotDismissibleByDefault() throws {
        let banner = normalizeInApp(try content(#"{"template":"banner","title":"T","body":"B"}"#))
        let modal = normalizeInApp(try content(#"{"template":"modal","title":"T","body":"B"}"#))

        XCTAssertFalse(banner.dismissible)
        XCTAssertTrue(modal.dismissible)
    }

    func testAnExplicitDismissibleWins() throws {
        let resolved = normalizeInApp(
            try content(#"{"template":"banner","title":"T","body":"B","dismissible":true}"#)
        )
        XCTAssertTrue(resolved.dismissible)
    }

    // MARK: - Equivalence

    /// The property the whole normaliser exists for: an old campaign and its
    /// hand-written modern equivalent must produce the same render input.
    func testLegacyAndModernSpellingsNormaliseIdentically() throws {
        let legacy = normalizeInApp(try content("""
        {
          "template": "modal", "title": "Sale", "body": "Half price",
          "imageUrl": "https://x.test/a.png", "ctaText": "Shop"
        }
        """))
        let modern = normalizeInApp(try content("""
        {
          "template": "modal", "title": "Sale", "body": "Half price",
          "media": {"url": "https://x.test/a.png", "kind": "image"},
          "buttons": [{"text": "Shop", "kind": "filled"}]
        }
        """))

        XCTAssertEqual(legacy.layout, modern.layout)
        XCTAssertEqual(legacy.media, modern.media)
        XCTAssertEqual(legacy.buttons, modern.buttons)
        XCTAssertEqual(legacy.dismissible, modern.dismissible)
    }
}

final class InAppDecodingTests: XCTestCase {

    /// A newer dashboard can author a template this build has never heard of.
    /// Decoding it as `selfhandled` means it stays pending rather than
    /// crashing the poll or being consumed and lost.
    func testUnknownTemplateDecodesAsSelfHandled() throws {
        let content = try JSONDecoder().decode(
            InAppContent.self,
            from: Data(#"{"template":"carousel","title":"T","body":"B"}"#.utf8)
        )
        XCTAssertEqual(content.template, .selfhandled)
    }

    func testMessageDecodesIdAndRouteAlongsideContent() throws {
        let message = try JSONDecoder().decode(
            InAppMessage.self,
            from: Data("""
            {
              "msgId": "m1",
              "template": "modal",
              "title": "T",
              "body": "B",
              "route": {"screen": "cart", "kv": {"id": "7"}}
            }
            """.utf8)
        )

        XCTAssertEqual(message.msgId, "m1")
        XCTAssertEqual(message.route?.screen, "cart")
        XCTAssertEqual(message.route?.kv, ["id": "7"])
        XCTAssertEqual(message.content.title, "T")
    }

    func testAspectRatiosConvertToNumbers() {
        XCTAssertEqual(InAppAspect.oneToOne.ratio, 1)
        XCTAssertEqual(InAppAspect.twoToOne.ratio, 2)
        XCTAssertEqual(InAppAspect.threeToFour.ratio, 0.75)
    }
}
