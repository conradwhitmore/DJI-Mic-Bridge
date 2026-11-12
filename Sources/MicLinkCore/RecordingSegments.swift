import Foundation

/// Saves selected intervals of an already-running PCM stream. Has no transport API.
public final class RecordingSegments {
    public struct Finished {
        public let url: URL?
        public let samples: Int
        public let reason: String
    }
    private var writer: WAVWriter?
    private var sampleLimit = 0
    public var isRecording: Bool { writer != nil }
    public var samples: Int { writer?.samples ?? 0 }

    public init() {}

    public func start(url: URL, seconds: Double) throws {
        guard writer == nil else { throw StreamError.invalid("已有录音正在保存") }
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else {
            throw StreamError.invalid("录音时限无效")
        }
        let limit = Int((seconds * 48000).rounded())
        guard limit > 0 else { throw StreamError.invalid("录音时限过短") }
        writer = try WAVWriter(url: url)
        sampleLimit = limit
    }

    /// Idle PCM is discarded. A chunk crossing the limit is trimmed to the exact sample.
    public func append(_ pcm: [Float]) throws -> Finished? {
        guard let writer else { return nil }
        let remaining = sampleLimit - writer.samples
        try writer.append(Array(pcm.prefix(remaining)))
        if writer.samples == sampleLimit { return try stop(reason: "定时录音完成") }
        return nil
    }

    public func stop(reason: String) throws -> Finished? {
        guard let current = writer else { return nil }
        defer { writer = nil; sampleLimit = 0 }
        try current.finish()
        if current.samples == 0 { try FileManager.default.removeItem(at: current.url) }
        return Finished(url: current.samples == 0 ? nil : current.url,
                        samples: current.samples, reason: reason)
    }
}
