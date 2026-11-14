// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DJIMicRXless",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RXlessDemo", targets: ["RXlessDemo"]),
               .executable(name: "MicBridge", targets: ["MicBridge"]),
               .executable(name: "Mini2Demo", targets: ["Mini2Demo"])],
    targets: [
        .target(name: "CLc3", path: "Vendor/liblc3", exclude: ["LICENSE", "UPSTREAM.md"],
                sources: ["src/attdet.c", "src/bits.c", "src/bwdet.c", "src/energy.c", "src/lc3.c", "src/ltpf.c", "src/mdct.c", "src/plc.c", "src/sns.c", "src/spec.c", "src/tables.c", "src/tns.c"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath("src")]),
        .target(name: "MicLinkCore", dependencies: ["CLc3"]),
        .executableTarget(name: "RXlessDemo", dependencies: ["MicLinkCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOBluetooth"),
                             .linkedFramework("CoreAudio"), .linkedFramework("AVFoundation")]),
        .target(name: "CBridgeAudio", publicHeadersPath: "include"),
        .target(name: "MicBridgeSupport"),
        .target(name: "Mini2Protocol", dependencies: ["MicLinkCore"]),
        .executableTarget(name: "Mini2Demo", dependencies: ["Mini2Protocol", "MicLinkCore", "MicBridgeSupport"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                             .linkedFramework("CoreBluetooth"), .linkedFramework("IOBluetooth"),
                             .linkedFramework("CoreAudio")]),
        .testTarget(name: "Mini2ProtocolTests", dependencies: ["Mini2Protocol", "MicLinkCore"]),
        .executableTarget(name: "MicBridge", dependencies: ["MicLinkCore", "MicBridgeSupport", "Mini2Protocol", "CBridgeAudio"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
                             .linkedFramework("CoreBluetooth"),
                             .linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio"),
                             .linkedFramework("AVFoundation"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "MicLinkCoreTests", dependencies: ["MicLinkCore"]),
        .testTarget(name: "MicBridgeSupportTests", dependencies: ["MicBridgeSupport", "CBridgeAudio"])
    ])
