import Foundation

@MainActor
@Observable
final class MLXDownloadManager {

    struct DownloadProgress: Sendable {
        let modelID: String
        let bytesDownloaded: Int64
        let totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0 }
    }

    private(set) var activeDownloads: [String: DownloadProgress] = [:]

    private let modelsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        self.modelsDirectory = appSupport.appendingPathComponent(
            "OpenWhisper/Models/MLX", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
    }

    var modelDirectory: URL { modelsDirectory }

    func modelPath(for modelID: String) -> URL {
        modelsDirectory.appendingPathComponent(modelID, isDirectory: true)
    }

    func isDownloaded(modelID: String) -> Bool {
        let path = modelPath(for: modelID)
        let configFile = path.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configFile.path)
    }

    // MARK: - Local Model Scanning

    /// Locations where models from other tools might already exist.
    private static let externalSearchPaths: [(name: String, path: String)] = [
        ("HuggingFace Cache", "~/.cache/huggingface/hub"),
        ("LM Studio", "~/.cache/lm-studio/models"),
        ("Ollama", "~/.ollama/models/blobs"),
    ]

    struct ExternalModelMatch: Sendable {
        let modelID: String
        let repoID: String
        let sourcePath: URL
        let sourceName: String  // e.g. "HuggingFace Cache"
    }

    /// Scan common locations for models that match our catalog.
    /// Returns matches that can be symlinked instead of re-downloaded.
    func scanForExistingModels(catalog: [MLXModelCatalogEntry]) -> [ExternalModelMatch] {
        var matches: [ExternalModelMatch] = []
        let fm = FileManager.default

        for entry in catalog {
            // Skip if already in our directory
            if isDownloaded(modelID: entry.id) { continue }

            // Check HuggingFace cache (most common)
            if let hfMatch = findInHuggingFaceCache(repoID: entry.repoID) {
                matches.append(ExternalModelMatch(
                    modelID: entry.id,
                    repoID: entry.repoID,
                    sourcePath: hfMatch,
                    sourceName: "HuggingFace Cache"
                ))
                continue
            }

            // Check LM Studio cache
            if let lmMatch = findInLMStudio(repoID: entry.repoID) {
                matches.append(ExternalModelMatch(
                    modelID: entry.id,
                    repoID: entry.repoID,
                    sourcePath: lmMatch,
                    sourceName: "LM Studio"
                ))
                continue
            }
        }

        return matches
    }

    /// Link an externally found model into our models directory via symlink.
    func linkExternalModel(_ match: ExternalModelMatch) throws {
        let destPath = modelPath(for: match.modelID)
        let fm = FileManager.default

        // Remove existing (empty or broken) directory if present
        if fm.fileExists(atPath: destPath.path) {
            try fm.removeItem(at: destPath)
        }

        try fm.createSymbolicLink(at: destPath, withDestinationURL: match.sourcePath)

        // Write metadata noting this is a linked model
        let metadataPath = modelsDirectory.appendingPathComponent(".\(match.modelID)-link-metadata.json")
        let metadata: [String: Any] = [
            "repoID": match.repoID,
            "linkedFrom": match.sourcePath.path,
            "sourceName": match.sourceName,
            "linkedDate": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try data.write(to: metadataPath)
    }

    /// HuggingFace cache stores models in: ~/.cache/huggingface/hub/models--{org}--{model}/snapshots/{hash}/
    private func findInHuggingFaceCache(repoID: String) -> URL? {
        let fm = FileManager.default
        let hfCacheDir = NSString("~/.cache/huggingface/hub").expandingTildeInPath
        // HF cache format: models--org--modelname
        let dirName = "models--\(repoID.replacingOccurrences(of: "/", with: "--"))"
        let modelCacheDir = URL(fileURLWithPath: hfCacheDir).appendingPathComponent(dirName)

        guard fm.fileExists(atPath: modelCacheDir.path) else { return nil }

        // Look in snapshots/ for the most recent snapshot
        let snapshotsDir = modelCacheDir.appendingPathComponent("snapshots")
        guard let snapshots = try? fm.contentsOfDirectory(atPath: snapshotsDir.path),
              !snapshots.isEmpty else { return nil }

        // Use the first snapshot (usually there's only one, or pick the newest)
        let sortedSnapshots = snapshots.sorted()
        guard let latestSnapshot = sortedSnapshots.last else { return nil }
        let snapshotPath = snapshotsDir.appendingPathComponent(latestSnapshot)

        // Verify it has a config.json (indicating a complete model)
        let configPath = snapshotPath.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configPath.path) else { return nil }

        return snapshotPath
    }

    /// LM Studio stores models in: ~/.cache/lm-studio/models/{org}/{model}/
    private func findInLMStudio(repoID: String) -> URL? {
        let fm = FileManager.default
        let lmStudioDir = NSString("~/.cache/lm-studio/models").expandingTildeInPath
        let modelPath = URL(fileURLWithPath: lmStudioDir).appendingPathComponent(repoID)

        guard fm.fileExists(atPath: modelPath.path) else { return nil }

        // Verify it has a config.json
        let configPath = modelPath.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configPath.path) else { return nil }

        return modelPath
    }

    /// Download all files for a model from HuggingFace.
    ///
    /// Fetches the file list from the HuggingFace tree API, then downloads each file
    /// individually using basic URLSession. Progress is tracked per model.
    ///
    /// TODO: Add resume support (Range header + .partial files).
    /// TODO: Add SHA256 verification using CryptoKit.
    func download(modelID: String, repoID: String) async throws {
        let destDir = modelPath(for: modelID)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Fetch file list from HuggingFace API
        let filesURL = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main")!
        let (data, _) = try await URLSession.shared.data(from: filesURL)
        guard let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MLXDownloadError.invalidFileList
        }

        // Only include top-level files (no subdirectories)
        let fileEntries = files.compactMap { entry -> (name: String, size: Int64)? in
            guard let path = entry["path"] as? String,
                  !path.hasPrefix("."),
                  !path.contains("/") else { return nil }
            let size =
                (entry["lfs"] as? [String: Any])?["size"] as? Int64
                ?? entry["size"] as? Int64 ?? 0
            return (name: path, size: size)
        }

        let totalBytes = fileEntries.reduce(0) { $0 + $1.size }
        var downloadedBytes: Int64 = 0

        for entry in fileEntries {
            let fileURL = URL(
                string: "https://huggingface.co/\(repoID)/resolve/main/\(entry.name)")!
            let destFile = destDir.appendingPathComponent(entry.name)

            // Skip already downloaded files
            if FileManager.default.fileExists(atPath: destFile.path) {
                downloadedBytes += entry.size
                continue
            }

            // Download to temp location, then move atomically
            let (tempURL, _) = try await URLSession.shared.download(from: fileURL)
            try FileManager.default.moveItem(at: tempURL, to: destFile)

            downloadedBytes += entry.size
            activeDownloads[modelID] = DownloadProgress(
                modelID: modelID,
                bytesDownloaded: downloadedBytes,
                totalBytes: totalBytes
            )
        }

        activeDownloads.removeValue(forKey: modelID)

        // Write metadata
        let metadata: [String: Any] = [
            "repoID": repoID,
            "downloadDate": ISO8601DateFormatter().string(from: Date()),
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: destDir.appendingPathComponent(".metadata.json"))
    }

    func deleteModel(modelID: String) throws {
        let path = modelPath(for: modelID)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

enum MLXDownloadError: LocalizedError {
    case invalidFileList

    var errorDescription: String? {
        switch self {
        case .invalidFileList: return "Failed to get file list from HuggingFace"
        }
    }
}
