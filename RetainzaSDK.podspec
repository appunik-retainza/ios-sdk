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

  s.source       = {
    :git => "https://github.com/appunik-retainza/ios-sdk.git",
    :tag => s.version.to_s
  }

  s.ios.deployment_target = "15.0"
  s.swift_versions = ["5.9"]

  s.source_files = "Sources/RetainzaSDK/**/*.swift"
  s.frameworks   = "Foundation"
end
