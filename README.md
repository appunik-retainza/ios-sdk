# Retainza iOS SDK

Identify users, track events, receive push and show in-app messages from
[Retainza](https://retainza.com).

## Requirements

- iOS 15.0+
- Xcode 15+ (Swift 5.9+)
- No third-party dependencies. To receive push, add Firebase Messaging to your
  app and pass the **FCM** token to `RetainzaPush.handleFCMToken(_:)`.

## Install

**Swift Package Manager**: in Xcode choose *File ▸ Add Package Dependencies*
and paste:

```
https://github.com/appunik-retainza/ios-sdk
```

or add it to `Package.swift`:

```swift
.package(url: "https://github.com/appunik-retainza/ios-sdk.git", from: "1.0.0")
```

and add the product `Retainza` to your target.

## Quick start

```swift
import RetainzaSDK

// App launch
try? Retainza.start(with: RetainzaConfig(
    publicKey: "pk_test_…",            // pk_live_… in release builds
    userProvider: { AuthStore.shared.userId }
))

// After sign-in
try await Retainza.shared?.identify("user-123", attributes: ["plan": "pro"])

// Anywhere
try await Retainza.shared?.track("order_placed", properties: ["total": 42.5])

// On sign-out
await Retainza.shared?.reset()
```

The module is `RetainzaSDK`, so write `import RetainzaSDK` (not `import Retainza`).
Get your public key from the Retainza dashboard under **API keys**; the full
integration guide is in the dashboard under **Developer docs**.

## Support

Questions or issues: [hello@retainza.com](mailto:hello@retainza.com).

## License

MIT. See [LICENSE](LICENSE).
