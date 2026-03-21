import Foundation

@MainActor
@Observable
final class ClaudeProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .commercial
    let capabilities: Set<AICapability>
    var status: ProviderStatus = .available
    let memoryFootprint: Int? = nil

    private let modelID: String
    private let keyManager: CommercialKeyManager

    init(modelID: String, name: String, capabilities: Set<AICapability>, keyManager: CommercialKeyManager) {
        self.id = "claude-\(modelID)"
        self.modelID = modelID
        self.name = name
        self.capabilities = capabilities
        self.keyManager = keyManager
    }

    nonisolated func load() async throws { }
    nonisolated func unload() async { }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyManager.getKey(for: .claude) else {
            throw ProviderError.noAPIKey
        }

        let start = CFAbsoluteTimeGetCurrent()

        var messages: [[String: Any]] = []
        messages.append(["role": "user", "content": request.prompt])

        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "max_tokens": request.maxTokens ?? 4096,
        ]
        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ConnectionError.httpError(statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw ProviderError.invalidResponse
        }

        let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let usage = json["usage"] as? [String: Any]
        let tokenCount = usage?["output_tokens"] as? Int

        return AIResponse(text: text, providerID: id, tokenCount: tokenCount, latencyMs: latency)
    }
}

enum ProviderError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from provider"
        case .modelNotLoaded: return "Model is not loaded"
        }
    }
}
