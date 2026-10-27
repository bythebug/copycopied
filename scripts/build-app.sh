#!/bin/zsh
# Builds build/backed.app from the BackedApp SwiftPM target (PLAN.md D1).
#   scripts/build-app.sh            ad-hoc signed, for running locally
#   DEVELOPER_ID="Developer ID Application: …" scripts/build-app.sh   hardened runtime, ready to notarize (Phase 8)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product BackedApp
app=build/backed.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/BackedApp" "$app/Contents/MacOS/backed"

# TODO(verify): bundle identifier is a placeholder until the signing team is known (PLAN.md Q3).
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.bythebug.backed</string>
  <key>CFBundleName</key><string>backed.</string>
  <key>CFBundleDisplayName</key><string>backed.</string>
  <key>CFBundleExecutable</key><string>backed</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>backed. reads your memory cards (never writes to them) to check every file is safely copied.</string>
</dict>
</plist>
EOF

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "$app"
