#!/bin/bash
set -euo pipefail
umask 077
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="$project_root/work/diagnostics/channel-observer"
mkdir -p "$output_dir"
xcrun swiftc "$project_root/scripts/diagnostics/Mic2ChannelObserver.swift" \
    -framework IOBluetooth -o "$output_dir/mic2-channel-observer"
printf '%s\n' "$output_dir/mic2-channel-observer"
