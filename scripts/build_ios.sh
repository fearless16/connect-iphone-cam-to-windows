#!/usr/bin/env bash
# Build the iOS app. Requires Xcode + a connected device with Developer Mode on.
# Replace the Team ID / bundle id with your signing identity.
set -euo pipefail

PROJ="$PWD"
APP_NAME=iPhoneCameraStream
TEAM_ID=""   # <-- set your Apple Developer Team ID
BUNDLE_ID=com.example.iphonecamerastream

xcodebuild \
  -project "$PROJ/ios/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

echo "Build done. Install on device and launch; it prints 'STATUS: Camera Active'."
