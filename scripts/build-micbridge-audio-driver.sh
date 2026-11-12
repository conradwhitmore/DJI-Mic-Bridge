#!/bin/bash
# Builds only in the project; never installs into the system audio directory.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
driver_archs="${MICBRIDGE_DRIVER_ARCHS:-arm64 x86_64}"
driver_signing="${MICBRIDGE_DRIVER_SIGNING_IDENTITY:--}"
driver_build="$project_root/.build/micbridge-audio-driver"
driver_output="$project_root/dist/MicBridgeAudio.driver"
mkdir -p "$driver_build" "$project_root/dist"
xcodebuild -quiet -project Vendor/BlackHole/BlackHole.xcodeproj -target BlackHole \
  -configuration Release -sdk macosx ARCHS="$driver_archs" ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO \
  PRODUCT_NAME=MicBridgeAudio PRODUCT_BUNDLE_IDENTIFIER=org.dji-mic-rxless.MicBridgeAudio \
  MARKETING_VERSION=0.1.0 SYMROOT="$driver_build/products" OBJROOT="$driver_build/objects" build
ditto "$driver_build/products/Release/MicBridgeAudio.driver" "$driver_output"
# Debug maps can contain the builder's home directory even in release builds.
/usr/bin/strip -S "$driver_output/Contents/MacOS/MicBridgeAudio"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$driver_output/Contents/Info.plist"
mkdir -p "$driver_output/Contents/Resources"
cp Vendor/BlackHole/LICENSE "$driver_output/Contents/Resources/BlackHole-LICENSE.txt"
cp Vendor/BlackHole/MICBRIDGE-CHANGES.txt "$driver_output/Contents/Resources/"
codesign --force --sign "$driver_signing" "$driver_output"
codesign --verify --strict "$driver_output"
# Corresponding source, including the build script, accompanies every binary.
COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname wheel -czf "$project_root/dist/MicBridgeAudio-Source.tar.gz" \
  Vendor/BlackHole scripts/build-micbridge-audio-driver.sh
printf '%s\n' "$driver_output" "$project_root/dist/MicBridgeAudio-Source.tar.gz"
