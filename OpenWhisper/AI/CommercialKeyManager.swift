import Foundation
import Security
import SwiftUI

@MainActor
@Observable
final class CommercialKeyManager {

    enum ServiceCategory: String, CaseIterable, Sendable {
        case llmProviders = "LLM Providers"
        case cloudVoiceModels = "Cloud Voice Models"
    }

    enum Service: String, CaseIterable, Sendable {
        case claude = "com.openwhisper.api.claude"
        case gpt = "com.openwhisper.api.gpt"
        case gemini = "com.openwhisper.api.gemini"
        case grok = "com.openwhisper.api.grok"
        case deepgram = "com.openwhisper.api.deepgram"
        case cartesia = "com.openwhisper.api.cartesia"

        var displayName: String {
            switch self {
            case .claude: return "Claude (Anthropic)"
            case .gpt: return "GPT (OpenAI)"
            case .gemini: return "Gemini (Google)"
            case .grok: return "Grok (xAI)"
            case .deepgram: return "Deepgram"
            case .cartesia: return "Cartesia"
            }
        }

        var keyPattern: String {
            switch self {
            case .claude: return "^sk-ant-.+"
            case .gpt: return "^sk-.+"
            case .gemini: return "^AI.+"
            case .grok: return "^xai-.+"
            case .deepgram: return "^.{8,}"  // Deepgram keys are opaque tokens
            case .cartesia: return "^.{8,}"  // Cartesia keys are opaque tokens
            }
        }

        var dashboardURL: URL? {
            switch self {
            case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
            case .gpt: return URL(string: "https://platform.openai.com/api-keys")
            case .gemini: return URL(string: "https://aistudio.google.com/apikey")
            case .grok: return URL(string: "https://console.x.ai")
            case .deepgram: return URL(string: "https://console.deepgram.com")
            case .cartesia: return URL(string: "https://play.cartesia.ai/keys")
            }
        }

        var category: ServiceCategory {
            switch self {
            case .claude, .gpt, .gemini, .grok: return .llmProviders
            case .deepgram, .cartesia: return .cloudVoiceModels
            }
        }

        static func services(in category: ServiceCategory) -> [Service] {
            allCases.filter { $0.category == category }
        }
    }

    enum ValidationDepth: String, CaseIterable, Sendable {
        case basic
        case guided
        case comprehensive

        var displayName: String {
            switch self {
            case .basic: return "Basic"
            case .guided: return "Guided"
            case .comprehensive: return "Comprehensive"
            }
        }
    }

    @ObservationIgnored
    @AppStorage("connectionTestDepth") var defaultDepth: String = ValidationDepth.guided.rawValue

    // MARK: - Keychain Operations

    func saveKey(_ key: String, for service: Service) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api-key",
        ]

        // Delete existing
        SecItemDelete(query as CFDictionary)

        // Add new
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func getKey(for service: Service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteKey(for service: Service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }

    func hasKey(for service: Service) -> Bool {
        getKey(for: service) != nil
    }

    // MARK: - Validation

    func validateKeyFormat(_ key: String, for service: Service) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: service.keyPattern) else { return false }
        let range = NSRange(key.startIndex..., in: key)
        return regex.firstMatch(in: key, range: range) != nil
    }

    func maskedKey(for service: Service) -> String? {
        guard let key = getKey(for: service) else { return nil }
        let prefix = String(key.prefix(8))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    // MARK: - Connection Testing

    struct TestResult: Sendable {
        let success: Bool
        let message: String
        let accessibleModels: [String]
        let diagnostics: String?
        let latencyMs: Int?
    }

    func testConnection(
        for service: Service,
        depth: ValidationDepth
    ) async -> TestResult {
        guard let key = getKey(for: service) else {
            return TestResult(success: false, message: "No API key configured", accessibleModels: [], diagnostics: nil, latencyMs: nil)
        }

        guard validateKeyFormat(key, for: service) else {
            return TestResult(
                success: false,
                message: "API key format is invalid for \(service.displayName)",
                accessibleModels: [],
                diagnostics: depth != .basic ? "Expected format matching: \(service.keyPattern)" : nil,
                latencyMs: nil
            )
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            let models = try await listModels(for: service, key: key)
            let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            switch depth {
            case .basic:
                return TestResult(success: true, message: "Connected", accessibleModels: [], diagnostics: nil, latencyMs: latency)
            case .guided:
                return TestResult(success: true, message: "Connected to \(service.displayName)", accessibleModels: models, diagnostics: nil, latencyMs: latency)
            case .comprehensive:
                return TestResult(success: true, message: "Connected to \(service.displayName)", accessibleModels: models, diagnostics: "Latency: \(latency)ms\nModels: \(models.count) accessible", latencyMs: latency)
            }
        } catch {
            let message = depth == .basic ? error.localizedDescription : translateError(error, for: service)
            let diagnostics = depth == .comprehensive ? "Raw error: \(error)" : nil
            return TestResult(success: false, message: message, accessibleModels: [], diagnostics: diagnostics, latencyMs: nil)
        }
    }

    // MARK: - API Calls

    private func listModels(for service: Service, key: String) async throws -> [String] {
        let (url, headers) = modelsEndpoint(for: service, key: key)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ConnectionError.httpError(httpResponse.statusCode)
        }

        return parseModelList(data: data, service: service)
    }

    private func modelsEndpoint(for service: Service, key: String) -> (URL, [String: String]) {
        switch service {
        case .claude:
            return (
                URL(string: "https://api.anthropic.com/v1/models")!,
                ["x-api-key": key, "anthropic-version": "2023-06-01"]
            )
        case .gpt:
            return (
                URL(string: "https://api.openai.com/v1/models")!,
                ["Authorization": "Bearer \(key)"]
            )
        case .gemini:
            return (
                URL(string: "https://generativelanguage.googleapis.com/v1/models?key=\(key)")!,
                [:]
            )
        case .grok:
            return (
                URL(string: "https://api.x.ai/v1/models")!,
                ["Authorization": "Bearer \(key)"]
            )
        case .deepgram:
            return (
                URL(string: "https://api.deepgram.com/v1/models")!,
                ["Authorization": "Token \(key)"]
            )
        case .cartesia:
            return (
                URL(string: "https://api.cartesia.ai/voices")!,
                ["X-API-Key": key, "Cartesia-Version": "2024-06-10"]
            )
        }
    }

    private func parseModelList(data: Data, service: Service) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch service {
        case .claude, .gpt, .grok:
            guard let models = json["data"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["id"] as? String }
        case .gemini:
            guard let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        case .deepgram:
            guard let models = json["stt"] as? [[String: Any]] else { return ["nova-2", "nova-2-general"] }
            return models.compactMap { $0["name"] as? String }
        case .cartesia:
            return ["sonic-2", "sonic-turbo"]
        }
    }

    // MARK: - Error Translation

    private func translateError(_ error: Error, for service: Service) -> String {
        if let connError = error as? ConnectionError {
            switch connError {
            case .httpError(401):
                return "This API key is invalid or has been revoked. Generate a new one at \(service.dashboardURL?.absoluteString ?? "the service dashboard")."
            case .httpError(403):
                return "This key doesn't have access to the requested resource. Check your plan tier."
            case .httpError(429):
                return "Rate limit exceeded. Your plan may have usage limits."
            case .httpError(let code):
                return "HTTP error \(code) from \(service.displayName)."
            case .invalidResponse:
                return "Invalid response from \(service.displayName). The service may be experiencing issues."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Could not reach \(service.displayName). Check your internet connection."
        }
        return error.localizedDescription
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Failed to save to Keychain (status: \(status))"
        }
    }
}

enum ConnectionError: LocalizedError {
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidResponse: return "Invalid response"
        }
    }
}
