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
