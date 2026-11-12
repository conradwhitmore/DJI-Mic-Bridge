#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build -c release
segment_build_dir="$(swift build -c release --show-bin-path)"
segment_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/recording-checks.XXXXXX")"
trap 'rm -rf "$segment_check_dir"' EXIT
mkdir -p work/diagnostics/segment-check-module-cache
xcrun swiftc -module-cache-path work/diagnostics/segment-check-module-cache \
    -I "$segment_build_dir/Modules" -I Vendor/liblc3/include \
    scripts/diagnostics/RecordingSegmentsChecks.swift \
    "$segment_build_dir"/MicLinkCore.build/*.o "$segment_build_dir"/CLc3.build/src/*.o \
    -o "$segment_check_dir/checks"
"$segment_check_dir/checks"
