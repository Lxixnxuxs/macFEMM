#!/usr/bin/env bash
# package_macos_dmg.sh - build macFEMM.app and package it as a local DMG.
#
# Usage:
#   ./tools/package_macos_dmg.sh [version]
#
# Example:
#   ./tools/package_macos_dmg.sh 0.1.0

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-dev}"
ARCH="$(uname -m)"
APP="$ROOT/mac/macFEMM.app"
DIST="$ROOT/dist"
DMG_ROOT="$DIST/dmgroot"
DMG="$DIST/macFEMM-${VERSION}-macOS-${ARCH}.dmg"

cd "$ROOT"

echo "==> Building FEMM solver binaries and core library"
./build_macos.sh

echo "==> Building and bundling macFEMM.app"
./mac/pack_app.sh release

echo "==> Creating DMG staging folder"
rm -rf "$DMG_ROOT" "$DMG"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> Creating $DMG"
hdiutil create \
  -volname "macFEMM" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG"

echo
echo "Built DMG:"
echo "$DMG"
echo
echo "This DMG is not notarized. For first launch, right-click macFEMM.app and choose Open."
