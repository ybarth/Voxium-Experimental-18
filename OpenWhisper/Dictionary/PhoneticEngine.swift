import Foundation

struct PhoneticEngine {

    // MARK: - Soundex

    static func soundex(_ word: String) -> String {
        let upper = word.uppercased().filter(\.isLetter)
        guard let first = upper.first else { return "" }

        let mapping: [Character: Character] = [
            "B": "1", "F": "1", "P": "1", "V": "1",
            "C": "2", "G": "2", "J": "2", "K": "2", "Q": "2", "S": "2", "X": "2", "Z": "2",
            "D": "3", "T": "3",
            "L": "4",
            "M": "5", "N": "5",
            "R": "6",
        ]

        var code = String(first)
        var lastCode: Character? = mapping[first]

        for char in upper.dropFirst() {
            guard let mapped = mapping[char] else {
                lastCode = nil
                continue
            }
            if mapped != lastCode {
                code.append(mapped)
                if code.count == 4 { break }
            }
            lastCode = mapped
        }

        while code.count < 4 { code.append("0") }
        return code
    }

    // MARK: - Metaphone

    static func metaphone(_ word: String) -> String {
        let upper = word.uppercased().filter(\.isLetter)
        guard !upper.isEmpty else { return "" }

        var chars = Array(upper)
        var result = ""
        var i = 0

        // Drop initial silent letters
        if chars.count >= 2 {
            let prefix = String(chars.prefix(2))
            if ["AE", "GN", "KN", "PN", "WR"].contains(prefix) {
                chars.removeFirst()
            }
        }

        while i < chars.count && result.count < 6 {
            let c = chars[i]
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            // Skip duplicate adjacent letters (except C)
            if c == prev && c != "C" {
                i += 1
                continue
            }

            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { result.append(c) }
            case "B":
                if prev != "M" { result.append("B") }
            case "C":
                if next == "H" { result.append("X"); i += 1 }
                else if next == "I" || next == "E" || next == "Y" { result.append("S") }
                else { result.append("K") }
            case "D":
                if next == "G" { /* skip */ } else { result.append("T") }
            case "F": result.append("F")
            case "G":
                if next == "H" && i + 2 < chars.count && !"AEIOU".contains(chars[i + 2]) {
                    i += 1
                } else if i > 0 && (next == "N" || next == nil) {
                    // silent
                } else { result.append("J") }
            case "H":
                if "AEIOU".contains(next ?? " ") && (prev == nil || !"AEIOU".contains(prev!)) {
                    result.append("H")
                }
            case "J": result.append("J")
            case "K":
                if prev != "C" { result.append("K") }
            case "L": result.append("L")
            case "M": result.append("M")
            case "N": result.append("N")
            case "P":
                if next == "H" { result.append("F"); i += 1 }
                else { result.append("P") }
            case "Q": result.append("K")
            case "R": result.append("R")
            case "S":
                if next == "H" { result.append("X"); i += 1 }
                else if next == "I" && i + 2 < chars.count && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X"); i += 2
                }
                else { result.append("S") }
            case "T":
                if next == "H" { result.append("0"); i += 1 }
                else if next == "I" && i + 2 < chars.count && (chars[i + 2] == "O" || chars[i + 2] == "A") {
                    result.append("X"); i += 2
                }
                else { result.append("T") }
            case "V": result.append("F")
            case "W", "Y":
                if let next, "AEIOU".contains(next) { result.append(c) }
            case "X": result.append("KS")
            case "Z": result.append("S")
            default: break
            }
            i += 1
        }

        return result
    }

    // MARK: - System Dictionary

    private static let systemWords: Set<String> = {
        guard let data = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(data.components(separatedBy: .newlines).map { $0.lowercased() })
    }()

    static func isStandardEnglishWord(_ word: String) -> Bool {
        systemWords.contains(word.lowercased())
    }

    // MARK: - Phonetic Index

    /// Builds lookup indexes from dictionary entries for fast correction.
    /// Returns: (soundexIndex, metaphoneIndex)
    static func buildIndexes(from entries: [DictionaryEntry]) -> (soundex: [String: [DictionaryEntry]], metaphone: [String: [DictionaryEntry]]) {
        var soundex: [String: [DictionaryEntry]] = [:]
        var metaphone: [String: [DictionaryEntry]] = [:]
        for entry in entries {
            soundex[entry.soundexCode, default: []].append(entry)
            metaphone[entry.metaphoneCode, default: []].append(entry)
        }
        return (soundex, metaphone)
    }

    /// Find dictionary entries that phonetically match a given word.
    /// Both Soundex AND Metaphone must match for a confident result.
    static func findMatches(
        for word: String,
        soundexIndex: [String: [DictionaryEntry]],
        metaphoneIndex: [String: [DictionaryEntry]]
    ) -> [DictionaryEntry] {
        let wordSoundex = soundex(word)
        let wordMetaphone = metaphone(word)

        let soundexMatches = Set(soundexIndex[wordSoundex, default: []].map(\.id))
        let metaphoneMatches = Set(metaphoneIndex[wordMetaphone, default: []].map(\.id))
        let bothMatch = soundexMatches.intersection(metaphoneMatches)

        let allEntries = (soundexIndex[wordSoundex, default: []] + metaphoneIndex[wordMetaphone, default: []])
        return allEntries.filter { bothMatch.contains($0.id) }
            .reduce(into: [UUID: DictionaryEntry]()) { $0[$1.id] = $1 }
            .values.map { $0 }
    }
}
