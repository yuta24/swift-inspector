#!/usr/bin/env bash
#
# Build InspectApp.app from the SPM executable target.
#
# Usage:
#   scripts/build_app.sh [VERSION] [BUILD_NUMBER]
#
# Environment variables:
#   SPARKLE_PUBLIC_KEY   Base64-encoded EdDSA public key to embed as
#                        SUPublicEDKey. If unset, the key is left empty
#                        and Sparkle will refuse to install updates —
#                        use only for local smoke testing.
#   SUFEED_URL           Overrides the default appcast URL. Defaults to
#                        the production GitHub Pages URL.
#
# Output:
#   build/InspectApp.app  — bundle ready for codesign + notarization.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="InspectApp"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"

SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
SUFEED_URL="${SUFEED_URL:-https://yuta24.github.io/swift-inspector/appcast.xml}"

# Sparkle treats a bundle with no SUPublicEDKey as unable to verify any
# signature, so it rejects every update as insecure. A bundle shipped that
# way could be installed but would never auto-update again. Fail loudly on
# CI; allow it locally only for build smoke tests where update flow is
# not exercised.
if [ -z "$SPARKLE_PUBLIC_KEY" ]; then
    if [ "${CI:-}" = "true" ]; then
        echo "error: SPARKLE_PUBLIC_KEY must be set in CI builds" >&2
        exit 1
    fi
    echo "warning: SPARKLE_PUBLIC_KEY is empty — the resulting bundle will refuse to install any update (Sparkle treats unsigned releases as insecure). Use only for local build smoke tests." >&2
fi

BUILD_DIR="$REPO_ROOT/build"
BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$BUNDLE/Contents"

cd "$REPO_ROOT/InspectApp"
swift build -c release

BINARY="$REPO_ROOT/InspectApp/.build/release/${APP_NAME}"
SPARKLE_FRAMEWORK="$REPO_ROOT/InspectApp/.build/release/Sparkle.framework"

if [ ! -f "$BINARY" ]; then
    echo "error: expected binary not found at $BINARY" >&2
    exit 1
fi
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "error: Sparkle.framework not found at $SPARKLE_FRAMEWORK" >&2
    exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Frameworks"
mkdir -p "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/${APP_NAME}"
# `ditto` preserves xattrs, resource forks, and the Versions/Current
# symlink that the framework bundle relies on. Plain `cp -R` can break
# codesign / notarize in subtle ways.
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

# Rewrite the Sparkle rpath. SPM builds the binary with an rpath pointing
# to the build directory; in the .app bundle the framework lives under
# Contents/Frameworks. `install_name_tool -add_rpath` errors on duplicates
# (exit 1) — on a fresh build it succeeds, on a rebuild the rpath already
# exists and we can safely skip.
if ! install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$CONTENTS/MacOS/${APP_NAME}" 2>/dev/null; then
    echo "note: @executable_path/../Frameworks rpath already present, skipping" >&2
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.yuta24.swift-inspector</string>
    <key>CFBundleName</key>
    <string>swift-inspector</string>
    <key>CFBundleDisplayName</key>
    <string>swift-inspector</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUFeedURL</key>
    <string>${SUFEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
EOF

echo "Built $BUNDLE (version $VERSION, build $BUILD_NUMBER)"
