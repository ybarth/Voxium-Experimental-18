import AVFoundation
import ScreenCaptureKit

@MainActor
@Observable
final class SystemAudioRecorder: NSObject {
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private let sampleRate: Double = 16000
    @ObservationIgnored private let streamOutput = StreamOutput()
    private let logger = TranscriptionLogger.shared

    var isRecording = false

    func startRecording() async throws {
        samples = []

        // Get shareable content — need at least one display
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplay
        }

        // Exclude our own app windows
        let excludedApps = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Minimal video config (required even for audio-only)
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        streamOutput.onAudioSamples = { [weak self] newSamples in
            Task { @MainActor [weak self] in
                self?.samples.append(contentsOf: newSamples)
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()

        self.stream = stream
        isRecording = true
        logger.info("System audio recording started", category: .transcription)
    }

    func stopRecording() async -> [Float] {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        isRecording = false
        let result = samples
        samples = []
        logger.info("System audio recording stopped (\(result.count) samples)", category: .transcription)
        return result
    }
}

// MARK: - Stream output handler

private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    var onAudioSamples: (([Float]) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return }

        // Detect format from the sample buffer
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        let samples: [Float]

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // 32-bit float
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)
            samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        } else if asbd.mBitsPerChannel == 16 {
            // 16-bit signed integer PCM
            let int16Count = length / MemoryLayout<Int16>.size
            let int16Ptr = UnsafeRawPointer(ptr).bindMemory(to: Int16.self, capacity: int16Count)
            samples = (0..<int16Count).map { Float(int16Ptr[$0]) / Float(Int16.max) }
        } else {
            return
        }

        onAudioSamples?(samples)
    }
}

enum SystemAudioRecorderError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found for screen capture"
        }
    }
}
