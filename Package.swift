// swift-tools-version:5.9
//
// Retainza iOS SDK — Swift Package manifest.
//
// swift-tools-version is deliberately 5.9 rather than 6.x: consumers on Xcode
// 15 must still be able to resolve this package, and nothing here needs the
// 6.x manifest API. The Swift *language* mode is likewise left at 5 (see
// swiftSettings below) so that Phase 1 can port sdk-core's logic without
// fighting strict concurrency checking on day one; tightening to language mode
// 6 is tracked as its own step once the client is feature-complete.
//
// ZERO DEPENDENCIES is a hard rule for this package. Everything it needs
// (URLSession, UserDefaults, SwiftUI, WKWebView, UserNotifications) ships in
// the OS. A mobile SDK that drags in third-party packages forces its version
// choices onto every host app, and that is the single most common reason teams
// refuse to adopt one.

import PackageDescription

let package = Package(
    name: "RetainzaSDK",
    // iOS 15 floor: SwiftUI's in-app message templates (Phase 3) need the
    // material/presentation APIs that landed in 15, and iOS 14 is under 1% of
    // installed devices.
    //
    // macOS 12 is declared because `swift test` builds for the HOST, and
    // without a floor here SwiftPM assumes macOS 10.13 — where async/await,
    // actors and `URLSession.data(for:)` do not exist, so the whole package
    // fails to compile on the one command developers run most. The floor is
    // honest rather than aspirational: the full test suite really does run on
    // macOS in CI. iOS remains the only platform the SDK is *shipped* for, and
    // the device-attribute code is `#if canImport(UIKit)`-guarded accordingly.
    //
    // watchOS and tvOS are out of scope for v1 — declaring them would imply
    // support this SDK neither builds nor tests.
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        // Product name is `Retainza` (what consumers `import`), while the package
        // and the CocoaPods pod are `RetainzaSDK`. This mirrors the naming picked
        // in the plan and keeps `import Retainza` reading naturally at call sites.
        .library(
            name: "Retainza",
            targets: ["RetainzaSDK"]
        )
    ],
    targets: [
        .target(
            name: "RetainzaSDK",
            path: "Sources/RetainzaSDK"
        ),
        .testTarget(
            name: "RetainzaSDKTests",
            dependencies: ["RetainzaSDK"],
            path: "Tests/RetainzaSDKTests"
        )
    ]
)
