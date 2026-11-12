import XCTest
import CoreAudio
import CBridgeAudio
@testable import MicBridgeSupport

final class BridgeAudioTests: XCTestCase {
    private func write(_ b: OpaquePointer, _ samples: [Float], now: Double = 1) {
        samples.withUnsafeBufferPointer { mb_buffer_write(b, $0.baseAddress, UInt32($0.count), now) }
    }
    private func render(_ b: OpaquePointer, count: Int, rate: Double = 48000, now: Double = 1) -> ([Float], [Float]) {
        var left = [Float](repeating: 42, count: count), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in mb_buffer_render(b, l.baseAddress, r.baseAddress, UInt32(count), rate, now) }
        }
        return (left, right)
    }
    func testIdentityRejectsOtherVirtualAndSimilarlyNamedDevices() {
        XCTAssertTrue(VirtualInputIdentity.matches(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", manufacturer: "Existential Audio Inc.", transport: kAudioDeviceTransportTypeVirtual))
        for (uid, name, maker) in [("BlackHole16ch_UID", "BlackHole 2ch", "Existential Audio Inc."),
                                  ("BlackHole2ch_UID", "Aggregate Device", "Apple"),
                                  ("fake", "BlackHole 2ch", "Existential Audio Inc.")] {
            XCTAssertFalse(VirtualInputIdentity.matches(uid: uid, name: name, manufacturer: maker, transport: kAudioDeviceTransportTypeVirtual))
        }
    }
    func testMicBridgeUSBLoopbackIsInputOnlyForRouteProtection() {
        for profile in VirtualInputIdentity.Profile.allCases {
            XCTAssertTrue(VirtualInputIdentity.allowsRoute(uid: profile.uid, name: profile.name,
                manufacturer: profile.manufacturer, transport: profile.transport, input: true))
            XCTAssertFalse(VirtualInputIdentity.allowsRoute(uid: profile.uid, name: profile.name,
                manufacturer: profile.manufacturer, transport: profile.transport, input: false))
            XCTAssertFalse(VirtualInputIdentity.allowsRoute(uid: profile.uid, name: "Other device",
                manufacturer: profile.manufacturer, transport: profile.transport, input: true))
        }
        XCTAssertFalse(VirtualInputIdentity.matches(uid: "MicBridgeAudio2ch_UID", name: "MicBridge Audio",
            manufacturer: "MicBridge", transport: kAudioDeviceTransportTypeVirtual))
        XCTAssertFalse(VirtualInputIdentity.matches(uid: "another_UID", name: "MicBridge Audio",
            manufacturer: "MicBridge", transport: kAudioDeviceTransportTypeUSB))
        XCTAssertTrue(VirtualInputIdentity.allowsRoute(uid: "USB-headset", name: "KT USB Audio",
            manufacturer: "KTMicro", transport: kAudioDeviceTransportTypeUSB, input: false))
        XCTAssertFalse(VirtualInputIdentity.allowsRoute(uid: "unknown-loopback", name: "Virtual device",
            manufacturer: "Other", transport: kAudioDeviceTransportTypeVirtual, input: true))
    }
    func testEmptyAndShortInputIsSilentUntilPrimed() throws {
        let b = try XCTUnwrap(mb_buffer_create(1024, 128)); defer { mb_buffer_destroy(b) }
        XCTAssertEqual(render(b, count: 64).0, [Float](repeating: 0, count: 64))
        write(b, [Float](repeating: 0.5, count: 64))
        XCTAssertEqual(render(b, count: 64).0, [Float](repeating: 0, count: 64))
        write(b, [Float](repeating: 0.5, count: 64))
        let (l,r) = render(b, count: 64)
        XCTAssertEqual(l,r); XCTAssertTrue(l.allSatisfy { $0 == 0.5 })
    }
    func testUnderrunAndResetNeverRepeatOldAudio() throws {
        let b = try XCTUnwrap(mb_buffer_create(1024, 128)); defer { mb_buffer_destroy(b) }
        write(b, [Float](repeating: 0.5, count: 256))
        let first = render(b, count: 512).0
        XCTAssertEqual(first.last, 0)
        XCTAssertEqual(render(b, count: 64).0, [Float](repeating: 0, count: 64))
        write(b, [Float](repeating: 0.75, count: 256)); mb_buffer_reset(b)
        XCTAssertEqual(render(b, count: 64).0, [Float](repeating: 0, count: 64))
        write(b, [Float](repeating: -0.25, count: 256))
        XCTAssertTrue(render(b, count: 64).0.allSatisfy { $0 == -0.25 })
    }
    func testWaitingDoesNotCountUnderrunsButActiveStarvationDoes() throws {
        let b = try XCTUnwrap(mb_buffer_create(1024, 128)); defer { mb_buffer_destroy(b) }
        _ = render(b, count: 480, now: 100)
        write(b, [Float](repeating: 0.5, count: 64), now: 100)
        _ = render(b, count: 480, now: 100)
        XCTAssertEqual(mb_buffer_stats(b).underrun_frames, 0)

        write(b, [Float](repeating: 0.5, count: 192), now: 100)
        _ = render(b, count: 512, now: 100)
        let activeUnderruns = mb_buffer_stats(b).underrun_frames
        XCTAssertGreaterThan(activeUnderruns, 0)
        mb_buffer_reset(b)
        for i in 0..<100 {
            XCTAssertTrue(render(b, count: 480, now: 101 + Double(i)).0.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(mb_buffer_stats(b).underrun_frames, activeUnderruns)

        write(b, [Float](repeating: -0.25, count: 256), now: 202)
        XCTAssertTrue(render(b, count: 64, now: 202).0.allSatisfy { $0 == -0.25 })
        _ = render(b, count: 512, now: 202)
        XCTAssertGreaterThan(mb_buffer_stats(b).underrun_frames, activeUnderruns)
    }
    func testStaleAudioIsDiscardedEvenWithBufferedFrames() throws {
        let b = try XCTUnwrap(mb_buffer_create(1024, 128)); defer { mb_buffer_destroy(b) }
        write(b, [Float](repeating: 0.5, count: 256), now: 1)
        XCTAssertEqual(render(b, count: 128, now: 1.3).0, [Float](repeating: 0, count: 128))
        XCTAssertEqual(mb_buffer_stats(b).queued_frames, 0)
    }
    func testOverflowIsBoundedAndReported() throws {
        let b = try XCTUnwrap(mb_buffer_create(1024, 128)); defer { mb_buffer_destroy(b) }
        write(b, [Float](repeating: 0.5, count: 2000))
        XCTAssertEqual(mb_buffer_stats(b).queued_frames, 1024)
        XCTAssertEqual(mb_buffer_stats(b).overflow_frames, 976)
        _ = render(b, count: 64)
        XCTAssertEqual(mb_buffer_stats(b).latency_dropped_frames, 896)
    }
    func testStereoAndSampleRateConversionPreserveToneFrequency() throws {
        for rate in [44100.0, 48000, 96000] {
            let b = try XCTUnwrap(mb_buffer_create(24000, 1920)); defer { mb_buffer_destroy(b) }
            let tone = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 1000 / 48000) * 0.5) }
            write(b,tone)
            let (l,r) = render(b, count: Int(rate * 0.08), rate: rate)
            XCTAssertEqual(l,r)
            let crossings = zip(l,l.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            XCTAssertEqual(Double(crossings), 80, accuracy: 1)
            XCTAssertTrue(l.allSatisfy { $0.isFinite && abs($0) <= 0.51 })
        }
    }
    func testInvalidSamplesAndRatesDoNotEscape() throws {
        let b = try XCTUnwrap(mb_buffer_create(64, 4)); defer { mb_buffer_destroy(b) }
        write(b, [.nan, .infinity, -.infinity, 2, -2, 0, 0, 0])
        XCTAssertTrue(render(b, count: 16).0.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertEqual(render(b, count: 16, rate: .nan).0, [Float](repeating: 0, count: 16))
        XCTAssertNil(mb_buffer_create(16, 16))
    }
    func testTenMinuteClockDriftSimulationRemainsBounded() throws {
        let b = try XCTUnwrap(mb_buffer_create(24000, 1920)); defer { mb_buffer_destroy(b) }
        write(b, [Float](repeating: 0.2, count: 1920), now: 0)
        for i in 0..<60000 {
            let time = Double(i)/100
            // Deliberately add source-clock skew (about 208 ppm).
            write(b, [Float](repeating: 0.2, count: i % 10 == 0 ? 481 : 480), now: time)
            _ = render(b, count: 480, now: time)
        }
        let stats = mb_buffer_stats(b)
        XCTAssertEqual(stats.overflow_frames, 0); XCTAssertEqual(stats.latency_dropped_frames, 0)
        XCTAssertEqual(stats.underrun_frames, 0)
        XCTAssertLessThan(stats.queued_frames, 4000)
    }
}
