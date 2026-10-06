# Retainza iOS SDK

Native Swift client for [Retainza](../../../../README.md) — identify users, track
events, register for push, and display in-app messages.

> **Status: Phase 3 — feature complete** (identify/track, collections, offline
> queue, sessions, consent, push helpers, SwiftUI in-app host). See
> [the plan](../../README.md) for the phases, and the
> [integration guide](../../../../docs/SDK-INTEGRATION-GUIDE-IOS.md) for usage.

## Requirements

- iOS 15.0+
- Swift 5.9+ (Xcode 15+)
- No third-party dependencies in the SDK. Receiving push needs Firebase
  Messaging in the app: Retainza sends through FCM, so register the **FCM**
  token with `RetainzaPush.handleFCMToken(_:)`, not the raw APNs token (see the
  guide, §4). `handleDeviceToken(_:)` is deprecated and no longer registers.

## Install

**Swift Package Manager** (primary):

```
https://github.com/appunik-retainza/ios-sdk
```

In `Package.swift`:

```swift
.package(url: "https://github.com/appunik-retainza/ios-sdk.git", from: "1.0.0")
```

**CocoaPods**:

```ruby
pod 'RetainzaSDK', '~> 1.0'
```

Then `import RetainzaSDK`. With SPM you add the product `Retainza` to your
target, but the module you import is `RetainzaSDK` (the same as the pod);
`import Retainza` does not compile.

## Developing

This package lives inside the Retainza monorepo at `sdk/native/ios/RetainzaSDK` and
is mirrored out to the public `appunik-retainza/ios-sdk` repo on release. Work
here, never in the mirror.

```bash
swift build
swift test
```

Behaviour is ported from `sdk/packages/sdk-core/src`, which remains the
behavioural source of truth for every Retainza client SDK — when the two would
disagree, the JS implementation is right and this one is a bug.
