import Foundation

// MARK: - Provider Protocol

protocol AIProvider: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var providerType: ProviderType { get }
    var capabilities: Set<AICapability> { get }
    var status: ProviderStatus { get }
    var memoryFootprint: Int? { get }

    func load() async throws
    func unload() async
    func complete(_ request: AIRequest) async throws -> AIResponse
}

// MARK: - Enums

enum ProviderType: String, Codable, Sendable {
    case mlx
    case ollama
    case commercial
}

enum ProviderStatus: String, Codable, Sendable {
    case notDownloaded
    case downloading
    case available
    case loading
    case loaded
    case error
}

enum AICapability: String, Codable, CaseIterable, Sendable {
    case reasoning
    case codeGeneration
    case creativity
    case multilingual
    case translation
    case phoneticAnalysis
    case fastInference
    case longContext
    case transcriptionAware
    case editorialAnalysis
    case visualGeneration
}

// MARK: - Request / Response

struct AIRequest: Sendable {
    let prompt: String
    let systemPrompt: String?
    let maxTokens: Int?
    let temperature: Double?
    let task: AITask
}

struct AIResponse: Sendable {
    let text: String
    let providerID: String
    let tokenCount: Int?
    let latencyMs: Int
}

// MARK: - Task Definitions

enum AITask: String, Codable, CaseIterable, Sendable {
    case dictionaryContext
    case transcriptionCorrection
    case transcriptionCleanup
    case editorialSuggestions
    case contentQualityFlag
    case titleGeneration
    case visualGeneration
    case documentScanning
    case contextFormatting
    case careModel

    var requiredCapabilities: Set<AICapability> {
        switch self {
        case .dictionaryContext: return [.phoneticAnalysis, .multilingual]
        case .transcriptionCorrection: return [.phoneticAnalysis, .transcriptionAware]
        case .transcriptionCleanup: return [.editorialAnalysis, .creativity]
        case .editorialSuggestions: return [.editorialAnalysis, .creativity]
        case .contentQualityFlag: return [.reasoning, .transcriptionAware]
        case .titleGeneration: return [.creativity, .fastInference]
        case .visualGeneration: return [.visualGeneration, .creativity]
        case .documentScanning: return [.reasoning, .multilingual]
        case .contextFormatting: return [.editorialAnalysis, .transcriptionAware]
        case .careModel: return [.reasoning, .fastInference]
        }
    }

    var displayName: String {
        switch self {
        case .dictionaryContext: return "Dictionary Context"
        case .transcriptionCorrection: return "Transcription Correction"
        case .transcriptionCleanup: return "Transcription Cleanup"
        case .editorialSuggestions: return "Editorial Suggestions"
        case .contentQualityFlag: return "Content Quality Flags"
        case .titleGeneration: return "Title Generation"
        case .visualGeneration: return "Visual Generation"
        case .documentScanning: return "Document Scanning"
        case .contextFormatting: return "Context Formatting"
        case .careModel: return "Care Model"
        }
    }
}

// MARK: - Task Assignment

struct TaskAssignment: Codable, Sendable {
    enum Mode: Codable, Sendable {
        case single(providerID: String)
        case council(councilID: UUID)
    }
    let mode: Mode
}

// MARK: - Health

enum HealthStatus: Sendable {
    case healthy
    case degraded(reason: String)
    case unhealthy(error: String)
}

// MARK: - Suggestions

struct ScoredSuggestion: Sendable {
    let providerID: String
    let providerName: String
    let score: Double
    let explanation: String
}

struct CouncilSuggestion: Sendable {
    let memberProviderIDs: [String]
    let chairmanProviderID: String
    let explanation: String
}
