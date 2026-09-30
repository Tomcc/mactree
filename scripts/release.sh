#!/bin/sh
# Build MacTree.app, sign it with the Developer ID, and pack it into a notarized, stapled
# build/MacTree.dmg with the usual drag-into-Applications window.
# MACTREE_SIGNING_SECRET holds JSON with p12_base64 and p12_password (the Developer ID
# Application identity), key_base64, key_id and issuer_id (an App Store Connect API key,
# for notarytool).
set -eu
secret=${MACTREE_SIGNING_SECRET:?set it to the signing secret JSON}
# Finder finds disks by name, so another mounted MacTree would get the window layout.
if [ -e /Volumes/MacTree ]; then
    echo "eject /Volumes/MacTree first" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
scripts/bundle.sh
app=build/MacTree.app
dmg=build/MacTree.dmg

umask 077
work=$(mktemp -d)
keychain="$work/signing.keychain-db"
original=""
cleanup() {
    hdiutil detach -quiet "$work/mount" 2>/dev/null || true
    [ -z "$original" ] || security list-keychains -d user -s $original
    security delete-keychain "$keychain" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

field() { printf '%s' "$secret" | jq -er ".$1"; }
field p12_base64 | base64 -d > "$work/cert.p12"
field key_base64 | base64 -d > "$work/key.p8"
notary="--key $work/key.p8 --key-id $(field key_id) --issuer $(field issuer_id)"

# A throwaway keychain, so the certificate never lands in the login one.
security create-keychain -p temp "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p temp "$keychain"
security import "$work/cert.p12" -k "$keychain" -P "$(field p12_password)" \
    -T /usr/bin/codesign -f pkcs12 >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k temp "$keychain" >/dev/null
# codesign finds the private key only in keychains on the search list; cleanup restores it.
original=$(security list-keychains -d user | tr -d '"')
security list-keychains -d user -s "$keychain" $original
identity=$(security find-identity -v -p codesigning "$keychain" \
    | awk '/Developer ID Application/ { print $2; exit }')
[ -n "$identity" ] || { echo "no Developer ID Application identity in the secret" >&2; exit 1; }
sign() {
    codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$@"
}

sign --options runtime --entitlements Resources/MacTree.entitlements "$app"
codesign --verify --strict -v "$app"

# The window: the app, an arrow, and Applications, over a background drawn at 1x and 2x.
umask 022
stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/MacTree.app"
ln -s /Applications "$stage/Applications"
swift scripts/make-dmg-background.swift "$work/background.png" 1
swift scripts/make-dmg-background.swift "$work/background@2x.png" 2
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" \
    -out "$stage/.background/background.tiff" 2>/dev/null
cp Resources/AppIcon.icns "$stage/.VolumeIcon.icns"
hdiutil create -quiet -volname MacTree -srcfolder "$stage" -fs HFS+ -format UDRW -ov \
    "$work/rw.dmg"
mkdir "$work/mount"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$work/mount" "$work/rw.dmg"
SetFile -a C "$work/mount"
# Finder saves the layout into the volume's .DS_Store.
osascript - "$work/mount" <<'APPLESCRIPT'
on run argv
    tell application "Finder"
        set theVolume to (POSIX file (item 1 of argv)) as alias
        open theVolume
        set theWindow to container window of theVolume
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set bounds of theWindow to {200, 120, 800, 548}
        set theOptions to icon view options of theWindow
        set arrangement of theOptions to not arranged
        set icon size of theOptions to 128
        set text size of theOptions to 13
        set background picture of theOptions to file ".background:background.tiff" of theVolume
        set position of item "MacTree.app" of theVolume to {150, 190}
        set position of item "Applications" of theVolume to {450, 190}
        -- Closing saves the layout; "update" would also delete the volume's custom icon.
        delay 1
        close theWindow
    end tell
end run
APPLESCRIPT
sync
hdiutil detach -quiet "$work/mount"
rm -f "$dmg"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg"
sign "$dmg"

# $notary is several arguments, so it stays unquoted.
result=$(xcrun notarytool submit "$dmg" $notary --wait --output-format json)
if [ "$(printf '%s' "$result" | jq -r .status)" != Accepted ]; then
    xcrun notarytool log "$(printf '%s' "$result" | jq -r .id)" $notary >&2
    exit 1
fi
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
echo "released $dmg"