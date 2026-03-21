import Foundation
import MLXLMCommon
import MLXLLM

// MARK: - Catalog Entry

struct MLXModelCatalogEntry: Sendable {
    let id: String
    let name: String
    let repoID: String
    let parameterCount: String
    let memoryGB: Int
    let capabilities: Set<AICapability>
}

// MARK: - Model Manager

@MainActor
@Observable
final class MLXModelManager {

    static let catalog: [MLXModelCatalogEntry] = [
        MLXModelCatalogEntry(
            id: "llama-3.1-8b-4bit",
            name: "Llama 3.1 8B",
            repoID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            parameterCount: "8B",
            memoryGB: 6,
            capabilities: [.reasoning, .codeGeneration]
        ),
        MLXModelCatalogEntry(
            id: "qwen-2.5-7b-4bit",
            name: "Qwen 2.5 7B",
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            parameterCount: "7B",
            memoryGB: 5,
            capabilities: [.multilingual, .translation, .reasoning]
        ),
        MLXModelCatalogEntry(
            id: "deepseek-r1-7b-4bit",
            name: "DeepSeek-R1 7B",
            repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
            parameterCount: "7B",
            memoryGB: 5,
            capabilities: [.reasoning, .codeGeneration]
        ),
        MLXModelCatalogEntry(
            id: "phi-3.5-mini-4bit",
            name: "Phi-3.5 Mini",
            repoID: "mlx-community/Phi-3.5-mini-instruct-4bit",
            parameterCount: "3.8B",
            memoryGB: 3,
            capabilities: [.fastInference, .reasoning, .codeGeneration]
        ),
        MLXModelCatalogEntry(
            id: "gemma-2-2b-4bit",
            name: "Gemma 2 2B",
            repoID: "mlx-community/gemma-2-2b-it-4bit",
            parameterCount: "2.6B",
            memoryGB: 2,
            capabilities: [.fastInference, .editorialAnalysis, .creativity]
        ),
        MLXModelCatalogEntry(
            id: "llama-3.2-3b-4bit",
            name: "Llama 3.2 3B",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            parameterCount: "3B",
            memoryGB: 2,
            capabilities: [.fastInference, .reasoning]
        ),
        MLXModelCatalogEntry(
            id: "qwen-2.5-1.5b-4bit",
            name: "Qwen 2.5 1.5B",
            repoID: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            parameterCount: "1.5B",
            memoryGB: 1,
            capabilities: [.fastInference, .multilingual, .translation]
        ),
        MLXModelCatalogEntry(
            id: "smollm-135m-4bit",
            name: "SmolLM 135M",
            repoID: "mlx-community/SmolLM-135M-Instruct-4bit",
            parameterCount: "135M",
            memoryGB: 1,
            capabilities: [.fastInference]
        ),
    ]

    let downloadManager = MLXDownloadManager()
    private var loadedContainers: [String: ModelContainer] = [:]
    private(set) var providers: [String: MLXProvider] = [:]

    func createProviders() -> [MLXProvider] {
        Self.catalog.map { entry in
            let provider = MLXProvider(catalogEntry: entry, modelManager: self)
            providers[entry.id] = provider
            return provider
        }
    }

    func loadModel(id: String) async throws -> ModelContainer {
        if let existing = loadedContainers[id] { return existing }

        guard Self.catalog.contains(where: { $0.id == id }) else {
            throw MLXModelError.modelNotFound(id)
        }

        let modelPath = downloadManager.modelPath(for: id)
        let configuration = ModelConfiguration(directory: modelPath)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration)
        loadedContainers[id] = container
        return container
    }

    func unloadModel(id: String) {
        loadedContainers.removeValue(forKey: id)
    }

    func isLoaded(id: String) -> Bool {
        loadedContainers[id] != nil
    }

    func generate(
        modelID: String,
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int?
    ) async throws -> String {
        let container = try await loadModel(id: modelID)

        // Build messages array for chat template
        var messages: [[String: String]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        // Prepare UserInput using the messages chat format
        let userInput = UserInput(prompt: .messages(messages))
        let lmInput = try await container.prepare(input: userInput)

        var params = GenerateParameters(temperature: 0.7)
        if let maxTok = maxTokens {
            params.maxTokens = maxTok
        }

        let stream = try await container.generate(input: lmInput, parameters: params)

        var output = ""
        for await generation in stream {
            switch generation {
            case .chunk(let text):
                output += text
            case .info:
                break
            case .toolCall:
                break
            }
        }

        return output
    }
}

// MARK: - MLX Provider

@MainActor
@Observable
final class MLXProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .mlx
    let capabilities: Set<AICapability>
    var status: ProviderStatus
    var memoryFootprint: Int?

    private let catalogEntry: MLXModelCatalogEntry
    private let modelManager: MLXModelManager

    init(catalogEntry: MLXModelCatalogEntry, modelManager: MLXModelManager) {
        self.id = "mlx-\(catalogEntry.id)"
        self.name = catalogEntry.name
        self.capabilities = catalogEntry.capabilities
        self.catalogEntry = catalogEntry
        self.modelManager = modelManager
        self.memoryFootprint = catalogEntry.memoryGB * 1_073_741_824  // GB to bytes

        if modelManager.downloadManager.isDownloaded(modelID: catalogEntry.id) {
            self.status = modelManager.isLoaded(id: catalogEntry.id) ? .loaded : .available
        } else {
            self.status = .notDownloaded
        }
    }

    func load() async throws {
        status = .loading
        do {
            if !modelManager.downloadManager.isDownloaded(modelID: catalogEntry.id) {
                status = .downloading
                try await modelManager.downloadManager.download(
                    modelID: catalogEntry.id,
                    repoID: catalogEntry.repoID
                )
            }
            _ = try await modelManager.loadModel(id: catalogEntry.id)
            status = .loaded
        } catch {
            status = .error
            throw error
        }
    }

    func unload() async {
        modelManager.unloadModel(id: catalogEntry.id)
        status = .available
    }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard status == .loaded || modelManager.isLoaded(id: catalogEntry.id) else {
            throw ProviderError.modelNotLoaded
        }

        let start = CFAbsoluteTimeGetCurrent()
        let text = try await modelManager.generate(
            modelID: catalogEntry.id,
            prompt: request.prompt,
            systemPrompt: request.systemPrompt,
            maxTokens: request.maxTokens
        )
        let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        return AIResponse(text: text, providerID: id, tokenCount: nil, latencyMs: latency)
    }
}

// MARK: - Errors

enum MLXModelError: LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "MLX model not found: \(id)"
        }
    }
}
