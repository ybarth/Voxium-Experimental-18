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
        // CursorPositionService.captureContext() does a live accessibility snapshot
        let context = cursorPositionService.captureContext()
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
