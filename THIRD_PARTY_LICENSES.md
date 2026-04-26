# Third-Party Licenses

swift-inspector bundles or links the following third-party software. Each
upstream project is distributed under the MIT License (compatible with
this project's MIT License), and the full license text lives in the
upstream repository. Source distributions and binary releases of
swift-inspector inherit those terms.

## DeviceKit

- Used by: `InspectServer` (linked into the host iOS app)
- Repository: https://github.com/devicekit/DeviceKit
- License: MIT — https://github.com/devicekit/DeviceKit/blob/master/LICENSE
- Purpose: Device identification (model name, marketing name) reported
  alongside the inspected hierarchy.

## Sparkle

- Used by: `InspectApp` (macOS client, embedded as `Sparkle.framework`)
- Repository: https://github.com/sparkle-project/Sparkle
- License: MIT — https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
- Purpose: In-app self-update for the macOS client.
- Distribution note: When building the `.app` for redistribution, the
  Sparkle license file is embedded inside `Sparkle.framework` automatically
  by Swift Package Manager — no manual copy is required.
