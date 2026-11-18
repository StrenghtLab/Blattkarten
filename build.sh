#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-Blattkarten.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Blattkarten.icns "$app/Contents/Resources/"
for architecture in arm64 x86_64; do
    xcrun swiftc -parse-as-library -target "$architecture-apple-macos14.0" \
        -module-name Blattkarten Blattkarten.swift Updates.swift CardArtwork.swift CardPrinting.swift PaperCard.swift TutorClient.swift TutorDock.swift LearningProgress.swift NativeTutorChat.swift PetCloset.swift StreakPet.swift -o "$app/Contents/MacOS/Blattkarten-$architecture"
done
xcrun lipo -create "$app/Contents/MacOS/Blattkarten-arm64" "$app/Contents/MacOS/Blattkarten-x86_64" \
    -output "$app/Contents/MacOS/Blattkarten"
rm "$app/Contents/MacOS/Blattkarten-arm64" "$app/Contents/MacOS/Blattkarten-x86_64"
widget="$app/Contents/PlugIns/StreakWidget.appex"
mkdir -p "$widget/Contents/MacOS"
cp StreakWidget/Info.plist "$widget/Contents/Info.plist"
for architecture in arm64 x86_64; do
    xcrun swiftc -parse-as-library -application-extension -target "$architecture-apple-macos14.0" \
        -module-name StreakWidget StreakPet.swift StreakWidget/StreakWidget.swift -o "$widget/Contents/MacOS/StreakWidget-$architecture"
done
xcrun lipo -create "$widget/Contents/MacOS/StreakWidget-arm64" "$widget/Contents/MacOS/StreakWidget-x86_64" \
    -output "$widget/Contents/MacOS/StreakWidget"
rm "$widget/Contents/MacOS/StreakWidget-arm64" "$widget/Contents/MacOS/StreakWidget-x86_64"
codesign --force --sign - --options runtime --entitlements StreakWidget/Widget.entitlements "$widget"
codesign --force --sign - --options runtime --entitlements Camera.entitlements "$app"
