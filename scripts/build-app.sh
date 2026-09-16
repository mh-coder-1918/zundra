#!/usr/bin/env bash
#
# Build Zundra.app with the Command Line Tools alone — swiftc plus the macOS
# SDK, no Xcode, no xcodebuild, no project file. This is the only build path
# there is; there is deliberately nothing to open in an IDE.
#
# Produces build/Zundra.app. Pass --install to also copy it to /Applications,
# and --run to (re)launch it.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/Zundra.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
BUNDLE_ID="eu.nundra.zundra"

echo "▶ Building Zundra.app ($ARCH, macOS 13 target)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- compile ---------------------------------------------------------------
swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -sdk "$SDK" \
  -o "$APP/Contents/MacOS/Zundra" \
  "$ROOT"/Sources/*.swift

# --- Info.plist (mirrors project.yml) --------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Zundra</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Zundra</string>
    <key>CFBundleDisplayName</key><string>Zundra</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# --- resources -------------------------------------------------------------
# The menu-bar glyph is a *template* image: macOS discards its colour and tints
# it for light/dark. The app icon is the opposite and is a separate file.
cp "$ROOT/Resources/MenuIconTemplate.png"    "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuIconTemplate@2x.png" "$APP/Contents/Resources/"

# Built on demand rather than committed, because composing it needs AppKit and
# `iconutil` — neither of which exists on the Linux box the source is edited on.
# Once generated it is committed like the template PNGs are, so a later build
# reuses it. Delete Resources/AppIcon.icns to force a rebuild after editing
# brain.svg or the palette in scripts/make-icon.swift.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "▶ Composing app icon"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/brain.svg" "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# --- sign (ad-hoc) ---------------------------------------------------------
# A *valid* ad-hoc signature is what keeps Gatekeeper on "unknown developer,
# click through" instead of "damaged, move to Trash", which has no escape at
# all — and an unsigned arm64 binary will not launch on Apple silicon in the
# first place. A broken signature is therefore worse than no release, so a
# failure here is fatal rather than a note in passing.
#
# `--deep` is deliberately gone: `man codesign` marks it "(DEPRECATED for
# signing as of macOS 13.0)". When a framework is embedded (Sparkle), sign it
# explicitly *before* the app — inside out — which is what --deep used to
# paper over.
if ! codesign --force --sign - "$APP"; then
  echo "✗ codesign failed — refusing to ship an unsigned bundle" >&2
  exit 1
fi
if ! codesign --verify --strict --verbose=2 "$APP"; then
  echo "✗ signature did not verify — Gatekeeper would call this bundle damaged" >&2
  exit 1
fi

echo "✓ Built $APP"

if [[ " $* " == *" --install "* ]]; then
  DEST="/Applications/Zundra.app"
  echo "▶ Installing to $DEST"
  osascript -e 'quit app "Zundra"' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "✓ Installed $DEST"
  APP="$DEST"
fi

if [[ " $* " == *" --run "* ]]; then
  echo "▶ Launching"
  open "$APP"
fi
