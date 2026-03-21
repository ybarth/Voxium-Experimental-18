import SwiftUI

struct CouncilsSettingsView: View {
    let appState: AppState

    private var councilStore: CouncilStore { appState.councilStore }
    private var registry: ProviderRegistry { appState.providerRegistry }

    @State private var editingCouncil: CouncilConfig?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Councils let multiple models collaborate on a task with a designated chairman.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New Council") {
                    let newCouncil = CouncilConfig(
                        name: "New Council",
                        memberProviderIDs: [],
                        chairmanProviderID: registry.availableProviders.first?.id ?? ""
                    )
                    editingCouncil = newCouncil
                    isCreating = true
                }
                .controlSize(.small)
            }

            if councilStore.councils.isEmpty {
                GroupBox {
                    Text("No councils configured. Create one to coordinate multiple AI providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(councilStore.councils) { council in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(council.name)
                                        .fontWeight(.medium)
                                    Text("\(council.memberProviderIDs.count) members, \(Int(council.timeoutSeconds))s timeout")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if council.reviewAnonymized {
                                    Image(systemName: "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help("Anonymous review enabled")
                                }
                                Button("Edit") {
                                    editingCouncil = council
                                    isCreating = false
                                }
                                .controlSize(.small)
                                Button("Delete") {
                                    councilStore.delete(id: council.id)
                                }
                                .controlSize(.small)
                                .foregroundStyle(.red)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            if council.id != councilStore.councils.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCouncil) { council in
            CouncilEditorView(
                council: council,
                registry: registry,
                isCreating: isCreating,
                onSave: { updated in
                    if isCreating {
                        councilStore.add(updated)
                    } else {
                        councilStore.update(updated)
                    }
                    editingCouncil = nil
                },
                onCancel: {
                    editingCouncil = nil
                }
            )
        }
    }
}

struct CouncilEditorView: View {
    @State var council: CouncilConfig
    let registry: ProviderRegistry
    let isCreating: Bool
    let onSave: (CouncilConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isCreating ? "New Council" : "Edit Council")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Name") {
                    TextField("Council name", text: $council.name)
                }

                Section("Members") {
                    if registry.availableProviders.isEmpty {
                        Text("No providers available. Configure API keys or local models first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(registry.availableProviders, id: \.id) { provider in
                            let isMember = council.memberProviderIDs.contains(provider.id)
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { isMember },
                                    set: { included in
                                        if included {
                                            if !council.memberProviderIDs.contains(provider.id) {
                                                council.memberProviderIDs.append(provider.id)
                                            }
                                        } else {
                                            council.memberProviderIDs.removeAll { $0 == provider.id }
                                            if council.chairmanProviderID == provider.id {
                                                council.chairmanProviderID = council.memberProviderIDs.first ?? ""
                                            }
                                        }
                                    }
                                )) {
                                    Text(provider.name)
                                }
                            }
                        }
                    }
                }

                Section("Chairman") {
                    let memberProviders = registry.availableProviders.filter {
                        council.memberProviderIDs.contains($0.id)
                    }
                    if memberProviders.isEmpty {
                        Text("Add members first to select a chairman.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Chairman", selection: $council.chairmanProviderID) {
                            ForEach(memberProviders, id: \.id) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                    }
                }

                Section("Options") {
                    Toggle("Anonymized Review", isOn: $council.reviewAnonymized)
                    Text("Members review each other's responses without knowing the source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(
                        value: $council.timeoutSeconds,
                        in: 10...300,
                        step: 10
                    ) {
                        Text("Timeout: \(Int(council.timeoutSeconds))s")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Save") {
                    onSave(council)
                }
                .disabled(council.name.trimmingCharacters(in: .whitespaces).isEmpty || council.memberProviderIDs.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
    }
}
