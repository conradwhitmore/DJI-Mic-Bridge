import XCTest
import Mini2Protocol
import MicLinkCore

final class PatchIdentityTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let a = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
        }
    }
    // Actual modified ARM code under emulation, not hardware captures.
    private let identity = "551804203a023412803ff04d4252470101000f000000f86f"
    private let enabled = "551804203a023412803ff04d4252470101000f0001002076"
    func testIdentityAndModesRequireMatchingRequestSequence() throws {
        for (hex, mode) in [(identity, Mini2PatchIdentity.Mode.disabled), (enabled, .enabled)] {
            let frame = try XCTUnwrap(Mini2Frame(bytes(hex)))
            XCTAssertTrue(Mini2SPPCommand.patchIdentity.matches(frame, sequence: 0x1234))
            XCTAssertFalse(Mini2SPPCommand.patchIdentity.matches(frame, sequence: 0x1235))
            let info = try XCTUnwrap(Mini2PatchIdentity(frame))
            XCTAssertEqual(info.revision, 1); XCTAssertTrue(info.supportsKeyMode)
            XCTAssertEqual(info.mode, mode); XCTAssertEqual(info.result, 0)
            XCTAssertNil(frame.patchKey); XCTAssertNil(frame.independentKey)
        }
    }
    func testIndependentEventsSurviveAllSPPFragmentBoundariesWithoutAudio() throws {
        for (hex, key) in [("551304033a020000803ff14d42524701069cf3", Mini2Hotkey.connection),
                           ("551304033a020000803ff14d425247010715e2", .powerSingle),
                           ("551304033a020000803ff14d4252470108e21a", .connectionDouble),
                           ("551304033a020000803ff14d42524701096b0b", .powerDouble)] {
            let raw = bytes(hex), envelope = [UInt8(0xaa), 0, UInt8(bytes(hex).count)] + bytes(hex) + [0xa5]
            XCTAssertEqual(raw.count, 19)
            for split in 0...envelope.count {
                var stream = Mini2SPPStream()
                let a = stream.feed(Data(envelope.prefix(split)), at: 0)
                let b = stream.feed(Data(envelope.dropFirst(split)), at: 0.01)
                let controls = a.controls + b.controls
                XCTAssertEqual(controls.count, 1); XCTAssertEqual(controls.first?.patchKey, key)
                XCTAssertTrue(a.audio.isEmpty && b.audio.isEmpty && a.events.isEmpty && b.events.isEmpty)
            }
        }
    }
    func testDoubleClicksRequireAdvertisedCapabilityAndEnabledMode() throws {
        // r2 fixtures from the patched ARM code, with bit 4 advertising independent double-clicks.
        let r2Off = try XCTUnwrap(Mini2PatchIdentity(XCTUnwrap(Mini2Frame(bytes("551804203a023412803ff04d4252470102001f00000024a0")))))
        let r2On = try XCTUnwrap(Mini2PatchIdentity(XCTUnwrap(Mini2Frame(bytes("551804203a023412803ff04d4252470102001f000100fcb9")))))
        let r1On = try XCTUnwrap(Mini2PatchIdentity(XCTUnwrap(Mini2Frame(bytes(enabled)))))
        XCTAssertEqual(r2On.revision, 2)
        XCTAssertTrue(r2On.supportsDoubleClicks)
        XCTAssertFalse(r1On.supportsDoubleClicks)
        for key in Mini2Hotkey.allCases {
            XCTAssertTrue(r2On.accepts(key))
            XCTAssertFalse(r2Off.accepts(key))
            XCTAssertEqual(r1On.accepts(key), key == .connection || key == .powerSingle)
        }
    }
    func testMalformedOrDifferentNamespaceDoesNotConfirmPatch() throws {
        let good = bytes(identity)
        for (offset, value) in [(4, UInt8(0x5a)), (5, 3), (8, 0x40), (9, 0), (10, 1),
                                (11, 0), (15, 2), (20, 3), (21, 1)] {
            var bad = good; bad[offset] = value
            let c = crc16(Array(bad.dropLast(2))); bad[bad.count - 2] = UInt8(c & 255); bad[bad.count - 1] = UInt8(c >> 8)
            XCTAssertNil(Mini2PatchIdentity(try XCTUnwrap(Mini2Frame(bad))))
        }
        var corrupt = good; corrupt[corrupt.count - 1] ^= 1
        XCTAssertNil(Mini2Frame(corrupt))
        var unsupported = good; unsupported[18] = 0
        let c = crc16(Array(unsupported.dropLast(2))); unsupported[unsupported.count - 2] = UInt8(c & 255); unsupported[unsupported.count - 1] = UInt8(c >> 8)
        let frame = try XCTUnwrap(Mini2Frame(unsupported))
        XCTAssertFalse(try XCTUnwrap(Mini2PatchIdentity(frame)).supportsKeyMode)
    }
}
