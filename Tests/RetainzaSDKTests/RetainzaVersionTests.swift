import XCTest

@testable import RetainzaSDK

/// Guards the two hand-maintained facts in this package: the version constant
/// and the podspec that has to agree with it.
final class RetainzaVersionTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(RetainzaVersion.current.isEmpty)
        XCTAssertEqual(Retainza.version, RetainzaVersion.current)
    }

    /// `RetainzaVersion.current` and `RetainzaSDK.podspec`'s `s.version` are two
    /// copies of one number. CocoaPods reads the podspec, SwiftPM consumers
    /// read the constant, and nothing in either toolchain cross-checks them —
    /// so if they drift, a pod-installed app silently reports a different
    /// `sdk_version` than an SPM-installed one and campaign targeting on SDK
    /// version quietly misfires. This test is that missing cross-check.
    func testPodspecVersionMatchesConstant() throws {
        // #filePath is <package>/Tests/RetainzaSDKTests/RetainzaVersionTests.swift,
        // so three deletions land on the package root next to the podspec.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let podspec = packageRoot.appendingPathComponent("RetainzaSDK.podspec")

        let source = try String(contentsOf: podspec, encoding: .utf8)
        let declared = source
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("s.version") else { return nil }
                // s.version = "0.0.1-alpha"  ->  0.0.1-alpha
                return trimmed.split(separator: "\"").dropFirst().first.map(String.init)
            }
            .first

        XCTAssertEqual(
            declared,
            RetainzaVersion.current,
            "RetainzaSDK.podspec and RetainzaVersion.current disagree. Bump both together."
        )
    }
}
