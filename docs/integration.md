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

## 3. Declare local network usage in `Info.plist`

iOS gates any local network communication behind a user prompt the first
time it happens. The listener inside `InspectServer` triggers this prompt,
so the host app must declare a usage string:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Allows runtime UI inspection from a paired Mac on the same Wi-Fi network. Only used in internal builds.</string>
```

The string is shown verbatim in the Local Network permission prompt —
write something your designers / QA team will recognize.

`NSBonjourServices` is **not** required on this side. That key only
restricts apps that *browse* for Bonjour services (the macOS client),
and macOS itself does not enforce it. Publishing a service with
`NWListener` works as long as Local Network access is granted.

If you only ship the inspector to internal builds (recommended — see
[privacy.md](privacy.md)), you can scope this key to those configurations
only by maintaining separate `Info.plist` files or by using build
settings to inject it conditionally.

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

## 5. Optional: show the IP and port on-screen

Some Wi-Fi setups (corp guest networks, conference rooms, locked-down
hotel Wi-Fi) block Bonjour while still routing direct TCP. Wire the
following into your debug menu so designers and QA can read the
device's listener address off the screen and type it into the macOS
client's **Connect by IP…** sheet:

```swift
#if DEBUG || SWIFT_INSPECTOR_ENABLED
Button("Show inspector connection info") {
    InspectServer.presentConnectionInfo()
}
#endif
```

The call brings up an overlay with `host:port` in a large monospaced
font. Tap outside the card to dismiss; long-press the address to copy
it to the pasteboard for AirDrop / chat handoff.

The function is a no-op (returns `false`, logs a warning to
Console.app) when the listener is not running, when no usable IPv4
interface is available (offline / cellular-only), or when there is no
foreground `UIWindowScene` to host the overlay. Authorization is
unchanged — every connection still goes through the device-side
pairing prompt.

## 6. Optional: stable Bonjour service name

By default the published Bonjour service name comes from
`UIDevice.current.name`, which on iOS 16+ returns the model
("iPhone") for apps without a special entitlement. If you want a more
recognizable label in the Mac client's device picker, pass an
explicit `serviceName` at start time:

```swift
#if DEBUG || SWIFT_INSPECTOR_ENABLED
InspectServer.start(serviceName: "QA-iPhone-Tanaka")
#endif
```

This is the recommended way to disambiguate when several team
members run the same model — e.g. read the value from a build-time
configuration so each device builds with a distinct label.
