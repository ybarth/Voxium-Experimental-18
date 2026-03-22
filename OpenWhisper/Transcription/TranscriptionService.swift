import Foundation
import SwiftWhisper

struct TranscriptionResult {
    let text: String
    let wordTimestamps: [WordTimestamp]
    let durationMs: Int
}

@MainActor
final class TranscriptionService {
    private var whisperInstance: Whisper?
    private var loadedModelURL: URL?
    private var promptPointer: UnsafeMutablePointer<CChar>?
    private let logger = TranscriptionLogger.shared

    deinit {
        if let promptPointer {
            free(promptPointer)
        }
    }

    // MARK: - Whisper transcription (in-process)

    func transcribe(audioFrames: [Float], modelURL: URL, initialPrompt: String? = nil) async throws -> TranscriptionResult {
        logger.info("Starting whisper transcription (\(audioFrames.count) frames, \(String(format: "%.1f", Double(audioFrames.count) / 16000))s audio)", category: .transcription)
        let start = CFAbsoluteTimeGetCurrent()

        let whisper = try getOrCreateWhisper(modelURL: modelURL)
        updateInitialPrompt(initialPrompt, on: whisper.params)
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let rawText = segments.map(\.text).joined()
        let filtered = filterTranscription(rawText)

        // Build word timestamps from segments, using the filtered text
        // so the displayed words match entry.text exactly.
        let wordTimestamps = buildWordTimestamps(from: segments, filteredText: filtered)

        let durationMs: Int
        if let last = segments.last {
            // Segment times from whisper.cpp are in centiseconds (10ms units)
            durationMs = last.endTime * 10
        } else {
            durationMs = Int(Double(audioFrames.count) / 16000 * 1000)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Whisper done in \(String(format: "%.2f", elapsed))s — \"\(filtered.prefix(80))\"", category: .transcription)

        return TranscriptionResult(text: filtered, wordTimestamps: wordTimestamps, durationMs: durationMs)
    }

    // MARK: - Server transcription

    func transcribe(audioFrames: [Float], using server: InferenceServerManager, initialPrompt: String? = nil) async throws -> TranscriptionResult {
        logger.info("Starting server transcription (\(audioFrames.count) frames, \(String(format: "%.1f", Double(audioFrames.count) / 16000))s audio)", category: .transcription)
        let start = CFAbsoluteTimeGetCurrent()

        let response = try await server.transcribe(audioFrames: audioFrames, initialPrompt: initialPrompt)
        let filtered = filterTranscription(response.text)
        let durationMs = Int(Double(audioFrames.count) / 16000 * 1000)

        // Use server word timestamps if available
        let wordTimestamps: [WordTimestamp]
        if let serverTs = response.wordTimestamps, !serverTs.isEmpty {
            let filteredWords = filtered.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            if serverTs.count == filteredWords.count {
                // Direct mapping — server words match filtered text
                wordTimestamps = filteredWords.enumerated().map { i, word in
                    WordTimestamp(id: i, word: word, startTimeMs: serverTs[i].startMs, endTimeMs: serverTs[i].endMs)
                }
            } else {
                // Word count mismatch after filtering — rebuild from duration
                wordTimestamps = buildWordTimestamps(filteredText: filtered, durationMs: durationMs)
            }
        } else {
            wordTimestamps = []
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Server done in \(String(format: "%.2f", elapsed))s (\(wordTimestamps.count) words) — \"\(filtered.prefix(80))\"", category: .transcription)

        return TranscriptionResult(text: filtered, wordTimestamps: wordTimestamps, durationMs: durationMs)
    }

    // MARK: - Private

    private func updateInitialPrompt(_ prompt: String?, on params: WhisperParams) {
        if let promptPointer {
            free(promptPointer)
            self.promptPointer = nil
        }

        if let prompt, !prompt.isEmpty {
            let pointer = strdup(prompt)
            self.promptPointer = pointer
            params.initial_prompt = UnsafePointer(pointer)
        } else {
            params.initial_prompt = nil
        }
    }

    /// Build word timestamps using the filtered text and segment timing.
    private func buildWordTimestamps(from segments: [Segment], filteredText: String) -> [WordTimestamp] {
        let totalStartMs = (segments.first?.startTime ?? 0) * 10
        let totalEndMs = (segments.last?.endTime ?? 0) * 10
        let totalDuration = totalEndMs - totalStartMs
        guard totalDuration > 0 else { return [] }
        return buildWordTimestamps(filteredText: filteredText, startMs: totalStartMs, durationMs: totalDuration)
    }

    /// Build character-weighted word timestamps over a time range.
    private func buildWordTimestamps(filteredText: String, startMs: Int = 0, durationMs: Int) -> [WordTimestamp] {
        let words = filteredText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, durationMs > 0 else { return [] }

        let totalChars = words.reduce(0) { $0 + max($1.count, 1) }
        var cursor = startMs

        return words.enumerated().map { i, word in
            let weight = Double(max(word.count, 1)) / Double(totalChars)
            let span = Int(Double(durationMs) * weight)
            let start = cursor
            let end = i == words.count - 1 ? startMs + durationMs : cursor + span
            cursor = end
            return WordTimestamp(id: i, word: word, startTimeMs: start, endTimeMs: end)
        }
    }

    func filterTranscription(_ text: String) -> String {
        var result = text
        // Remove <|...|> special tokens
        result = result.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        // Remove [BRACKET_TAGS] - matches [BLANK_AUDIO], [MUSIC], [inaudible], etc.
        result = result.replacingOccurrences(of: "\\[\\w[\\w\\s]*\\]", with: "", options: .regularExpression)
        // Remove (PAREN_TAGS) - matches (music), (inaudible), (SPEAKING FOREIGN LANGUAGE), etc.
        result = result.replacingOccurrences(of: "\\([A-Za-z][A-Za-z\\s]*\\)", with: "", options: .regularExpression)
        // Remove musical note sequences
        result = result.replacingOccurrences(of: "♪+", with: "", options: .regularExpression)
        // Collapse multiple spaces and trim
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Filter common hallucinated phrases when they're the entire output
        let hallucinatedPhrases = [
            "thank you for watching",
            "thank you for listening",
            "thanks for watching",
            "thanks for listening",
        ]
        if hallucinatedPhrases.contains(result.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return ""
        }
        return result
    }

    private func getOrCreateWhisper(modelURL: URL) throws -> Whisper {
        if let whisperInstance, loadedModelURL == modelURL {
            return whisperInstance
        }

        logger.info("Loading whisper model from \(modelURL.lastPathComponent)", category: .model)
        let params = WhisperParams(strategy: .greedy)
        params.language = .english
        params.token_timestamps = true

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        self.whisperInstance = whisper
        self.loadedModelURL = modelURL
        logger.info("Whisper model loaded", category: .model)
        return whisper
    }
}
