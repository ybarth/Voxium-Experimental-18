import Foundation

@MainActor
@Observable
final class GeminiProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .commercial
    let capabilities: Set<AICapability>
    var status: ProviderStatus = .available
    let memoryFootprint: Int? = nil

    private let modelID: String
    private let keyManager: CommercialKeyManager

    init(modelID: String, name: String, capabilities: Set<AICapability>, keyManager: CommercialKeyManager) {
        self.id = "gemini-\(modelID)"
        self.modelID = modelID
        self.name = name
        self.capabilities = capabilities
        self.keyManager = keyManager
    }

    nonisolated func load() async throws { }
    nonisolated func unload() async { }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyManager.getKey(for: .gemini) else {
            throw ProviderError.noAPIKey
        }

        let start = CFAbsoluteTimeGetCurrent()

        var contents: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt {
            contents.append(["role": "user", "parts": [["text": systemPrompt]]])
            contents.append(["role": "model", "parts": [["text": "Understood."]]])
        }
        contents.append(["role": "user", "parts": [["text": request.prompt]]])

        var body: [String: Any] = ["contents": contents]
        if let maxTokens = request.maxTokens {
            body["generationConfig"] = ["maxOutputTokens": maxTokens]
        }

        let urlString = "https://generativelanguage.googleapis.com/v1/models/\(modelID):generateContent?key=\(key)"
        var urlRequest = URLRequest(url: URL(string: urlString)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ConnectionError.httpError(statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw ProviderError.invalidResponse
        }

        let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return AIResponse(text: text, providerID: id, tokenCount: nil, latencyMs: latency)
    }
}
