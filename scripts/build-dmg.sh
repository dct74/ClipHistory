#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipHistory"
DIST="$ROOT/dist"
APP_BUNDLE="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

# Single source of truth for the version — the value the app itself reports.
VERSION="$(sed -n 's/.*currentVersion = "\(.*\)"/\1/p' "$ROOT/Sources/ClipHistory/UpdateChecker.swift" | head -1)"
if [ -z "$VERSION" ]; then
    echo "✗ Could not read currentVersion from UpdateChecker.swift" >&2
    exit 1
fi

# Command Line Tools ship without SwiftUI's macro plugin (needed for
# @State/@Bindable), so `swift build` fails on a CLT-only setup. Borrow Xcode's
# copy when it's around. `set -u` + bash 3.2 means the empty-array idiom below.
SWIFT_FLAGS=()
TOOLCHAIN_PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins"
XCODE_PLUGIN_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [ ! -f "$TOOLCHAIN_PLUGINS/libSwiftUIMacros.dylib" ] && [ -f "$XCODE_PLUGIN_PATH/libSwiftUIMacros.dylib" ]; then
    echo "▸ Toolchain lacks libSwiftUIMacros.dylib — using Xcode's macro plugins"
    SWIFT_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$XCODE_PLUGIN_PATH")
fi

# ── 1. Release build ──────────────────────────────────────────────────────────
echo "▸ Building release binary…"
cd "$ROOT"
swift build -c release ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

# ── 2. Generate app icon ──────────────────────────────────────────────────────
echo "▸ Generating icons…"
mkdir -p "$DIST"
swift scripts/generate-icons.swift "$DIST"

echo "▸ Compiling AppIcon.icns…"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
rm -rf "$DIST/AppIcon.iconset"          # clean up intermediate files

# ── 3. Assemble .app bundle ───────────────────────────────────────────────────
echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME"   "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$DIST/AppIcon.icns"         "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClipHistory</string>

    <key>CFBundleIdentifier</key>
    <string>com.weiyuankong.cliphistory</string>

    <key>CFBundleName</key>
    <string>ClipHistory</string>

    <key>CFBundleDisplayName</key>
    <string>ClipHistory</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <!-- Stamped from UpdateChecker.currentVersion below (PlistBuddy). -->
    <key>CFBundleVersion</key>
    <string>0</string>

    <key>CFBundleShortVersionString</key>
    <string>0</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>

    <!-- Hide from Dock; lives only in the menu bar -->
    <key>LSUIElement</key>
    <true/>

    <key>NSPrincipalClass</key>
    <string>NSApplication</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSAccessibilityUsageDescription</key>
    <string>ClipHistory needs Accessibility access to detect your clipboard shortcut and paste items into other apps.</string>
</dict>
</plist>
PLIST

# Stamp the version read from the source above.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# ── 4. Ad-hoc code sign ───────────────────────────────────────────────────────
echo "▸ Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP_BUNDLE"

# ── 5. Create DMG with drag-to-Applications layout ────────────────────────────
echo "▸ Creating DMG…"
rm -f "$DMG"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -r "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname   "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format    UDZO \
    -o         "$DMG"

# ── 6. Verify the DMG actually carries this build ────────────────────────────
# A failed hdiutil run used to leave the previous DMG in place, which then got
# published under the new version. Read the version back out of the image.
echo "▸ Verifying DMG contents…"
VERIFY_MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MNT" "$DMG" >/dev/null
DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$VERIFY_MNT/$APP_NAME.app/Contents/Info.plist")"
hdiutil detach "$VERIFY_MNT" -quiet
rmdir "$VERIFY_MNT" 2>/dev/null || true
if [ "$DMG_VERSION" != "$VERSION" ]; then
    echo "✗ DMG carries $DMG_VERSION, expected $VERSION" >&2
    exit 1
fi

# ── 7. Checksum (users verify the download with it) ──────────────────────────
echo "▸ Writing checksum…"
( cd "$DIST" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256" )

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✓  $DMG"
cat "$DIST/$APP_NAME.dmg.sha256"
echo "   Open the DMG and drag $APP_NAME.app → Applications to install."
