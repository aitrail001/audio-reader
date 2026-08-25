#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product AudioReader
BIN=".build/release/AudioReader"
APP="$ROOT/AudioReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AudioReader"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -d ".build/release/AudioReader_AudioReader.bundle" ]]; then
  cp -R ".build/release/AudioReader_AudioReader.bundle" "$APP/Contents/Resources/AudioReader_AudioReader.bundle"
fi
if [[ -f ".build/release/ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy" ]]; then
  cp ".build/release/ZIPFoundation_ZIPFoundation.bundle/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
fi
if [[ -f "$ROOT/Resources/AppIcon-trimmed.icns" ]]; then
  cp "$ROOT/Resources/AppIcon-trimmed.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/AudioReader"
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
