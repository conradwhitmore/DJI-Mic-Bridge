import XCTest
@testable import MicLinkCore

final class SignalHistoryTests: XCTestCase {
    func testKnownSineLevelAndPeak() throws {
        let history = SignalHistory()
        let sine = (0..<960).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        history.append(sine)
        let window = try XCTUnwrap(history.windows.last)
        XCTAssertEqual(window.peakDB, -6.0206, accuracy: 0.001)
        XCTAssertEqual(window.rmsDB, -9.0309, accuracy: 0.001)
        XCTAssertEqual(history.sessionPeak, 0.5, accuracy: 0.0001)
    }
    func testPacketBoundariesDoNotChangeWindowsAndHistoryIsBounded() {
        let whole = SignalHistory(capacity: 4), fragmented = SignalHistory(capacity: 4)
        var samples: [Float] = []
        for i in 1...8 { samples += [Float](repeating: Float(i)/10, count: 960) }
        whole.append(samples)
        for offset in stride(from: 0, to: samples.count, by: 137) {
            fragmented.append(Array(samples[offset..<min(offset+137,samples.count)]))
        }
        XCTAssertEqual(whole.windows.count, 4)
        XCTAssertEqual(whole.windows.map(\.peak), fragmented.windows.map(\.peak))
        XCTAssertEqual(whole.windows.map(\.rms), fragmented.windows.map(\.rms))
        XCTAssertEqual(whole.windows.first?.peak, 0.5)
    }
    func testSilenceAndFullScaleRemainFinite() throws {
        let history = SignalHistory()
        history.append([Float](repeating: 0, count: 960))
        XCTAssertEqual(history.windows.last?.rmsDB, -96)
        history.append([Float](repeating: 1, count: 960))
        XCTAssertEqual(history.windows.last?.rmsDB, 0)
        XCTAssertEqual(history.windows.last?.peakDB, 0)
        history.append([Float](repeating: .nan, count: 960))
        XCTAssertEqual(history.windows.last?.rmsDB, -96)
    }

    func testHFP16kMaintainsTwentyMillisecondWindows() {
        let history = SignalHistory(sampleRate: 16000)
        history.append(Array(repeating: 0.5, count: 319))
        XCTAssertTrue(history.windows.isEmpty)
        history.append([0.5])
        XCTAssertEqual(history.windows.count, 1)
        XCTAssertEqual(history.windows[0].rms, 0.5, accuracy: 0.0001)
        history.append(Array(repeating: 0, count: 16000 * 4))
        XCTAssertEqual(history.windows.count, 200)
        XCTAssertEqual(history.windows.last?.peak, 0)
    }
    func testInvalidDisplayRateUsesDefaultWindow() {
        for rate in [Double.nan, .infinity, -1, 0] {
            let history = SignalHistory(sampleRate: rate)
            history.append(Array(repeating: 0, count: 960))
            XCTAssertEqual(history.windows.count, 1)
        }
    }
}
