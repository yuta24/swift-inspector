# swift-inspector

A runtime view hierarchy inspector for iOS apps, with a companion macOS
client that renders the hierarchy as an interactive 3D scene. Designed to
be usable against real devices without Xcode attached — for example during
designer review or QA on an internal TestFlight/Ad-hoc build.

## Components

- **InspectServer** — Swift package linked into the iOS app. Publishes a
  Bonjour service, captures the window hierarchy on request, and streams
  live updates.
- **InspectApp** — macOS client that discovers servers on the local
  network and inspects them.
- **InspectCore** — shared wire format, models, and message protocol.

## Integration

Add `InspectServer` as a Swift package dependency of your iOS app and
start the server at launch:

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

## Build configurations

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

## Using the client

1. Launch the iOS app on a device on the same local network as your Mac.
2. Open the macOS `InspectApp`. The device appears in the sidebar picker
   once Bonjour discovery resolves it.
3. Select the device and press **Connect** to capture the current
   hierarchy, then use **Live** for auto-refreshing updates.
