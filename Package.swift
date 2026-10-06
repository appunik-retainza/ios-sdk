// swift-tools-version:5.9

import Foundation
import PackageDescription

// Tests are not published, so the test target exists only where they do.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests")

let package = Package(
    name: "RetainzaSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Retainza",
            targets: ["RetainzaSDK"]
        )
    ],
    targets: [
        .target(
            name: "RetainzaSDK",
            path: "Sources/RetainzaSDK"
        )
    ] + (hasTests ? [
        .testTarget(
            name: "RetainzaSDKTests",
            dependencies: ["RetainzaSDK"],
            path: "Tests/RetainzaSDKTests"
        )
    ] : [])
)
