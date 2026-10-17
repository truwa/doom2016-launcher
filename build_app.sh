#!/bin/bash
# Assemble dist/Doom.app. Wine is downloaded on first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Doom.app"
KOSMIC_ZIP="$ROOT/dist/upstream/libvulkan_kosmickrisp-x86_64.zip"
KOSMIC_SHA="927fb90c337f655725bdafa2f9e2c14cac476e45efaa9598b16370e8f52132d2"
KOSMIC_SRC="$ROOT/dist/upstream/kosmickrisp"
PYTHON_DIR="$ROOT/dist/python-standalone"
SIBLING_PYTHON="/Users/truwa/Projects/uncharted-macos-crossover/dist/python-standalone"

mkdir -p "$ROOT/dist/upstream"
if [[ ! -f "$KOSMIC_SRC/libvulkan_kosmickrisp.dylib" ]]; then
    if [[ ! -f "$KOSMIC_ZIP" ]]; then
        curl -fL "https://github.com/truwa/kosmickrisp-compat/releases/download/v0.1.0/libvulkan_kosmickrisp-x86_64.zip" \
            -o "$KOSMIC_ZIP"
    fi
    echo "$KOSMIC_SHA  $KOSMIC_ZIP" | shasum -a 256 -c -
    rm -rf "$KOSMIC_SRC"
    mkdir -p "$KOSMIC_SRC"
    unzip -o "$KOSMIC_ZIP" -d "$KOSMIC_SRC"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
    "$APP/Contents/Resources/engine" \
    "$APP/Contents/Resources/vulkan/icd.d" \
    "$APP/Contents/Frameworks"

cp "$KOSMIC_SRC/libvulkan_kosmickrisp.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/vulkan/kosmickrisp_icd.json" "$APP/Contents/Resources/vulkan/icd.d/"
cp "$ROOT/launch.py" "$ROOT/NOTICES.txt" "$APP/Contents/Resources/engine/"
cp "$ROOT/NOTICES.txt" "$APP/Contents/Resources/NOTICES.txt"
cp "$ROOT/macos/cover.jpg" "$APP/Contents/Resources/cover.jpg"
chmod 755 "$APP/Contents/Frameworks/libvulkan_kosmickrisp.dylib"

if [[ ! -x "$PYTHON_DIR/bin/python3" ]]; then
    if [[ -x "$SIBLING_PYTHON/bin/python3" ]]; then
        mkdir -p "$PYTHON_DIR"
        rsync -a "$SIBLING_PYTHON/" "$PYTHON_DIR/"
    else
        ASSET="$(curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" \
            | python3 -c 'import json,sys; rel=json.load(sys.stdin); print(next(a["browser_download_url"] for a in rel["assets"] if "aarch64-apple-darwin" in a["name"] and a["name"].endswith("install_only.tar.gz")))')"
        curl -fL "$ASSET" -o "$ROOT/dist/python.tar.gz"
        rm -rf "$PYTHON_DIR"
        mkdir -p "$PYTHON_DIR"
        tar -xzf "$ROOT/dist/python.tar.gz" -C "$PYTHON_DIR" --strip-components 1
        rm "$ROOT/dist/python.tar.gz"
    fi
fi
mkdir -p "$APP/Contents/Resources/python"
rsync -a "$PYTHON_DIR/" "$APP/Contents/Resources/python/"

swiftc -parse-as-library -O -o "$APP/Contents/MacOS/Doom" \
    -framework SwiftUI -framework AppKit -framework WebKit \
    "$ROOT/macos/DoomApp.swift"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Doom</string>
    <key>CFBundleIdentifier</key>
    <string>com.doom2016.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDisplayName</key>
    <string>DOOM (2016)</string>
    <key>CFBundleName</key>
    <string>DOOM (2016)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.6</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>The game folder may be on the Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>The game folder may be in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>The game folder may be in Downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>The game folder may be on an external volume.</string>
</dict>
</plist>
EOF

echo "Built $APP"
du -sh "$APP"
