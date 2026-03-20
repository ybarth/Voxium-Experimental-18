import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AudioFileImporter {
    private let logger = TranscriptionLogger.shared

    struct ImportResult {
        let samples: [Float]
        let sampleRate: Double
        let durationMs: Int
    }

    static let supportedTypes: [UTType] = [.wav, .aiff, .mp3, .mpeg4Audio]

    /// Decode an audio file to 16kHz mono Float32 samples.
    func decodeFile(url: URL) async throws -> ImportResult {
        logger.info("Importing audio file: \(url.lastPathComponent)", category: .transcription)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = Int(CMTimeGetSeconds(duration) * 1000)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioFileImportError.noAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioFileImportError.readerCreationFailed
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw AudioFileImportError.readFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        var allSamples: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }

            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)

            guard let ptr = dataPointer else { continue }

            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)
            let chunk = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
            allSamples.append(contentsOf: chunk)
        }

        guard reader.status == .completed else {
            throw AudioFileImportError.readFailed(reader.error?.localizedDescription ?? "Reader did not complete")
        }

        logger.info("Imported \(allSamples.count) samples (\(durationMs)ms) from \(url.lastPathComponent)", category: .transcription)

        return ImportResult(samples: allSamples, sampleRate: 16000, durationMs: durationMs)
    }
}

enum AudioFileImportError: LocalizedError {
    case noAudioTrack
    case readerCreationFailed
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "No audio track found in file"
        case .readerCreationFailed:
            return "Failed to create audio reader"
        case .readFailed(let msg):
            return "Failed to read audio: \(msg)"
        }
    }
}
