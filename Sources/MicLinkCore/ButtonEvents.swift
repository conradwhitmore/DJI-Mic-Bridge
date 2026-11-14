import Foundation

public enum MicButton: String, CaseIterable, Codable { case power, record, link }
public struct MicButtonEvent: Codable {
    public let button: MicButton
    public let sequence: UInt16
    public let timestamp: TimeInterval
    public let previousValue: UInt8
    public let value: UInt8
    public let source: String?
    public var isStateChangeCandidate: Bool { source != "04/68" && button != .link }
    init(button: MicButton, sequence: UInt16, timestamp: TimeInterval, previousValue: UInt8, value: UInt8) {
        self.button = button; self.sequence = sequence; self.timestamp = timestamp
        self.previousValue = previousValue; self.value = value; source = nil
    }
    public init(button: MicButton, time: TimeInterval, source: String) {
        self.button = button; sequence = 0; timestamp = time
        previousValue = 0; value = 1; self.source = source
    }
    public init(independent event: MicKeyTestEvent, time: TimeInterval) {
        button = event.button; sequence = event.sequence; timestamp = time
        previousValue = 0; value = 1; source = "04/68"
    }
}

/// Experimental state correlations. Power/record changes are not raw key-down events.
public final class MicButtonDetector {
    private var lastSequence: UInt16?
    private var lastTime: TimeInterval?
    private var previous: [UInt8]?
    public init() {}
    public func observe(_ c: [UInt8], time: TimeInterval) -> [MicButtonEvent] {
        guard c.count == 58, c[0] == 0x55, c[1] == 58, c[2] == 4,
              c[4] == 0x3a, c[5] == 2, c[8] == 0, c[9] == 2, c[10] == 0xff,
              crc8(Array(c.prefix(3))) == c[3],
              crc16(Array(c.dropLast(2))) == UInt16(c[56]) | UInt16(c[57]) << 8 else { return [] }
        if let lastTime, time < lastTime || time-lastTime > 3 {
            previous = nil; lastSequence = nil
        }
        let sequence = UInt16(c[6]) | UInt16(c[7]) << 8
        if let lastSequence {
            let delta = sequence &- lastSequence
            guard delta != 0, delta < 0x8000 else { return [] }
        }
        let state: [UInt8] = [c[45] & 0x20, c[44] & 0x01, c[20] & 0x08] // payload 34 bit 5, 33 bit 0, 9 bit 3
        var events: [MicButtonEvent] = []
        if let previous {
            for (index, button) in MicButton.allCases.enumerated() {
                let changed = button == .link ? previous[index] == 0 && state[index] == 8 : previous[index] != state[index]
                if changed { events.append(MicButtonEvent(button: button, sequence: sequence, timestamp: time, previousValue: previous[index], value: state[index])) }
            }
        }
        previous = state; lastSequence = sequence; lastTime = time
        return events
    }
}
