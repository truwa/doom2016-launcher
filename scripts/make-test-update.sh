#!/bin/bash
# Make a local update feed with a higher version than the built app.
# Usage: ./scripts/make-test-update.sh 1.2.0
# The running app must be a DEBUG build. Release builds ignore this feed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: ./scripts/make-test-update.sh <version>" >&2
    exit 1
fi
SRC="$ROOT/dist/Doom2016GOG.app"
if [[ ! -d "$SRC" ]]; then
    echo "Build the DEBUG app first: DEBUG=1 ./build_app.sh" >&2
    exit 1
fi
SIGN_ID="${SIGN_ID:-Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)}"
WORK="$ROOT/dist/update-test"
rm -rf "$WORK"
mkdir -p "$WORK/payload"
cp -R "$SRC" "$WORK/payload/Doom2016GOG.app"
APP="$WORK/payload/Doom2016GOG.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --entitlements "$ROOT/macos/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
ZIP_NAME="DOOM-2016-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$WORK/$ZIP_NAME"
SIZE="$(stat -f%z "$WORK/$ZIP_NAME")"
python3 - "$WORK/release.json" "$VERSION" "$SIZE" "$ZIP_NAME" <<'PY'
import json, sys
path, version, size, name = sys.argv[1:]
document = {
    "tag_name": version,
    "name": version,
    "body": f"Local test release {version}.",
    "assets": [{
        "name": name,
        "browser_download_url": name,
        "size": int(size),
    }],
}
with open(path, "w", encoding="utf-8") as output:
    json.dump(document, output, indent=2)
    output.write("\n")
PY
rm -rf "$WORK/payload"
cat <<EOF
Test feed: $WORK

The app you open must be the DEBUG build, and its version must be lower than $VERSION.

  open --env DOOM_UPDATE_FEED="$WORK" --env DOOM_UPDATE_SKIP_NOTARIZATION=1 "$SRC"

To exercise the localhost path instead, serve the folder and point the feed at the JSON:

  python3 -m http.server 8765 --directory "$WORK"
  open --env DOOM_UPDATE_FEED="http://127.0.0.1:8765/release.json" --env DOOM_UPDATE_SKIP_NOTARIZATION=1 "$SRC"

Leave DOOM_UPDATE_SKIP_NOTARIZATION unset to confirm an unnotarized zip is rejected.
EOF
