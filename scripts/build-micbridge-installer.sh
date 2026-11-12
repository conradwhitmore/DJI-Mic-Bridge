#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
source "$project_root/scripts/lib/signing.sh"
signing_identity="$(micbridge_signing_identity "$project_root")"
export MICBRIDGE_DRIVER_SIGNING_IDENTITY="$signing_identity"
bash scripts/build-micbridge-audio-driver.sh
stage="$(mktemp -d "$project_root/.build/micbridge-installer.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
export MICBRIDGE_APP_OUTPUT="$stage/root/Applications/MicBridge.app"
bash scripts/build-micbridge.sh
mkdir -p "$stage/root/Library/Audio/Plug-Ins/HAL" "$stage/resources" "$stage/packages"
ditto dist/MicBridgeAudio.driver "$stage/root/Library/Audio/Plug-Ins/HAL/MicBridgeAudio.driver"
cp packaging/micbridge/welcome.html "$stage/resources/"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/MicBridge/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/MicBridge/Info.plist)
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
python3 - "$stage/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as stream: components = plistlib.load(stream)
for item in components:
    item['BundleIsRelocatable'] = False
    item['BundleOverwriteAction'] = 'upgrade'
with open(path, 'wb') as stream: plistlib.dump(components, stream)
PY
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
  --scripts packaging/micbridge/scripts --install-location / --ownership recommended \
  --identifier org.dji-mic-rxless.micbridge.installer --version "$version.$build" \
  "$stage/packages/MicBridgeComponent.pkg"
app_archs="$(lipo -archs "$MICBRIDGE_APP_OUTPUT/Contents/MacOS/MicBridge")"
host_archs="${app_archs// /,}"
cat > "$stage/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>MicBridge $version</title>
  <welcome file="welcome.html"/>
  <options customize="never" require-scripts="false" hostArchitectures="$host_archs"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="org.dji-mic-rxless.micbridge.installer"/></choice>
  <pkg-ref id="org.dji-mic-rxless.micbridge.installer" version="$version.$build" onConclusion="RequireRestart">MicBridgeComponent.pkg</pkg-ref>
</installer-gui-script>
EOF
package_output="${MICBRIDGE_INSTALLER_OUTPUT:-$project_root/dist/MicBridge-Installer.pkg}"
mkdir -p "$(dirname "$package_output")"
if [[ -n "${MICBRIDGE_INSTALLER_SIGNING_IDENTITY:-}" ]]; then
    productbuild --distribution "$stage/Distribution.xml" --resources "$stage/resources" \
      --package-path "$stage/packages" --sign "$MICBRIDGE_INSTALLER_SIGNING_IDENTITY" "$package_output"
else
    productbuild --distribution "$stage/Distribution.xml" --resources "$stage/resources" \
      --package-path "$stage/packages" "$package_output"
    printf '%s\n' 'Local development installer: package is unsigned; App and driver use the selected code-signing identity.'
fi
shasum -a 256 "$package_output" dist/MicBridgeAudio-Source.tar.gz > "${package_output%.pkg}.sha256"
printf '%s\n' "$package_output"
