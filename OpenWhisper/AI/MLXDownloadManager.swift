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
