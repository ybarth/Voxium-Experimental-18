import Foundation

// MARK: - Data models

struct WordTimestamp: Codable, Identifiable, Equatable {
    let id: Int
    let word: String
    let startTimeMs: Int
    let endTimeMs: Int
}

enum AudioSourceType: String, Codable {
    case microphone, systemAudio, mixed, imported
}

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date
    let audioFilename: String?
    let wordTimestamps: [WordTimestamp]?
    let durationMs: Int?
    let audioSource: AudioSourceType?
    let appName: String?
    let bundleIdentifier: String?

    /// Legacy init for backward compat and simple adds.
    init(text: String) {
        self.id = UUID()
        self.text = text
        self.date = Date()
        self.audioFilename = nil
        self.wordTimestamps = nil
        self.durationMs = nil
        self.audioSource = nil
        self.appName = nil
        self.bundleIdentifier = nil
    }

    /// Full init with all fields.
    init(
        id: UUID = UUID(),
        text: String,
        date: Date = Date(),
        audioFilename: String? = nil,
        wordTimestamps: [WordTimestamp]? = nil,
        durationMs: Int? = nil,
        audioSource: AudioSourceType? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.audioFilename = audioFilename
        self.wordTimestamps = wordTimestamps
        self.durationMs = durationMs
        self.audioSource = audioSource
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }

    var hasPlaybackData: Bool {
        audioFilename != nil && wordTimestamps != nil && !(wordTimestamps?.isEmpty ?? true)
    }

    var hasAudio: Bool {
        audioFilename != nil
    }
}

// MARK: - HistoryStore (file-based)

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [TranscriptionEntry] = []

    private static let legacyStorageKey = "transcriptionHistory"
    private let audioFileManager = AudioFileManager.shared
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        migrateFromUserDefaultsIfNeeded()
        load()
        // Ensure backups directory exists
        try? FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func add(
        text: String,
        audioFilename: String? = nil,
        wordTimestamps: [WordTimestamp]? = nil,
        durationMs: Int? = nil,
        audioSource: AudioSourceType? = nil,
        appName: String? = nil,
        bundleIdentifier: String? = nil
    ) {
        let entry = TranscriptionEntry(
            text: text,
            audioFilename: audioFilename,
            wordTimestamps: wordTimestamps,
            durationMs: durationMs,
            audioSource: audioSource,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        entries.insert(entry, at: 0)
        saveEntry(entry)
    }

    func addEntry(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        saveEntry(entry)
        pruneIfNeeded()
    }

    /// Update word timestamps for an existing entry (e.g., after timing analysis).
    func updateTimestamps(id: UUID, wordTimestamps: [WordTimestamp]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[index]
        let updated = TranscriptionEntry(
            id: old.id,
            text: old.text,
            date: old.date,
            audioFilename: old.audioFilename,
            wordTimestamps: wordTimestamps,
            durationMs: old.durationMs,
            audioSource: old.audioSource,
            appName: old.appName,
            bundleIdentifier: old.bundleIdentifier
        )
        entries[index] = updated
        saveEntry(updated)
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        audioFileManager.deleteEntryDirectory(for: id)
    }

    func clearAll() {
        for entry in entries {
            audioFileManager.deleteEntryDirectory(for: entry.id)
        }
        entries.removeAll()
    }

    // MARK: - Backup & Restore

    private static let backupFolderKey = "backupFolderPath"

    private static var defaultBackupsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/Backups", isDirectory: true)
    }

    private var backupsDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: Self.backupFolderKey),
           !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return Self.defaultBackupsDirectory
    }

    /// The display path for the current backup folder.
    var backupFolderPath: String {
        backupsDirectory.path
    }

    /// Set a custom backup folder, or pass nil to reset to default.
    func setBackupFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.backupFolderKey)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.backupFolderKey)
            try? FileManager.default.createDirectory(at: Self.defaultBackupsDirectory, withIntermediateDirectories: true)
        }
    }

    /// Create a timestamped backup of all current history entries.
    /// Returns the backup folder URL.
    @discardableResult
    func createBackup(label: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = label ?? formatter.string(from: Date())
        let backupDir = backupsDirectory.appendingPathComponent(name, isDirectory: true)

        // Don't overwrite existing backups
        guard !fm.fileExists(atPath: backupDir.path) else {
            TranscriptionLogger.shared.info("Backup '\(name)' already exists", category: .general)
            return backupDir
        }

        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Copy each entry directory
        let historyDir = audioFileManager.historyDirectoryURL
        guard fm.fileExists(atPath: historyDir.path) else { return backupDir }

        for entryID in audioFileManager.allEntryIDs() {
            let src = audioFileManager.entryDirectoryURL(for: entryID)
            let dst = backupDir.appendingPathComponent(entryID.uuidString, isDirectory: true)
            try fm.copyItem(at: src, to: dst)
        }

        TranscriptionLogger.shared.info("Backup created: \(name) (\(entries.count) entries)", category: .general)
        return backupDir
    }

    /// List all available backups, sorted newest first.
    func availableBackups() -> [(name: String, url: URL, date: Date?)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { url in
            let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
            return (name: url.lastPathComponent, url: url, date: attrs?.creationDate)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Restore history from a backup folder, replacing current entries.
    func restoreBackup(from backupDir: URL) throws {
        let fm = FileManager.default

        // Clear current entries
        clearAll()

        // Copy entry directories from backup into live history
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for src in contents {
            guard let entryID = UUID(uuidString: src.lastPathComponent) else { continue }
            let dst = audioFileManager.entryDirectoryURL(for: entryID)
            try? fm.removeItem(at: dst) // remove if exists
            try fm.copyItem(at: src, to: dst)
        }

        // Reload from disk
        load()
        TranscriptionLogger.shared.info("Restored backup '\(backupDir.lastPathComponent)' (\(entries.count) entries)", category: .general)
    }

    // MARK: - Persistence

    private func saveEntry(_ entry: TranscriptionEntry) {
        do {
            try audioFileManager.ensureEntryDirectory(for: entry.id)
            let url = audioFileManager.metadataFileURL(for: entry.id)
            let data = try encoder.encode(entry)
            try data.write(to: url, options: .atomic)
        } catch {
            TranscriptionLogger.shared.error("Failed to save entry \(entry.id): \(error)", category: .general)
        }
    }

    private func load() {
        let entryIDs = audioFileManager.allEntryIDs()
        var loaded: [TranscriptionEntry] = []

        for entryID in entryIDs {
            let url = audioFileManager.metadataFileURL(for: entryID)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(TranscriptionEntry.self, from: data) else {
                continue
            }
            loaded.append(entry)
        }

        // Sort newest first
        entries = loaded.sorted { $0.date > $1.date }
    }

    // MARK: - Pruning

    private func pruneIfNeeded() {
        let maxEntries = UserDefaults.standard.integer(forKey: "maxHistoryEntries")
        let maxAgeDays = UserDefaults.standard.integer(forKey: "maxHistoryAgeDays")

        // Prune by count (0 = unlimited)
        if maxEntries > 0, entries.count > maxEntries {
            let removed = entries.suffix(from: maxEntries)
            for entry in removed {
                audioFileManager.deleteEntryDirectory(for: entry.id)
            }
            entries = Array(entries.prefix(maxEntries))
        }

        // Prune by age (0 = never)
        if maxAgeDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
            let expired = entries.filter { $0.date < cutoff }
            for entry in expired {
                audioFileManager.deleteEntryDirectory(for: entry.id)
            }
            entries.removeAll { $0.date < cutoff }
        }
    }

    // MARK: - Migration from UserDefaults

    private func migrateFromUserDefaultsIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyStorageKey) else { return }

        // Use a lenient decoder that handles missing fields
        let legacyDecoder = JSONDecoder()
        guard let legacyEntries = try? legacyDecoder.decode([TranscriptionEntry].self, from: data) else { return }

        for entry in legacyEntries {
            saveEntry(entry)
        }

        UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
        TranscriptionLogger.shared.info("Migrated \(legacyEntries.count) entries from UserDefaults to file storage", category: .general)
    }
}
