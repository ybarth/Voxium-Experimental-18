import Foundation
import SwiftWhisper

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

    func transcribe(audioFrames: [Float], modelURL: URL, initialPrompt: String? = nil) async throws -> String {
        logger.info("Starting whisper transcription (\(audioFrames.count) frames, \(String(format: "%.1f", Double(audioFrames.count) / 16000))s audio)", category: .transcription)
        let start = CFAbsoluteTimeGetCurrent()

        let whisper = try getOrCreateWhisper(modelURL: modelURL)
        updateInitialPrompt(initialPrompt, on: whisper.params)
        let segments = try await whisper.transcribe(audioFrames: audioFrames)
        let rawText = segments.map(\.text).joined()
        let filtered = filterTranscription(rawText)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Whisper done in \(String(format: "%.2f", elapsed))s — \"\(filtered.prefix(80))\"", category: .transcription)
        return filtered
    }

    // MARK: - Server transcription

    func transcribe(audioFrames: [Float], using server: InferenceServerManager) async throws -> String {
        logger.info("Starting server transcription (\(audioFrames.count) frames, \(String(format: "%.1f", Double(audioFrames.count) / 16000))s audio)", category: .transcription)
        let start = CFAbsoluteTimeGetCurrent()

        let rawText = try await server.transcribe(audioFrames: audioFrames)
        let filtered = filterTranscription(rawText)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Server done in \(String(format: "%.2f", elapsed))s — \"\(filtered.prefix(80))\"", category: .transcription)
        return filtered
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

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        self.whisperInstance = whisper
        self.loadedModelURL = modelURL
        logger.info("Whisper model loaded", category: .model)
        return whisper
    }
}
