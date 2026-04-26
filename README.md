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

## Privacy & security considerations

The inspector exposes the running app's UI to anyone on the same local
network. Treat every build that includes `InspectServer` as a build that
**leaks UI state over the wire**, and choose your distribution channels
accordingly.

Concretely:

- **`accessibilityIdentifier` / `accessibilityLabel` / view text** can
  contain personal data (email addresses, account names, message bodies).
  These fields are captured verbatim and sent to the connected client.
- **Group / solo screenshots** show whatever is on screen at the moment
  of capture, including any data your app is currently displaying.
- **Bonjour discovery** advertises the device name on the local network.
  An attacker on the same Wi-Fi can see that an inspectable build is
  running, even before any client connects.
- **Device-side approval is required** for every connection, but once
  granted the session has full read access to the hierarchy until the
  app is closed.

Recommended posture:
- Ship inspector-enabled builds only to internal channels (TestFlight
  Internal, Ad-hoc, dogfood) — never to public TestFlight or the App
  Store.
- Run inspector sessions on trusted networks (office VLAN, personal
  hotspot), not open Wi-Fi.
- The compile-time gate is the primary defense. Verify in your CI
  release pipeline that `SWIFT_INSPECTOR_ENABLED` is **not** set on the
  App Store configuration before submission.

## Third-party licenses

swift-inspector links DeviceKit (in the iOS server) and Sparkle (in the
macOS client). Both are MIT-licensed and compatible with this project's
license. See [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) for
attribution and upstream URLs.

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

## Releasing a new version

Releases are fully automated by `.github/workflows/release.yml`. The
one-time setup below has to land before the first tag.

### One-time setup

**1. Generate the EdDSA key pair.** Sparkle ships `generate_keys` inside
its SPM artifact. After running `swift package resolve` in `InspectApp/`
once, locate it and run:

```sh
SIGN_TOOLS=$(find InspectApp/.build/artifacts -name generate_keys -perm +111 | head -n1)
"$SIGN_TOOLS"
```

It prints the public key on stdout and stores the private key in the
macOS Keychain. Export the private key with `"$SIGN_TOOLS" -x` and
register both into GitHub Secrets (see the table below).

**2. Create the `gh-pages` branch and enable GitHub Pages.**

```sh
git checkout --orphan gh-pages
git rm -rf .
git commit --allow-empty -m "init gh-pages"
git push origin gh-pages
git checkout main
```

Then in GitHub: **Settings → Pages → Build and deployment → Source:
Deploy from a branch → `gh-pages` / `(root)`**. The workflow publishes
`appcast.xml` to that branch and it gets served at
`https://yuta24.github.io/swift-inspector/appcast.xml` — that URL is
baked into the app via `SUFeedURL`.

**3. Register repository secrets.**

| Secret | Value |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key (`generate_keys -x` output). |
| `SPARKLE_PUBLIC_KEY`  | Matching public key, embedded into `Info.plist` at build time. |
| `DEV_ID_CERT_P12`     | Developer ID Application `.p12`, base64-encoded. |
| `DEV_ID_CERT_PASSWORD`| Password for the `.p12`. |
| `DEV_ID_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ID`, `NOTARYTOOL_PASSWORD`, `TEAM_ID` | Notarization credentials. |

### Cutting a release

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow builds the `.app`, codesigns and notarizes it, signs the
archive with the EdDSA key, uploads it as a Release asset, and updates
`appcast.xml` on `gh-pages`. Running clients pick up the new version on
their next launch or manual check.
