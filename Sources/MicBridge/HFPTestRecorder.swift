import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import MicLinkCore

private let hfpTestInputCallback: AudioQueueInputCallback = { context, queue, buffer, _, _, _ in
    guard let context else { return }
    Unmanaged<HFPTestRecorder>.fromOpaque(context).takeUnretainedValue().consume(queue, buffer)
}

/// Explicit, bounded diagnostic recording on a pinned Bluetooth input. Never follows default input.
final class HFPTestRecorder {
    let url: URL
    let target: String
    private let uid: String
    private let device: AudioDeviceID
    private var queue: AudioQueueRef?
    private var file: AudioFileID?
    private var ownsFile = false
    private var frames: Int64 = 0
    private var ended = false
    private var healthTimer: Timer?
    private var began = Date()
    private var lastBuffer = Date()
    private(set) var sampleRate: Double = 16000
    var samples: (([Float], Double) -> Void)?
    var failed: ((String) -> Void)?
    var limitReached: (() -> Void)?
    var seconds: Double { Double(frames) / sampleRate }

    init(target: String, url: URL) throws {
        self.target = target; self.url = url
        let reader = AudioRoutes(target: target)
        guard let input = try reader.devices().first(where: {
            try reader.isTarget($0) && reader.hasStream($0, input: true)
                && reader.integer($0, kAudioDevicePropertyDeviceIsAlive) == 1
                && reader.integer($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth
        }) else { throw StreamError.invalid("此发射器的普通蓝牙输入不可用") }
        device = input; uid = try reader.string(input, kAudioDevicePropertyDeviceUID)
        var property = reader.property(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0, size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(input, &property, 0, nil, &size, &rate), "读取输入采样率")
        guard [8000.0, 16000, 24000, 32000, 48000].contains(rate) else { throw StreamError.invalid("不支持当前输入采样率") }
        sampleRate = rate
    }
    private func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw StreamError.invalid("\(action)失败（\(status)）") }
    }
    func start() throws {
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        do {
            try check(AudioQueueNewInput(&format, hfpTestInputCallback, Unmanaged.passUnretained(self).toOpaque(),
                CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, 0, &queue), "创建测试录音")
            guard let queue else { throw StreamError.invalid("无法创建测试录音队列") }
            var chosen = uid as CFString
            let selected = withUnsafePointer(to: &chosen) { AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
            try check(selected, "选择发射器输入")
            try verifyInput()
            try check(AudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, [], &file), "创建测试录音文件")
            ownsFile = true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(queue, UInt32(sampleRate / 10) * 2, &buffer), "分配录音缓冲")
                guard let buffer else { throw StreamError.invalid("无法分配录音缓冲") }
                try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "准备测试录音")
            }
            began = Date(); lastBuffer = began
            try check(AudioQueueStart(queue, nil), "启动 HFP 测试")
            healthTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkHealth() }
            RunLoop.main.add(healthTimer!, forMode: .common)
        } catch { _ = try? stop(); throw error }
    }
    private func verifyInput() throws {
        let reader = AudioRoutes(target: target)
        guard try reader.string(device, kAudioDevicePropertyDeviceUID) == uid,
              try reader.integer(device, kAudioDevicePropertyDeviceIsAlive) == 1 else { throw StreamError.invalid("发射器输入已断开，测试已停止") }
        if let queue {
            var current: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
            let selected = withUnsafeMutablePointer(to: &current) { AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, $0, &size) }
            try check(selected, "核对录音输入")
            guard current as String == uid else { throw StreamError.invalid("录音输入发生变化，测试已停止") }
        }
    }
    private func checkHealth() {
        guard !ended else { return }
        do {
            try verifyInput()
            if Date().timeIntervalSince(began) >= 120 { limitReached?() }
            else if Date().timeIntervalSince(lastBuffer) > 8 { failed?("超过 8 秒未收到音频，测试已停止；可待蓝牙恢复后重试") }
        } catch { failed?(error.localizedDescription) }
    }
    fileprivate func consume(_ queue: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
        guard !ended, let file else { return }
        do {
            try verifyInput()
            let count = Int(buffer.pointee.mAudioDataByteSize) / 2
            if count > 0 {
                var packets = UInt32(count)
                try check(AudioFileWritePackets(file, false, UInt32(count * 2), nil, frames, &packets, buffer.pointee.mAudioData), "保存测试录音")
                guard packets == UInt32(count) else { throw StreamError.invalid("测试录音写入不完整") }
                frames += Int64(count); lastBuffer = Date()
                let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
                let pcm = (0..<count).map { Float(Int16(littleEndian: data[$0])) / 32768 }
                samples?(pcm, seconds)
            }
            try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "继续测试录音")
        } catch {
            // Stop/dispose on the next main-run-loop turn, outside the queue callback.
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in guard let self, !self.ended else { return }; self.failed?(message) }
        }
    }
    @discardableResult func stop() throws -> Double {
        guard !ended else { return seconds }
        ended = true; healthTimer?.invalidate(); healthTimer = nil
        var failure: OSStatus = noErr
        if let queue {
            failure = AudioQueueStop(queue, true)
            let result = AudioQueueDispose(queue, true)
            if failure == noErr { failure = result }
            self.queue = nil
        }
        if let file {
            let result = AudioFileClose(file); if failure == noErr { failure = result }; self.file = nil
        }
        if ownsFile, frames == 0, FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        try check(failure, "结束测试录音")
        return seconds
    }
    deinit { _ = try? stop() }
}

/// Used only for explicit HFP-test playback, never when a capture or SPP session is active.
func prepareHFPTestPlaybackOutput() throws -> String {
    let reader = AudioRoutes(target: "DJI")
    let outputs = try reader.devices().filter {
        try !reader.isDJI($0) && reader.hasStream($0, input: false) && reader.integer($0, kAudioDevicePropertyDeviceIsAlive) == 1
    }
    let airpods = try outputs.first { try reader.string($0, kAudioObjectPropertyName).localizedCaseInsensitiveContains("AirPods") && reader.integer($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth }
    let speakers = try outputs.first { try reader.integer($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
    guard var output = airpods ?? speakers else { throw StreamError.invalid("请连接 AirPods 或启用 Mac 扬声器后试听") }
    var property = reader.property(kAudioHardwarePropertyDefaultOutputDevice)
    let current = try reader.integer(reader.system, kAudioHardwarePropertyDefaultOutputDevice)
    if current != output {
        let status = AudioObjectSetPropertyData(reader.system, &property, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &output)
        guard status == noErr else { throw StreamError.invalid("无法选择安全的试听输出（\(status)）") }
    }
    try AudioRoutes.checkPlaybackOutput()
    return try reader.string(output, kAudioObjectPropertyName)
}
