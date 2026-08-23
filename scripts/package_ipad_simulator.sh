#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="${TMPDIR:-/tmp}/AudioReader-iPad-DerivedData"
APP="$PROJECT_ROOT/AudioReader-iPad.app"
PRODUCT="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/AudioReader.app"

cd "$PROJECT_ROOT"
xcodebuild \
  -project AudioReader.xcodeproj \
  -scheme AudioReader-iOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -x "$PRODUCT/AudioReader" ]]; then
  print -u2 "iPad Simulator app was not produced at $PRODUCT"
  exit 1
fi

if [[ "$APP" != "$PROJECT_ROOT/AudioReader-iPad.app" ]]; then
  print -u2 "Refusing to replace unexpected app path: $APP"
  exit 1
fi

/bin/rm -rf "$APP"
/usr/bin/ditto "$PRODUCT" "$APP"
/usr/bin/codesign --force --sign - "$APP"

print "Built $APP"
