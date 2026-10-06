import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// The reserved attribute vocabulary.
///
/// Retainza stores a profile as one JSON attribute bag, and every filter, segment
/// and personalisation token reads that bag. So "add a first-name field" is not
/// a schema change — it is an agreement about a *name*. These constants are
/// that agreement, and they must match `sdk-core/src/context.ts` exactly: a
/// segment built against `first_name` silently misses every user whose SDK
/// spelled it `firstName`.
///
/// Grouped by who is responsible for the value, because that distinction is the
/// whole privacy story: auto attributes need no permission and no app code,
/// supplied attributes can only come from the app and are usually PII.
public enum AutoAttribute {
    public static let platform = "platform"
    public static let appVersion = "app_version"
    public static let sdkVersion = "sdk_version"
    public static let installDate = "install_date"
    public static let lastActive = "last_active"
    public static let language = "language"
    public static let country = "country"
    public static let timezone = "tz"
    public static let deviceModel = "device_model"
    public static let deviceManufacturer = "device_manufacturer"
    public static let osName = "os_name"
    public static let osVersion = "os_version"
    public static let sessionCount = "session_count"
    public static let firstSessionAt = "first_session_at"
    public static let lastSessionAt = "last_session_at"
    public static let sessionDurationTotal = "session_duration_total"
    public static let pushPermission = "push_permission"

    public static let all = [
        platform, appVersion, sdkVersion, installDate, lastActive,
        language, country, timezone,
        deviceModel, deviceManufacturer, osName, osVersion,
        sessionCount, firstSessionAt, lastSessionAt, sessionDurationTotal,
        pushPermission,
    ]
}

/// Reserved identity fields. PII — only the app can know these.
public enum SuppliedAttribute {
    public static let firstName = "first_name"
    public static let lastName = "last_name"
    public static let email = "email"
    public static let phone = "phone"
    public static let gender = "gender"
    public static let birthdate = "birthdate"

    public static let all = [firstName, lastName, email, phone, gender, birthdate]
}

/// Consent flags, written by `setConsent`.
public enum ConsentAttribute {
    public static let marketing = "consent_marketing"
    public static let analytics = "consent_analytics"

    public static let all = [marketing, analytics]
}

public enum ReservedAttribute {
    public static let all = AutoAttribute.all + SuppliedAttribute.all + ConsentAttribute.all
}

/// The OS-level notification permission, as the app already knows it.
///
/// The SDK never prompts: prompting is a product decision with exactly one shot
/// per install, so it belongs to the app. This is the difference between "has a
/// token" and "can actually be reached" — a revoked permission leaves a
/// perfectly valid token behind that silently drops every push.
public enum PushPermission: String, Sendable {
    case authorized, denied, provisional, undetermined
}

/// The platform value sent with a push token. Always `.ios` from this SDK.
public enum Platform: String, Codable, Sendable {
    case ios, android
}

/// What happened to a push notification.
///
/// `delivered` means the payload reached the device and the app saw it;
/// `opened` means the user tapped it. Neither is observable server-side —
/// APNs and FCM both report only that they accepted the send — so these acks
/// are the sole source of every delivery and open rate in the dashboard.
public enum PushAction: String, Sendable {
    case delivered, opened
}

/// The rich identity an app can supply alongside its own attributes.
///
/// Deliberately camelCase at the API and snake_case on the wire: developers
/// write `firstName`, filters and personalisation tokens read `first_name`, and
/// `attributesAndColumns()` is the single place the two are reconciled.
public struct RetainzaProfile: Sendable {
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    /// E.164 recommended, e.g. "+919876543210".
    public var phone: String?
    public var gender: String?
    /// ISO-8601 date, e.g. "1994-07-21".
    public var birthdate: String?
    /// BCP-47, e.g. "en-IN". Stored as a column, not an attribute.
    public var locale: String?

    public init(
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        gender: String? = nil,
        birthdate: String? = nil,
        locale: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.gender = gender
        self.birthdate = birthdate
        self.locale = locale
    }

    /// Split into wire attributes plus the two top-level columns.
    ///
    /// `email` is both a column (so the audience list can show an address
    /// without unpacking JSON per row) and an attribute (so filters see it like
    /// anything else). Blank strings are dropped rather than sent — writing an
    /// empty `first_name` would overwrite a good value with nothing.
    func attributesAndColumns() -> (attributes: [String: AttrValue], email: String?, locale: String?) {
        var attributes: [String: AttrValue] = [:]
        func put(_ key: String, _ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return }
            attributes[key] = .string(trimmed)
        }
        put(SuppliedAttribute.firstName, firstName)
        put(SuppliedAttribute.lastName, lastName)
        put(SuppliedAttribute.email, email)
        put(SuppliedAttribute.phone, phone)
        put(SuppliedAttribute.gender, gender)
        put(SuppliedAttribute.birthdate, birthdate)

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocale = locale?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            attributes,
            (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil,
            (trimmedLocale?.isEmpty == false) ? trimmedLocale : nil
        )
    }
}

/// Device and locale facts the SDK collects itself.
///
/// A NOTE ON WHAT NATIVE BUYS US
/// -----------------------------
/// `sdk-core` leaves `device_model` and `device_manufacturer` empty and relies
/// on the host app to inject them, because Metro resolves imports statically
/// and a JS SDK cannot optionally reach a native module. This SDK *is* the
/// native layer, so it fills them in with no app code at all — one of the few
/// places the native port is strictly better than the JS one rather than
/// merely equivalent.
///
/// Everything is best-effort. A value that cannot be read is omitted rather
/// than guessed: a missing attribute is recoverable, a wrong one silently
/// changes who receives a campaign.
/// Named `Attributes`, NOT `Context`, and that is load-bearing.
///
/// A module-level `Context` shadows SwiftUI's `Context` typealias inside every
/// `UIViewRepresentable` in this module, and the resulting error names the
/// return type rather than the shadowing — an afternoon to find. Matching the
/// Kotlin port's `Attributes` object keeps the two readable side by side too.
enum Attributes {
    /// Timezone, language and country.
    ///
    /// Country comes from the device's *locale* region, not GPS — good enough
    /// for targeting and the only signal available without a permission prompt.
    /// `tz` powers user-local campaign scheduling, which is why it is collected
    /// even though it looks redundant next to `country`.
    static func collect() -> [String: AttrValue] {
        var out: [String: AttrValue] = [:]

        out[AutoAttribute.timezone] = .string(TimeZone.current.identifier)

        if #available(iOS 16.0, macOS 13.0, *) {
            if let language = Locale.current.language.languageCode?.identifier, !language.isEmpty {
                out[AutoAttribute.language] = .string(language.lowercased())
            }
            if let region = Locale.current.region?.identifier, !region.isEmpty {
                out[AutoAttribute.country] = .string(region.uppercased())
            }
        } else {
            if let language = Locale.current.languageCode, !language.isEmpty {
                out[AutoAttribute.language] = .string(language.lowercased())
            }
            if let region = Locale.current.regionCode, !region.isEmpty {
                out[AutoAttribute.country] = .string(region.uppercased())
            }
        }

        out[AutoAttribute.platform] = .string(Platform.ios.rawValue)
        out[AutoAttribute.sdkVersion] = .string(RetainzaVersion.current)

        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !appVersion.isEmpty {
            out[AutoAttribute.appVersion] = .string(appVersion)
        }

        #if canImport(UIKit)
        // MainActor-isolated in newer SDKs, and this can be called from any
        // thread, so read it off the main actor only when we are already there.
        // The values are constants for the life of the process, so a cached
        // read is not a staleness risk.
        out[AutoAttribute.deviceModel] = .string(Self.deviceModel)
        out[AutoAttribute.deviceManufacturer] = .string("Apple")
        out[AutoAttribute.osName] = .string("iOS")
        out[AutoAttribute.osVersion] = .string(Self.osVersion)
        #endif

        return out
    }

    #if canImport(UIKit)
    /// The hardware identifier ("iPhone15,3"), not the marketing name.
    ///
    /// `UIDevice.model` returns "iPhone" for every iPhone ever made, which is
    /// useless for targeting. `utsname` gives the actual model, and mapping it
    /// to a marketing name is the dashboard's job — a lookup table shipped in
    /// an app binary goes stale the day new hardware ships.
    private static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        // `withUnsafeBytes(of:)` borrows `info.machine` exclusively for the
        // duration of the closure, so nothing inside may touch `info` again —
        // reading `MemoryLayout.size(ofValue: info.machine)` in there is an
        // overlapping access that fails to compile for iOS (though not for
        // the host, which is why this only surfaced in the simulator build).
        // Copying the bytes out first sidesteps it entirely.
        let bytes = withUnsafeBytes(of: &info.machine) { Array($0) }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    private static let osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    #endif

    /// Merge attribute layers into what goes on the wire. Later layers win.
    ///
    /// Order is: SDK-collected context → `config.defaultAttributes` → the
    /// values passed at the call site. The app always wins: if an integration
    /// sets its own `country` from a billing address, that is a deliberate
    /// choice and the SDK must not overwrite it.
    static func merge(_ layers: [String: AttrValue]?...) -> [String: AttrValue] {
        var out: [String: AttrValue] = [:]
        for layer in layers {
            guard let layer else { continue }
            for (key, value) in layer { out[key] = value }
        }
        return out
    }
}
