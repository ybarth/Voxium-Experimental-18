import Foundation
import Observation

// MARK: - VerbalSpellingEngine

/// Maps spoken letter names (regular alphabet), NATO phonetic words, or IPA symbols
/// to characters and assembles a spelled word in real time.
@MainActor
@Observable
final class VerbalSpellingEngine {

    // MARK: - State

    /// The word being assembled from spoken letters (not used in IPA mode).
    private(set) var assembledWord: String = ""

    /// The current phonetic input mode.
    var mode: PhoneticMethod = .regular

    /// In IPA mode, phonetic symbols are accumulated here instead of `assembledWord`.
    private(set) var ipaAnnotation: String = ""

    // MARK: - Public API

    /// Processes transcribed text from the speech recognition engine.
    /// Extracts letter tokens and appends the corresponding character(s) to the assembled word.
    func processTranscribedText(_ text: String) {
        let tokens = tokenize(text)
        for token in tokens {
            switch mode {
            case .regular:
                if let char = VerbalSpellingEngine.regularLookup[token] {
                    assembledWord.append(char)
                }
            case .nato:
                if let char = VerbalSpellingEngine.natoLookup[token] {
                    assembledWord.append(char)
                }
            case .ipa:
                if VerbalSpellingEngine.ipaSymbols.contains(token) {
                    if !ipaAnnotation.isEmpty { ipaAnnotation += " " }
                    ipaAnnotation += token
                }
            }
        }
    }

    /// Removes the last appended character (or IPA token in IPA mode).
    func undoLastCharacter() {
        switch mode {
        case .regular, .nato:
            guard !assembledWord.isEmpty else { return }
            assembledWord.removeLast()
        case .ipa:
            guard !ipaAnnotation.isEmpty else { return }
            // Remove the last whitespace-delimited token
            var tokens = ipaAnnotation.components(separatedBy: " ")
            tokens.removeLast()
            ipaAnnotation = tokens.joined(separator: " ")
        }
    }

    /// Clears all assembled state.
    func clear() {
        assembledWord = ""
        ipaAnnotation = ""
    }

    /// Returns the current assembled result.
    /// In IPA mode, returns the IPA annotation string.
    func currentWord() -> String {
        switch mode {
        case .regular, .nato:
            return assembledWord
        case .ipa:
            return ipaAnnotation
        }
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String) -> [String] {
        // Split on whitespace/punctuation, lowercase each token
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - NATO Alphabet Lookup

    /// Maps NATO phonetic words (lowercased) to uppercase letters.
    static let natoLookup: [String: Character] = [
        "alpha": "A",
        "bravo": "B",
        "charlie": "C",
        "delta": "D",
        "echo": "E",
        "foxtrot": "F",
        "golf": "G",
        "hotel": "H",
        "india": "I",
        "juliet": "J",
        "juliett": "J",  // alternate spelling
        "kilo": "K",
        "lima": "L",
        "mike": "M",
        "november": "N",
        "oscar": "O",
        "papa": "P",
        "quebec": "Q",
        "romeo": "R",
        "sierra": "S",
        "tango": "T",
        "uniform": "U",
        "victor": "V",
        "whiskey": "W",
        "whisky": "W",   // alternate spelling
        "xray": "X",
        "x-ray": "X",
        "yankee": "Y",
        "zulu": "Z",
    ]

    // MARK: - Regular Alphabet Lookup

    /// Maps spoken letter names and common speech-recognition variants (lowercased) to uppercase letters.
    static let regularLookup: [String: Character] = [
        // A
        "a": "A",
        "ay": "A",
        "eh": "A",
        // B
        "b": "B",
        "bee": "B",
        "be": "B",
        // C
        "c": "C",
        "see": "C",
        "sea": "C",
        "si": "C",
        // D
        "d": "D",
        "dee": "D",
        "de": "D",
        // E
        "e": "E",
        "ee": "E",
        // F
        "f": "F",
        "ef": "F",
        "eff": "F",
        // G
        "g": "G",
        "gee": "G",
        "ge": "G",
        // H
        "h": "H",
        "aitch": "H",
        "haitch": "H",
        // I
        "i": "I",
        "eye": "I",
        "aye": "I",
        // J
        "j": "J",
        "jay": "J",
        "jae": "J",
        // K
        "k": "K",
        "kay": "K",
        "ka": "K",
        // L
        "l": "L",
        "el": "L",
        "ell": "L",
        // M
        "m": "M",
        "em": "M",
        "emm": "M",
        // N
        "n": "N",
        "en": "N",
        "enn": "N",
        // O
        "o": "O",
        "oh": "O",
        "owe": "O",
        // P
        "p": "P",
        "pee": "P",
        "pe": "P",
        // Q
        "q": "Q",
        "cue": "Q",
        "que": "Q",
        "kyu": "Q",
        // R
        "r": "R",
        "ar": "R",
        "are": "R",
        // S
        "s": "S",
        "es": "S",
        "ess": "S",
        // T
        "t": "T",
        "tee": "T",
        "te": "T",
        "ti": "T",
        // U
        "u": "U",
        "you": "U",
        "yew": "U",
        // V
        "v": "V",
        "vee": "V",
        "ve": "V",
        // W
        "w": "W",
        "double-u": "W",
        "doubleyou": "W",
        "double you": "W",
        // X
        "x": "X",
        "ex": "X",
        "eks": "X",
        // Y
        "y": "Y",
        "why": "Y",
        "wye": "Y",
        // Z
        "z": "Z",
        "zee": "Z",
        "zed": "Z",
        "ze": "Z",
    ]

    // MARK: - IPA Symbol Set

    /// A curated set of IPA symbols and digraphs that the engine recognises in IPA mode.
    /// The user would speak the IPA symbol name; Whisper typically transcribes them using
    /// the Latin/Unicode characters directly (e.g. "ʃ", "æ", "ɪ").
    static let ipaSymbols: Set<String> = [
        // Vowels
        "i", "ɪ", "e", "ɛ", "æ", "a", "ɑ", "ɒ", "ɔ", "o", "ʊ", "u",
        "ʌ", "ə", "ɜ", "ɐ", "ɨ", "ʉ", "ɯ", "y", "ø", "œ",
        // Diphthongs (as digraphs)
        "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ", "ɪə", "eə", "ʊə",
        // Consonants
        "p", "b", "t", "d", "k", "g", "f", "v", "θ", "ð",
        "s", "z", "ʃ", "ʒ", "h", "tʃ", "dʒ", "m", "n", "ŋ",
        "l", "r", "ɹ", "j", "w", "x", "ɣ", "ʔ",
        // Stress/length markers
        "ˈ", "ˌ", "ː",
    ]
}
