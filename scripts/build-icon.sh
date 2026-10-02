#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
output_dir="$project_dir/.build/icon-composer"
needs_build=false
for source in "$0" Resources/AppIcon.icon/icon.json Resources/AppIcon.icon/Assets/*; do
    if [[ ! "$output_dir/Assets.car" -nt "$source" || ! -f "$output_dir/Info.plist" || ! -f "$output_dir/AppIcon.icns" ]]; then
        needs_build=true
    fi
done
if [[ "$needs_build" == false ]]; then exit 0; fi
mkdir -p "$output_dir"
xcrun actool Resources/AppIcon.icon --compile "$output_dir" \
    --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
    --output-partial-info-plist "$output_dir/Info.plist" \
    --output-format human-readable-text --warnings --errors
