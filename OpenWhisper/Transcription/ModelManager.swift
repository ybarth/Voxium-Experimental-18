import Foundation

// MARK: - Model types

enum ModelBackend {
    case whisperCpp
    case inferenceServer
}

enum TranscriptionModel: String {
    // Whisper models (in-process via SwiftWhisper)
    case base
    case small
    case medium
    // Parakeet model (local inference server via sherpa-onnx NeMo CTC)
    case parakeetTDT   // kept for backward compat — maps to same model as parakeetCTC
    case parakeetCTC
    // Granite model (local inference server via MLX Audio)
    case graniteSpeech

    /// Models shown in the picker. parakeetTDT is hidden (legacy alias).
    static var allCases: [TranscriptionModel] {
        [.base, .small, .medium, .parakeetCTC, .graniteSpeech]
    }

    var backend: ModelBackend {
        switch self {
        case .base, .small, .medium:
            return .whisperCpp
        case .parakeetTDT, .parakeetCTC, .graniteSpeech:
            return .inferenceServer
        }
    }

    /// File name for whisper.cpp models (only meaningful for .whisperCpp backend).
    var fileName: String {
        switch self {
        case .base:   return "ggml-base.en.bin"
        case .small:  return "ggml-small.en-q5_1.bin"
        case .medium: return "ggml-medium.en-q5_0.bin"
        default:      return ""
        }
    }

    /// Download URL for whisper.cpp models.
    var downloadURL: URL {
        let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
        return URL(string: base + fileName)!
    }

    /// Identifier sent to the inference server's /load endpoint.
    var serverModelIdentifier: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .base:          return "Whisper Base (142 MB, very fast)"
        case .small:         return "Whisper Small (181 MB, fast)"
        case .medium:        return "Whisper Medium (514 MB, moderate)"
        case .parakeetTDT:   return "Parakeet 110M (~458 MB, very fast)"
        case .parakeetCTC:   return "Parakeet 110M (~458 MB, very fast)"
        case .graniteSpeech: return "Granite 4.0 1B Speech BF16 (~4.5 GB, MLX)"
        }
    }

    var categoryLabel: String {
        switch self {
        case .base, .small, .medium:       return "Whisper (Local)"
        case .parakeetTDT, .parakeetCTC:   return "Parakeet / NVIDIA (Server)"
        case .graniteSpeech:               return "Granite / IBM (MLX Server)"
        }
    }

    var requiresServer: Bool { backend == .inferenceServer }
}

// Keep the old name available for any references
typealias WhisperModel = TranscriptionModel

// MARK: - Model manager

@MainActor
@Observable
final class ModelManager {
    var isDownloading = false
    var downloadProgress: Double = 0
    var errorMessage: String?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: Int = 0
    private let logger = TranscriptionLogger.shared

    var selectedModel: TranscriptionModel {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedModel")
            logger.info("Model changed to \(selectedModel.rawValue)", category: .model)
        }
    }

    /// For whisper models: true when the .bin file exists on disk.
    /// For server models: always true (server manager handles readiness).
    var isModelReady: Bool {
        switch selectedModel.backend {
        case .whisperCpp:
            return modelFileURL != nil
        case .inferenceServer:
            return true
        }
    }

    var modelFileURL: URL? {
        guard selectedModel.backend == .whisperCpp else { return nil }
        guard let dir = modelsDirectory else { return nil }
        let path = dir.appendingPathComponent(selectedModel.fileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private var modelsDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        return appSupport
            .appendingPathComponent("OpenWhisper")
            .appendingPathComponent("Models")
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        self.selectedModel = TranscriptionModel(rawValue: stored) ?? .small
        logger.info("ModelManager initialized with model: \(selectedModel.rawValue)", category: .model)
    }

    func ensureModelAvailable() {
        guard selectedModel.backend == .whisperCpp else { return }
        if modelFileURL == nil {
            startDownload()
        }
    }

    func selectModel(_ model: TranscriptionModel) {
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        selectedModel = model

        if model.backend == .whisperCpp {
            if modelFileURL == nil {
                logger.info("Starting download for \(model.fileName)", category: .download)
                downloadTask = Task { await downloadModel() }
            } else {
                isDownloading = false
                downloadProgress = 1.0
            }
        } else {
            // Server models — server manager handles setup separately
            isDownloading = false
            downloadProgress = 0
        }
    }

    func startDownload() {
        guard selectedModel.backend == .whisperCpp else { return }
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        logger.info("Starting download for \(selectedModel.fileName)", category: .download)
        downloadTask = Task { await downloadModel() }
    }

    func downloadModel() async {
        guard let modelsDir = modelsDirectory else {
            errorMessage = "Cannot determine models directory"
            logger.error("Cannot determine models directory", category: .download)
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot create models directory: \(error.localizedDescription)"
            logger.error("Cannot create models directory: \(error.localizedDescription)", category: .download)
            return
        }

        let destinationURL = modelsDir.appendingPathComponent(selectedModel.fileName)

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let generation = self.downloadGeneration
        logger.info("Connecting to \(selectedModel.downloadURL)...", category: .download)

        do {
            try Task.checkCancellation()

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            let delegate = DownloadDelegate { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                }
            }

            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: OperationQueue.main)
            defer { session.invalidateAndCancel() }

            let (tempURL, response) = try await withTaskCancellationHandler {
                try await delegate.download(session: session, from: selectedModel.downloadURL)
            } onCancel: {
                session.invalidateAndCancel()
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("Download failed: HTTP \(code)", category: .download)
                throw URLError(.badServerResponse)
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            downloadProgress = 1.0
            logger.info("Download complete: \(selectedModel.fileName)", category: .download)
        } catch is CancellationError {
            logger.info("Download cancelled", category: .download)
        } catch let error as URLError where error.code == .cancelled {
            logger.info("Download cancelled", category: .download)
        } catch {
            guard self.downloadGeneration == generation else { return }
            isDownloading = false
            errorMessage = "Download failed: \(error.localizedDescription)"
            logger.error("Download failed: \(error.localizedDescription)", category: .download)
        }
    }
}

// MARK: - Download delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(session: URLSession, from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: tempFile)
            guard let response = downloadTask.response else {
                continuation?.resume(throwing: URLError(.badServerResponse))
                continuation = nil
                return
            }
            continuation?.resume(returning: (tempFile, response))
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
