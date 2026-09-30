#!/bin/sh
# Build a release MacTree.app into build/; pass --install to copy it to ~/Applications.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=build/MacTree.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/MacTree "$app/Contents/MacOS/MacTree"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacTree</string>
    <key>CFBundleDisplayName</key><string>MacTree</string>
    <key>CFBundleIdentifier</key><string>com.tomcc.mactree</string>
    <key>CFBundleExecutable</key><string>MacTree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>MacTree asks Finder to empty the Trash and show Get Info.</string>
</dict>
</plist>
PLIST
# Ad-hoc signed: enough to run locally, not to distribute.
codesign --force --sign - "$app"
echo "built $app"
if [ "${1:-}" = "--install" ]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/MacTree.app
    cp -R "$app" ~/Applications/
    echo "installed ~/Applications/MacTree.app"
fi
