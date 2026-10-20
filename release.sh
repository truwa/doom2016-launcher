#!/bin/bash
# Build, sign, notarize, staple, zip, and publish one GitHub release.
# Usage: ./release.sh 1.2.0 [notes.txt]
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
rm -f "$NOTARY_ZIP" "$FINAL_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

echo "Submitting for notarization…"
SUBMIT_JSON="$(mktemp)"
set +e
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$PROFILE" --wait --output-format json >"$SUBMIT_JSON"
submit_status=$?
set -e
if ! python3 - "$SUBMIT_JSON" "$PROFILE" "$submit_status" <<'PY'
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
    rm -f "$SUBMIT_JSON"
    exit 1
fi
rm -f "$NOTARY_ZIP" "$SUBMIT_JSON"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$VERSION" "$FINAL_ZIP" \
        --repo truwa/doom2016-launcher \
        --title "$VERSION" \
        --notes-file "$NOTES_FILE"
else
    gh release create "$VERSION" "$FINAL_ZIP" \
        --repo truwa/doom2016-launcher \
        --title "$VERSION" \
        --notes "$(cat <<EOF
Download DOOM-2016-${VERSION}.zip, unzip it, and open Doom2016GOG.app.

The game is not included.
EOF
)"
fi
echo "Published $FINAL_ZIP as release $VERSION"
