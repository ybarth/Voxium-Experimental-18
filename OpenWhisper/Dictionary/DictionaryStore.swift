import Foundation

protocol DictionaryStore: Sendable {
    func loadEntries() throws -> [DictionaryEntry]
    func saveEntries(_ entries: [DictionaryEntry]) throws
    func audioDirectory() -> URL
}

final class LocalDictionaryStore: DictionaryStore {
    private let baseDirectory: URL
    private let dictionaryFile: URL
    private let audioDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("OpenWhisper/Dictionary", isDirectory: true)
        self.dictionaryFile = baseDirectory.appendingPathComponent("dictionary.json")
        self.audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    func loadEntries() throws -> [DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: dictionaryFile.path) else { return [] }
        let data = try Data(contentsOf: dictionaryFile)
        return try JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    func saveEntries(_ entries: [DictionaryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: dictionaryFile, options: .atomic)
    }

    func audioDirectory() -> URL { audioDir }
}
