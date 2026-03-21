import SwiftUI

enum AIProviderTab: String, CaseIterable {
    case localModels = "Local Models"
    case apiKeys = "API Keys"
    case ollama = "Ollama"
    case councils = "Councils"
    case taskRouting = "Task Routing"
    case careModel = "Care Model"

    var systemImage: String {
        switch self {
        case .localModels: return "cpu"
        case .apiKeys: return "key"
        case .ollama: return "server.rack"
        case .councils: return "person.3"
        case .taskRouting: return "arrow.triangle.branch"
        case .careModel: return "heart.circle"
        }
    }
}

struct AIProvidersSettingsView: View {
    let appState: AppState
    @State private var selectedTab: AIProviderTab = .localModels

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(AIProviderTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 14))
                            Text(tab.rawValue)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }

            // Content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .localModels:
                        LocalModelsSettingsView(appState: appState)
                    case .apiKeys:
                        APIKeysSettingsView(appState: appState)
                    case .ollama:
                        OllamaSettingsView(appState: appState)
                    case .councils:
                        CouncilsSettingsView(appState: appState)
                    case .taskRouting:
                        TaskRoutingSettingsView(appState: appState)
                    case .careModel:
                        CareModelSettingsView(appState: appState)
                    }
                }
                .padding()
            }
        }
    }
}
