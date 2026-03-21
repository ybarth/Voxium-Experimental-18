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
