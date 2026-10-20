@preconcurrency import AVFoundation
import CoreAudio
import os

nonisolated private let logger = Logger(subsystem: "com.sotto.app", category: "SystemAudioCapture")

/// Records what the Mac is playing (every process except Sotto) through a Core Audio
/// process tap, resampled to 16 kHz mono like `AudioCaptureService`.
///
/// The tap is attached to a private aggregate device, which is the only way to read it.
/// macOS asks for "System Audio Recording" permission the first time the tap starts.
/// There is no public API to query that permission; when it is denied the tap delivers
/// silence instead of failing, so callers should treat an all-silent result as a
/// permission problem.
nonisolated final class SystemAudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status):
                "\(step) failed (OSStatus \(status))"
            case .unsupportedFormat:
                "System audio uses an unsupported format"
            }
        }
    }

    private static let targetSampleRate: Double = 16_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?

    private var sampleBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.sotto.system-audio-io", qos: .userInteractive)

    private(set) var isCapturing = false

    deinit {
        tearDown()
    }

    // MARK: - Start / Stop

    func startCapture() throws {
        guard !isCapturing else { return }
        bufferLock.withLock { sampleBuffer.removeAll() }

        do {
            try createTap()
            let tapFormat = try readTapFormat()
            try createAggregateDevice()
            try startIOProc(tapFormat: tapFormat)
        } catch {
            tearDown()
            throw error
        }

        isCapturing = true
        logger.info("System audio capture started")
    }

    func stopCapture() -> [Float] {
        tearDown()
        // Wait for an IO callback that was already running when the device stopped.
        ioQueue.sync {}
        isCapturing = false
        return bufferLock.withLock {
            let samples = sampleBuffer
            sampleBuffer.removeAll()
            return samples
        }
    }

    /// Samples recorded after `sampleOffset`, for transcribing while the recording runs.
    /// Same contract as `AudioCaptureService.getBufferDelta(since:)`.
    func getBufferDelta(since sampleOffset: Int) -> (samples: [Float], nextOffset: Int) {
        bufferLock.withLock {
            let clamped = max(0, min(sampleOffset, sampleBuffer.count))
            return (Array(sampleBuffer.dropFirst(clamped)), sampleBuffer.count)
        }
    }

    // MARK: - Setup

    private func createTap() throws {
        let excluded = Self.ownProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "Creating the system audio tap")
        tapID = newTapID
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description),
            "Reading the system audio format"
        )
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw CaptureError.unsupportedFormat
        }
        return format
    }

    private func createAggregateDevice() throws {
        let tapUID = try tapUID()
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sotto System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(properties as CFDictionary, &newDeviceID),
            "Creating the system audio device"
        )
        aggregateDeviceID = newDeviceID
    }

    private func startIOProc(tapFormat: AVAudioFormat) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
        converter.downmix = true
        self.converter = converter

        var newProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, ioQueue) { [weak self] _, inputData, _, _, _ in
                guard let self,
                      let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                self.append(buffer, converter: converter, targetFormat: targetFormat)
            },
            "Registering the system audio callback"
        )
        ioProcID = newProcID
        try check(AudioDeviceStart(aggregateDeviceID, newProcID), "Starting the system audio device")
    }

    private func tearDown() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        converter = nil
    }

    // MARK: - Audio Processing

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(
            (Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate).rounded(.up)
        )
        guard frameCount > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        bufferLock.withLock { sampleBuffer.append(contentsOf: samples) }
    }

    // MARK: - Core Audio Helpers

    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid), "Reading the system audio tap ID")
        guard let uid else { throw CaptureError.coreAudio("Reading the system audio tap ID", kAudioHardwareUnspecifiedError) }
        return uid.takeRetainedValue() as String
    }

    /// Sotto's own Core Audio process object, so its sounds stay out of the recording.
    private static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else {
            logger.warning("Could not resolve Sotto's audio process object (\(status)); its own sounds may be recorded")
            return nil
        }
        return processObject
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            logger.error("\(step) failed: \(status)")
            throw CaptureError.coreAudio(step, status)
        }
    }
}
