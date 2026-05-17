#!/usr/bin/env bash
# pack_app.sh — bundle the `swift build` output into a macOS .app with the
# solver binaries packaged alongside so Document drivers can find them.
#
# Usage: ./pack_app.sh [Debug|Release]   (default: Debug)

set -eu

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/mac"
BUILD_BASE="$MAC/.build"
BIN_DIR="$BUILD_BASE/$CONFIG"

# Ensure libfemm_core + solvers exist.
if [ ! -f "$ROOT/build/libfemm_core/libfemm_core.a" ]; then
  echo "libfemm_core.a missing. Run ./build_macos.sh first." >&2
  exit 1
fi
if [ ! -x "$ROOT/build/fkn/fknsolve" ]; then
  echo "Solvers missing. Run ./build_macos.sh first." >&2
  exit 1
fi

# Build the Swift app.
cd "$MAC"
if [ "$CONFIG" = "release" ]; then
  swift build -c release
else
  swift build
fi

APP="$MAC/macFEMM.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/macFEMM" "$APP/Contents/MacOS/macFEMM"

# Bundle the solver binaries + triangle right next to the main executable so
# FEMM_BIN logic can find them (the library walks upward for a build/
# directory; we also set FEMM_BIN via a launcher if needed later).
cp "$ROOT/build/belasolv/belasolve"  "$APP/Contents/MacOS/"
cp "$ROOT/build/csolv/csolve"        "$APP/Contents/MacOS/"
cp "$ROOT/build/hsolv/hsolve"        "$APP/Contents/MacOS/"
cp "$ROOT/build/fkn/fknsolve"        "$APP/Contents/MacOS/"
cp "$ROOT/build/triangle/triangle"   "$APP/Contents/MacOS/"

if [ -f "$MAC/Sources/macFEMM/Resources/macFEMM.icns" ]; then
  cp "$MAC/Sources/macFEMM/Resources/macFEMM.icns" "$APP/Contents/Resources/macFEMM.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>macFEMM</string>
    <key>CFBundleDisplayName</key><string>macFEMM</string>
    <key>CFBundleIdentifier</key><string>industries.p2p.macFEMM</string>
    <key>CFBundleExecutable</key><string>macFEMM</string>
    <key>CFBundleIconFile</key><string>macFEMM</string>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>NSSupportsSuddenTermination</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>macFEMM Magnetics Problem</string>
            <key>CFBundleTypeExtensions</key><array><string>fem</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>macFEMM Electrostatics Problem</string>
            <key>CFBundleTypeExtensions</key><array><string>fee</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>macFEMM Heat Flow Problem</string>
            <key>CFBundleTypeExtensions</key><array><string>feh</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>macFEMM Current Flow Problem</string>
            <key>CFBundleTypeExtensions</key><array><string>fec</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so launchd doesn't balk.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Launch with: open '$APP'"
