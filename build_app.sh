#!/bin/bash
# Assemble dist/Doom2016GOG.app. Wine is downloaded on first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Doom2016GOG.app"
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
# Dock icon: the DOOM title from the cover, on the red field. macOS rounds the corners.
ICONSET="$ROOT/dist/AppIcon.iconset"
SOURCE="$ROOT/dist/AppIcon-source.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift - "$ROOT/macos/cover.jpg" "$SOURCE" << 'EOF'
import AppKit
let cover = NSImage(contentsOfFile: CommandLine.arguments[1])!
let src = NSBitmapImageRep(data: cover.tiffRepresentation!)!
let x0 = 28, y0 = 18, lw = 292, lh = 146
let logoRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: lw, pixelsHigh: lh,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: lw * 4, bitsPerPixel: 32)!
for y in 0..<lh {
    for x in 0..<lw {
        let c = src.colorAt(x: x0 + x, y: y0 + y)!
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)!.getRed(&r, green: &g, blue: &b, alpha: &a)
        var alpha = (min(g, b) - 0.28) / 0.42
        if alpha < 0 { alpha = 0 }
        if alpha > 1 { alpha = 1 }
        logoRep.setColor(NSColor(calibratedRed: min(1, r + 0.04), green: min(1, g + 0.02), blue: min(1, b), alpha: alpha), atX: x, y: y)
    }
}
let logo = NSImage(size: NSSize(width: lw, height: lh))
logo.addRepresentation(logoRep)
let s: CGFloat = 1024
let image = NSImage(size: NSSize(width: s, height: s))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let top = NSColor(calibratedRed: 0.62, green: 0.08, blue: 0.05, alpha: 1)
let mid = NSColor(calibratedRed: 0.45, green: 0.04, blue: 0.03, alpha: 1)
let bot = NSColor(calibratedRed: 0.22, green: 0.02, blue: 0.015, alpha: 1)
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bot.cgColor, mid.cgColor, top.cgColor] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: s / 2, y: 0), end: CGPoint(x: s / 2, y: s), options: [])
let targetW = s * 0.78
let scale = targetW / CGFloat(lw)
let targetH = CGFloat(lh) * scale
logo.draw(in: NSRect(x: (s - targetW) / 2, y: (s - targetH) / 2, width: targetW, height: targetH), from: NSRect(x: 0, y: 0, width: lw, height: lh), operation: .sourceOver, fraction: 1)
image.unlockFocus()
try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
EOF
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$SOURCE"
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
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

SIGN_ID="Developer ID Application: Mehmet Akif Ozdas (2DG34W64L7)"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    while IFS= read -r -d '' binary; do
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$binary"
    done < <(python3 - "$APP" <<'PY'
import os, subprocess, sys
root = sys.argv[1]
for dirpath, _, names in os.walk(root):
    for name in names:
        path = os.path.join(dirpath, name)
        if os.path.islink(path) or path.endswith("/Contents/MacOS/Doom"):
            continue
        kind = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout
        if "Mach-O" in kind:
            print(path, end="\0")
PY
)
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

echo "Built $APP"
du -sh "$APP"
