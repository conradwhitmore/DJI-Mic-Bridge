import XCTest
@testable import Mini2Protocol

final class SPPHotkeyTests: XCTestCase {
    private let models: [(MiniTransmitterModel, Mini2Hotkey)] = [(.mini, .powerSingle), (.mini2, .powerDouble)]
    private func status(_ nc: Bool, capture: UInt8 = 0, disabled: Bool = false) -> Mini2SPPStatus {
        var b = [UInt8](repeating: 0, count: 22)
        b[11] = nc ? 0x80 : 0; b[12] = capture; b[15] = disabled ? 8 : 0
        return Mini2SPPStatus(bytes: b)
    }
    func testBaselineAndEachDenoiseEdge() {
        for (model, powerEvent) in models {
            var h = Mini2SPPHotkeys(model: model)
            XCTAssertEqual(h.observe(status(true), at: 0), [])
            XCTAssertEqual(h.observe(status(true), at: 0.2), [])
            XCTAssertEqual(h.observe(status(false), at: 0.4), [powerEvent])
            XCTAssertEqual(h.observe(status(false), at: 0.6), [])
            XCTAssertEqual(h.observe(status(true), at: 0.8), [powerEvent])
        }
    }
    func testCaptureEventsStayDistinctAndCoexist() {
        for (model, powerEvent) in models {
            var h = Mini2SPPHotkeys(model: model)
            XCTAssertEqual(h.observe(status(false, capture: 1), at: 0), [.connection])
            XCTAssertEqual(h.observe(status(false, capture: 1), at: 0.2), [.connection])
            XCTAssertEqual(h.observe(status(true, capture: 1), at: 0.4), [.connection, powerEvent])
        }
    }
    func testGapReconnectAndDisabledButtonOnlySynchronize() {
        for (model, powerEvent) in models {
            var h = Mini2SPPHotkeys(model: model)
            _ = h.observe(status(false), at: 0)
            XCTAssertEqual(h.observe(status(true), at: 2), [])
            h.resetBaseline()
            XCTAssertEqual(h.observe(status(false), at: 2.2), [])
            XCTAssertEqual(h.observe(status(true, disabled: true), at: 2.4), [])
            XCTAssertEqual(h.observe(status(true), at: 2.6), [])
            XCTAssertEqual(h.observe(status(false), at: 2.8), [powerEvent])
        }
    }
    func testSoftwareWriteDoesNotTriggerPowerButCaptureStillWorks() {
        for (model, powerEvent) in models {
            var h = Mini2SPPHotkeys(model: model)
            _ = h.observe(status(false), at: 0)
            h.softwareDenoiseWrite(at: 0.1)
            XCTAssertEqual(h.observe(status(true, capture: 1), at: 0.3), [.connection])
            for t in stride(from: 0.5, through: 6.5, by: 0.2) { XCTAssertEqual(h.observe(status(true), at: t), []) }
            XCTAssertEqual(h.observe(status(false), at: 6.8), [powerEvent])
        }
    }
}
