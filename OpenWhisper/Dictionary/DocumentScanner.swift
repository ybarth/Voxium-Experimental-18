import Foundation
import NaturalLanguage
import PDFKit

// MARK: - UnknownWord

/// A word found in a scanned document that is likely custom/domain-specific.
struct UnknownWord: Identifiable {
    let id: UUID = UUID()
    /// The word as it appeared in the document (original casing preserved).
    let word: String
    /// The sentence in which the word appeared.
    let contextSentence: String
    /// Confidence that this is a custom/domain word. Lower = more likely custom.
    /// Range: 0.0 (definitely custom) – 1.0 (likely standard).
    let confidenceScore: Double
}

// MARK: - DocumentScanner

/// Extracts text from PDF, DOCX, RTF, and Markdown documents, then detects
/// words that are likely custom/domain-specific and returns them as `UnknownWord`
/// values suitable for adding to the user's dictionary.
struct DocumentScanner {

    // MARK: - Main Entry Point

    /// Scans the document at `url` and returns words that appear to be non-standard.
    /// Runs on a background thread via Swift concurrency.
    func scanDocument(url: URL) async -> [UnknownWord] {
        let text = await extractText(from: url)
        guard !text.isEmpty else { return [] }
        let sentences = splitIntoSentences(text)
        return detectUnknownWords(in: sentences)
    }

    // MARK: - Text Extraction

    private func extractText(from url: URL) async -> String {
        let ext = url.pathExtension.lowercased()
        return await Task.detached(priority: .userInitiated) {
            switch ext {
            case "pdf":
                return self.extractPDF(url: url)
            case "docx":
                return self.extractDOCX(url: url)
            case "rtf", "rtfd":
                return self.extractRTF(url: url)
            case "md", "markdown", "txt":
                return self.extractPlainText(url: url)
            default:
                // Attempt plain-text fallback for unknown extensions
                return self.extractPlainText(url: url)
            }
        }.value
    }

    // PDF via PDFKit
    private func extractPDF(url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        for index in 0 ..< document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                pages.append(pageText)
            }
        }
        return pages.joined(separator: "\n")
    }

    // DOCX via textutil (ships with macOS)
    private func extractDOCX(url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress error output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // RTF/RTFD via NSAttributedString
    private func extractRTF(url: URL) -> String {
        guard let attrStr = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return "" }
        return attrStr.string
    }

    // Plain text / Markdown
    private func extractPlainText(url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Sentence Splitting

    /// Splits `text` into individual sentences using NLTokenizer.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let tagger = NLTokenizer(unit: .sentence)
        tagger.string = text
        tagger.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        // Fallback: split on newlines if tokenizer yields nothing
        if sentences.isEmpty {
            sentences = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return sentences
    }

    // MARK: - Unknown Word Detection

    private func detectUnknownWords(in sentences: [String]) -> [UnknownWord] {
        // Track seen words to avoid duplicates (keep first occurrence context)
        var seen: [String: UnknownWord] = [:]

        for (sentenceIndex, sentence) in sentences.enumerated() {
            let tokens = tokenizeWords(sentence)

            for (tokenIndex, token) in tokens.enumerated() {
                // Skip very short tokens (1-2 characters) — unlikely to be custom words
                guard token.count >= 3 else { continue }

                // Normalise for dictionary lookup
                let normalised = token.lowercased()

                // Skip already processed words
                guard seen[normalised] == nil else { continue }

                // Compute a confidence score for "is this a standard word?"
                var score = 1.0  // starts as "definitely standard"

                // Not in system dictionary: significant signal that it may be custom
                if !PhoneticEngine.isStandardEnglishWord(normalised) {
                    score -= 0.3
                }

                // Capitalised mid-sentence → likely proper noun
                let isFirstToken = tokenIndex == 0
                let isFirstSentence = sentenceIndex == 0
                let isCapitalized = token.first?.isUppercase == true
                if isCapitalized && !(isFirstToken && isFirstSentence) {
                    score -= 0.1
                }

                // Non-ASCII characters → foreign word / special term
                if token.unicodeScalars.contains(where: { $0.value > 127 }) {
                    score -= 0.2
                }

                // CamelCase pattern (letter followed by uppercase letter)
                if hasCamelCase(token) {
                    score -= 0.15
                }

                // Clamp to [0, 1]
                let clamped = max(0.0, min(1.0, score))

                // Only surface words that have some signal of being non-standard
                // (score < 1.0 means at least one heuristic fired)
                if clamped < 1.0 {
                    let unknown = UnknownWord(
                        word: token,
                        contextSentence: sentence,
                        confidenceScore: clamped
                    )
                    seen[normalised] = unknown
                }
            }
        }

        // Sort by confidence ascending (most likely custom first)
        return seen.values.sorted { $0.confidenceScore < $1.confidenceScore }
    }

    // MARK: - Word Tokenization

    /// Splits a sentence into word tokens, stripping punctuation.
    private func tokenizeWords(_ sentence: String) -> [String] {
        sentence
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: tokenStripCharacters) }
            .filter { !$0.isEmpty }
    }

    private let tokenStripCharacters: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(.symbols)
        // Keep apostrophes inside words (e.g. "don't"), hyphens (e.g. "well-known")
        set.remove(charactersIn: "'-")
        return set
    }()

    // MARK: - Heuristics

    /// Returns true if `word` contains a CamelCase transition (e.g. "MacBook", "iPhone").
    private func hasCamelCase(_ word: String) -> Bool {
        let chars = Array(word)
        for i in 1 ..< chars.count {
            if chars[i - 1].isLowercase && chars[i].isUppercase {
                return true
            }
        }
        return false
    }
}
