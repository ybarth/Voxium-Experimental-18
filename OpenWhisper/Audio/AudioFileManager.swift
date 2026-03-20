import Foundation
import AudioToolbox

@MainActor
final class AudioFileManager {
    static let shared = AudioFileManager()

    private let fileManager = FileManager.default

    var historyDirectoryURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/History", isDirectory: true)
    }

    func entryDirectoryURL(for entryID: UUID) -> URL {
        historyDirectoryURL.appendingPathComponent(entryID.uuidString, isDirectory: true)
    }

    func audioFileURL(for entryID: UUID) -> URL {
        entryDirectoryURL(for: entryID).appendingPathComponent("audio.caf")
    }

    func originalAudioFileURL(for entryID: UUID) -> URL {
        entryDirectoryURL(for: entryID).appendingPathComponent("audio-original.caf")
    }

    func metadataFileURL(for entryID: UUID) -> URL {
        entryDirectoryURL(for: entryID).appendingPathComponent("metadata.json")
    }

    func waveformDataFileURL(for entryID: UUID) -> URL {
        entryDirectoryURL(for: entryID).appendingPathComponent("waveform.json")
    }

    func appearanceFileURL(for entryID: UUID) -> URL {
        entryDirectoryURL(for: entryID).appendingPathComponent("appearance.json")
    }

    /// Save per-entry appearance overrides.
    func saveEntryAppearance(_ overrides: EntryAppearanceOverride, for entryID: UUID) {
        let url = appearanceFileURL(for: entryID)
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Load per-entry appearance overrides (nil = use global defaults).
    func loadEntryAppearance(for entryID: UUID) -> EntryAppearanceOverride? {
        let url = appearanceFileURL(for: entryID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EntryAppearanceOverride.self, from: data)
    }

    /// Ensures the entry directory exists, creating it if needed.
    func ensureEntryDirectory(for entryID: UUID) throws {
        let dir = entryDirectoryURL(for: entryID)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Legacy wrapper — delegates to SilenceAnalyzer.
    static func trimSilence(from samples: [Float], sampleRate: Double = 16000) -> SilenceAnalyzer.TrimResult {
        SilenceAnalyzer.trimLeadingSilence(from: samples, sampleRate: sampleRate)
    }

    /// Saves Float32 audio samples as a 16kHz mono CAF file using AudioToolbox.
    /// The caller is responsible for trimming silence before calling this method.
    /// Returns the filename ("audio.caf") on success.
    @discardableResult
    func saveAudio(samples: [Float], sampleRate: Double = 16000, entryID: UUID) throws -> String {
        try ensureEntryDirectory(for: entryID)
        let url = audioFileURL(for: entryID)

        let trimmed = samples

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var audioFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &asbd,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        )

        guard status == noErr, let file = audioFile else {
            throw AudioFileManagerError.createFailed(status)
        }

        defer { ExtAudioFileDispose(file) }

        try trimmed.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }

            let buffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(trimmed.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: baseAddress)
            )

            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)

            let writeStatus = ExtAudioFileWrite(file, UInt32(trimmed.count), &bufferList)
            guard writeStatus == noErr else {
                throw AudioFileManagerError.writeFailed(writeStatus)
            }
        }

        return "audio.caf"
    }

    /// Save the original untrimmed audio. Called before trimming.
    @discardableResult
    func saveOriginalAudio(samples: [Float], sampleRate: Double = 16000, entryID: UUID) throws -> String {
        try ensureEntryDirectory(for: entryID)
        let url = originalAudioFileURL(for: entryID)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )

        var audioFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &asbd, nil,
            AudioFileFlags.eraseFile.rawValue, &audioFile
        )
        guard status == noErr, let file = audioFile else {
            throw AudioFileManagerError.createFailed(status)
        }
        defer { ExtAudioFileDispose(file) }

        try samples.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            let buffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: baseAddress)
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let writeStatus = ExtAudioFileWrite(file, UInt32(samples.count), &bufferList)
            guard writeStatus == noErr else {
                throw AudioFileManagerError.writeFailed(writeStatus)
            }
        }
        return "audio-original.caf"
    }

    /// Returns the audio file URL if the file exists for the given entry.
    func loadAudioURL(for entryID: UUID) -> URL? {
        let url = audioFileURL(for: entryID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the original (untrimmed) audio URL if it exists.
    func loadOriginalAudioURL(for entryID: UUID) -> URL? {
        let url = originalAudioFileURL(for: entryID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Save waveform data as JSON alongside the entry.
    func saveWaveformData(_ data: WaveformData, for entryID: UUID) {
        let url = waveformDataFileURL(for: entryID)
        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(data) else { return }
        try? json.write(to: url, options: .atomic)
    }

    /// Load waveform data for an entry (lazy — only when needed for bar view).
    func loadWaveformData(for entryID: UUID) -> WaveformData? {
        let url = waveformDataFileURL(for: entryID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WaveformData.self, from: data)
    }

    /// Deletes the audio file for an entry.
    func deleteAudio(for entryID: UUID) {
        let url = audioFileURL(for: entryID)
        try? fileManager.removeItem(at: url)
    }

    /// Deletes the entire entry directory (metadata + audio).
    func deleteEntryDirectory(for entryID: UUID) {
        let dir = entryDirectoryURL(for: entryID)
        try? fileManager.removeItem(at: dir)
    }

    /// Returns all entry UUIDs that have directories in the history folder.
    func allEntryIDs() -> [UUID] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { url in
            UUID(uuidString: url.lastPathComponent)
        }
    }

    /// Total size of all audio files in bytes.
    func totalStorageBytes() -> Int64 {
        var total: Int64 = 0
        for entryID in allEntryIDs() {
            let dir = entryDirectoryURL(for: entryID)
            if let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(size)
                    }
                }
            }
        }
        return total
    }
}

enum AudioFileManagerError: LocalizedError {
    case createFailed(OSStatus)
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status):
            return "Failed to create audio file (OSStatus \(status))"
        case .writeFailed(let status):
            return "Failed to write audio data (OSStatus \(status))"
        }
    }
}
