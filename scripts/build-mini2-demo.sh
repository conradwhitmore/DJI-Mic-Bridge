#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/lib/signing.sh"
# Optional local-only identity; never copy personal certificate metadata into source.
local_identity="$HOME/.config/micbridge/mini2-demo-signing-identity"
if [[ -z "${MICBRIDGE_SIGNING_IDENTITY+x}" && -f "$local_identity" ]]; then
    export MICBRIDGE_SIGNING_IDENTITY="$(cat "$local_identity")"
fi
signing_identity="$(micbridge_signing_identity "$project_root")"
app_path="$project_root/dist/MicBridge Mini 2 Demo.app"
if /bin/ps -axo command= | /usr/bin/grep -Fqx -- "$app_path/Contents/MacOS/Mini2Demo"; then
    printf '%s\n' 'Quit Mini 2 Demo before replacing its bundle.' >&2
    exit 1
fi
swift build -c release --product Mini2Demo
binary_dir="$(swift build -c release --product Mini2Demo --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Mini2Demo" "$app_path/Contents/MacOS/Mini2Demo"
/usr/bin/strip -S "$app_path/Contents/MacOS/Mini2Demo"
cp Resources/Mini2Demo/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md docs/MINI2-DEMO.md docs/MIC-MINI-2-FIRMWARE.md "$app_path/Contents/Resources/"
cp Vendor/liblc3/LICENSE "$app_path/Contents/Resources/liblc3-LICENSE"
/usr/bin/codesign --force --sign "$signing_identity" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
