import AVFoundation
import Foundation

@MainActor
@Observable
final class AudioPlaybackManager {
    var isPlaying = false
    var currentTimeMs: Int = 0
    var durationMs: Int = 0
    var playbackRate: Float = 1.0
    var activeWordIndex: Int = -1

    /// Called when the current audio finishes playing (for continuous mode).
    var onPlaybackFinished: (() -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    private var audioSampleRate: Double = 0
    private var totalFrames: AVAudioFramePosition = 0

    /// Frame offset from last seek/pause — used to compute current position.
    private var seekFrameOffset: AVAudioFramePosition = 0

    /// Generation counter to invalidate stale completion handlers after seek/stop.
    private var scheduleGeneration: Int = 0

    private(set) var timestamps: [WordTimestamp] = []
    private var timer: Timer?

    var hasTimestamps: Bool { !timestamps.isEmpty }

    // MARK: - Loading

    /// Load audio for playback.
    ///
    /// Uses AVAudioEngine + AVAudioUnitTimePitch so playback speed can be
    /// changed without pitch distortion (no chipmunk effect at any rate).
    func load(url: URL, entryText: String, storedTimestamps: [WordTimestamp] = []) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            self.audioSampleRate = file.processingFormat.sampleRate
            self.totalFrames = file.length
            self.durationMs = Int(Double(file.length) / audioSampleRate * 1000)
            self.currentTimeMs = 0
            self.activeWordIndex = -1
            self.seekFrameOffset = 0

            // Build audio engine: playerNode → timePitch → mainMixer
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()

            engine.attach(player)
            engine.attach(pitch)
            engine.connect(player, to: pitch, format: file.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)

            pitch.rate = playbackRate

            self.engine = engine
            self.playerNode = player
            self.timePitch = pitch

            // Timestamp setup
            let words = entryText.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }

            if !storedTimestamps.isEmpty,
               storedTimestamps.count == words.count {
                self.timestamps = Self.normalizeTimestamps(
                    storedTimestamps, to: self.durationMs
                )
            } else if !words.isEmpty, durationMs > 0 {
                self.timestamps = Self.syntheticTimestamps(
                    words: words, durationMs: self.durationMs
                )
            } else {
                self.timestamps = []
            }
        } catch {
            TranscriptionLogger.shared.error(
                "Failed to load audio: \(error)", category: .general
            )
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let engine, let playerNode else { return }
        if isPlaying {
            pause()
        } else {
            do {
                if !engine.isRunning {
                    try engine.start()
                }
                scheduleAudio(from: seekFrameOffset)
                playerNode.play()
                isPlaying = true
                startTimer()
            } catch {
                TranscriptionLogger.shared.error(
                    "Failed to start audio engine: \(error)", category: .general
                )
            }
        }
    }

    func pause() {
        if let playerNode, isPlaying {
            seekFrameOffset = currentFramePosition()
            scheduleGeneration += 1
            playerNode.stop()
        }
        isPlaying = false
        stopTimer()
    }

    func stop() {
        scheduleGeneration += 1
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        timePitch = nil
        audioFile = nil
        audioSampleRate = 0
        totalFrames = 0
        seekFrameOffset = 0
        isPlaying = false
        currentTimeMs = 0
        activeWordIndex = -1
        timestamps = []
        onPlaybackFinished = nil
        stopTimer()
    }

    func seek(toMs ms: Int) {
        let clamped = min(max(ms, 0), durationMs)
        currentTimeMs = clamped
        seekFrameOffset = AVAudioFramePosition(Double(clamped) / 1000.0 * audioSampleRate)

        if isPlaying, let playerNode {
            scheduleAudio(from: seekFrameOffset)
            playerNode.play()
        }
        updateActiveWord()
    }

    /// Update visual state (currentTimeMs + activeWordIndex) without
    /// seeking the underlying player. Used during scrubber drag.
    func previewSeek(toMs ms: Int) {
        let clamped = min(max(ms, 0), durationMs)
        currentTimeMs = clamped
        updateActiveWord()
    }

    func seekToWord(at index: Int) {
        guard index >= 0, index < timestamps.count else { return }
        seek(toMs: timestamps[index].startTimeMs)
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        timePitch?.rate = rate
    }

    // MARK: - Audio scheduling

    private func scheduleAudio(from startFrame: AVAudioFramePosition) {
        guard let playerNode, let audioFile else { return }
        playerNode.stop()

        let framesToPlay = totalFrames - startFrame
        guard framesToPlay > 0 else { return }

        seekFrameOffset = startFrame
        scheduleGeneration += 1
        let gen = scheduleGeneration

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(framesToPlay),
            at: nil
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == gen, self.isPlaying else { return }
                self.currentTimeMs = self.durationMs
                self.isPlaying = false
                self.stopTimer()
                // Keep highlight on the last word
                if !self.timestamps.isEmpty {
                    self.activeWordIndex = self.timestamps.count - 1
                }
                self.onPlaybackFinished?()
            }
        }
    }

    /// Compute the current frame position in the audio file.
    private func currentFramePosition() -> AVAudioFramePosition {
        guard let playerNode,
              let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return AVAudioFramePosition(Double(currentTimeMs) / 1000.0 * audioSampleRate)
        }
        return min(seekFrameOffset + playerTime.sampleTime, totalFrames)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, let playerNode else { return }

        if let nodeTime = playerNode.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            let currentFrame = seekFrameOffset + playerTime.sampleTime
            currentTimeMs = min(
                Int(Double(currentFrame) / audioSampleRate * 1000),
                durationMs
            )
        }

        updateActiveWord()
    }

    private func updateActiveWord() {
        guard !timestamps.isEmpty else {
            activeWordIndex = -1
            return
        }

        let ms = currentTimeMs
        var found = -1

        for i in stride(from: timestamps.count - 1, through: 0, by: -1) {
            if ms >= timestamps[i].startTimeMs {
                found = i
                break
            }
        }

        if found != activeWordIndex {
            activeWordIndex = found
        }
    }

    // MARK: - Timestamp helpers

    /// Rescale timestamps proportionally so their range spans `audioDurationMs`.
    static func normalizeTimestamps(
        _ ts: [WordTimestamp], to audioDurationMs: Int
    ) -> [WordTimestamp] {
        guard let last = ts.last, last.endTimeMs > 0, audioDurationMs > 0 else {
            return ts
        }
        let ratio = Double(audioDurationMs) / Double(last.endTimeMs)
        // If already within 20 % of correct, don't touch
        if ratio > 0.8 && ratio < 1.2 { return ts }
        return ts.map {
            WordTimestamp(
                id: $0.id, word: $0.word,
                startTimeMs: Int(Double($0.startTimeMs) * ratio),
                endTimeMs: min(Int(Double($0.endTimeMs) * ratio), audioDurationMs)
            )
        }
    }

    /// Build timestamps weighted by character count so longer words get
    /// proportionally more time — a better approximation of speech cadence
    /// than even distribution.
    static func syntheticTimestamps(
        words: [String], durationMs: Int
    ) -> [WordTimestamp] {
        guard !words.isEmpty, durationMs > 0 else { return [] }

        let totalChars = words.reduce(0) { $0 + max($1.count, 1) }
        var cursor = 0

        return words.enumerated().map { i, word in
            let weight = Double(max(word.count, 1)) / Double(totalChars)
            let span = Int(Double(durationMs) * weight)
            let start = cursor
            let end: Int
            if i == words.count - 1 {
                end = durationMs          // absorb rounding remainder
            } else {
                end = cursor + span
            }
            cursor = end
            return WordTimestamp(
                id: i, word: word, startTimeMs: start, endTimeMs: end
            )
        }
    }
}
