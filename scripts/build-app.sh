#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
bash scripts/swift-local.sh build -c release
binary_dir="$(bash scripts/swift-local.sh build -c release --show-bin-path)"
app_dir="$project_dir/dist/Bilingual Live Caption.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
bash scripts/build-icon.sh
cp .build/icon-composer/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp .build/icon-composer/Assets.car "$app_dir/Contents/Resources/Assets.car"
cp "$binary_dir/BilingualLiveCaption" "$app_dir/Contents/MacOS/BilingualLiveCaption"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge .build/icon-composer/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - --identifier net.waylonwu.bilingual-live-caption "$app_dir"
touch "$app_dir"
printf 'Built %s\n' "$app_dir"
