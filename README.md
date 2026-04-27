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

## Quick start

Add `swift-inspector` as a Swift package dependency of your iOS app and
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

You also need an `NSLocalNetworkUsageDescription` string in `Info.plist`
so iOS will allow the listener to accept connections. See
[docs/integration.md](docs/integration.md) for the full setup including
the build flag that gates inspection out of App Store releases.

## Privacy

Inspector-enabled builds expose view text, screenshots, and Bonjour
discovery over the local network. Ship them to internal channels only
(TestFlight Internal, Ad-hoc, dogfood), never to public TestFlight or the
App Store. See [docs/privacy.md](docs/privacy.md) for the full posture.

## Using the client

1. Launch the iOS app on a device on the same local network as your Mac.
2. Open the macOS `InspectApp`. The device appears in the sidebar picker
   once Bonjour discovery resolves it.
3. Select the device and press **Connect** to capture the current
   hierarchy, then use **Live** for auto-refreshing updates.

## Installing the macOS client

Download the latest `InspectApp-<version>.zip` from
[Releases](https://github.com/yuta24/swift-inspector/releases), unzip,
and drag `InspectApp.app` into `~/Applications/` (or another location
you can write to — Sparkle needs write access to replace the bundle
during updates).

Built-in update checking: the app checks once at launch and again
every 24 hours, and you can trigger a manual check via **swift-inspector
→ アップデートを確認…** in the menu bar.

## License

MIT — see [`LICENSE`](LICENSE). Bundled third-party software (DeviceKit,
Sparkle) is attributed in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Acknowledgments

The split-process design (small server SDK linked into the host iOS
app, separate native client over Bonjour) is directly inspired by
[**LookinServer**](https://github.com/QMUI/LookinServer) — the
underlying architectural shape, the service-on-iOS / inspector-on-macOS
split, and the live update flow all owe a clear debt to that project.
If you need the broadest feature surface and don't mind an
Objective-C-first SDK, LookinServer is the more mature choice.

swift-inspector exists in that space because we wanted:

- A **Swift-native, Swift-Package-Manager-only** integration with no
  Objective-C runtime or CocoaPods baggage.
- A **designer-first** macOS client — 3D scene navigation, live
  hierarchy diff, reduced jargon — instead of an engineer-first one.
- Tight scope: only what's needed for a designer / QA reviewing builds
  on a real device, not a full debugger replacement.

Other projects in the same space worth knowing about: [Reveal][reveal]
(commercial), [FLEX][flex] (in-app overlay, no companion app), and the
runtime view debugger built into Xcode itself.

[reveal]: https://revealapp.com
[flex]: https://github.com/flipboard/FLEX
