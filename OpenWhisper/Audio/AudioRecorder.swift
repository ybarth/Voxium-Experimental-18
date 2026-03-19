import AVFoundation
import CoreAudio
import AudioToolbox
import os

// MARK: - Audio input device

struct AudioInputDevice: Identifiable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String

    var id: String { uid }
}

// MARK: - Level meter

final class AudioLevelMeter: Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: Float(0))

    func update(_ rms: Float) {
        _lock.withLock { $0 = rms }
    }

    func read() -> Float {
        _lock.withLock { $0 }
    }
}

// MARK: - Audio recorder

@MainActor
@Observable
final class AudioRecorder {
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private let sampleRate: Double = 16000

    @ObservationIgnored let levelMeter = AudioLevelMeter()
    var recentLevels: [Float] = Array(repeating: 0, count: 30)
    @ObservationIgnored private var levelTimer: Timer?

    /// UID of the selected input device. nil means system default.
    var selectedDeviceUID: String? = UserDefaults.standard.string(forKey: "selectedInputDeviceUID") {
        didSet {
            UserDefaults.standard.set(selectedDeviceUID, forKey: "selectedInputDeviceUID")
        }
    }

    func startRecording() throws {
        samples = []
        recentLevels = Array(repeating: 0, count: 30)

        let engine = AVAudioEngine()

        // Set specific input device if selected
        if let uid = selectedDeviceUID,
           let deviceID = Self.deviceID(forUID: uid),
           let audioUnit = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.noInputDevice
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, converter: converter, targetFormat: targetFormat, meter: meter)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        // 30fps timer to update recentLevels
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = self.levelMeter.read()
                self.recentLevels.append(level)
                if self.recentLevels.count > 30 {
                    self.recentLevels.removeFirst()
                }
            }
        }
    }

    func stopRecording() -> [Float] {
        levelTimer?.invalidate()
        levelTimer = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let result = samples
        samples = []
        recentLevels = Array(repeating: 0, count: 30)
        return result
    }

    private nonisolated func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        meter: AudioLevelMeter
    ) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        )
        guard frameCapacity > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }

        guard error == nil else { return }

        let floatArray = Array(UnsafeBufferPointer(
            start: outputBuffer.floatChannelData?[0],
            count: Int(outputBuffer.frameLength)
        ))

        // Compute RMS for level metering
        if !floatArray.isEmpty {
            var sumOfSquares: Float = 0
            for sample in floatArray {
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / Float(floatArray.count))
            meter.update(rms)
        }

        Task { @MainActor [weak self] in
            self?.samples.append(contentsOf: floatArray)
        }
    }

    // MARK: - Device enumeration

    static func availableInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var result: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID, &inputAddress, 0, nil, &streamSize
            ) == noErr, streamSize > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &nameAddress, 0, nil, &nameSize, &name
            ) == noErr else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &uidAddress, 0, nil, &uidSize, &uid
            ) == noErr else { continue }

            result.append(AudioInputDevice(
                deviceID: deviceID,
                name: name as String,
                uid: uid as String
            ))
        }

        return result
    }

    /// Resolve a device UID to its current AudioDeviceID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for device in availableInputDevices() {
            if device.uid == uid { return device.deviceID }
        }
        return nil
    }
}

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device found"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
