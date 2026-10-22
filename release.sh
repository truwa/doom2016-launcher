#!/bin/bash
# Build, sign, notarize, staple, zip, make a disk image, and publish one GitHub release.
# Usage: ./release.sh 1.3 [notes.txt]
# The Apple ID password stays in the Keychain profile. It is not read from this file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-}"
NOTES_FILE="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: ./release.sh <version> [notes-file]" >&2
    exit 1
fi
if [[ "${DEBUG:-}" == "1" ]]; then
    echo "Refusing to release a DEBUG build." >&2
    exit 1
fi

PROFILE="${NOTARY_KEYCHAIN_PROFILE:-doom2016-notary}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)}"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "Developer ID certificate not found: $SIGN_ID" >&2
    exit 1
fi
if ! history_err="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 >/dev/null)"; then
    if grep -q "No Keychain password item" <<<"$history_err"; then
        cat >&2 <<EOF
No notarytool keychain profile named "$PROFILE".
Store the Apple ID credentials in the Keychain once. Do not put the password in the repo:

  xcrun notarytool store-credentials "$PROFILE" --apple-id YOU@icloud.com --team-id 2DG34W64L7

Use an app-specific password. Set NOTARY_KEYCHAIN_PROFILE if the profile has another name.
EOF
        exit 1
    fi
    echo "Could not read notarization history for profile $PROFILE:" >&2
    echo "$history_err" >&2
fi

export VERSION BUILD="$VERSION" REQUIRE_SIGN=1 SIGN_ID
"$ROOT/build_app.sh"

APP="$ROOT/dist/Doom2016GOG.app"
NOTARY_ZIP="$ROOT/dist/DOOM-2016-${VERSION}.notarize.zip"
FINAL_ZIP="$ROOT/dist/DOOM-2016-${VERSION}.zip"
FINAL_DMG="$ROOT/dist/DOOM-2016-${VERSION}.dmg"

notarize_file() {
    local target="$1"
    echo "Submitting $(basename "$target") for notarization…"
    local submit_json submit_status
    submit_json="$(mktemp)"
    set +e
    xcrun notarytool submit "$target" --keychain-profile "$PROFILE" --wait --output-format json >"$submit_json"
    submit_status=$?
    set -e
    if ! python3 - "$submit_json" "$PROFILE" "$submit_status" <<'PY'
import json, subprocess, sys
path, profile, submit_status = sys.argv[1:]
raw = open(path, encoding="utf-8").read().strip()
report = None
if raw:
    try:
        report = json.loads(raw)
    except json.JSONDecodeError:
        print(raw)
if not isinstance(report, dict):
    print(f"notarytool submit failed (exit {submit_status}).")
    sys.exit(1)
status = report.get("status")
submission = report.get("id")
print(f"Notarization status: {status} ({submission})")
if status == "Accepted":
    sys.exit(0)
if raw:
    print(raw)
if submission:
    print("Fetching the notarization log…")
    subprocess.run(["xcrun", "notarytool", "log", submission, "--keychain-profile", profile], check=False)
sys.exit(1)
PY
    then
        rm -f "$submit_json"
        exit 1
    fi
    rm -f "$submit_json"
}

create_release_dmg() {
    local app="$1"
    local dmg="$2"
    local readme="$3"
    local volname="DOOM (2016)"
    local rw="$ROOT/dist/.DOOM-2016-${VERSION}.rw.dmg"
    local mount=""
    rm -f "$rw" "$dmg"
    if [[ -d "/Volumes/${volname}" ]]; then
        hdiutil detach "/Volumes/${volname}" -force >/dev/null 2>&1 || true
    fi
    local megs=$(( $(du -sm "$app" | awk '{print $1}') + 40 ))
    hdiutil create -size "${megs}m" -fs HFS+ -volname "$volname" "$rw" >/dev/null
    mount="$(hdiutil attach "$rw" | sed -n 's/.*\(\/Volumes\/.*\)/\1/p' | tail -1)"
    if [[ -z "$mount" || ! -d "$mount" ]]; then
        echo "Could not mount the disk image." >&2
        exit 1
    fi
    ditto "$app" "$mount/Doom2016GOG.app"
    ln -s /Applications "$mount/Applications"
    cp "$readme" "$mount/README.md"
    codesign --verify --deep --strict "$mount/Doom2016GOG.app"
    local layout_script layout_pid layout_ok _
    layout_script="$(mktemp)"
    layout_ok=0
    cat > "$layout_script" <<APPLESCRIPT
tell application "Finder"
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 820, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 13
    delay 1
    set position of item "Doom2016GOG.app" of container window to {160, 170}
    set position of item "Applications" of container window to {460, 170}
    set position of item "README.md" of container window to {310, 310}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
    osascript "$layout_script" &
    layout_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        if ! kill -0 "$layout_pid" 2>/dev/null; then
            if wait "$layout_pid"; then
                layout_ok=1
            fi
            break
        fi
        sleep 1
    done
    if kill -0 "$layout_pid" 2>/dev/null; then
        kill "$layout_pid" 2>/dev/null || true
        wait "$layout_pid" 2>/dev/null || true
    fi
    rm -f "$layout_script"
    if [[ "$layout_ok" != "1" ]]; then
        echo "Finder layout was skipped. The disk image still contains the app, Applications, and the readme." >&2
    fi
    sync
    hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach "$mount" -force >/dev/null
    hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
    rm -f "$rw"
    codesign --force --sign "$SIGN_ID" --timestamp "$dmg"
}

rm -f "$NOTARY_ZIP" "$FINAL_ZIP" "$FINAL_DMG"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
notarize_file "$NOTARY_ZIP"
rm -f "$NOTARY_ZIP"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

echo "Building the disk image…"
create_release_dmg "$APP" "$FINAL_DMG" "$ROOT/README.md"
notarize_file "$FINAL_DMG"
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"

if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$VERSION" "$FINAL_ZIP" "$FINAL_DMG" \
        --repo truwa/doom2016-launcher \
        --title "$VERSION" \
        --notes-file "$NOTES_FILE"
else
    gh release create "$VERSION" "$FINAL_ZIP" "$FINAL_DMG" \
        --repo truwa/doom2016-launcher \
        --title "$VERSION" \
        --notes "$(cat <<EOF
Download DOOM-2016-${VERSION}.dmg, open it, and drag Doom2016GOG.app to Applications. The readme is in the disk image.

Check for Updates installs DOOM-2016-${VERSION}.zip.

The game is not included.
EOF
)"
fi
echo "Published $FINAL_ZIP and $FINAL_DMG as release $VERSION"
