#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
destination="${1:-$PWD/Blattkarten-$version.dmg}"
if [[ "$destination" != /* ]]; then destination="$PWD/$destination"; fi
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
./build.sh "$stage/Blattkarten.app"
ln -s /Applications "$stage/Programme"
hdiutil create -volname Blattkarten -srcfolder "$stage" -format UDZO "$destination"
hdiutil verify "$destination"
