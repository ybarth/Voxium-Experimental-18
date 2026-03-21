import SwiftUI

struct TaskRoutingSettingsView: View {
    let appState: AppState

    private var router: TaskRouter { appState.taskRouter }
    private var registry: ProviderRegistry { appState.providerRegistry }
    private var councilStore: CouncilStore { appState.councilStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Global default
            GroupBox("Global Default") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Used for any task that doesn't have a specific override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    AssignmentPicker(
                        label: "Default",
                        assignment: Binding(
                            get: { router.globalDefault },
                            set: { router.setGlobalDefault($0) }
                        ),
                        registry: registry,
                        councilStore: councilStore
                    )
                }
                .padding(.vertical, 4)
            }

            // Per-task overrides
            GroupBox("Per-Task Overrides") {
                VStack(spacing: 0) {
                    ForEach(AITask.allCases, id: \.self) { task in
                        TaskOverrideRow(
                            task: task,
                            router: router,
                            registry: registry,
                            councilStore: councilStore
                        )
                        if task != AITask.allCases.last {
                            Divider()
                        }
                    }
                }
            }

            // Suggest button
            GroupBox("Suggestions") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let the registry suggest optimal assignments based on available providers and their capabilities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        ForEach(AITask.allCases.prefix(3), id: \.self) { task in
                            SuggestButton(task: task, router: router, registry: registry)
                        }
                        Spacer()
                        Button("Suggest All") {
                            for task in AITask.allCases {
                                let suggestions = registry.suggest(for: task)
                                if let top = suggestions.first {
                                    router.setOverride(
                                        for: task,
                                        assignment: TaskAssignment(mode: .single(providerID: top.providerID))
                                    )
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(registry.availableProviders.isEmpty)

                        Button("Clear All Overrides") {
                            router.clearAllOverrides()
                        }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct TaskOverrideRow: View {
    let task: AITask
    let router: TaskRouter
    let registry: ProviderRegistry
    let councilStore: CouncilStore

    private var currentAssignment: TaskAssignment? {
        router.perTaskOverrides[task]
    }

    private var assignmentDescription: String {
        guard let assignment = currentAssignment else {
            return router.globalDefault != nil ? "Using global default" : "No assignment"
        }
        switch assignment.mode {
        case .single(let id):
            return registry.provider(for: id)?.name ?? id
        case .council(let id):
            return councilStore.council(for: id)?.name ?? "Council \(id)"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName)
                    .fontWeight(.medium)
                Text(assignmentDescription)
                    .font(.caption)
                    .foregroundStyle(currentAssignment != nil ? .primary : .secondary)
            }

            Spacer()

            SuggestButton(task: task, router: router, registry: registry)

            if currentAssignment != nil {
                Button("Clear") {
                    router.clearOverride(for: task)
                }
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

struct SuggestButton: View {
    let task: AITask
    let router: TaskRouter
    let registry: ProviderRegistry

    var body: some View {
        Button("Suggest") {
            let suggestions = registry.suggest(for: task)
            if let top = suggestions.first {
                router.setOverride(
                    for: task,
                    assignment: TaskAssignment(mode: .single(providerID: top.providerID))
                )
            }
        }
        .controlSize(.small)
        .disabled(registry.availableProviders.isEmpty)
        .help(suggestTooltip)
    }

    private var suggestTooltip: String {
        let suggestions = registry.suggest(for: task)
        guard let top = suggestions.first else { return "No suitable providers available" }
        return top.explanation
    }
}

struct AssignmentPicker: View {
    let label: String
    @Binding var assignment: TaskAssignment?
    let registry: ProviderRegistry
    let councilStore: CouncilStore

    private enum PickerMode: String, CaseIterable {
        case none = "None"
        case provider = "Provider"
        case council = "Council"
    }

    private var mode: PickerMode {
        guard let a = assignment else { return .none }
        switch a.mode {
        case .single: return .provider
        case .council: return .council
        }
    }

    private var selectedProviderID: String {
        if case .single(let id) = assignment?.mode { return id }
        return registry.availableProviders.first?.id ?? ""
    }

    private var selectedCouncilID: UUID? {
        if case .council(let id) = assignment?.mode { return id }
        return councilStore.councils.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: Binding(
                get: { mode },
                set: { newMode in
                    switch newMode {
                    case .none:
                        assignment = nil
                    case .provider:
                        let id = registry.availableProviders.first?.id ?? ""
                        if !id.isEmpty {
                            assignment = TaskAssignment(mode: .single(providerID: id))
                        }
                    case .council:
                        if let first = councilStore.councils.first {
                            assignment = TaskAssignment(mode: .council(councilID: first.id))
                        }
                    }
                }
            )) {
                ForEach(PickerMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .labelsHidden()

            if mode == .provider {
                if registry.availableProviders.isEmpty {
                    Text("No providers available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Provider", selection: Binding(
                        get: { selectedProviderID },
                        set: { assignment = TaskAssignment(mode: .single(providerID: $0)) }
                    )) {
                        ForEach(registry.availableProviders, id: \.id) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                }
            } else if mode == .council {
                if councilStore.councils.isEmpty {
                    Text("No councils configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Council", selection: Binding(
                        get: { selectedCouncilID ?? councilStore.councils.first!.id },
                        set: { assignment = TaskAssignment(mode: .council(councilID: $0)) }
                    )) {
                        ForEach(councilStore.councils) { council in
                            Text(council.name).tag(council.id)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}
