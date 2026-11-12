# Third-party notices

## Google liblc3

Source: https://github.com/google/liblc3
Pinned commit: f9c127fd35975a0494b9e187589501ee984dc4b6
License: Apache License 2.0, retained at Vendor/liblc3/LICENSE.

Upstream include/ and src/ are unchanged. A local include/module.modulemap exposes only lc3.h to Swift; it is not an upstream file. Copyright notices in upstream source files are preserved. No upstream NOTICE file was present in the pinned checkout.

## BlackHole / MicBridge Audio

Source: https://github.com/ExistentialAudio/BlackHole
Pinned tag: v0.7.1; commit: e2b22aaaba4e507a097131704bf96dabc004d9cf.
License: GPL-3.0, retained at Vendor/BlackHole/LICENSE.

MicBridge Audio is a separately loaded CoreAudio HAL driver derived from BlackHole.
It uses its own identity and reports USB transport for compatibility with apps
that hide virtual devices. It remains a software loopback. Modified files and
rebuild instructions are listed in Vendor/BlackHole/MICBRIDGE-CHANGES.txt.
The complete corresponding modified driver source and build script accompany the
installer as MicBridgeAudio-Source.tar.gz, also included in the App resources.
The installer places the driver beside existing HAL plugins; it does not remove
or replace the official BlackHole driver. MicBridge communicates with these
separately loaded drivers through public CoreAudio APIs.

Compatibility approach reference: https://github.com/HD838A/remote-mic-app
(SayAll, third_party/blackhole/blackhole-device-usb.patch). MicBridge uses its own
build/installer scripts and identifiers. No SayAll application code is bundled.

## Project scope

Builds include the device renders tracked in Resources/MicBridge/Devices for Mic 2, Mic Mini, Mic Mini 2 and Mic 3. These images are separate from the original application code.
Original pages, image URLs and SHA-256 hashes are recorded in Resources/MicBridge/Devices/SOURCES.json.
Product imagery and trademarks remain the property of their respective owners and are not relicensed by the project's original-code license.

The original code and research concern DJI Mic 2 Bluetooth audio interoperability. Vendor trademarks do not imply endorsement. The original code license does not relicense dependencies or imply a warranty of codec patent clearance.

## Interoperability research references

- https://github.com/flight-commander/dji_mic2_firmware — publicly available firmware used for offline protocol analysis; firmware binaries are not included.
- https://github.com/fky1990/DJI-Mic-2-Bridge — reference for reading macOS cached Bluetooth battery data; the local implementation checks selector availability and ABI. SPP battery querying was independently traced in TX firmware.
- https://github.com/sohumsuthar/dji-mic-bridge — background reference for Bluetooth microphone workflows.

References do not imply endorsement or relicense their source. The app icon is drawn by the project's own scripts/make-micbridge-icon.swift.
