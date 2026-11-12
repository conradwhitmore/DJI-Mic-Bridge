import Foundation

public struct SignalWindow {
    public let peak: Float
    public let rms: Float
    public var peakDB: Float { SignalHistory.decibels(peak) }
    public var rmsDB: Float { SignalHistory.decibels(rms) }
}

/// 20 ms windows at the supplied sample rate (48 kHz by default). This observes PCM; it never changes the audio samples.
public final class SignalHistory {
    public private(set) var windows: [SignalWindow] = []
    public private(set) var sessionPeak: Float = 0
    public let capacity: Int
    private let windowSamples: Int
    private var count = 0
    private var peak: Float = 0
    private var squares: Double = 0
    public init(capacity: Int = 200, sampleRate: Double = 48000) {
        self.capacity = max(1, capacity)
        windowSamples = sampleRate.isFinite && sampleRate >= 100 && sampleRate <= 384000 ? Int((sampleRate * 0.02).rounded()) : 960
    }
    public static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 && amplitude.isFinite ? max(-96, 20 * log10(amplitude)) : -96
    }
    public func append(_ samples: [Float]) {
        for sample in samples {
            let value = sample.isFinite ? abs(sample) : 0
            peak = max(peak, value); squares += Double(value) * Double(value); count += 1
            sessionPeak = max(sessionPeak, value)
            if count == windowSamples {
                windows.append(SignalWindow(peak: peak, rms: Float(sqrt(squares / Double(windowSamples)))))
                if windows.count > capacity { windows.removeFirst(windows.count - capacity) }
                count = 0; peak = 0; squares = 0
            }
        }
    }
}
