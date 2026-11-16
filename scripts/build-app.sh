#!/usr/bin/env bash
# Builds dist/Agent Huddle.app (release, ad-hoc signed, menu-bar/accessory app with no Dock icon) and a zip.
# Installs nothing: copy the .app to /Applications yourself if you want it there.
set -euo pipefail
cd "$(dirname "$0")/.."
# The release workflow passes the tag (VERSION=1.2.3); a local build takes the newest v* tag, so About matches the release.
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0.0)"; VERSION="${VERSION#v}"
fi
# Build number: the commit count, so every build from a newer commit is higher (About shows it in brackets).
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Both go into Info.plist (XML): accept plain numbers only, so a tag can never inject markup.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-app.sh: VERSION must look like 1.2.3 (got an invalid value)" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "build-app.sh: BUILD must be a number (got an invalid value)" >&2; exit 1; }
swift build -c release --product AgentHuddle
BIN="$(swift build -c release --show-bin-path)/AgentHuddle"
APP="dist/Agent Huddle.app"
rm -rf "$APP" dist/AgentHuddle.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentHuddle"
# App icon: rendered by the app itself, then sips/iconutil -> AppIcon.icns
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
"$BIN" --icon "$ICONSET/../icon-1024.png"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICONSET/../icon-1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICONSET/../icon-1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
mkdir -p assets && cp "$ICONSET/../icon-1024.png" assets/icon-1024.png
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.t3huddle.AgentHuddle</string>
  <key>CFBundleName</key><string>Agent Huddle</string>
  <key>CFBundleDisplayName</key><string>Agent Huddle</string>
  <key>CFBundleExecutable</key><string>AgentHuddle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mika Koivisto. MIT License.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>&1 | tail -1
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
(cd dist && ditto -c -k --keepParent "Agent Huddle.app" AgentHuddle.zip)
echo "built: $APP  ($(du -sh "$APP" | cut -f1))  and dist/AgentHuddle.zip"
