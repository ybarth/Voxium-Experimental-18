import Foundation

@MainActor
@Observable
final class GPTProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .commercial
    let capabilities: Set<AICapability>
    var status: ProviderStatus = .available
    let memoryFootprint: Int? = nil

    private let modelID: String
    private let keyManager: CommercialKeyManager

    init(modelID: String, name: String, capabilities: Set<AICapability>, keyManager: CommercialKeyManager) {
        self.id = "gpt-\(modelID)"
        self.modelID = modelID
        self.name = name
        self.capabilities = capabilities
        self.keyManager = keyManager
    }

    nonisolated func load() async throws { }
    nonisolated func unload() async { }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyManager.getKey(for: .gpt) else {
            throw ProviderError.noAPIKey
        }

        let start = CFAbsoluteTimeGetCurrent()

        var messages: [[String: String]] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": request.prompt])

        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
        ]
        if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }
        if let temperature = request.temperature { body["temperature"] = temperature }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ConnectionError.httpError(statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw ProviderError.invalidResponse
        }

        let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let usage = json["usage"] as? [String: Any]
        let tokenCount = usage?["completion_tokens"] as? Int

        return AIResponse(text: text, providerID: id, tokenCount: tokenCount, latencyMs: latency)
    }
}
