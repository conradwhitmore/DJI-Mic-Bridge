import XCTest
@testable import MicBridgeSupport

final class DeviceProfileTests: XCTestCase {
    func testModelsCannotInheritMic2Transport() {
        let pairs: [(String, MicModel)] = [("DJI-MIC2-A1B2C3", .mic2), ("DJI Mic Mini", .mini),
            ("DJI-MIC-MINI2-A1B2C3", .mini2), ("DJI Mic 3", .mic3),
            ("DJI Mic Mini 2S", .unknown), ("DJI Mic 20", .unknown), ("Other Mic 2", .unknown)]
        for (name, model) in pairs { XCTAssertEqual(MicModel.identify(name), model) }
        for model in MicModel.allCases where model != .mic2 && model != .mini2 { XCTAssertNil(model.adapter) }
        XCTAssertEqual(MicModel.mic2.adapter, .mic2SPP)
        XCTAssertEqual(MicModel.mini2.adapter, .mini2SPP)
    }
    func testDeletionSurvivesPreferencesReconstructionWithoutEnablingStartupConnection() {
        let suite = "MicBridgeTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BridgePreferences(defaults: defaults)
        XCTAssertFalse(settings.autoSPP)
        XCTAssertTrue(settings.resident)
        settings.showWindow = true
        XCTAssertFalse(settings.autoSPP)
        settings.autoSPP = true
        settings.prepareReconnectDeletion()
        let restarted = BridgePreferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(restarted.autoSPP)
        XCTAssertTrue(restarted.showWindow)
        restarted.autoSPP = true
        XCTAssertTrue(restarted.autoSPP)
    }
}
