# Integration

How to add `InspectServer` to an iOS app and gate it out of public
release builds.

## 1. Add the Swift package

Add `swift-inspector` as a Swift package dependency of your iOS app and
link the `InspectServer` product to your app target.

## 2. Start the server at launch

```swift
import InspectServer

@main
struct MyApp: App {
    init() {
        #if DEBUG || SWIFT_INSPECTOR_ENABLED
        InspectServer.start()
        #endif
    }

    var body: some Scene { /* ... */ }
}
```

The `#if` guard is required because `InspectServer` compiles to nothing
unless either `DEBUG` or `SWIFT_INSPECTOR_ENABLED` is defined — without
the guard, Release builds would fail with "Cannot find 'InspectServer'
in scope".

## 3. Declare Bonjour usage in `Info.plist`

iOS requires apps that publish or browse Bonjour services to declare
them in `Info.plist`. Without these keys, `InspectServer.start()` will
succeed but the device will never be advertised on the network — a silent
failure that's easy to miss.

```xml
<key>NSBonjourServices</key>
<array>
    <string>_swift-inspector._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>Allows runtime UI inspection from a paired Mac on the same Wi-Fi network. Only used in internal builds.</string>
```

The string under `NSLocalNetworkUsageDescription` is shown to the user
in the Local Network permission prompt the first time the app starts
the listener — write something your designers / QA team will recognize.

If you only ship the inspector to internal builds (recommended — see
[privacy.md](privacy.md)), you can scope these keys to those
configurations only by maintaining separate `Info.plist` files or by
using build settings to inject them conditionally.

## 4. Pick a build configuration

`InspectServer` is gated by a compile-time flag so that reflection,
screenshot capture, and the Bonjour/TCP listener never ship in a public
release:

| Configuration                  | Active compile flags                | InspectServer |
| ------------------------------ | ----------------------------------- | ------------- |
| Local Debug                    | `DEBUG`                             | ✅ Included   |
| Internal / TestFlight / Ad-hoc | add `SWIFT_INSPECTOR_ENABLED`       | ✅ Included   |
| App Store Release              | *(neither)*                         | ❌ Excluded   |

To enable it in a non-Debug configuration (e.g. an "Internal" scheme used
for designer review), add `SWIFT_INSPECTOR_ENABLED` to that
configuration's **Other Swift Flags** via `SWIFT_ACTIVE_COMPILATION_CONDITIONS`:

```
SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) SWIFT_INSPECTOR_ENABLED
```

**Do not** set `SWIFT_INSPECTOR_ENABLED` on your App Store configuration.
The App Store build must leave it undefined so the inspection code is
compiled out entirely. The `DEBUG || SWIFT_INSPECTOR_ENABLED` guard in
source makes this the default when you do nothing special.
