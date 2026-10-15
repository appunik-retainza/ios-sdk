import Foundation

/// What an HTML in-app document asked for through `window.engage`.
enum InAppBridgeMessage: Equatable {
    /// A CTA. Without a route, the message's own route is used, as for a native button.
    case cta(InAppRoute?)
    case dismiss
    case track(String, [String: AttrValue])
}

/// The JS bridge between an HTML in-app document and the app.
///
/// The same contract as the React Native SDK's `bridge.ts`: the document gets
/// exactly three verbs (`engage.cta`, `engage.dismiss`, `engage.track`), and
/// they land on the same handlers the native presentations call, so an HTML
/// campaign's clicks and dismissals are counted exactly like a native one's.
///
/// Pure on purpose: the parser and the injected script are the security
/// boundary, and they are unit-tested without a WebView.
enum InAppBridge {
    /// Name of the `WKScriptMessageHandler` the page posts to.
    static let handlerName = "retainza"

    /// Longest message the page may post. Anything longer is ignored, not truncated.
    static let maxMessageLength = 8_192

    /// `default-src 'none'` means no fetch, XHR, WebSocket, beacon, frame or
    /// remote script: a campaign cannot phone home or exfiltrate anything it can
    /// see. Images over https and as data URIs, because messages have hero
    /// images. Inline style and script, because that is how documents are
    /// authored and how the bridge is called.
    static let contentSecurityPolicy =
        "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; form-action 'none'"

    /// Defines `window.engage` before the authored document runs. One
    /// `postMessage` per call with a JSON string payload; nothing it sends is
    /// trusted on arrival.
    static let script = """
    (function () {
      function post(payload) {
        try { window.webkit.messageHandlers.\(handlerName).postMessage(JSON.stringify(payload)); } catch (e) {}
      }
      window.engage = {
        cta: function (route) { post({ type: 'cta', route: route }); },
        dismiss: function () { post({ type: 'dismiss' }); },
        track: function (event, props) { post({ type: 'track', event: event, props: props }); }
      };
    })();
    """

    /// Wrap an authored document with the CSP, the bridge and a mobile viewport.
    static func document(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:transparent;-webkit-text-size-adjust:100%;}</style>
        <script>\(script)</script>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    /// Parse what the document posted. Nil for anything unrecognised: a page can
    /// post arbitrary values, and nothing may be forwarded on trust.
    static func parse(_ body: Any?) -> InAppBridgeMessage? {
        guard let raw = body as? String, raw.utf16.count <= maxMessageLength,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch json["type"] as? String {
        case "cta":
            return .cta(route(json["route"]))
        case "dismiss":
            return .dismiss
        case "track":
            guard let event = json["event"] as? String, !event.isEmpty else { return nil }
            var properties: [String: AttrValue] = [:]
            for (key, value) in json["props"] as? [String: Any] ?? [:] {
                if let scalar = scalar(value) { properties[key] = scalar }
            }
            return .track(event, properties)
        default:
            return nil
        }
    }

    /// A route is only usable if `screen` is a non-empty string. `kv` values are
    /// coerced to strings; nested and null values are dropped, because a router
    /// handed one is a router that throws where nobody is looking.
    private static func route(_ value: Any?) -> InAppRoute? {
        guard let object = value as? [String: Any],
              let screen = object["screen"] as? String, !screen.isEmpty
        else { return nil }
        var kv: [String: String] = [:]
        for (key, value) in object["kv"] as? [String: Any] ?? [:] {
            switch scalar(value) {
            case .string(let s): kv[key] = s
            case .bool(let b): kv[key] = b ? "true" : "false"
            case .number: kv[key] = (value as? NSNumber)?.stringValue
            case .null, nil: break
            }
        }
        return InAppRoute(screen: screen, kv: kv.isEmpty ? nil : kv)
    }

    /// Strings, numbers, booleans and null. Objects and arrays are not scalars.
    private static func scalar(_ value: Any) -> AttrValue? {
        switch value {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        default:
            return nil
        }
    }
}
