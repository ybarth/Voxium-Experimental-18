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
