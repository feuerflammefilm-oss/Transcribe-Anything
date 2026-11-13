#!/usr/bin/env bash
# Baut "Transcribe Anything.app" (Apple Silicon). Läuft auf GitHub Actions (macOS mit Xcode 26).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Transcribe Anything"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="${VERSION:-0.1.0}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Swift-Code kompilieren"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> App-Paket zusammenbauen"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TranscribeAnything" "$APP/Contents/MacOS/TranscribeAnything"
# Ressourcen-Bundles der Bibliotheken (z. B. WhisperKit) mitkopieren
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> App-Icon erzeugen"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signieren"
codesign --force --deep --sign - "$APP"

echo "==> ZIP erstellen"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/Transcribe-Anything.zip"
echo "Fertig: $BUILD_DIR/Transcribe-Anything.zip"
