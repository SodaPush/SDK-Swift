# SodaPush Swift SDK

The SodaPush Swift SDK registers Apple device tokens with an APNs backend you deploy and control. [SodaPush Server](https://github.com/SodaPush/Server) can run on Cloudflare Workers, D1, and Queues within free-plan limits for small workloads; your account owns the device data and credentials. The operator UI lives in [SodaPush Admin](https://github.com/SodaPush/AdminClient-Swift).

## Requirements

- Swift 6 and Swift Package Manager
- iOS 15+, macOS 12+, watchOS 9+, or visionOS 1+
- A SodaPush HTTPS origin, app ID, and SDK registration key

## Installation

Add `https://github.com/SodaPush/SDK-Swift.git` in Xcode, or declare the package:

```swift
.package(url: "https://github.com/SodaPush/SDK-Swift.git", branch: "main")
```

Importing `SodaPush` also re-exports `RuntimeSecretMacro` and its `#Secret` macro.

## Configure and register

```swift
import SodaPush

let configuration = SodaPushConfiguration(
    serverURL: URL(string: "https://push.example.com")!,
    appID: "your-app-id",
    registrationKeyID: #Secret("registration-key-id"),
    registrationSecret: #Secret("registration-secret"),
    environment: .production
)

let context = SodaPushDeviceContext(
    userID: "customer-42",
    tags: ["paid", "beta"]
)
let client = SodaPushClient(configuration: configuration, context: context)
let notifications = SodaPushNotificationCoordinator(client: client)

let granted = try await notifications.requestAuthorization()
```

`SodaPushDeviceContext` automatically reports platform, app version/build, locale, preferred device language, and time zone. Supply custom tags and an application-defined user ID for audience targeting. Values can also be changed before the next registration:

```swift
await client.updateTags(["paid", "early-access"])
await client.updateUserID("customer-42")
```

Forward the APNs token from the application delegate:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Task {
        try await notifications.didReceiveDeviceToken(deviceToken)
    }
}
```

Keep the coordinator strongly referenced. The host app remains responsible for `UNUserNotificationCenter.delegate`, foreground presentation, and response handling.

To deactivate this installation in the configured APNs environment:

```swift
try await notifications.unregister()
```

## Identity and request security

The SDK persists an installation UUID scoped to the normalized server origin, app ID, and APNs environment. An app may pass its own UUID when it already owns a stable installation identity.

Registration and unregistration use HMAC-SHA256 signatures covering the method, canonical target, timestamp, nonce, and request-body hash. Server failures retain their HTTP status, error code, message, and request ID; task cancellation remains `CancellationError`.

Both signed device operations use HTTP POST (`/register` and `/unregister`). The unregister request carries the APNs environment in its JSON body, which is included in the signature.

Registration credentials are necessarily present in the app binary. `#Secret` raises the cost of basic static extraction but is not attestation. Never place an APNs `.p8` key in a client app.

## Test

```sh
swift test
```

The suite covers signed registration, tags and user IDs, stable installation identity, environment-scoped removal, response validation, and error propagation.
