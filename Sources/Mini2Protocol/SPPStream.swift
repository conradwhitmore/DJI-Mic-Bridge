import Foundation

/// Shared ordinary-SPP receive path for MicBridge and protocol integration tests.
/// No commands or factory mode: only checked audio and status-derived hotkeys.
public struct Mini2SPPStream {
    private var framing = Mini2SPPParser()
    private var status = Mini2StatusParser()
    private var hotkeys = Mini2SPPHotkeys()
    public private(set) var statusCount = 0
    public var sequenceGaps: Int { status.sequenceGaps }
    public init() {}
    public struct Batch {
        public var audio: [Data] = []
        public var statuses: [Mini2SPPStatus] = []
        public var events: [Mini2Hotkey] = []
        public var controls: [Mini2Frame] = []
    }
    public mutating func feed(_ data: Data, at time: TimeInterval) -> Batch {
        var result = Batch()
        let discarded = framing.discardedBytes
        let envelopes = framing.feed(data)
        if discarded != framing.discardedBytes { status.resetFraming(); hotkeys.resetBaseline() }
        for envelope in envelopes {
            if let control = envelope.control { result.controls.append(control) }
            for block in envelope.blocks {
                let gaps = status.sequenceGaps, invalid = status.invalidBlocks, duplicates = status.duplicateBlocks
                let snapshots = status.feed(block)
                if gaps != status.sequenceGaps || invalid != status.invalidBlocks { hotkeys.resetBaseline() }
                for snapshot in snapshots {
                    statusCount += 1
                    result.statuses.append(snapshot)
                    result.events += hotkeys.observe(snapshot, at: time)
                }
                if duplicates == status.duplicateBlocks, let payload = mini2AudioPayload(block) {
                    result.audio.append(payload)
                }
            }
        }
        return result
    }
}
