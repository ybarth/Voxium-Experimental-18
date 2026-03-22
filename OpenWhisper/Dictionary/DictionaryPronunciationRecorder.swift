import AVFoundation
import Foundation

/// Records and plays back pronunciation audio for dictionary entries.
/// Uses its own AVAudioEngine instance (separate from the main AudioRecorder).
/// Records at 44.1kHz stereo to CAF files in the dictionary audio directory.
/// This engine and the main AudioRecorder are never used simultaneously —
/// pronunciation recording happens in dictionary UI, not during live transcription.
@MainActor
@Observable
final class DictionaryPronunciationRecorder: NSObject {

    // MARK: - State

    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var errorMessage: String?

    // MARK: - Private

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var durationTimer: Timer?
    @ObservationIgnored private let store: DictionaryStore

    // MARK: - Init

    init(store: DictionaryStore = LocalDictionaryStore()) {
        self.store = store
        super.init()
    }

    // MARK: - Recording

    /// Start recording a pronunciation. Returns without throwing — any error is stored in `errorMessage`.
    func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil

        do {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0 else {
                errorMessage = "No audio input device found"
                return
            }

            // Record at 44.1kHz stereo (standard playback quality)
            let recordFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100,
                channels: 1,
                interleaved: false
            )!

            // Create a temp file — we'll move it to the audio directory when recording stops
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("caf")

            let audioFile = try AVAudioFile(forWriting: tempURL, settings: recordFormat.settings)
            self.audioFile = audioFile

            // Install tap with converter if input format differs from record format
            if let converter = AVAudioConverter(from: inputFormat, to: recordFormat) {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                    self?.writeSamples(buffer: buffer, converter: converter, targetFormat: recordFormat, file: audioFile)
                }
            } else {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                    try? audioFile.write(from: buffer)
                }
            }

            engine.prepare()
            try engine.start()
            self.engine = engine

            isRecording = true
            recordingDuration = 0
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recordingDuration += 0.1
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stop recording and save to the dictionary audio directory.
    /// Returns the filename (UUID.caf) on success, or nil if nothing was recorded.
    @discardableResult
    func stopRecording() -> String? {
        guard isRecording else { return nil }

        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        guard let audioFile else {
            self.audioFile = nil
            return nil
        }

        let tempURL = audioFile.url
        self.audioFile = nil

        // Move from temp directory to dictionary audio directory
        let filename = UUID().uuidString + ".caf"
        let destURL = store.audioDirectory().appendingPathComponent(filename)

        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            return filename
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    // MARK: - Playback

    /// Play back a pronunciation audio file by filename.
    func play(filename: String) {
        guard !isPlaying else { return }
        errorMessage = nil

        let fileURL = store.audioDirectory().appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = "Audio file not found"
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stop playback if in progress.
    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// Delete a pronunciation audio file by filename.
    func deleteAudio(filename: String) {
        let fileURL = store.audioDirectory().appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private nonisolated func writeSamples(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        file: AVAudioFile
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
        try? file.write(from: outputBuffer)
    }
}

// MARK: - AVAudioPlayerDelegate

extension DictionaryPronunciationRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.isPlaying = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.player = nil
            self?.isPlaying = false
            self?.errorMessage = error?.localizedDescription ?? "Playback error"
        }
    }
}
