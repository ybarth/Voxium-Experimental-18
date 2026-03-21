import Foundation
import SwiftUI

@MainActor
@Observable
final class OllamaDiscovery {

    private(set) var isInstalled = false
    private(set) var discoveredModels: [OllamaModelProvider] = []

    private let ollamaBase = "http://localhost:11434"

    func detect() async {
        // Check if Ollama is running
        guard let url = URL(string: "\(ollamaBase)/api/tags") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            isInstalled = true

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }

            discoveredModels = models.compactMap { modelInfo in
                guard let name = modelInfo["name"] as? String else { return nil }
                let size = modelInfo["size"] as? Int64 ?? 0
                return OllamaModelProvider(
                    modelName: name,
                    sizeBytes: size,
                    baseURL: ollamaBase
                )
            }
        } catch {
            isInstalled = false
            discoveredModels = []
        }
    }
}

@MainActor
@Observable
final class OllamaModelProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .ollama
    let capabilities: Set<AICapability>
    var status: ProviderStatus = .loaded  // Ollama models are always "loaded" by Ollama
    let memoryFootprint: Int?

    private let modelName: String
    private let baseURL: String

    init(modelName: String, sizeBytes: Int64, baseURL: String) {
        self.id = "ollama-\(modelName)"
        self.name = "Ollama: \(modelName)"
        self.modelName = modelName
        self.baseURL = baseURL
        self.memoryFootprint = Int(sizeBytes)
        // Infer basic capabilities — Ollama models are general-purpose
        self.capabilities = [.reasoning, .creativity]
    }

    nonisolated func load() async throws { }
    nonisolated func unload() async { }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let start = CFAbsoluteTimeGetCurrent()

        var body: [String: Any] = [
            "model": modelName,
            "prompt": request.prompt,
            "stream": false,
        ]
        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        }

        var urlRequest = URLRequest(url: URL(string: "\(baseURL)/api/generate")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw ProviderError.invalidResponse
        }

        let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return AIResponse(text: text, providerID: id, tokenCount: nil, latencyMs: latency)
    }
}
