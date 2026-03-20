import AVFoundation
import CoreAudio

@MainActor
@Observable
final class MixedAudioRecorder {
    @ObservationIgnored private var micRecorder = AudioRecorder()
    @ObservationIgnored private var systemRecorder = SystemAudioRecorder()
    @ObservationIgnored private var mixedSamples: [Float] = []
    @ObservationIgnored private var mixTimer: Timer?
    private let logger = TranscriptionLogger.shared

    var isRecording = false

    /// Mic level meter for waveform display.
    var levelMeter: AudioLevelMeter { micRecorder.levelMeter }
    var recentLevels: [Float] { micRecorder.recentLevels }

    func startRecording() async throws {
        mixedSamples = []

        try micRecorder.startRecording()
        try await systemRecorder.startRecording()
        isRecording = true

        logger.info("Mixed audio recording started", category: .transcription)
    }

    func stopRecording() async -> [Float] {
        let micSamples = micRecorder.stopRecording()
        let systemSamples = await systemRecorder.stopRecording()
        isRecording = false

        let mixed = mixAudio(mic: micSamples, system: systemSamples)
        logger.info("Mixed audio stopped — mic: \(micSamples.count), system: \(systemSamples.count), mixed: \(mixed.count)", category: .transcription)
        return mixed
    }

    // MARK: - Audio mixing

    private func mixAudio(mic: [Float], system: [Float]) -> [Float] {
        let length = max(mic.count, system.count)
        guard length > 0 else { return [] }

        let micWeight: Float = 0.7
        let systemWeight: Float = 0.7

        var mixed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let m = i < mic.count ? mic[i] * micWeight : 0
            let s = i < system.count ? system[i] * systemWeight : 0
            // Soft clipping via tanh
            mixed[i] = tanhf(m + s)
        }

        // Normalize to 0.9 peak
        let peak = mixed.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let scale = min(0.9 / peak, 1.0)
            if scale < 1.0 {
                for i in 0..<mixed.count {
                    mixed[i] *= scale
                }
            }
        }

        return mixed
    }
}
