# Privacy & security

The inspector exposes the running app's UI to anyone on the same local
network. Treat every build that includes `InspectServer` as a build that
**leaks UI state over the wire**, and choose your distribution channels
accordingly.

## What gets exposed

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

## Recommended posture

- Ship inspector-enabled builds only to internal channels (TestFlight
  Internal, Ad-hoc, dogfood) — never to public TestFlight or the App
  Store.
- Run inspector sessions on trusted networks (office VLAN, personal
  hotspot), not open Wi-Fi.
- The compile-time gate is the primary defense. Verify in your CI
  release pipeline that `SWIFT_INSPECTOR_ENABLED` is **not** set on the
  App Store configuration before submission.
