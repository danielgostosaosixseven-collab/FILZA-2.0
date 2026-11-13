#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/HYperRegedit-original-identity.xcarchive"
IPA="$BUILD_DIR/Filza-External-V1000-unsigned.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }
python3 "$ROOT/tools/validate_patch_security.py"
python3 "$ROOT/tools/validate_ipa_resources.py" --source-only

xcodebuild \
  -project "$ROOT/ThreeOneOSFive.xcodeproj" \
  -scheme "Filza Bypass External" \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

APP="$ARCHIVE/Products/Applications/FILZA EXTERNAL BYPASS.app"
test -d "$APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FILZA EXTERNAL BYPASS' "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$IPA" Payload
  rm -rf Payload
)
python3 "$ROOT/tools/validate_ipa_resources.py" "$IPA"
echo "$IPA"
