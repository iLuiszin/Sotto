import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio

/// Records one specific input device through a HAL audio unit, delivering mono Float32
/// buffers at the device's sample rate.
///
/// AVAudioEngine's input node does not stay on a chosen device: when the default output
/// changes (a Bluetooth headset switching profile, a sound starting to play) the engine
/// moves its input back to the system default. With a Bluetooth headset as the default,
/// that opens the headset's microphone, which also drops its audio to call quality.
nonisolated final class HALInputUnit: @unchecked Sendable {
    enum Failure: LocalizedError {
        case component
        case status(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .component: "The audio input unit is unavailable"
            case .status(let step, let status): "\(step) failed (OSStatus \(status))"
            }
        }
    }

    let format: AVAudioFormat
    private let unit: AudioUnit
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var isRunning = false

    private static let inputBus: AudioUnitElement = 1
    private static let outputBus: AudioUnitElement = 0

    init(deviceID: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        (unit, format) = try Self.makeUnit(deviceID: deviceID)
        self.onBuffer = onBuffer

        // From here on `deinit` disposes the unit if anything throws.
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<HALInputUnit>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: nil
        )
        callback.inputProcRefCon = Unmanaged.passUnretained(self).toOpaque()
        try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, Self.outputBus, &callback, "Registering the input callback")
        try Self.check(AudioUnitInitialize(unit), "Initializing the input unit")
    }

    /// An input-only HAL unit bound to `deviceID`, and the mono format it delivers.
    private static func makeUnit(deviceID: AudioDeviceID) throws -> (AudioUnit, AVAudioFormat) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure.component }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "Creating the input unit")
        guard let unit = newUnit else { throw Failure.component }

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enable, "Enabling input")
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &disable, "Disabling output")
            var device = deviceID
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputBus, &device, "Selecting the input device")

            var deviceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &deviceFormat, &size),
                "Reading the device format"
            )
            guard deviceFormat.mSampleRate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.mSampleRate, channels: 1)
            else { throw Failure.status("Reading the device format", kAudioUnitErr_FormatNotSupported) }

            var streamFormat = format.streamDescription.pointee
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &streamFormat, "Setting the capture format")
            return (unit, format)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        stop()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func start() throws {
        guard !isRunning else { return }
        try Self.check(AudioOutputUnitStart(unit), "Starting the input unit")
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        if status == noErr {
            onBuffer(buffer)
        }
        return status
    }

    /// For plain C structs and integers only.
    private static func set<T: BitwiseCopyable>(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ value: inout T,
        _ step: String
    ) throws {
        try check(
            AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)),
            step
        )
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure.status(step, status) }
    }
}
