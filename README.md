# SodaPush Swift SDK

SodaPush-SDK_Swift registers Apple device tokens with a deployed
[SodaPush Server](https://github.com/guoPhineas/SodaPush-Server). Add it to the
business application that receives notifications. The operator-facing
[SodaPush-Client_Swift](https://github.com/guoPhineas/SodaPush-Client_Swift)
does not embed this SDK.

## Requirements

- Swift 6.0 or later and Swift Package Manager
- iOS 15, macOS 12, watchOS 9, or visionOS 1
- A SodaPush Server at an HTTPS origin
- The app ID and registration key returned by `POST /v1/apps`

tvOS is not declared because it does not expose the corresponding third-party
remote-notification registration flow used by the coordinator.

## Add the package

In Xcode, add:

```text
https://github.com/guoPhineas/SodaPush-SDK_Swift.git
```

Or add the package in `Package.swift`:

```swift
.package(
    url: "https://github.com/guoPhineas/SodaPush-SDK_Swift.git",
    branch: "main"
)
```

The package depends on and re-exports `RuntimeSecretMacro`, so importing
`SodaPush` also makes `#Secret` available.

## Configure the client

```swift
import SodaPush

let configuration = SodaPushConfiguration(
    serverURL: URL(string: "https://push.example.com")!,
    appID: "your-app-id",
    registrationKeyID: #Secret("registration-key-id"),
    registrationSecret: #Secret("registration-secret"),
    environment: .production
)

let client = SodaPushClient(configuration: configuration)
let notifications = SodaPushNotificationCoordinator(client: client)
```

Keep the coordinator strongly referenced for as long as its convenience methods
are needed.

`serverURL` must be an HTTPS origin such as `https://push.example.com` or
`https://push.example.com:8443`. Paths, queries, fragments, and embedded
credentials are rejected.

## Register for notifications

Request authorization and start the platform registration flow:

```swift
let granted = try await notifications.requestAuthorization()
```

Forward the device token delivered by the application delegate:

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

Use the corresponding application-delegate callback on macOS or watchOS. The
coordinator deliberately does not assign `UNUserNotificationCenter.delegate`;
the host application remains responsible for foreground presentation and
notification-response handling.

To disable this installation in the configured APNs environment:

```swift
try await notifications.unregister()
```

## Installation identity

By default, `SodaPushClient` persists a stable installation UUID in the host
application's `UserDefaults`. The value is scoped by normalized Server origin,
app ID, and APNs environment. Applications that own a stable identity may
inject it explicitly:

```swift
let client = SodaPushClient(
    configuration: configuration,
    installationID: existingInstallationID
)
```

Changing the Server origin, app ID, or environment intentionally selects a
different stored identity.

## Request contract

Registration uses:

```text
PUT /v1/apps/:appID/devices/:installationID
```

Unregistration uses:

```text
DELETE /v1/apps/:appID/devices/:installationID?environment=:environment
```

Both requests contain `X-Soda-Key-ID`, `X-Soda-Timestamp`, `X-Soda-Nonce`, and
`X-Soda-Signature`. HMAC-SHA256 covers the method, canonical target, timestamp,
nonce, and SHA-256 body hash. The DELETE query is part of the canonical target.

Server errors are surfaced as `SodaPushError.server` with HTTP status, error
code, message, and request ID. Swift task cancellation remains a
`CancellationError` rather than being converted to a transport failure.

## Security boundary

Use only a least-privilege, rotatable registration credential in an application
binary. `#Secret` makes simple static string extraction harder, but it cannot
prevent extraction from a running or reverse-engineered application. It is not
device attestation. APNs `.p8` keys must remain on the Server.

## Dependency policy

`RuntimeSecretMacro` is pinned to a reviewed Git revision because that repository
does not currently publish version tags. Update the revision deliberately when
adopting macro changes. `Package.resolved` records the complete dependency graph
used by this repository's tests.

## Test

```sh
swift test
```

The suite verifies request construction, HMAC signatures, environment-scoped
unregistration, stable installation identity, error decoding, empty-token
validation, and cancellation behavior.

## Repository layout

- `Sources/SodaPush/SodaPush.swift`: configuration, transport, signing, registration, unregistration, and installation identity
- `Sources/SodaPush/SodaPushNotificationCoordinator.swift`: notification permission and platform registration bridge
- `Tests/SodaPushTests`: SDK contract and behavior tests
