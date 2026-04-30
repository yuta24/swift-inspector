# swift-inspector

A runtime view hierarchy inspector for iOS apps, with a companion macOS
client that renders the hierarchy as an interactive 3D scene. Designed to
be usable against real devices without Xcode attached — for example during
designer review or QA on an internal TestFlight/Ad-hoc build.

## Components

- **InspectServer** — Swift package linked into the iOS app. Publishes a
  Bonjour service, captures the window hierarchy on request, and streams
  live updates.
- **AppInspector** — macOS client that discovers servers on the local
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
2. Open the macOS `AppInspector`. The device appears in the sidebar picker
   once Bonjour discovery resolves it.
3. Select the device and press **Connect** to capture the current
   hierarchy, then use **Live** for auto-refreshing updates.

### When Bonjour doesn't work

Some Wi-Fi networks (corporate guest networks, conference rooms, hotels)
block multicast DNS, which prevents Bonjour discovery from finding the
device. The TCP listener itself is usually still reachable. To get
around this:

1. On the iOS device, open your debug menu and call
   `InspectServer.presentConnectionInfo()` — see
   [docs/integration.md](docs/integration.md#optional-show-the-ip-and-port-on-screen).
   The device shows its IP and port (e.g. `192.168.1.42:8765`).
2. In the AppInspector sidebar, click **Connect by IP…** and type
   the host and port. The pairing prompt and the rest of the flow are
   identical to a Bonjour-discovered connection.

### Sharing snapshots offline (bug bundles)

For asynchronous handoff to engineering — e.g. designer files a bug
without keeping the device tethered — you can export the captured
hierarchy (with screenshots and optional repro notes) as a single
`.swiftinspector` JSON file:

- **File ▷ Export Bug Bundle…** (⌘⇧E) saves the current capture.
- **File ▷ Open Bug Bundle…** (⌘O), or drag a `.swiftinspector` file
  onto the window, opens one for offline review. The 2D / 3D scene,
  hierarchy tree, measurement tools, and Figma diff all work against
  the archived data without a connected device.

## Installing the macOS client

Download the latest `AppInspector-<version>.zip` from
[Releases](https://github.com/yuta24/swift-inspector/releases), unzip,
and drag `AppInspector.app` into `~/Applications/` (or another location
you can write to — Sparkle needs write access to replace the bundle
during updates).

Built-in update checking: the app checks once at launch and again
every 24 hours, and you can trigger a manual check via **AppInspector
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
