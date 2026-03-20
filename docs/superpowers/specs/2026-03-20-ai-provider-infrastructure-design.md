# AI Provider Infrastructure — Design Spec

> Layer 1+2 from the [AI Intelligence Layer Roadmap](../../ai-roadmap.md).
> This is the foundation that all subsequent features (Dictionary, Transcription Post-Processing, etc.) build upon.
> **Note:** The roadmap originally described Ollama as the primary local runtime. During design, this evolved to MLX-primary (better Apple Silicon performance) with Ollama as optional. The roadmap should be updated to reflect this.

## 1. Overview

A unified AI provider infrastructure that manages local open-source models (via MLX on Apple Silicon), optional Ollama integration, and commercial BYOK API keys. Providers self-declare capabilities. A plugin registry with capability-based discovery suggests models for tasks, while users retain full control over assignments. A task router resolves requests through a layered configuration (global default + per-task overrides). A care model service predictively pre-loads models based on user context.

## 2. Provider Protocol & Capability System

```swift
protocol AIProvider: Identifiable {
    var id: String { get }
    var name: String { get }
    var providerType: ProviderType { get }
    var capabilities: Set<AICapability> { get }
    var status: ProviderStatus { get }
    var memoryFootprint: Int? { get }               // bytes, nil for APIs

    func load() async throws                         // load into memory (no-op for APIs)
    func unload() async                              // free memory (no-op for APIs)
    func complete(_ request: AIRequest) async throws -> AIResponse
}

enum ProviderType: String, Codable {
    case mlx
    case ollama
    case commercial
}

enum ProviderStatus: String, Codable {
    case notDownloaded      // MLX model not yet on disk
    case downloading        // download in progress
    case available          // on disk but not in memory
    case loading            // loading into memory
    case loaded             // ready for inference
    case error              // failed to load or health check failed
}

enum AICapability: String, Codable, CaseIterable {
    // Cognitive
    case reasoning
    case codeGeneration
    case creativity

    // Language
    case multilingual
    case translation
    case phoneticAnalysis

    // Speed
    case fastInference
    case longContext

    // Domain
    case transcriptionAware
    case editorialAnalysis
    case visualGeneration
}
```

### AIRequest / AIResponse

```swift
struct AIRequest {
    let prompt: String
    let systemPrompt: String?
    let maxTokens: Int?
    let temperature: Double?
    let task: AITask                                 // which task this is for (for logging/stats)
}

struct AIResponse {
    let text: String
    let providerID: String
    let tokenCount: Int?
    let latencyMs: Int
}
```

Providers self-declare capabilities. The curated MLX model list ships with pre-defined capability profiles. Commercial providers inherit capabilities from known model specs.

## 3. Provider Registry & Discovery

```swift
@MainActor
@Observable
final class ProviderRegistry {
    // Registration
    private(set) var providers: [String: any AIProvider] = [:]
    func register(_ provider: any AIProvider)
    func unregister(id: String)
    var availableProviders: [any AIProvider]

    // Discovery
    func providers(matching capabilities: Set<AICapability>) -> [any AIProvider]
    func suggest(for task: AITask) -> [ScoredSuggestion]
    func suggestCouncil(for task: AITask) -> CouncilSuggestion

    // Lifecycle
    var loadedProviders: [any AIProvider]
    var totalMemoryUsage: Int                        // bytes across all loaded
    var memoryBudget: Int                            // user-configurable ceiling

    // Health
    func healthCheck(id: String) async -> HealthStatus
    func healthCheckAll() async -> [String: HealthStatus]
}

struct ScoredSuggestion {
    let provider: any AIProvider
    let score: Double                                // 0-1, based on capability match
    let explanation: String                          // "Strong multilingual + phonetic analysis"
}
```

### Suggestion Scoring

When suggesting models for a task, the registry considers:
1. **Capability overlap** — how many of the task's required capabilities does this provider have?
2. **Performance history** — if used for this task before: response time, user acceptance rate
3. **Load state** — prefer already-loaded models to avoid latency
4. **Memory impact** — can this model fit given what's already loaded?

### Memory Budget

User sets a ceiling in Settings (default: 80% of system RAM). The registry tracks total footprint of loaded models and warns/refuses if a load would exceed the budget.

## 4. Backend Implementations

### 4.1 MLX Backend

`MLXModelManager` manages local open-source models running via MLX on Apple Silicon (Metal GPU).

**Curated model list (launch):**

| Model | Params | ~RAM (4-bit) | Capabilities |
|-------|--------|-------------|--------------|
| Llama 3.1 70B | 70B | ~45 GB | reasoning, codeGeneration, longContext |
| Qwen 2.5 72B | 72B | ~46 GB | multilingual, translation, longContext |
| Kimi-Dev-72B | 72B | ~46 GB | codeGeneration, reasoning, longContext |
| GLM-4.6 | 355B MoE / 32B active | ~40 GB | reasoning, creativity, multilingual |
| DeepSeek-R1 32B | 32B | ~20 GB | reasoning, codeGeneration |
| Gemma 2 27B | 27B | ~17 GB | editorialAnalysis, creativity |
| Phi-4 14B | 14B | ~9 GB | fastInference, reasoning |
| Mixtral 8x22B | MoE ~140B / 44B active | ~85 GB | reasoning, creativity, longContext |

**MLX inference stack:** Uses Apple's `ml-explore/mlx-swift-examples` package, specifically the `MLXLLM` module which provides high-level LLM inference (model loading, tokenization, streaming generation). The lower-level `mlx-swift` tensor library is a transitive dependency. Inference uses `MLXLLM.generate` with streaming token output.

**Responsibilities:**
- Download models from HuggingFace (MLX-quantized repos)
- Download progress with pause/resume (HTTP range requests)
- Integrity verification (SHA256 checksums)
- Load models into memory via `MLXLLM` model loading APIs
- Run inference on Metal GPU via `MLXLLM.generate` with streaming
- Report memory footprint from model metadata
- Each model registers as an `AIProvider` with pre-defined capabilities
- On load failure: set status to `.error` with descriptive message, allow retry, log diagnostics

**Future expansion:** Support any MLX-compatible model from HuggingFace (user browses/downloads), with "recommended" badge on curated models.

### 4.2 Ollama Backend

`OllamaProvider` wraps locally-installed Ollama as an optional convenience integration.

- Detects Ollama installation (`/usr/local/bin/ollama` or Homebrew paths)
- If present, queries Ollama API (`localhost:11434`) for available models
- Each discovered Ollama model registers as an `AIProvider` with inferred capabilities
- Delegates inference to Ollama's HTTP API
- If Ollama not installed → registers zero providers, no errors
- Ollama manages its own model storage — no duplication

### 4.3 Commercial Backends (BYOK)

One class per service, all implementing `AIProvider`:

| Service | Class | Key Format Regex | API Base |
|---------|-------|-----------------|----------|
| Claude | `ClaudeProvider` | `sk-ant-.*` | api.anthropic.com |
| GPT | `GPTProvider` | `sk-.*` | api.openai.com |
| Gemini | `GeminiProvider` | `AI.*` | generativelanguage.googleapis.com |
| Grok | `GrokProvider` | `xai-.*` | api.x.ai |

**Each commercial provider:**
- Validates key format before attempting connection
- Stores API key in macOS Keychain (never UserDefaults)
- Queries available models for the key → each discovered model registers as a separate `AIProvider`
- Connection testing at three configurable depth levels (see Section 8)

## 5. Council System

### Data Model

```swift
struct CouncilConfig: Codable, Identifiable {
    let id: UUID
    var name: String                               // "My Reasoning Council"
    var memberProviderIDs: [String]                // providers participating
    var chairmanProviderID: String                 // synthesizes final answer
    var reviewAnonymized: Bool                     // default: true
    var timeoutSeconds: TimeInterval               // per-member timeout, default: 60
    var costWarningThreshold: Double?              // warn if estimated cost exceeds this (USD)
}
```

### Council Orchestrator

```swift
@MainActor
final class CouncilOrchestrator {
    func execute(_ request: AIRequest, council: CouncilConfig) async throws -> AIResponse
    func executeWithStreaming(_ request: AIRequest, council: CouncilConfig) -> AsyncStream<String>
    func cancelExecution()
}
```

**Three stages** (per Karpathy's LLM Council pattern):

1. **First opinions** — Request sent to all council members concurrently. Each responds independently.
2. **Peer review** — Each member receives all other responses (anonymized as "Response A", "Response B", etc. if `reviewAnonymized` is true). Each provides a critique + ranking.
3. **Chairman synthesis** — Chairman receives all original responses + all peer reviews. Produces the final answer.

**Streaming clarification:** `executeWithStreaming` streams only the chairman's Stage 3 output. Stages 1 and 2 run to completion internally, reporting progress via status callbacks (e.g., "3/4 members responded", "Peer review in progress") rather than streamed text.

**Timeout handling:** If a member doesn't respond within `timeoutSeconds`, the council proceeds without it. Chairman is informed which members timed out.

**Cost awareness:** For councils mixing commercial APIs, the system estimates token cost before execution. If cost exceeds `costWarningThreshold`, warns the user before proceeding.

**Named councils are reusable.** Define once (e.g., "My Reasoning Council"), assign to multiple tasks. Edit in one place.

## 6. Task Router & Layered Configuration

### Task Definitions

```swift
enum AITask: String, Codable, CaseIterable {
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
}
```

Each task has a required capability set used for suggestions:

| Task | Required Capabilities |
|------|----------------------|
| dictionaryContext | phoneticAnalysis, multilingual |
| transcriptionCorrection | phoneticAnalysis, transcriptionAware |
| transcriptionCleanup | editorialAnalysis, creativity |
| editorialSuggestions | editorialAnalysis, creativity |
| contentQualityFlag | reasoning, transcriptionAware |
| titleGeneration | creativity, fastInference |
| visualGeneration | visualGeneration, creativity |
| documentScanning | reasoning, multilingual |
| contextFormatting | editorialAnalysis, transcriptionAware |
| careModel | reasoning, fastInference |

### Task Assignment

```swift
struct TaskAssignment: Codable {
    enum Mode: Codable {
        case single(providerID: String)
        case council(councilID: UUID)
    }
    let mode: Mode
}
```

### Task Router

```swift
@MainActor
@Observable
final class TaskRouter {
    var globalDefault: TaskAssignment?
    var perTaskOverrides: [AITask: TaskAssignment]

    func resolve(task: AITask) -> TaskAssignment?
    // Returns per-task override if set, otherwise global default

    func suggest(for task: AITask) -> [ScoredSuggestion]
    // Asks ProviderRegistry for capability-matched suggestions

    func suggestCouncil(for task: AITask) -> CouncilSuggestion
    // Suggests council composition with complementary capabilities + chairman
}
```

**Layered configuration:**
- **Layer 1 — Global default:** One model or named council that handles all tasks unless overridden
- **Layer 2 — Per-task overrides:** Any specific task can override with a different model or council

**Persistence:** `TaskRouter` configuration (global default + per-task overrides) is stored as JSON in `~/Library/Application Support/OpenWhisper/AI/task-routing.json`. Loaded on app launch, saved on change.

**Settings flow:**
1. User sets global default (single model or named council)
2. For any task, user can tap "Override" to assign a different model/council
3. Each task slot has a "Suggest" button that queries the registry
4. Suggestions ranked by capability match with explanation text
5. User accepts or ignores suggestion

## 7. Care Model Service

```swift
@MainActor
@Observable
final class CareModelService {
    // Configuration
    var pollInterval: TimeInterval = 5.0
    var preloadLeadTime: TimeInterval = 30.0
    var keepAliveTimeout: TimeInterval = 300.0       // unload after 5 min unused

    // Context Inputs
    // - AccessibilityContext (active app, window, cursor, selected text)
    // - Recent dictation content (last N transcriptions, full text)
    // - Dictation topic/domain trends (rolling summary)
    // - Recent transcription history metadata (from HistoryStore)
    // - Time of day + day of week (habit patterns)
    // - Currently loaded models (from ProviderRegistry)

    // Prediction Loop
    func start()
    func stop()
    func assessContext() async -> [PredictedTask]
    // Sends context snapshot to assigned care model
    // Returns ranked tasks with confidence scores

    // Learning
    func logPredictionOutcome(predicted: AITask, actuallyUsed: Bool)
    // Feeds accuracy back for better predictions
}

struct PredictedTask {
    let task: AITask
    let confidence: Double                           // 0-1
    let reason: String                               // "User is in Xcode editing Swift"
}
```

**How it works:**
1. Care model (assigned via TaskRouter like any other task) runs on a polling loop (every 5s)
2. Each poll sends a compact context snapshot: active app, window title, recent dictation content, accessibility tree summary, time patterns
3. Care model returns ranked predictions: "transcriptionCleanup (90%), dictionaryContext (70%)"
4. Service resolves which models those tasks need via TaskRouter
5. Pre-loads predicted models if they fit within memory budget
6. Immediately reassesses when significant context change detected (app switch, etc.)
7. Unloads models that haven't been used or predicted for longer than `keepAliveTimeout`
8. Logs prediction accuracy to improve over time

**Poll overlap protection:** If a previous `assessContext()` call is still in-flight when the next poll fires, the poll is skipped. This prevents runaway resource consumption if the care model is a slower, larger model. The user can assign any model as the care model, but the task's required capabilities (`reasoning, fastInference`) serve as a suggestion guide toward models that can respond within the poll interval.

**Dictation content analysis:** The care model ingests the substance of recent dictations — not just metadata. If the user has been dictating about database schemas, it predicts coding-related tasks. If dictating Hebrew words, it predicts multilingual dictionary needs.

## 8. Connection Testing & Diagnostics

Three configurable depth levels for BYOK API key testing:

### Basic
- Validate key format (regex per service)
- Single minimal API call (list models endpoint)
- Report: "Connected" or raw error message

### Guided
- Everything in Basic, plus:
- Translate common errors to plain English:
  - `401` → "This API key is invalid or has been revoked"
  - `403` → "This key doesn't have access to the requested model — check your plan tier"
  - `429` → "Rate limit exceeded — your plan may have usage limits"
  - `timeout` → "Could not reach [service] — check your internet connection or if the service is down"
  - Expired key → "This key has expired — generate a new one at [service dashboard URL]"
- Suggest specific fixes with links to the service's dashboard/docs

### Comprehensive
- Everything in Guided, plus:
- Test each model endpoint the key has access to
- Report which models are accessible: "Your key has access to: GPT-4o, GPT-4, GPT-3.5-turbo"
- Estimate rate limits if the API reports them
- Show account tier if discoverable
- Latency measurement per model endpoint

User selects default depth in Settings. Can trigger any depth level on-demand from the API Keys settings tab.

## 9. Model Storage & Downloads

**Location:** `~/Library/Application Support/OpenWhisper/Models/MLX/`

```
Models/MLX/
├─ llama-3.1-70b-4bit/
│  ├─ model.safetensors (sharded)
│  ├─ config.json
│  ├─ tokenizer.json
│  └─ .metadata.json              // capabilities, HF repo URL, download date
├─ phi-4-14b-4bit/
│  └─ ...
└─ .download-state.json           // in-progress/paused downloads
```

**Download manager:**
- Downloads from HuggingFace MLX community repos
- Pause/resume support (HTTP range requests)
- SHA256 integrity verification
- Progress reporting for UI
- Configurable concurrent downloads (1-3 simultaneous)
- Curated model list maps each model → specific HF repo + expected file list

**Ollama models** managed by Ollama — no duplicate storage.

**Existing whisper models** stay at `~/Library/Application Support/OpenWhisper/Models/`. The `MLX/` subdirectory keeps LLM models separate.

## 10. Settings UI

New "AI Providers" section in Settings with sub-tabs:

### Local Models Tab
- Memory usage bar (loaded models vs budget)
- Model list with status indicators (loaded/ready/downloading/not downloaded)
- Capability tags per model
- Download/pause/delete controls
- Care Model badge on assigned model
- Memory budget configuration (default: 80% system RAM)

### API Keys Tab
- One section per commercial service (Claude, GPT, Gemini, Grok)
- Key input field with format validation indicator
- "Test Connection" button with depth selector (Basic/Guided/Comprehensive)
- Results panel showing diagnostic output, accessible models, error explanations
- Keys stored in Keychain — field shows masked key if already set

### Ollama Tab
- Auto-detect status ("Ollama found at /usr/local/bin/ollama" or "Not detected")
- List of discovered Ollama models with inferred capabilities
- Refresh button to re-scan

### Councils Tab
- Named council list (create, edit, delete)
- Council editor: pick members from all available providers, pick chairman
- Toggle anonymized review
- Set timeout and cost warning threshold
- "Suggest Council" button per task that auto-composes from available providers

### Task Routing Tab
- Global default assignment (model or council picker)
- Per-task override list — each of the 10 AITasks with:
  - Current assignment (or "Using global default")
  - "Override" button → model/council picker
  - "Suggest" button → capability-matched recommendations with explanations
  - "Clear override" to fall back to global default

### Care Model Tab
- Assigned model/council display
- Poll interval configuration
- Keep-alive timeout configuration
- Memory budget share configuration
- Prediction log viewer (recent predictions vs actual usage)
- Enable/disable toggle

## 11. Dependencies

### New Files (AI/ module)

**Core:**
- `AIProvider.swift` — protocol, capability enum, request/response types, status enum
- `ProviderRegistry.swift` — registration, discovery, health checks, memory tracking
- `TaskRouter.swift` — task enum, assignment model, layered resolution, suggestions

**Backends:**
- `MLXModelManager.swift` — curated model list, download, load/unload, inference
- `MLXDownloadManager.swift` — HuggingFace download with pause/resume, checksums
- `OllamaProvider.swift` — detection, discovery, API wrapper
- `ClaudeProvider.swift` — Anthropic API integration
- `GPTProvider.swift` — OpenAI API integration
- `GeminiProvider.swift` — Google AI API integration
- `GrokProvider.swift` — xAI API integration
- `CommercialKeyManager.swift` — Keychain storage, format validation, connection testing

**Council:**
- `CouncilConfig.swift` — council data model
- `CouncilOrchestrator.swift` — three-stage execution
- `CouncilStore.swift` — persistence for named councils

**Care Model:**
- `CareModelService.swift` — context polling, prediction, pre-loading

### New Views
- `AIProvidersSettingsView.swift` — container with sub-tabs
- `LocalModelsSettingsView.swift` — model list, memory bar, downloads
- `APIKeysSettingsView.swift` — key input, validation, testing
- `OllamaSettingsView.swift` — detection, model list
- `CouncilsSettingsView.swift` — council CRUD, member picker
- `TaskRoutingSettingsView.swift` — global default + per-task overrides
- `CareModelSettingsView.swift` — configuration and prediction log

### Modified Files
- `AppState.swift` — hold `ProviderRegistry`, `TaskRouter`, `CareModelService`
- `SettingsView.swift` / `SettingsTabView.swift` — add AI Providers section
- `project.yml` — add MLX Swift package dependency

### New SPM Dependencies
- `ml-explore/mlx-swift-examples` — provides `MLXLLM` module for high-level LLM inference (model loading, tokenization, streaming generation). Transitively depends on `mlx-swift` (low-level tensor library).

### Existing Code Untouched
- `InferenceServerManager` — Parakeet/Granite transcription continues working as-is
- `TranscriptionService` — unchanged until Layer 3 features integrate
- All existing recording/overlay/paste infrastructure — unaffected

## 12. Relationship to Other Roadmap Items

**Layer 2 (LLM Council):** The council system is included in this spec since it's tightly coupled with the provider infrastructure. `CouncilOrchestrator` consumes `AIProvider` instances from the registry.

**Layer 3 features** consume this infrastructure through `TaskRouter`:
- Dictionary (Sub-project E) → calls `TaskRouter.resolve(.dictionaryContext)` and `.transcriptionCorrection`
- Transcription Post-Processing (F) → calls `.transcriptionCleanup` and `.contextFormatting`
- History Intelligence (G) → calls `.editorialSuggestions`, `.contentQualityFlag`, `.titleGeneration`
- Visual Generation (H) → calls `.visualGeneration`

Each Layer 3 feature only needs to know which `AITask` to request. The router and registry handle everything else.
