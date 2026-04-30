# Changelog

All notable changes to swift-inspector are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-04-30

The first tagged release. Bundles the runtime view-hierarchy
inspector for iOS apps with a designer-first macOS client.

### Added

- **Runtime hierarchy capture** over a Bonjour + TCP service published
  by `InspectServer` from inside the host iOS app. Captures view tree,
  frames in window-space, screenshots (group + solo), Auto Layout
  constraints, typography, colors, and accessibility metadata.
- **macOS client (`AppInspector`)** with:
  - 2D screen-faithful canvas with optional Figma frame overlay,
    opacity slider, alignment guides, and per-layer diff.
  - 3D exploded-stack canvas with adjustable layer spacing and grid.
  - Inspector pane with collapsible Frame / Appearance / Typography /
    Layer / Measurement / Constraints / Properties / Accessibility
    sections; ancestor breadcrumb; per-section persistent expanded
    state.
  - Hierarchy tree with text + property filters ("hidden", "zero
    size", "transparent", "differing from Figma only"), focus mode,
    and stable expansion across live captures.
  - Live mode (server-push subscription, falls back to client polling
    against older servers) with selectable refresh interval.
  - Distance / overlap measurement between two views (Option-hover
    or pin-as-reference).
- **Pairing security**: every macOS client must be approved at the
  device-side prompt before any inspection traffic flows; approvals
  can be remembered as "Always allow" and revoked from the host app
  via `InspectServer.forgetAllPairedClients()`.
- **Connect by IP** fallback for environments where Bonjour discovery
  is blocked (corp Wi-Fi with client isolation, guest networks).
  Sidebar **Connect by IP…** button on the Mac, plus
  `InspectServer.presentConnectionInfo()` on the device side that
  shows a full-screen `host:port` overlay with long-press-to-copy.
- **Bug bundle export / offline viewer**: capture the current
  hierarchy (with screenshots, handshake metadata, and optional
  repro notes) as a single `.swiftinspector` JSON file via
  **File ▷ Export Bug Bundle…** (⌘⇧E). Re-open via
  **File ▷ Open Bug Bundle…** (⌘O) or by dragging the file onto the
  window — the inspector, scenes, measurement, and Figma diff all
  work against archived data without a connected device. Re-export
  preserves the original capture metadata so a triaging engineer can
  add notes and forward the bundle without losing the device label.
- **Crash-report integration**: AppInspector scans
  `~/Library/Logs/DiagnosticReports/` on launch and offers to
  pre-fill a GitHub issue when its own bundle has crashed, with an
  always-visible re-enable affordance under the menu bar.
- **Sparkle auto-update** wired in for the macOS client (launch +
  every 24h, manual check via menu bar).
- **Figma comparison**: paste a Figma frame URL, fetch the rendered
  image with Personal Access Token, and overlay it on the 2D canvas;
  per-layer diff (frame / size / typography / color) surfaces
  matched layers and "Differing only" filtering on the hierarchy
  tree. PAT is stored in the Keychain.
- **Build flag gating**: the inspector compiles to nothing unless
  `DEBUG` or `SWIFT_INSPECTOR_ENABLED` is set, so App Store builds
  cannot accidentally ship it. See [docs/integration.md](docs/integration.md)
  and [docs/privacy.md](docs/privacy.md).
- **DocC** for `InspectServer.start(serviceName:)`.
- **Localization**: bilingual UI (English source language + Japanese)
  via xcstrings catalog.

### Notes

- The Bonjour-discovered device name reflects `UIDevice.current.name`,
  which on iOS 16+ returns the model name ("iPhone") for apps without
  the user-assigned-device-name entitlement. To disambiguate multiple
  devices in the picker, pass an explicit `serviceName` to
  `InspectServer.start(serviceName:)`.
- Manually-added endpoints from "Connect by IP…" are kept in memory
  for the running session only; they need to be re-typed on next
  launch.
- AppInspector ships without a custom app icon in this release;
  Finder and the Dock show the generic placeholder. A real icon is
  planned for a future version.

[Unreleased]: https://github.com/yuta24/swift-inspector/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yuta24/swift-inspector/releases/tag/v0.1.0
