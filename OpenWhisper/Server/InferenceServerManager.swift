import Foundation

// MARK: - Errors

enum InferenceError: LocalizedError {
    case pythonNotFound
    case serverNotRunning
    case serverStartTimeout
    case setupFailed(String)
    case modelLoadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python 3 not found. Install via: brew install python3"
        case .serverNotRunning:
            return "Inference server is not running"
        case .serverStartTimeout:
            return "Server failed to start within timeout"
        case .setupFailed(let msg):
            return "Setup failed: \(msg)"
        case .modelLoadFailed(let msg):
            return "Model load failed: \(msg)"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}

// MARK: - Server responses

struct HealthResponse: Codable {
    let status: String
    let serverVersion: String?
    let modelLoaded: String?
    let modelLoading: Bool
    let downloadProgress: Double
    let error: String?
    let uptime: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case serverVersion = "server_version"
        case modelLoaded = "model_loaded"
        case modelLoading = "model_loading"
        case downloadProgress = "download_progress"
        case error
        case uptime
    }
}

struct TranscriptionResult: Codable {
    let text: String
    let duration: Double?
}

// MARK: - Server manager

@MainActor
@Observable
final class InferenceServerManager {
    enum ServerState: Equatable {
        case stopped
        case settingUp
        case installingDependencies
        case starting
        case running
        case loadingModel(progress: Double)
        case error(String)

        static func == (lhs: ServerState, rhs: ServerState) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped),
                 (.settingUp, .settingUp),
                 (.installingDependencies, .installingDependencies),
                 (.starting, .starting),
                 (.running, .running):
                return true
            case let (.loadingModel(a), .loadingModel(b)):
                return a == b
            case let (.error(a), .error(b)):
                return a == b
            default:
                return false
            }
        }

        var displayString: String {
            switch self {
            case .stopped: return "Stopped"
            case .settingUp: return "Setting up Python..."
            case .installingDependencies: return "Installing dependencies..."
            case .starting: return "Starting server..."
            case .running: return "Running"
            case .loadingModel(let p): return "Loading model (\(Int(p * 100))%)..."
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    var state: ServerState = .stopped
    var loadedModelName: String?

    private var serverProcess: Process?
    private var healthCheckTask: Task<Void, Never>?
    private let port = 8178
    private let expectedServerVersion = "granite-mlx-v1"
    private let logger = TranscriptionLogger.shared

    private var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenWhisper")
            .appendingPathComponent("Server")
    }

    private var venvDir: URL { baseDir.appendingPathComponent("venv") }
    private var scriptPath: URL { baseDir.appendingPathComponent("inference_server.py") }
    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenWhisper")
            .appendingPathComponent("ServerModels")
    }

    var serverURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Public API

    /// Ensure the server is running and has the specified model loaded.
    func ensureRunning(model: TranscriptionModel) async throws {
        if case .running = state, loadedModelName == model.rawValue {
            logger.info("Server already running with model \(model.rawValue)", category: .server)
            return
        }

        if try await reuseOrReplaceExistingServerIfNeeded(for: model) {
            return
        }

        // Stop existing server if running a different model
        if serverProcess != nil {
            stop()
        }

        // 1. Setup Python environment
        state = .settingUp
        logger.info("Setting up inference server for \(model.rawValue)...", category: .server)
        try await setupPythonEnvironment(for: model)

        // 2. Write server script
        try writeServerScript()

        // 3. Start server process
        state = .starting
        logger.info("Starting inference server process...", category: .server)
        try await startServerProcess()

        // 4. Load model
        state = .loadingModel(progress: 0)
        logger.info("Requesting model load: \(model.rawValue)", category: .server)
        try await requestModelLoad(model)

        // 5. Begin health monitoring
        startHealthMonitoring()

        state = .running
        loadedModelName = model.rawValue
        logger.info("Inference server ready with model: \(model.rawValue)", category: .server)
    }

    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        if let process = serverProcess, process.isRunning {
            logger.info("Terminating inference server (PID \(process.processIdentifier))...", category: .server)
            process.terminate()
        }
        serverProcess = nil
        state = .stopped
        loadedModelName = nil
        logger.info("Inference server stopped", category: .server)
    }

    func restart(model: TranscriptionModel) async throws {
        logger.info("Restarting inference server...", category: .server)
        stop()
        try await ensureRunning(model: model)
    }

    func resetEnvironment(for model: TranscriptionModel) throws {
        stop()

        let fileManager = FileManager.default
        let pathsToRemove = resetPaths(for: model)

        for path in pathsToRemove where fileManager.fileExists(atPath: path.path) {
            logger.info("Removing inference environment path: \(path.path)", category: .server)
            try fileManager.removeItem(at: path)
        }

        state = .stopped
        loadedModelName = nil
        logger.info("Inference environment reset for \(model.rawValue)", category: .server)
    }

    /// Send audio to the server for transcription.
    func transcribe(audioFrames: [Float]) async throws -> String {
        guard case .running = state else {
            throw InferenceError.serverNotRunning
        }

        logger.debug("Sending \(audioFrames.count) frames to server for transcription", category: .transcription)

        // Encode float32 samples as base64
        let audioData = audioFrames.withUnsafeBytes { Data($0) }
        let base64Audio = audioData.base64EncodedString()

        let url = serverURL.appendingPathComponent("transcribe")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = ["audio": base64Audio, "sample_rate": 16000]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            logger.error("Server transcription failed (HTTP \(statusCode)): \(body)", category: .transcription)
            throw InferenceError.transcriptionFailed("HTTP \(statusCode)")
        }

        let result = try JSONDecoder().decode(TranscriptionResult.self, from: responseData)
        if let dur = result.duration {
            logger.info("Server transcription complete in \(String(format: "%.2f", dur))s", category: .transcription)
        }
        return result.text
    }

    /// Fetch current health from the server.
    func fetchHealth() async -> HealthResponse? {
        let url = serverURL.appendingPathComponent("health")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Python environment

    private func findPython() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                logger.info("Found Python at: \(path)", category: .server)
                return path
            }
        }
        logger.error("Python 3 not found in any standard location", category: .server)
        throw InferenceError.pythonNotFound
    }

    private func setupPythonEnvironment(for model: TranscriptionModel) async throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let pythonPath = try findPython()
        if model == .graniteSpeech {
            try ensurePythonVersion(at: pythonPath, minimumMajor: 3, minimumMinor: 10)
        }

        // Create venv if it doesn't exist
        let venvPython = venvDir.appendingPathComponent("bin/python3").path
        if !FileManager.default.fileExists(atPath: venvPython) {
            logger.info("Creating Python virtual environment at \(venvDir.path)...", category: .server)
            try await runShellProcess(pythonPath, arguments: ["-m", "venv", venvDir.path])
            logger.info("Virtual environment created", category: .server)
        } else {
            logger.info("Virtual environment already exists", category: .server)
        }

        // Install dependencies
        state = .installingDependencies
        let pipPath = venvDir.appendingPathComponent("bin/pip").path
        let requirements = pythonRequirements(for: model)

        logger.info("Installing dependencies: \(requirements.joined(separator: ", "))", category: .server)
        try await runShellProcess(pipPath, arguments: ["install", "--upgrade", "pip"])
        try await runShellProcess(pipPath, arguments: ["install"] + requirements)
        logger.info("Dependencies installed successfully", category: .server)
    }

    private func pythonRequirements(for model: TranscriptionModel) -> [String] {
        var reqs = ["flask", "numpy", "soundfile", "huggingface-hub"]
        switch model {
        case .parakeetTDT, .parakeetCTC:
            reqs.append("sherpa-onnx")
        case .graniteSpeech:
            reqs += ["mlx-audio"]
        default:
            break
        }
        return reqs
    }

    private func writeServerScript() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try InferenceServerScript.content.write(to: scriptPath, atomically: true, encoding: .utf8)
        logger.info("Server script written to \(scriptPath.path)", category: .server)
    }

    // MARK: - Server process management

    private func startServerProcess() async throws {
        let pythonPath = venvDir.appendingPathComponent("bin/python3").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath.path]

        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["MODELS_DIR"] = modelsDir.path
        env["PYTHONUNBUFFERED"] = "1"
        // Ensure HOME is set (may be missing when launched from Finder)
        if env["HOME"] == nil {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        // Disable HuggingFace XET accelerator — it requires auth context
        // that isn't available when the app launches the server subprocess.
        // Standard HTTPS downloads work fine for our model sizes.
        env["HF_HUB_DISABLE_XET"] = "1"
        process.environment = env

        // Capture stdout/stderr for logging
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        pipeToLogger(stdoutPipe, prefix: "server-out")
        pipeToLogger(stderrPipe, prefix: "server-err")

        try process.run()
        serverProcess = process
        logger.info("Server process started (PID \(process.processIdentifier))", category: .server)

        // Wait for the server to respond to health checks
        var attempts = 0
        let maxAttempts = 30
        while attempts < maxAttempts {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            if let health = await fetchHealth(), health.status == "ok" {
                logger.info("Server health check passed after \(attempts + 1)s", category: .server)
                return
            }
            if let proc = serverProcess, !proc.isRunning {
                logger.error("Server process exited during startup (code \(proc.terminationStatus))", category: .server)
                throw InferenceError.setupFailed("Server process exited with code \(proc.terminationStatus)")
            }
            attempts += 1
        }
        logger.error("Server did not respond after \(maxAttempts)s", category: .server)
        throw InferenceError.serverStartTimeout
    }

    private func requestModelLoad(_ model: TranscriptionModel) async throws {
        let url = serverURL.appendingPathComponent("load")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600 // model downloads can take a while

        let body = ["model": model.serverModelIdentifier]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Poll for progress while the model loads
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if let health = await self.fetchHealth(), health.modelLoading {
                    self.state = .loadingModel(progress: health.downloadProgress)
                    self.logger.debug("Model download progress: \(Int(health.downloadProgress * 100))%", category: .download)
                }
            }
        }

        defer { progressTask.cancel() }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Model load request failed: \(errorMsg)", category: .model)
            throw InferenceError.modelLoadFailed(errorMsg)
        }

        logger.info("Model load confirmed by server: \(model.rawValue)", category: .model)
    }

    private func requestServerShutdown() async {
        let url = serverURL.appendingPathComponent("shutdown")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        do {
            _ = try await URLSession.shared.data(for: request)
            logger.info("Requested shutdown of existing inference server", category: .server)
        } catch {
            logger.debug("Shutdown request failed: \(error.localizedDescription)", category: .server)
        }
    }

    private func waitForServerToStop(timeoutSeconds: Int = 10) async {
        for _ in 0..<timeoutSeconds {
            if await fetchHealth() == nil { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Health monitoring

    private func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self else { return }

                if let health = await self.fetchHealth() {
                    if health.status == "ok" {
                        self.logger.debug("Health check OK (uptime: \(Int(health.uptime ?? 0))s)", category: .server)
                    }
                } else {
                    self.logger.error("Health check failed — server unreachable", category: .server)
                    if let process = self.serverProcess, !process.isRunning {
                        self.logger.error("Server process is dead (exit code \(process.terminationStatus))", category: .server)
                        self.state = .error("Server crashed (exit code \(process.terminationStatus))")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func reuseOrReplaceExistingServerIfNeeded(for model: TranscriptionModel) async throws -> Bool {
        guard let health = await fetchHealth(), health.status == "ok" else {
            return false
        }

        let serverVersion = health.serverVersion ?? "unknown"
        guard serverVersion == expectedServerVersion else {
            logger.info(
                "Found stale inference server version \(serverVersion); requesting shutdown before restart.",
                category: .server
            )
            await requestServerShutdown()
            await waitForServerToStop()
            return false
        }

        logger.info("Reusing existing inference server on port \(port)", category: .server)

        if health.modelLoaded == model.rawValue {
            loadedModelName = model.rawValue
            state = .running
            startHealthMonitoring()
            return true
        }

        if health.modelLoading {
            state = .loadingModel(progress: health.downloadProgress)
        }

        try await requestModelLoad(model)
        loadedModelName = model.rawValue
        state = .running
        startHealthMonitoring()
        return true
    }

    private func pipeToLogger(_ pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    self?.logger.debug("[\(prefix)] \(line)", category: .server)
                }
            }
        }
    }

    private func ensurePythonVersion(at path: String, minimumMajor: Int, minimumMinor: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw InferenceError.setupFailed("Unable to determine Python version at \(path)")
        }

        let components = output.split(separator: ".", omittingEmptySubsequences: false)
        let major = components.first.flatMap { Int($0) } ?? 0
        let minor = components.dropFirst().first.flatMap { Int($0) } ?? 0

        let isSupported = major > minimumMajor || (major == minimumMajor && minor >= minimumMinor)
        guard isSupported else {
            throw InferenceError.setupFailed(
                "Granite MLX requires Python \(minimumMajor).\(minimumMinor)+, found \(output.isEmpty ? "unknown" : output) at \(path). Install a newer Homebrew Python."
            )
        }
    }

    private func resetPaths(for model: TranscriptionModel) -> [URL] {
        var paths = [baseDir]

        switch model {
        case .parakeetTDT, .parakeetCTC:
            paths.append(modelsDir.appendingPathComponent("parakeet-tdt-ctc-110m"))
        case .graniteSpeech:
            paths.append(huggingFaceCacheDirectory(for: "mlx-community/granite-4.0-1b-speech-bf16"))
            paths.append(huggingFaceCacheDirectory(for: "ibm-granite/granite-4.0-1b-speech"))
        default:
            break
        }

        return paths
    }

    private func huggingFaceCacheDirectory(for repoID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"))
    }

    private func runShellProcess(_ path: String, arguments: [String]) async throws {
        logger.debug("Running: \(path) \(arguments.joined(separator: " "))", category: .server)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let output = String(
                        data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    continuation.resume(
                        throwing: InferenceError.setupFailed(
                            "Process exited with code \(proc.terminationStatus): \(output.suffix(500))"
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
