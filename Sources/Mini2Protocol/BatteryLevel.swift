import Foundation

/// Mini 2 02.03.17.00: 0x1009763E quantizes the battery percentage into seven bands.
/// SPP carries this value in byte 13 of the validated 22-byte status snapshot.
public enum Mini2BatteryLevel: UInt8, CaseIterable {
    case highest = 1, high, middle, low, veryLow, critical, empty

    public var percentRange: ClosedRange<Int> {
        switch self {
        case .highest: return 81...100
        case .high: return 61...80
        case .middle: return 41...60
        case .low: return 21...40
        case .veryLow: return 11...20
        case .critical: return 4...10
        case .empty: return 0...3
        }
    }

    /// Representative display values, not an exact percentage reported by the device.
    public var estimatedPercent: Int {
        switch self {
        case .highest: return 90
        case .high: return 70
        case .middle: return 50
        case .low: return 30
        case .veryLow: return 15
        case .critical: return 7
        case .empty: return 2
        }
    }
}
