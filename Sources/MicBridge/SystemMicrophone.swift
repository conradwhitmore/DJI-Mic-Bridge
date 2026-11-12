import AppKit
import AudioToolbox
import CoreAudio
import MicLinkCore
import MicBridgeSupport
import CBridgeAudio

struct VirtualAudioDevice {
    let id: AudioDeviceID
    let rate: Double
    let profile: VirtualInputIdentity.Profile
    var name: String { profile.name }

    static func read(_ id: AudioDeviceID, reader: AudioRoutes) throws -> VirtualAudioDevice? {
        guard try reader.isBridgeInput(id), reader.hasStream(id, input: false),
              let profile = try VirtualInputIdentity.profile(uid: reader.string(id, kAudioDevicePropertyDeviceUID),
                name: reader.string(id, kAudioObjectPropertyName), manufacturer: reader.string(id, kAudioObjectPropertyManufacturer),
                transport: reader.integer(id, kAudioDevicePropertyTransportType)) else { return nil }
        var property = reader.property(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0), size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &rate) == noErr,
              rate.isFinite, rate >= 8000, rate <= 192000 else { throw StreamError.invalid("虚拟麦克风采样率暂不支持") }
        return VirtualAudioDevice(id: id, rate: rate, profile: profile)
    }
    static func find() throws -> VirtualAudioDevice? {
        let reader = AudioRoutes(target: "DJI")
        let devices = try reader.devices().compactMap { try read($0, reader: reader) }
        return devices.min { $0.profile.rawValue < $1.profile.rawValue }
    }
}

private let virtualOutputCallback: AURenderCallback = { context, _, _, _, frames, data in
    let output = Unmanaged<SystemMicrophone>.fromOpaque(context).takeUnretainedValue()
    guard let data else { return kAudio_ParamError }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    guard buffers.count == 2,
          buffers[0].mDataByteSize >= frames * 4, buffers[1].mDataByteSize >= frames * 4,
          let left = buffers[0].mData, let right = buffers[1].mData else {
        for buffer in buffers { if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) } }
        return noErr
    }
    mb_buffer_render(output.buffer, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self),
                     frames, output.device.rate, mb_buffer_now(output.buffer))
    return noErr
}

/// Output-only AUHAL, pinned to the loopback UID. Never changes default output
/// or captures any hardware input. All control operations run on the main thread.
final class SystemMicrophone {
    let device: VirtualAudioDevice
    fileprivate let buffer: OpaquePointer
    private var unit: AudioUnit?
    private var monitor: Timer?
    private var awaitingAudio = true
    var failed: ((String) -> Void)?
    var updated: ((String) -> Void)?
    init(device: VirtualAudioDevice) throws {
        self.device = device
        guard let buffer = mb_buffer_create(24000, 1920) else { throw StreamError.invalid("无法创建实时音频缓冲") }
        self.buffer = buffer
    }
    private func check(_ code: OSStatus, _ action: String) throws {
        guard code == noErr else { throw StreamError.invalid("\(action)失败（\(code)）") }
    }
    func start() throws {
        guard unit == nil else { return }
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw StreamError.invalid("系统音频输出组件不可用") }
            try check(AudioComponentInstanceNew(component, &unit), "创建虚拟麦克风输出")
            guard let unit else { throw StreamError.invalid("无法创建音频输出") }
            var disabled: UInt32 = 0, enabled: UInt32 = 1
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, 4), "禁用硬件输入")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, 4), "启用输出")
            var id = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4), "选择桥接音频设备")
            var format = AudioStreamBasicDescription(mSampleRate: device.rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "设置桥接音频格式")
            var callback = AURenderCallbackStruct(inputProc: virtualOutputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "设置实时音频回调")
            try verifyDevice()
            try check(AudioUnitInitialize(unit), "初始化虚拟麦克风")
            try check(AudioOutputUnitStart(unit), "启用虚拟麦克风")
            monitor = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(monitor!, forMode: .common)
        } catch { stop(); throw error }
    }
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        awaitingAudio = false
        samples.withUnsafeBufferPointer { pcm in
            guard let base = pcm.baseAddress else { return }
            mb_buffer_write(buffer, base, UInt32(pcm.count), mb_buffer_now(buffer))
        }
    }
    func reset() {
        awaitingAudio = true
        mb_buffer_reset(buffer)
        updated?("等待设备连接")
    }
    private func verifyDevice() throws {
        guard let current = try VirtualAudioDevice.read(device.id, reader: AudioRoutes(target: "DJI")),
              current.profile == device.profile, current.rate == device.rate else {
            throw StreamError.invalid("虚拟麦克风已移除或格式改变，请重新启用")
        }
        guard let unit else { return }
        var id: AudioDeviceID = 0, size: UInt32 = 4
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size), "核对输出设备")
        guard id == device.id else { throw StreamError.invalid("虚拟麦克风输出设备已变化") }
    }
    private func poll() {
        do {
            try verifyDevice()
            guard !awaitingAudio else {
                updated?("等待设备连接")
                return
            }
            let stats = mb_buffer_stats(buffer)
            updated?(String(format: "缓冲 %.0f ms · 输出 %.0f kHz · 欠载 %llu 帧 · 丢弃 %llu 帧", Double(stats.queued_frames)/48,
                device.rate/1000, stats.underrun_frames, stats.overflow_frames + stats.latency_dropped_frames))
        } catch { let message = error.localizedDescription; stop(); failed?(message) }
    }
    func makeDefaultInput() throws {
        try verifyDevice()
        let reader = AudioRoutes(target: "DJI")
        var property = reader.property(kAudioHardwarePropertyDefaultInputDevice), id = device.id
        try check(AudioObjectSetPropertyData(reader.system, &property, 0, nil, 4, &id), "选择系统麦克风")
        guard try reader.integer(reader.system, kAudioHardwarePropertyDefaultInputDevice) == id else { throw StreamError.invalid("系统输入切换未生效") }
    }
    func stop() {
        monitor?.invalidate(); monitor = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        reset()
    }
    deinit { stop(); mb_buffer_destroy(buffer) }
}
