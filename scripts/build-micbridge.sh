#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/lib/signing.sh"
signing_identity="$(micbridge_signing_identity "$project_root")"
# Freeze connection/route behavior; permit only the structured result observer.
python3 scripts/check-micbridge-transport.py
build_args=(-c release --product MicBridge)
if [[ -n "${MICBRIDGE_APP_ARCH:-}" ]]; then
    case "$MICBRIDGE_APP_ARCH" in arm64|x86_64) ;; *) echo 'MICBRIDGE_APP_ARCH must be arm64 or x86_64' >&2; exit 1 ;; esac
    build_args+=(--arch "$MICBRIDGE_APP_ARCH")
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_path="${MICBRIDGE_APP_OUTPUT:-$project_root/dist/MicBridge.app}"
# Packaging can use an isolated staging path while the current app keeps running.
# Never replace a live executable in-place.
if /bin/ps -axo command= | /usr/bin/grep -Fqx -- "$app_path/Contents/MacOS/MicBridge"; then
    printf '%s\n' 'Quit this MicBridge app before replacing its bundle.' >&2
    exit 1
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/Devices"
cp "$binary_dir/MicBridge" "$app_path/Contents/MacOS/MicBridge"
# Remove local debug-map paths from the distributable copy before signing.
/usr/bin/strip -S "$app_path/Contents/MacOS/MicBridge"
cp Resources/MicBridge/Info.plist "$app_path/Contents/Info.plist"
cp Resources/MicBridge/Devices/* "$app_path/Contents/Resources/Devices/"
cp Resources/MicBridge/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp docs/MICBRIDGE.txt "$app_path/Contents/Resources/MicBridge Help.txt"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/"
cp Vendor/liblc3/LICENSE "$app_path/Contents/Resources/liblc3-LICENSE"
cp Vendor/BlackHole/LICENSE "$app_path/Contents/Resources/BlackHole-LICENSE.txt"
cp Vendor/BlackHole/MICBRIDGE-CHANGES.txt "$app_path/Contents/Resources/"
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -czf "$app_path/Contents/Resources/MicBridgeAudio-Source.tar.gz" \
  Vendor/BlackHole scripts/build-micbridge-audio-driver.sh
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
