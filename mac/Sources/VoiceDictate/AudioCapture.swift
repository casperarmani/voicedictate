import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio straight from Core Audio (an AUHAL input unit) and delivers
/// mono Float32 samples at the device's native rate via `onSamples`.
///
/// AVAudioEngine isn't used on purpose: it always opens the *system default* input first.
/// When that's AirPods, merely opening their mic flips them into low-quality call mode,
/// even if we switch to the built-in mic a moment later. Here the device is chosen before
/// anything is opened, so AirPods are never touched.
final class AudioCapture {
    var onSamples: (([Float], Double) -> Void)?
    /// Called when the device we use goes away or changes format (or, when following the
    /// system default, when the default input changes).
    var onConfigurationChange: (() -> Void)?

    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID = 0
    private var sampleRate: Double = 48000
    private var followsDefault = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var renderBuffer = [Float](repeating: 0, count: 8192)
    private(set) var deviceName = "none"
    private(set) var isBuiltIn = false

    var isRunning: Bool { unit != nil }

    func start(preferBuiltIn: Bool) throws {
        stop()
        let builtIn = preferBuiltIn ? AudioDevices.builtInInput() : nil
        guard let device = builtIn ?? AudioDevices.defaultInput() else {
            throw Self.error("No microphone found")
        }
        followsDefault = builtIn == nil
        deviceID = device
        deviceName = AudioDevices.name(device) ?? "microphone"
        isBuiltIn = AudioDevices.isBuiltIn(device)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw Self.error("No audio input unit") }
        var newUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(comp, &newUnit), "create input unit")
        guard let u = newUnit else { throw Self.error("No audio input unit") }

        do {
            var on: UInt32 = 1, off: UInt32 = 0
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
            try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
            var dev = device
            try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")

            var hw = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read format")
            sampleRate = hw.mSampleRate > 0 ? hw.mSampleRate : 48000

            var fmt = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                mBitsPerChannel: 32, mReserved: 0)
            try Self.check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, size), "set format")

            var cb = AURenderCallbackStruct(inputProc: audioInputCallback,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
            try Self.check(AudioUnitInitialize(u), "initialize")
            unit = u
            try Self.check(AudioOutputUnitStart(u), "start")
        } catch {
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            unit = nil
            throw error
        }

        addListeners()
        Log.info("[Audio] Capturing from \(deviceName) at \(Int(sampleRate)) Hz")
    }

    func stop() {
        removeListeners()
        guard let u = unit else { return }
        unit = nil
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    /// Runs on the Core Audio I/O thread.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let u = unit else { return noErr }
        let n = Int(frames)
        if renderBuffer.count < n { return noErr }  // never allocate here; skip absurd sizes
        return renderBuffer.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                      mData: UnsafeMutableRawPointer(buf.baseAddress)))
            let status = AudioUnitRender(u, flags, timestamp, 1, frames, &abl)
            if status == noErr { onSamples?(Array(buf[0..<n]), sampleRate) }
            return status
        }
    }

    // MARK: device change listeners

    private func addListeners() {
        func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Log.info("[Audio] Microphone changed (\(selector == kAudioHardwarePropertyDefaultInputDevice ? "default input" : "device"))")
                self?.onConfigurationChange?()
            }
            if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr {
                listeners.append((object, addr, block))
            }
        }
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive)
        listen(deviceID, kAudioDevicePropertyNominalSampleRate)
        if followsDefault { listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) }
    }

    private func removeListeners() {
        for (object, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    private static func error(_ msg: String) -> NSError {
        NSError(domain: "VoiceDictate", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw error("Could not \(what) (\(status))") }
    }
}

private func audioInputCallback(refCon: UnsafeMutableRawPointer,
                                flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
                                data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, frames)
}

enum AudioDevices {
    private static func prop(_ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = prop(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = prop(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        var addr = prop(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr else { return false }
        return type == kAudioDeviceTransportTypeBuiltIn
    }

    static func name(_ id: AudioDeviceID) -> String? {
        var addr = prop(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func builtInInput() -> AudioDeviceID? {
        allDevices().first { hasInput($0) && isBuiltIn($0) }
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = prop(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }
}

/// Streaming sample-rate converter: any mono rate -> 16 kHz mono Float32.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                          channels: 1, interleaved: false)!

    func to16k(_ samples: [Float], rate: Double) -> [Float] {
        if rate == 16000 { return samples }
        if inFormat?.sampleRate != rate {
            inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = AVAudioConverter(from: inFormat!, to: outFormat)
        }
        guard let converter, let inFormat,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let cap = AVAudioFrameCount(Double(samples.count) * 16000 / rate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { Log.warn("[Audio] resample failed: \(error)"); return [] }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    func reset() { converter?.reset() }
}
