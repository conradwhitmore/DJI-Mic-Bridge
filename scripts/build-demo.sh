#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_path="$project_root/dist/DJI Mic RXless Demo.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/RXlessDemo" "$app_path/Contents/MacOS/RXlessDemo"
/usr/bin/strip -S "$app_path/Contents/MacOS/RXlessDemo"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp docs/RECOVERY.md "$app_path/Contents/Resources/RECOVERY.md"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Vendor/liblc3/LICENSE "$app_path/Contents/Resources/liblc3-LICENSE"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
