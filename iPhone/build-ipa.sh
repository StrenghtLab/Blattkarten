#!/bin/bash
set -euo pipefail
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "Das iPhone-SDK fehlt. Führe den Build mit vollständigem Xcode aus." >&2
    exit 1
fi
cd "$(dirname "$0")"
destination="${1:-$PWD/Blattkarten-iPhone.ipa}"
if [[ "$destination" != /* ]]; then destination="$PWD/$destination"; fi
mkdir -p "$(dirname "$destination")"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
xcrun xcodebuild -project Blattkarten.xcodeproj -target Blattkarten -configuration Release -sdk iphoneos \
    "CONFIGURATION_BUILD_DIR=$stage/build" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
ditto "$stage/build/Blattkarten.app" "$stage/Payload/Blattkarten.app"
(cd "$stage" && zip -qry Blattkarten.ipa Payload)
mv "$stage/Blattkarten.ipa" "$destination"
unzip -tq "$destination"
printf '%s\n' "$destination"
