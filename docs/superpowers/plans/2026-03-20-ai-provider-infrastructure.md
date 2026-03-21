# AI Provider Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a unified AI provider infrastructure with MLX local models, Ollama integration, BYOK commercial APIs, LLM Council, task routing, and predictive care model service.

**Architecture:** Plugin-style provider registry where all backends (MLX, Ollama, commercial APIs) implement a common `AIProvider` protocol with capability-based discovery. A `TaskRouter` resolves AI tasks to providers/councils via layered configuration. A `CareModelService` predictively pre-loads models based on user context.

**Tech Stack:** Swift/SwiftUI, MLX via `ml-explore/mlx-swift-examples` (MLXLLM module), macOS Keychain (Security framework), URLSession for API/download, PDFKit

**Spec:** `docs/superpowers/specs/2026-03-20-ai-provider-infrastructure-design.md`

**Note on testing:** This project has no test infrastructure (per CLAUDE.md). Each task verifies correctness via build + manual verification. Establish test targets as a future improvement.

---

## File Structure

### New Directory: `OpenWhisper/AI/`

**Core (protocol + registry + routing):**
- `AIProvider.swift` — `AIProvider` protocol, `AICapability`, `ProviderType`, `ProviderStatus`, `AIRequest`, `AIResponse` enums/structs
- `ProviderRegistry.swift` — `ProviderRegistry` class: registration, discovery, health checks, memory tracking, suggestion scoring
- `TaskRouter.swift` — `AITask` enum, `TaskAssignment`, `TaskRouter` class with layered resolution

**Backends:**
- `MLXModelManager.swift` — Curated model catalog, model loading/unloading via MLXLLM, provider registration
- `MLXDownloadManager.swift` — HuggingFace download with pause/resume, checksums, progress
- `OllamaProvider.swift` — Ollama detection, model discovery, HTTP API wrapper
- `ClaudeProvider.swift` — Anthropic API: key validation, model discovery, inference
- `GPTProvider.swift` — OpenAI API: key validation, model discovery, inference
- `GeminiProvider.swift` — Google AI API: key validation, model discovery, inference
- `GrokProvider.swift` — xAI API: key validation, model discovery, inference
- `CommercialKeyManager.swift` — Keychain CRUD, format validation, connection testing at 3 depths

**Council:**
- `CouncilConfig.swift` — `CouncilConfig` data model
- `CouncilOrchestrator.swift` — Three-stage council execution (opinions → review → synthesis)
- `CouncilStore.swift` — JSON persistence for named councils

**Care Model:**
- `CareModelService.swift` — Context polling, task prediction, model pre-loading

### New Directory: `OpenWhisper/Views/AI/`

- `AIProvidersSettingsView.swift` — Container with sub-tab navigation
- `LocalModelsSettingsView.swift` — Model list, memory bar, download controls
- `APIKeysSettingsView.swift` — Key input, validation indicators, test connection
- `OllamaSettingsView.swift` — Detection status, discovered models
- `CouncilsSettingsView.swift` — Council CRUD, member picker, chairman selector
- `TaskRoutingSettingsView.swift` — Global default + per-task overrides with suggestions
- `CareModelSettingsView.swift` — Config, prediction log, enable/disable

### Modified Files

- `project.yml` — Add `mlx-swift-examples` SPM dependency
- `AppState.swift` — Add `ProviderRegistry`, `TaskRouter`, `CareModelService` properties; initialize on launch
- `SettingsView.swift` — Add AI Providers section/tab
- `SettingsTabView.swift` — Wire up AI Providers settings

---

## Task 1: Add MLX SPM Dependency

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add mlx-swift-examples package to project.yml**

Add under the `packages:` section:

```yaml
  mlx-swift-examples:
    url: https://github.com/ml-explore/mlx-swift-examples
    branch: main
```

Add to `dependencies:` under the OpenWhisper target:

```yaml
      - package: mlx-swift-examples
        product: MLXLLM
```

- [ ] **Step 2: Regenerate Xcode project and build**

```bash
cd "/Users/yishai/Documents/Warp Coding Projects/Open Wispr"
xcodegen generate
xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds. MLX package resolves and links.

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "feat: add mlx-swift-examples SPM dependency for local LLM inference"
```

---

## Task 2: Core Protocol & Types

**Files:**
- Create: `OpenWhisper/AI/AIProvider.swift`

- [ ] **Step 1: Create the AI directory**

```bash
mkdir -p "OpenWhisper/AI"
```

- [ ] **Step 2: Write AIProvider.swift with all core types**

```swift
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
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/AI/AIProvider.swift
git commit -m "feat: add AIProvider protocol, capabilities, task definitions, and core types"
```

---

## Task 3: Provider Registry

**Files:**
- Create: `OpenWhisper/AI/ProviderRegistry.swift`

- [ ] **Step 1: Write ProviderRegistry.swift**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class ProviderRegistry {

    // MARK: - State

    private(set) var providers: [String: any AIProvider] = [:]
    private(set) var performanceHistory: [String: [AITask: PerformanceRecord]] = [:]

    var memoryBudget: Int {
        get { UserDefaults.standard.integer(forKey: "aiMemoryBudget").nonZeroOr(defaultMemoryBudget) }
        set { UserDefaults.standard.set(newValue, forKey: "aiMemoryBudget") }
    }

    // MARK: - Computed

    var availableProviders: [any AIProvider] {
        Array(providers.values).sorted { $0.name < $1.name }
    }

    var loadedProviders: [any AIProvider] {
        providers.values.filter { $0.status == .loaded }
    }

    var totalMemoryUsage: Int {
        loadedProviders.compactMap(\.memoryFootprint).reduce(0, +)
    }

    private var defaultMemoryBudget: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.8)
    }

    // MARK: - Registration

    func register(_ provider: any AIProvider) {
        providers[provider.id] = provider
    }

    func unregister(id: String) {
        providers.removeValue(forKey: id)
    }

    func provider(for id: String) -> (any AIProvider)? {
        providers[id]
    }

    // MARK: - Discovery

    func providers(matching capabilities: Set<AICapability>) -> [any AIProvider] {
        availableProviders.filter { provider in
            capabilities.isSubset(of: provider.capabilities)
        }
    }

    func suggest(for task: AITask) -> [ScoredSuggestion] {
        let required = task.requiredCapabilities
        return availableProviders.compactMap { provider in
            let overlap = provider.capabilities.intersection(required)
            guard !overlap.isEmpty else { return nil }
            let capabilityScore = Double(overlap.count) / Double(required.count)
            let loadBonus: Double = provider.status == .loaded ? 0.1 : 0.0
            let historyBonus = performanceBonus(for: provider.id, task: task)
            let score = min(1.0, capabilityScore + loadBonus + historyBonus)
            let explanation = describeMatch(provider: provider, task: task, overlap: overlap)
            return ScoredSuggestion(
                providerID: provider.id,
                providerName: provider.name,
                score: score,
                explanation: explanation
            )
        }.sorted { $0.score > $1.score }
    }

    func suggestCouncil(for task: AITask) -> CouncilSuggestion? {
        let suggestions = suggest(for: task)
        guard suggestions.count >= 2 else { return nil }
        let members = Array(suggestions.prefix(3))
        let chairman = members.first!
        return CouncilSuggestion(
            memberProviderIDs: members.map(\.providerID),
            chairmanProviderID: chairman.providerID,
            explanation: "Council of top \(members.count) providers for \(task.displayName)"
        )
    }

    // MARK: - Health

    func healthCheck(id: String) async -> HealthStatus {
        guard let provider = providers[id] else {
            return .unhealthy(error: "Provider not found")
        }
        if provider.status == .loaded {
            return .healthy
        } else if provider.status == .error {
            return .unhealthy(error: "Provider in error state")
        }
        return .degraded(reason: "Provider not loaded")
    }

    // MARK: - Performance Tracking

    func recordPerformance(providerID: String, task: AITask, latencyMs: Int, accepted: Bool) {
        var records = performanceHistory[providerID, default: [:]]
        var record = records[task, default: PerformanceRecord()]
        record.totalRequests += 1
        record.totalLatencyMs += latencyMs
        if accepted { record.acceptedCount += 1 }
        records[task] = record
        performanceHistory[providerID] = records
    }

    // MARK: - Memory

    func canLoad(memoryFootprint: Int) -> Bool {
        totalMemoryUsage + memoryFootprint <= memoryBudget
    }

    // MARK: - Private

    private func performanceBonus(for providerID: String, task: AITask) -> Double {
        guard let record = performanceHistory[providerID]?[task],
              record.totalRequests > 0 else { return 0.0 }
        let acceptRate = Double(record.acceptedCount) / Double(record.totalRequests)
        return acceptRate * 0.15
    }

    private func describeMatch(provider: any AIProvider, task: AITask, overlap: Set<AICapability>) -> String {
        let capNames = overlap.map(\.rawValue).sorted().joined(separator: ", ")
        return "\(provider.name) — matches: \(capNames)"
    }
}

// MARK: - Supporting Types

struct PerformanceRecord: Codable, Sendable {
    var totalRequests: Int = 0
    var totalLatencyMs: Int = 0
    var acceptedCount: Int = 0

    var averageLatencyMs: Int {
        totalRequests > 0 ? totalLatencyMs / totalRequests : 0
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self != 0 ? self : fallback
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/ProviderRegistry.swift
git commit -m "feat: add ProviderRegistry with discovery, suggestions, health checks, memory tracking"
```

---

## Task 4: Task Router

**Files:**
- Create: `OpenWhisper/AI/TaskRouter.swift`

- [ ] **Step 1: Write TaskRouter.swift**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class TaskRouter {

    // MARK: - State

    var globalDefault: TaskAssignment?
    var perTaskOverrides: [AITask: TaskAssignment] = [:]

    private let storageURL: URL

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let aiDir = appSupport.appendingPathComponent("OpenWhisper/AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        self.storageURL = aiDir.appendingPathComponent("task-routing.json")
        load()
    }

    // MARK: - Resolution

    func resolve(task: AITask) -> TaskAssignment? {
        perTaskOverrides[task] ?? globalDefault
    }

    // MARK: - Configuration

    func setGlobalDefault(_ assignment: TaskAssignment?) {
        globalDefault = assignment
        save()
    }

    func setOverride(for task: AITask, assignment: TaskAssignment?) {
        if let assignment {
            perTaskOverrides[task] = assignment
        } else {
            perTaskOverrides.removeValue(forKey: task)
        }
        save()
    }

    func clearOverride(for task: AITask) {
        perTaskOverrides.removeValue(forKey: task)
        save()
    }

    func clearAllOverrides() {
        perTaskOverrides.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        let data = TaskRoutingData(
            globalDefault: globalDefault,
            overrides: perTaskOverrides
        )
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: storageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(TaskRoutingData.self, from: data) else { return }
        globalDefault = decoded.globalDefault
        perTaskOverrides = decoded.overrides
    }
}

// MARK: - Persistence Model

private struct TaskRoutingData: Codable {
    let globalDefault: TaskAssignment?
    let overrides: [AITask: TaskAssignment]
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/TaskRouter.swift
git commit -m "feat: add TaskRouter with layered config (global default + per-task overrides) and JSON persistence"
```

---

## Task 5: Council Data Model & Store

**Files:**
- Create: `OpenWhisper/AI/CouncilConfig.swift`
- Create: `OpenWhisper/AI/CouncilStore.swift`

- [ ] **Step 1: Write CouncilConfig.swift**

```swift
import Foundation

struct CouncilConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var memberProviderIDs: [String]
    var chairmanProviderID: String
    var reviewAnonymized: Bool
    var timeoutSeconds: TimeInterval
    var costWarningThreshold: Double?

    init(
        id: UUID = UUID(),
        name: String,
        memberProviderIDs: [String],
        chairmanProviderID: String,
        reviewAnonymized: Bool = true,
        timeoutSeconds: TimeInterval = 60,
        costWarningThreshold: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.memberProviderIDs = memberProviderIDs
        self.chairmanProviderID = chairmanProviderID
        self.reviewAnonymized = reviewAnonymized
        self.timeoutSeconds = timeoutSeconds
        self.costWarningThreshold = costWarningThreshold
    }
}
```

- [ ] **Step 2: Write CouncilStore.swift**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class CouncilStore {

    private(set) var councils: [CouncilConfig] = []
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let aiDir = appSupport.appendingPathComponent("OpenWhisper/AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        self.storageURL = aiDir.appendingPathComponent("councils.json")
        load()
    }

    func council(for id: UUID) -> CouncilConfig? {
        councils.first { $0.id == id }
    }

    func add(_ council: CouncilConfig) {
        councils.append(council)
        save()
    }

    func update(_ council: CouncilConfig) {
        if let index = councils.firstIndex(where: { $0.id == council.id }) {
            councils[index] = council
            save()
        }
    }

    func delete(id: UUID) {
        councils.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(councils) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([CouncilConfig].self, from: data) else { return }
        councils = decoded
    }
}
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/AI/CouncilConfig.swift OpenWhisper/AI/CouncilStore.swift
git commit -m "feat: add CouncilConfig data model and CouncilStore with JSON persistence"
```

---

## Task 6: Council Orchestrator

**Files:**
- Create: `OpenWhisper/AI/CouncilOrchestrator.swift`

- [ ] **Step 1: Write CouncilOrchestrator.swift**

```swift
import Foundation

@MainActor
final class CouncilOrchestrator {

    private let registry: ProviderRegistry
    private var currentTask: Task<Void, Never>?

    enum Stage: Sendable {
        case firstOpinions(completed: Int, total: Int)
        case peerReview(completed: Int, total: Int)
        case chairmanSynthesis
        case complete
    }

    init(registry: ProviderRegistry) {
        self.registry = registry
    }

    func execute(
        _ request: AIRequest,
        council: CouncilConfig,
        onStageUpdate: @escaping @Sendable (Stage) -> Void
    ) async throws -> AIResponse {

        let members = council.memberProviderIDs.compactMap { registry.provider(for: $0) }
        guard let chairman = registry.provider(for: council.chairmanProviderID) else {
            throw CouncilError.chairmanUnavailable
        }
        guard !members.isEmpty else {
            throw CouncilError.noMembers
        }

        // Stage 1: First Opinions
        let opinions = try await collectOpinions(
            request: request,
            members: members,
            timeout: council.timeoutSeconds,
            onProgress: { completed, total in
                onStageUpdate(.firstOpinions(completed: completed, total: total))
            }
        )

        // Stage 2: Peer Review
        onStageUpdate(.peerReview(completed: 0, total: members.count))
        let reviews = try await collectReviews(
            opinions: opinions,
            members: members,
            anonymized: council.reviewAnonymized,
            timeout: council.timeoutSeconds,
            onProgress: { completed, total in
                onStageUpdate(.peerReview(completed: completed, total: total))
            }
        )

        // Stage 3: Chairman Synthesis
        onStageUpdate(.chairmanSynthesis)
        let synthesis = try await synthesize(
            request: request,
            opinions: opinions,
            reviews: reviews,
            chairman: chairman,
            anonymized: council.reviewAnonymized
        )

        onStageUpdate(.complete)
        return synthesis
    }

    /// Streaming variant — runs stages 1-2 internally, streams only the chairman's Stage 3 output.
    /// Status updates for stages 1-2 are reported via onStageUpdate callback.
    func executeWithStreaming(
        _ request: AIRequest,
        council: CouncilConfig,
        onStageUpdate: @escaping @Sendable (Stage) -> Void
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    // Run full execute — chairman's text comes back as a single response
                    // For true token-level streaming, the chairman provider would need a streaming API
                    let response = try await execute(request, council: council, onStageUpdate: onStageUpdate)
                    // Simulate streaming by yielding the full text
                    // TODO: Replace with actual token-level streaming when AIProvider supports it
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func cancelExecution() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Stage 1: First Opinions

    private func collectOpinions(
        request: AIRequest,
        members: [any AIProvider],
        timeout: TimeInterval,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [(providerID: String, response: AIResponse)] {
        var results: [(providerID: String, response: AIResponse)] = []
        let total = members.count

        await withTaskGroup(of: (String, AIResponse?).self) { group in
            for member in members {
                group.addTask {
                    do {
                        let response = try await withThrowingTaskGroup(of: AIResponse.self) { inner in
                            inner.addTask { try await member.complete(request) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw CouncilError.memberTimeout(member.id)
                            }
                            let result = try await inner.next()!
                            inner.cancelAll()
                            return result
                        }
                        return (member.id, response)
                    } catch {
                        return (member.id, nil)
                    }
                }
            }

            for await (id, response) in group {
                if let response {
                    results.append((providerID: id, response: response))
                }
                onProgress(results.count, total)
            }
        }

        guard !results.isEmpty else {
            throw CouncilError.allMembersTimedOut
        }
        return results
    }

    // MARK: - Stage 2: Peer Review

    private func collectReviews(
        opinions: [(providerID: String, response: AIResponse)],
        members: [any AIProvider],
        anonymized: Bool,
        timeout: TimeInterval,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [(providerID: String, review: String)] {
        var reviews: [(providerID: String, review: String)] = []
        let respondedMembers = members.filter { m in opinions.contains { $0.providerID == m.id } }
        let total = respondedMembers.count

        let reviewPrompt = buildReviewPrompt(opinions: opinions, anonymized: anonymized)

        await withTaskGroup(of: (String, String?).self) { group in
            for member in respondedMembers {
                group.addTask {
                    let request = AIRequest(
                        prompt: reviewPrompt,
                        systemPrompt: "You are reviewing responses from other AI models. Provide a critique and ranking of each response.",
                        maxTokens: 1000,
                        temperature: 0.3,
                        task: request.task
                    )
                    do {
                        let response = try await withThrowingTaskGroup(of: AIResponse.self) { inner in
                            inner.addTask { try await member.complete(request) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw CouncilError.memberTimeout(member.id)
                            }
                            let result = try await inner.next()!
                            inner.cancelAll()
                            return result
                        }
                        return (member.id, response.text)
                    } catch {
                        return (member.id, nil)
                    }
                }
            }

            for await (id, review) in group {
                if let review {
                    reviews.append((providerID: id, review: review))
                }
                onProgress(reviews.count, total)
            }
        }

        return reviews
    }

    // MARK: - Stage 3: Chairman Synthesis

    private func synthesize(
        request: AIRequest,
        opinions: [(providerID: String, response: AIResponse)],
        reviews: [(providerID: String, review: String)],
        chairman: any AIProvider,
        anonymized: Bool
    ) async throws -> AIResponse {
        let synthesisPrompt = buildSynthesisPrompt(
            originalRequest: request.prompt,
            opinions: opinions,
            reviews: reviews,
            anonymized: anonymized
        )

        let synthesisRequest = AIRequest(
            prompt: synthesisPrompt,
            systemPrompt: "You are the chairman of an AI council. Synthesize the best final answer from the responses and peer reviews provided. Focus on accuracy and completeness.",
            maxTokens: request.maxTokens,
            temperature: 0.4,
            task: request.task
        )

        return try await chairman.complete(synthesisRequest)
    }

    // MARK: - Prompt Building

    private func buildReviewPrompt(
        opinions: [(providerID: String, response: AIResponse)],
        anonymized: Bool
    ) -> String {
        var prompt = "Review the following responses and provide a critique and ranking:\n\n"
        for (index, opinion) in opinions.enumerated() {
            let label = anonymized ? "Response \(Character(UnicodeScalar(65 + index)!))" : opinion.providerID
            prompt += "### \(label)\n\(opinion.response.text)\n\n"
        }
        prompt += "Provide your critique of each response and rank them from best to worst."
        return prompt
    }

    private func buildSynthesisPrompt(
        originalRequest: String,
        opinions: [(providerID: String, response: AIResponse)],
        reviews: [(providerID: String, review: String)],
        anonymized: Bool
    ) -> String {
        var prompt = "Original question: \(originalRequest)\n\n"
        prompt += "## Responses\n\n"
        for (index, opinion) in opinions.enumerated() {
            let label = anonymized ? "Response \(Character(UnicodeScalar(65 + index)!))" : opinion.providerID
            prompt += "### \(label)\n\(opinion.response.text)\n\n"
        }
        prompt += "## Peer Reviews\n\n"
        for (index, review) in reviews.enumerated() {
            let label = anonymized ? "Reviewer \(Character(UnicodeScalar(65 + index)!))" : review.providerID
            prompt += "### \(label)\n\(review.review)\n\n"
        }
        prompt += "Based on all responses and reviews, synthesize the best final answer."
        return prompt
    }
}

// MARK: - Errors

enum CouncilError: LocalizedError {
    case chairmanUnavailable
    case noMembers
    case memberTimeout(String)
    case allMembersTimedOut

    var errorDescription: String? {
        switch self {
        case .chairmanUnavailable: return "Chairman model is not available"
        case .noMembers: return "No council members available"
        case .memberTimeout(let id): return "Council member \(id) timed out"
        case .allMembersTimedOut: return "All council members timed out"
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/CouncilOrchestrator.swift
git commit -m "feat: add CouncilOrchestrator with 3-stage execution (opinions, review, synthesis)"
```

---

## Task 7: Commercial Key Manager

**Files:**
- Create: `OpenWhisper/AI/CommercialKeyManager.swift`

- [ ] **Step 1: Write CommercialKeyManager.swift**

```swift
import Foundation
import Security

@MainActor
@Observable
final class CommercialKeyManager {

    enum Service: String, CaseIterable, Sendable {
        case claude = "com.openwhisper.api.claude"
        case gpt = "com.openwhisper.api.gpt"
        case gemini = "com.openwhisper.api.gemini"
        case grok = "com.openwhisper.api.grok"

        var displayName: String {
            switch self {
            case .claude: return "Claude (Anthropic)"
            case .gpt: return "GPT (OpenAI)"
            case .gemini: return "Gemini (Google)"
            case .grok: return "Grok (xAI)"
            }
        }

        var keyPattern: String {
            switch self {
            case .claude: return "^sk-ant-.+"
            case .gpt: return "^sk-.+"
            case .gemini: return "^AI.+"
            case .grok: return "^xai-.+"
            }
        }

        var dashboardURL: URL? {
            switch self {
            case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
            case .gpt: return URL(string: "https://platform.openai.com/api-keys")
            case .gemini: return URL(string: "https://aistudio.google.com/apikey")
            case .grok: return URL(string: "https://console.x.ai")
            }
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
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/CommercialKeyManager.swift
git commit -m "feat: add CommercialKeyManager with Keychain storage, format validation, 3-depth connection testing"
```

---

## Task 8: Commercial Providers (Claude, GPT, Gemini, Grok)

**Files:**
- Create: `OpenWhisper/AI/ClaudeProvider.swift`
- Create: `OpenWhisper/AI/GPTProvider.swift`
- Create: `OpenWhisper/AI/GeminiProvider.swift`
- Create: `OpenWhisper/AI/GrokProvider.swift`

- [ ] **Step 1: Write ClaudeProvider.swift**

Implements `AIProvider` for Anthropic's Claude API. Uses Messages API with the stored API key. The other three providers follow the same pattern with service-specific API differences.

```swift
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
```

- [ ] **Step 2: Write GPTProvider.swift**

Same pattern, OpenAI chat completions API:

```swift
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
```

- [ ] **Step 3: Write GeminiProvider.swift**

Google Generative AI API:

```swift
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
```

- [ ] **Step 4: Write GrokProvider.swift**

xAI API (OpenAI-compatible format):

```swift
import Foundation

@MainActor
@Observable
final class GrokProvider: AIProvider {
    let id: String
    let name: String
    let providerType: ProviderType = .commercial
    let capabilities: Set<AICapability>
    var status: ProviderStatus = .available
    let memoryFootprint: Int? = nil

    private let modelID: String
    private let keyManager: CommercialKeyManager

    init(modelID: String, name: String, capabilities: Set<AICapability>, keyManager: CommercialKeyManager) {
        self.id = "grok-\(modelID)"
        self.modelID = modelID
        self.name = name
        self.capabilities = capabilities
        self.keyManager = keyManager
    }

    nonisolated func load() async throws { }
    nonisolated func unload() async { }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyManager.getKey(for: .grok) else {
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

        var urlRequest = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
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
```

- [ ] **Step 5: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add OpenWhisper/AI/ClaudeProvider.swift OpenWhisper/AI/GPTProvider.swift \
  OpenWhisper/AI/GeminiProvider.swift OpenWhisper/AI/GrokProvider.swift
git commit -m "feat: add commercial API providers (Claude, GPT, Gemini, Grok) implementing AIProvider"
```

---

## Task 9: MLX Download Manager

**Files:**
- Create: `OpenWhisper/AI/MLXDownloadManager.swift`

- [ ] **Step 1: Write MLXDownloadManager.swift**

Handles downloading MLX model files from HuggingFace with pause/resume and checksum verification. This is a standalone utility used by `MLXModelManager`.

```swift
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
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]

    private let modelsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.modelsDirectory = appSupport.appendingPathComponent("OpenWhisper/Models/MLX", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
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

    func download(modelID: String, repoID: String) async throws {
        let destDir = modelPath(for: modelID)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Fetch file list from HuggingFace API (includes SHA256 in "oid" field for LFS files)
        let filesURL = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main")!
        let (data, _) = try await URLSession.shared.data(from: filesURL)
        guard let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.invalidFileList
        }

        let fileEntries = files.compactMap { entry -> (name: String, sha256: String?, size: Int64)? in
            guard let path = entry["path"] as? String,
                  !path.hasPrefix("."), !path.contains("/") else { return nil }
            let sha = (entry["lfs"] as? [String: Any])?["oid"] as? String  // LFS SHA256
                ?? entry["oid"] as? String  // Git SHA
            let size = (entry["lfs"] as? [String: Any])?["size"] as? Int64
                ?? entry["size"] as? Int64 ?? 0
            return (name: path, sha256: sha, size: size)
        }

        for entry in fileEntries {
            let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(entry.name)")!
            let destFile = destDir.appendingPathComponent(entry.name)
            let partialFile = destDir.appendingPathComponent(entry.name + ".partial")

            // Skip already downloaded files
            if FileManager.default.fileExists(atPath: destFile.path) { continue }

            // Resume support: check for partial download
            var request = URLRequest(url: fileURL)
            var existingSize: Int64 = 0
            if FileManager.default.fileExists(atPath: partialFile.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partialFile.path),
               let size = attrs[.size] as? Int64 {
                existingSize = size
                request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
            }

            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            let outputHandle: FileHandle
            if existingSize > 0, (response as? HTTPURLResponse)?.statusCode == 206 {
                // Resuming — append to existing partial file
                outputHandle = try FileHandle(forWritingTo: partialFile)
                outputHandle.seekToEndOfFile()
            } else {
                // Fresh download
                FileManager.default.createFile(atPath: partialFile.path, contents: nil)
                outputHandle = try FileHandle(forWritingTo: partialFile)
            }

            // Stream download
            for try await byte in asyncBytes {
                outputHandle.write(Data([byte]))
            }
            outputHandle.closeFile()

            // SHA256 verification (if available from HF metadata)
            if let expectedSHA = entry.sha256, expectedSHA.count == 64 {
                let fileData = try Data(contentsOf: partialFile)
                let computedSHA = SHA256Hash(data: fileData)
                if computedSHA != expectedSHA {
                    try? FileManager.default.removeItem(at: partialFile)
                    throw DownloadError.checksumMismatch
                }
            }

            // Move partial to final
            try FileManager.default.moveItem(at: partialFile, to: destFile)

            // Update progress
            activeDownloads[modelID] = DownloadProgress(
                modelID: modelID,
                bytesDownloaded: existingSize + (entry.size - existingSize),
                totalBytes: entry.size
            )
        }

        activeDownloads.removeValue(forKey: modelID)

        // Write metadata
        let metadata: [String: Any] = [
            "repoID": repoID,
            "downloadDate": ISO8601DateFormatter().string(from: Date()),
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: destDir.appendingPathComponent(".metadata.json"))
    }

    /// Compute SHA256 hash of data
    private func SHA256Hash(data: Data) -> String {
        import CommonCrypto  // Note: use CC_SHA256 or CryptoKit's SHA256
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    // Note: The implementer should use CryptoKit's SHA256 (import CryptoKit; SHA256.hash(data:))
    // instead of CommonCrypto for cleaner Swift code. The above is pseudocode for the algorithm.

    func deleteModel(modelID: String) throws {
        let path = modelPath(for: modelID)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

enum DownloadError: LocalizedError {
    case invalidFileList
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidFileList: return "Failed to get file list from HuggingFace"
        case .checksumMismatch: return "Downloaded file checksum doesn't match"
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/MLXDownloadManager.swift
git commit -m "feat: add MLXDownloadManager for HuggingFace model downloads with metadata tracking"
```

---

## Task 10: MLX Model Manager

**Files:**
- Create: `OpenWhisper/AI/MLXModelManager.swift`

- [ ] **Step 1: Write MLXModelManager.swift**

Manages the curated model catalog, loading/unloading via MLXLLM, and registers each as an `AIProvider`. Note: the actual MLXLLM import and inference calls depend on the `mlx-swift-examples` package API. The structure below follows the MLXLLM module's patterns.

```swift
import Foundation
import SwiftUI
import MLXLLM
import MLX

struct MLXModelCatalogEntry: Sendable {
    let id: String
    let name: String
    let repoID: String
    let parameterCount: String
    let memoryGB: Int
    let capabilities: Set<AICapability>
}

@MainActor
@Observable
final class MLXModelManager {

    static let catalog: [MLXModelCatalogEntry] = [
        MLXModelCatalogEntry(id: "llama-3.1-70b-4bit", name: "Llama 3.1 70B", repoID: "mlx-community/Meta-Llama-3.1-70B-Instruct-4bit", parameterCount: "70B", memoryGB: 45, capabilities: [.reasoning, .codeGeneration, .longContext]),
        MLXModelCatalogEntry(id: "qwen-2.5-72b-4bit", name: "Qwen 2.5 72B", repoID: "mlx-community/Qwen2.5-72B-Instruct-4bit", parameterCount: "72B", memoryGB: 46, capabilities: [.multilingual, .translation, .longContext]),
        MLXModelCatalogEntry(id: "kimi-dev-72b-4bit", name: "Kimi-Dev-72B", repoID: "mlx-community/Kimi-Dev-72B-4bit", parameterCount: "72B", memoryGB: 46, capabilities: [.codeGeneration, .reasoning, .longContext]),
        MLXModelCatalogEntry(id: "glm-4.6-4bit", name: "GLM-4.6", repoID: "mlx-community/GLM-4.6-4bit", parameterCount: "355B MoE", memoryGB: 40, capabilities: [.reasoning, .creativity, .multilingual]),
        MLXModelCatalogEntry(id: "deepseek-r1-32b-4bit", name: "DeepSeek-R1 32B", repoID: "mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit", parameterCount: "32B", memoryGB: 20, capabilities: [.reasoning, .codeGeneration]),
        MLXModelCatalogEntry(id: "gemma-2-27b-4bit", name: "Gemma 2 27B", repoID: "mlx-community/gemma-2-27b-it-4bit", parameterCount: "27B", memoryGB: 17, capabilities: [.editorialAnalysis, .creativity]),
        MLXModelCatalogEntry(id: "phi-4-14b-4bit", name: "Phi-4 14B", repoID: "mlx-community/phi-4-4bit", parameterCount: "14B", memoryGB: 9, capabilities: [.fastInference, .reasoning]),
        MLXModelCatalogEntry(id: "mixtral-8x22b-4bit", name: "Mixtral 8x22B", repoID: "mlx-community/Mixtral-8x22B-Instruct-v0.1-4bit", parameterCount: "MoE 140B", memoryGB: 85, capabilities: [.reasoning, .creativity, .longContext]),
    ]

    let downloadManager = MLXDownloadManager()
    private var loadedModels: [String: ModelContainer] = [:]
    private(set) var providers: [String: MLXProvider] = [:]

    func createProviders() -> [MLXProvider] {
        Self.catalog.map { entry in
            let provider = MLXProvider(
                catalogEntry: entry,
                modelManager: self
            )
            providers[entry.id] = provider
            return provider
        }
    }

    func loadModel(id: String) async throws -> ModelContainer {
        if let existing = loadedModels[id] { return existing }

        guard let entry = Self.catalog.first(where: { $0.id == id }) else {
            throw MLXModelError.modelNotFound(id)
        }

        let modelPath = downloadManager.modelPath(for: id)
        let configuration = ModelConfiguration(directory: modelPath)
        let container = try await MLXLLM.loadModelContainer(configuration: configuration)
        loadedModels[id] = container
        return container
    }

    func unloadModel(id: String) {
        loadedModels.removeValue(forKey: id)
    }

    func isLoaded(id: String) -> Bool {
        loadedModels[id] != nil
    }

    func generate(modelID: String, prompt: String, systemPrompt: String?, maxTokens: Int?) async throws -> String {
        let container = try await loadModel(id: modelID)

        let userMessages: [[String: String]]
        if let systemPrompt {
            userMessages = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ]
        } else {
            userMessages = [
                ["role": "user", "content": prompt],
            ]
        }

        let chatPrompt = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(messages: userMessages)
        }

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(prompt: .init(prompt: chatPrompt))
            var output = ""
            let maxTok = maxTokens ?? 2048
            for try await token in try MLXLMCommon.generate(input: input, parameters: .init(temperature: 0.7), context: context) {
                output += token.chunk
                if token.tokenCount >= maxTok { break }
            }
            return output
        }

        return result
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
        self.memoryFootprint = catalogEntry.memoryGB * 1_073_741_824 // GB to bytes

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

enum MLXModelError: LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "MLX model not found: \(id)"
        }
    }
}
```

**Note:** The exact MLXLLM API (`ModelContainer`, `loadModelContainer`, `generate`) may need adjustment based on the current version of `mlx-swift-examples`. The implementer should check the package's API and adapt the method signatures accordingly. The structure and flow are correct.

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds. If MLXLLM API differs from what's shown, adapt to match the actual package API.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/MLXModelManager.swift
git commit -m "feat: add MLXModelManager with curated 8-model catalog, MLXLLM inference, and MLXProvider"
```

---

## Task 11: Ollama Provider

**Files:**
- Create: `OpenWhisper/AI/OllamaProvider.swift`

- [ ] **Step 1: Write OllamaProvider.swift**

```swift
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
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/OllamaProvider.swift
git commit -m "feat: add OllamaDiscovery and OllamaModelProvider for optional Ollama integration"
```

---

## Task 12: Care Model Service

**Files:**
- Create: `OpenWhisper/AI/CareModelService.swift`

- [ ] **Step 1: Write CareModelService.swift**

```swift
import Foundation
import SwiftUI

struct PredictedTask: Sendable {
    let task: AITask
    let confidence: Double
    let reason: String
}

@MainActor
@Observable
final class CareModelService {

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "careModelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "careModelEnabled") }
    }

    var pollInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "careModelPollInterval")
            return val > 0 ? val : 5.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "careModelPollInterval") }
    }

    var keepAliveTimeout: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "careModelKeepAlive")
            return val > 0 ? val : 300.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "careModelKeepAlive") }
    }

    private(set) var lastPredictions: [PredictedTask] = []
    private(set) var predictionLog: [PredictionLogEntry] = []
    private(set) var isAssessing = false

    private var pollTask: Task<Void, Never>?
    private var lastModelUseTimes: [String: Date] = [:]

    private let registry: ProviderRegistry
    private let taskRouter: TaskRouter
    private let historyStore: HistoryStore
    private let cursorPositionService: CursorPositionService

    init(registry: ProviderRegistry, taskRouter: TaskRouter, historyStore: HistoryStore, cursorPositionService: CursorPositionService) {
        self.registry = registry
        self.taskRouter = taskRouter
        self.historyStore = historyStore
        self.cursorPositionService = cursorPositionService
    }

    // MARK: - Prediction Logging

    struct PredictionLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let predictions: [PredictedTask]
        var outcomes: [AITask: Bool] = [:] // task -> was it actually used?
    }

    func logPredictionOutcome(predicted: AITask, actuallyUsed: Bool) {
        guard var lastEntry = predictionLog.last else { return }
        lastEntry.outcomes[predicted] = actuallyUsed
        predictionLog[predictionLog.count - 1] = lastEntry
    }

    func start() {
        guard isEnabled else { return }
        stop()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isAssessing {
                    await self.runAssessment()
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func recordModelUse(providerID: String) {
        lastModelUseTimes[providerID] = Date()
    }

    // MARK: - Assessment

    private func runAssessment() async {
        isAssessing = true
        defer { isAssessing = false }

        guard let assignment = taskRouter.resolve(task: .careModel) else { return }

        let provider: (any AIProvider)?
        switch assignment.mode {
        case .single(let providerID):
            provider = registry.provider(for: providerID)
        case .council:
            // Care model should be a single model for speed
            provider = nil
        }

        guard let provider, provider.status == .loaded else { return }

        let contextSnapshot = buildContextSnapshot()
        let request = AIRequest(
            prompt: contextSnapshot,
            systemPrompt: """
            You are a predictive context model. Based on the user's current context, predict which AI tasks are likely needed soon.
            Return a JSON array of predictions: [{"task": "<AITask rawValue>", "confidence": 0.0-1.0, "reason": "brief explanation"}]
            Only return the JSON array, nothing else.
            """,
            maxTokens: 500,
            temperature: 0.3,
            task: .careModel
        )

        do {
            let response = try await provider.complete(request)
            if let predictions = parsePredictions(response.text) {
                lastPredictions = predictions
                predictionLog.append(PredictionLogEntry(date: Date(), predictions: predictions))
                if predictionLog.count > 100 { predictionLog.removeFirst() }
                await preloadForPredictions(predictions)
            }
        } catch {
            // Silently fail — care model is best-effort
        }
    }

    private func buildContextSnapshot() -> String {
        var parts: [String] = []

        // Accessibility context — active app, window, cursor text
        if let context = cursorPositionService.lastCapturedContext {
            if let appName = context.applicationName {
                parts.append("Active app: \(appName)")
            }
            if let bundleID = context.bundleIdentifier {
                parts.append("Bundle ID: \(bundleID)")
            }
            if let textBefore = context.textBeforeCursor?.suffix(100) {
                parts.append("Text near cursor: ...\(textBefore)")
            }
            if let selected = context.selectedText, !selected.isEmpty {
                parts.append("Selected text: \(selected.prefix(100))")
            }
        }

        // Recent dictation content
        let recentEntries = historyStore.entries.prefix(5)
        if !recentEntries.isEmpty {
            parts.append("Recent dictations:")
            for entry in recentEntries {
                parts.append("- \(entry.text.prefix(200))")
            }
        }

        // Currently loaded models
        let loaded = registry.loadedProviders.map(\.name)
        if !loaded.isEmpty {
            parts.append("Currently loaded models: \(loaded.joined(separator: ", "))")
        }

        // Time context
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        parts.append("Current time: \(formatter.string(from: Date()))")

        return parts.joined(separator: "\n")
    }

    private func parsePredictions(_ text: String) -> [PredictedTask]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        return json.compactMap { item in
            guard let taskRaw = item["task"] as? String,
                  let task = AITask(rawValue: taskRaw),
                  let confidence = item["confidence"] as? Double,
                  let reason = item["reason"] as? String else { return nil }
            return PredictedTask(task: task, confidence: confidence, reason: reason)
        }
    }

    private func preloadForPredictions(_ predictions: [PredictedTask]) async {
        for prediction in predictions where prediction.confidence > 0.6 {
            guard let assignment = taskRouter.resolve(task: prediction.task) else { continue }
            switch assignment.mode {
            case .single(let providerID):
                guard let provider = registry.provider(for: providerID),
                      provider.status == .available,
                      let footprint = provider.memoryFootprint,
                      registry.canLoad(memoryFootprint: footprint) else { continue }
                try? await provider.load()
            case .council:
                break // Don't pre-load entire councils
            }
        }

        // Unload stale models
        let now = Date()
        for provider in registry.loadedProviders {
            guard provider.providerType == .mlx,
                  let lastUse = lastModelUseTimes[provider.id],
                  now.timeIntervalSince(lastUse) > keepAliveTimeout else { continue }
            // Check if any prediction still needs this model
            let stillNeeded = predictions.contains { p in
                guard let assignment = taskRouter.resolve(task: p.task) else { return false }
                if case .single(let id) = assignment.mode { return id == provider.id }
                return false
            }
            if !stillNeeded {
                await provider.unload()
            }
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds. May need to adjust `historyStore.entries` access based on actual `HistoryStore` API.

- [ ] **Step 3: Commit**

```bash
git add OpenWhisper/AI/CareModelService.swift
git commit -m "feat: add CareModelService with predictive context polling and model pre-loading"
```

---

## Task 13: AppState Integration

**Files:**
- Modify: `OpenWhisper/AppState.swift`

- [ ] **Step 1: Add AI infrastructure properties to AppState**

Add these properties alongside existing service declarations (after line ~40):

```swift
let providerRegistry = ProviderRegistry()
let taskRouter = TaskRouter()
let councilStore = CouncilStore()
let councilOrchestrator: CouncilOrchestrator
let commercialKeyManager = CommercialKeyManager()
let mlxModelManager = MLXModelManager()
let ollamaDiscovery = OllamaDiscovery()
let careModelService: CareModelService
```

Initialize `councilOrchestrator` and `careModelService` in `init()` since they depend on other properties:

```swift
// In init(), after existing initialization:
self.councilOrchestrator = CouncilOrchestrator(registry: providerRegistry)
self.careModelService = CareModelService(
    registry: providerRegistry,
    taskRouter: taskRouter,
    historyStore: historyStore,
    cursorPositionService: cursorPositionService
)

// Register providers
Task {
    await setupAIProviders()
}
```

- [ ] **Step 2: Add setupAIProviders method**

```swift
private func setupAIProviders() async {
    // Register MLX providers
    for provider in mlxModelManager.createProviders() {
        providerRegistry.register(provider)
    }

    // Discover Ollama models
    await ollamaDiscovery.detect()
    for provider in ollamaDiscovery.discoveredModels {
        providerRegistry.register(provider)
    }

    // Register commercial providers for configured keys
    registerCommercialProviders()

    // Start care model
    careModelService.start()
}

private func registerCommercialProviders() {
    Task {
        // Discover and register models for each service that has a key
        await discoverAndRegister(service: .claude)
        await discoverAndRegister(service: .gpt)
        await discoverAndRegister(service: .gemini)
        await discoverAndRegister(service: .grok)
    }
}

private func discoverAndRegister(service: CommercialKeyManager.Service) async {
    guard commercialKeyManager.hasKey(for: service) else { return }

    // Use connection test to discover available models
    let result = await commercialKeyManager.testConnection(for: service, depth: .guided)
    guard result.success else { return }

    let defaultCapabilities: Set<AICapability> = [.reasoning, .creativity, .editorialAnalysis, .codeGeneration, .multilingual]

    for modelID in result.accessibleModels {
        let provider: any AIProvider
        switch service {
        case .claude:
            provider = ClaudeProvider(modelID: modelID, name: "Claude: \(modelID)", capabilities: defaultCapabilities.union([.longContext]), keyManager: commercialKeyManager)
        case .gpt:
            provider = GPTProvider(modelID: modelID, name: "GPT: \(modelID)", capabilities: defaultCapabilities, keyManager: commercialKeyManager)
        case .gemini:
            provider = GeminiProvider(modelID: modelID, name: "Gemini: \(modelID)", capabilities: defaultCapabilities.union([.fastInference]), keyManager: commercialKeyManager)
        case .grok:
            provider = GrokProvider(modelID: modelID, name: "Grok: \(modelID)", capabilities: defaultCapabilities, keyManager: commercialKeyManager)
        }
        providerRegistry.register(provider)
    }
}
```

- [ ] **Step 3: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds. The AI infrastructure is now wired into the app lifecycle.

- [ ] **Step 4: Commit**

```bash
git add OpenWhisper/AppState.swift
git commit -m "feat: integrate AI provider infrastructure into AppState with provider registration"
```

---

## Task 14: Settings UI — AI Providers Container & Local Models Tab

**Files:**
- Create: `OpenWhisper/Views/AI/AIProvidersSettingsView.swift`
- Create: `OpenWhisper/Views/AI/LocalModelsSettingsView.swift`
- Modify: `OpenWhisper/Views/SettingsView.swift` — add AI Providers tab

- [ ] **Step 1: Create Views/AI directory**

```bash
mkdir -p "OpenWhisper/Views/AI"
```

- [ ] **Step 2: Write AIProvidersSettingsView.swift**

Container view with tab navigation across the 6 sub-tabs:

```swift
import SwiftUI

enum AISettingsTab: String, CaseIterable {
    case localModels = "Local Models"
    case apiKeys = "API Keys"
    case ollama = "Ollama"
    case councils = "Councils"
    case taskRouting = "Task Routing"
    case careModel = "Care Model"
}

struct AIProvidersSettingsView: View {
    @State private var selectedTab: AISettingsTab = .localModels
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(AISettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12))
                            .foregroundColor(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                selectedTab == tab ?
                                    Color.accentColor.opacity(0.1) : Color.clear
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()

            // Content
            ScrollView {
                switch selectedTab {
                case .localModels:
                    LocalModelsSettingsView(appState: appState)
                case .apiKeys:
                    Text("API Keys settings — coming in next task")
                        .foregroundColor(.secondary)
                        .padding()
                case .ollama:
                    Text("Ollama settings — coming in next task")
                        .foregroundColor(.secondary)
                        .padding()
                case .councils:
                    Text("Councils settings — coming in next task")
                        .foregroundColor(.secondary)
                        .padding()
                case .taskRouting:
                    Text("Task Routing settings — coming in next task")
                        .foregroundColor(.secondary)
                        .padding()
                case .careModel:
                    Text("Care Model settings — coming in next task")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }
}
```

- [ ] **Step 3: Write LocalModelsSettingsView.swift**

```swift
import SwiftUI

struct LocalModelsSettingsView: View {
    let appState: AppState

    private var registry: ProviderRegistry { appState.providerRegistry }
    private var mlxManager: MLXModelManager { appState.mlxModelManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Memory bar
            memoryBar

            // Model list
            ForEach(MLXModelManager.catalog, id: \.id) { entry in
                modelRow(entry)
            }

            // Memory budget
            HStack {
                Text("Memory Budget")
                    .font(.system(size: 12))
                Spacer()
                Text("\(registry.memoryBudget / 1_073_741_824) GB (\(Int(Double(registry.memoryBudget) / Double(ProcessInfo.processInfo.physicalMemory) * 100))%)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var memoryBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Memory Usage")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(registry.totalMemoryUsage / 1_073_741_824) GB / \(registry.memoryBudget / 1_073_741_824) GB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * memoryFraction)
                }
            }
            .frame(height: 8)
        }
    }

    private var memoryFraction: Double {
        guard registry.memoryBudget > 0 else { return 0 }
        return min(1.0, Double(registry.totalMemoryUsage) / Double(registry.memoryBudget))
    }

    private func modelRow(_ entry: MLXModelCatalogEntry) -> some View {
        let provider = registry.provider(for: "mlx-\(entry.id)")

        return HStack {
            Circle()
                .fill(statusColor(provider?.status))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(entry.parameterCount) · ~\(entry.memoryGB) GB · MLX 4-bit")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Capability tags
            HStack(spacing: 4) {
                ForEach(Array(entry.capabilities).prefix(2), id: \.self) { cap in
                    Text(cap.rawValue)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                }
            }

            // Action button
            actionButton(entry, provider: provider)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actionButton(_ entry: MLXModelCatalogEntry, provider: (any AIProvider)?) -> some View {
        let status = provider?.status ?? .notDownloaded
        switch status {
        case .loaded:
            Text("Loaded")
                .font(.system(size: 11))
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
        case .available:
            Button("Load") {
                Task { try? await provider?.load() }
            }
            .font(.system(size: 11))
        case .notDownloaded:
            Button("Download") {
                Task { try? await provider?.load() }
            }
            .font(.system(size: 11))
        case .downloading:
            Text("Downloading...")
                .font(.system(size: 11))
                .foregroundColor(.blue)
        case .loading:
            ProgressView()
                .scaleEffect(0.7)
        case .error:
            Button("Retry") {
                Task { try? await provider?.load() }
            }
            .font(.system(size: 11))
            .foregroundColor(.red)
        }
    }

    private func statusColor(_ status: ProviderStatus?) -> Color {
        switch status {
        case .loaded: return .green
        case .available: return .gray
        case .downloading, .loading: return .blue
        case .error: return .red
        default: return .gray.opacity(0.5)
        }
    }
}
```

- [ ] **Step 4: Add AI Providers to SettingsView**

In `SettingsView.swift`, add a tab or section for AI Providers that renders `AIProvidersSettingsView(appState: appState)`. The exact integration point depends on the current tab structure — read the file and add it alongside existing settings sections.

- [ ] **Step 5: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
```

Expected: Build succeeds. AI Providers tab visible in Settings.

- [ ] **Step 6: Commit**

```bash
git add OpenWhisper/Views/AI/ OpenWhisper/Views/SettingsView.swift
git commit -m "feat: add AI Providers settings container with Local Models tab (memory bar, model list)"
```

---

## Task 15: Settings UI — API Keys Tab

**Files:**
- Create: `OpenWhisper/Views/AI/APIKeysSettingsView.swift`
- Modify: `OpenWhisper/Views/AI/AIProvidersSettingsView.swift` — wire up tab

- [ ] **Step 1: Write APIKeysSettingsView.swift**

View for each commercial service: key input, format validation indicator, test connection button with depth selector, results panel.

- [ ] **Step 2: Wire into AIProvidersSettingsView**

Replace the `.apiKeys` placeholder with `APIKeysSettingsView(appState: appState)`.

- [ ] **Step 3: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
git add OpenWhisper/Views/AI/
git commit -m "feat: add API Keys settings tab with key input, validation, and connection testing"
```

---

## Task 16: Settings UI — Ollama, Councils, Task Routing, Care Model Tabs

**Files:**
- Create: `OpenWhisper/Views/AI/OllamaSettingsView.swift`
- Create: `OpenWhisper/Views/AI/CouncilsSettingsView.swift`
- Create: `OpenWhisper/Views/AI/TaskRoutingSettingsView.swift`
- Create: `OpenWhisper/Views/AI/CareModelSettingsView.swift`
- Modify: `OpenWhisper/Views/AI/AIProvidersSettingsView.swift` — wire all tabs

- [ ] **Step 1: Write OllamaSettingsView.swift**

Detection status, discovered model list, refresh button.

- [ ] **Step 2: Write CouncilsSettingsView.swift**

Named council list, council editor (member picker from all providers, chairman selector, anonymized toggle, timeout, cost threshold).

- [ ] **Step 3: Write TaskRoutingSettingsView.swift**

Global default picker (model or council), per-task override list with suggest buttons. Each AITask shows current assignment and override controls.

- [ ] **Step 4: Write CareModelSettingsView.swift**

Enable/disable toggle, poll interval, keep-alive timeout, prediction log viewer.

- [ ] **Step 5: Wire all tabs into AIProvidersSettingsView**

Replace remaining placeholder text cases with actual view instances.

- [ ] **Step 6: Build and commit**

```bash
xcodegen generate && xcodebuild -scheme OpenWhisper -configuration Debug -derivedDataPath .build build \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=T2ZTUY8F2X
git add OpenWhisper/Views/AI/
git commit -m "feat: add Ollama, Councils, Task Routing, and Care Model settings tabs"
```

---

## Task 17: Integration Verification

**Files:** None new — verification only.

- [ ] **Step 1: Full build verification**

```bash
cd "/Users/yishai/Documents/Warp Coding Projects/Open Wispr"
scripts/setup.sh && scripts/build.sh
```

Expected: Clean build with no warnings from AI module files.

- [ ] **Step 2: Manual smoke test**

Launch the app. Verify:
1. AI Providers appears in Settings
2. Local Models tab shows 8 models with correct names and sizes
3. API Keys tab shows all 4 services with key input fields
4. No crashes on tab navigation
5. Memory bar renders correctly

- [ ] **Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address integration issues from smoke testing"
```
