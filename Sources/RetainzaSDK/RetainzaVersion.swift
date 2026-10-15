/// The version reported as the `sdk_version` profile attribute, and the single
/// source of truth for this package's version number.
///
/// Hand-kept in sync with `RetainzaSDK.podspec`. A Swift package has no manifest
/// the runtime can read — `Package.swift` is build-time only — so the version
/// has to be a constant somewhere, and a wrong version in telemetry is worse
/// than a duplicated string. `RetainzaVersionTests` fails the build if this and
/// the podspec ever drift, so it cannot silently go stale.
///
/// This mirrors the same arrangement in the JS SDK
/// (`sdk/packages/sdk-core/src/version.ts`), for the same reason.
public enum RetainzaVersion {
    /// Semantic version of the Retainza iOS SDK.
    public static let current = "1.1.0"
}
