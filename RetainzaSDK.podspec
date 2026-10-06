# CocoaPods manifest for the Retainza iOS SDK.
#
# SPM is the primary distribution channel; this podspec exists for the large
# number of app teams still on a Podfile. Both channels build the SAME sources
# (`s.source_files` below points at exactly the directory SwiftPM compiles), so
# there is no second copy of the code to keep in sync — only the version number,
# which `RetainzaVersionTests.testPodspecVersionMatchesConstant` cross-checks.
#
# Publishing: `pod trunk push RetainzaSDK.podspec` against the tag pushed to the
# public mirror repo. See sdk/native/README.md for the release steps.

Pod::Spec.new do |s|
  s.name         = "RetainzaSDK"
  s.version      = "1.0.0"
  s.summary      = "Retainza — user engagement, push and in-app messaging for iOS."
  s.description  = <<~DESC
    The native iOS client for Retainza. Identify users, track events, register for
    push, and display in-app messages. Talks only to Retainza's public-key-scoped
    ingest API — no secret key ever ships in an app binary.
  DESC

  s.homepage     = "https://github.com/appunik-retainza/ios-sdk"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "Retainza" => "hello@retainza.com" }

  # Points at the public mirror repo, not this monorepo: CocoaPods clones the
  # source at install time, so the URL has to be one every consumer can reach.
  s.source       = {
    :git => "https://github.com/appunik-retainza/ios-sdk.git",
    :tag => s.version.to_s
  }

  # Matches Package.swift's platform floor. Keep the two in step — a podspec
  # claiming a lower floor than the sources actually support fails at compile
  # time in the consumer's project, which is the worst place to find out.
  s.ios.deployment_target = "15.0"
  s.swift_versions = ["5.9"]

  s.source_files = "Sources/RetainzaSDK/**/*.swift"
  s.frameworks   = "Foundation"
end
