import SwiftUI
import KeyboardShortcuts

enum AppTab: String, CaseIterable {
    case home = "Home"
    case settings = "Settings"
    case history = "History"
    case aiProviders = "AI Providers"
    case chainOfThought = "Chain of Thought"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .home: return "house"
        case .settings: return "gear"
        case .history: return "clock"
        case .aiProviders: return "cpu"
        case .chainOfThought: return "brain.head.profile"
        case .logs: return "doc.text"
        }
    }
}

struct MainWindowView: View {
    let appState: AppState
    @State private var selectedTab: AppTab = .home
    @State private var pendingTab: AppTab?
    @State private var showUnsavedAlert = false
    @State private var micAuthorized = Permissions.isMicrophoneAuthorized
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Binding that intercepts tab changes away from settings to check for unsaved hotkey changes.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if selectedTab == .settings && newTab != .settings && appState.hasUnsavedHotkeyChanges {
                    pendingTab = newTab
                    showUnsavedAlert = true
                } else {
                    selectedTab = newTab
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(AppTab.allCases, id: \.self, selection: tabSelection) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
            } detail: {
                Group {
                    switch selectedTab {
                    case .home:
                        homeTab
                    case .settings:
                        SettingsTabView(appState: appState)
                    case .history:
                        HistoryView(historyStore: appState.historyStore, appState: appState)
                    case .aiProviders:
                        AIProvidersSettingsView(appState: appState)
                    case .chainOfThought:
                        ChainOfThoughtView(contextStore: appState.contextStore)
                    case .logs:
                        LogsView(logger: TranscriptionLogger.shared)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Status bar
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(appState.isRecording || appState.isTranscribing ? 1.0 : 0.8)

                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if appState.modelManager.selectedModel.requiresServer {
                    // Server model status
                    serverStatusIndicator
                } else if !appState.modelManager.isModelReady {
                    if appState.modelManager.isDownloading {
                        ProgressView()
                            .controlSize(.mini)
                        Text("\(Int(appState.modelManager.downloadProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Model not ready")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 580, maxWidth: 700, minHeight: 420, maxHeight: 640)
        .onReceive(permissionTimer) { _ in
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
        .onAppear {
            micAuthorized = Permissions.isMicrophoneAuthorized
            accessibilityGranted = Permissions.isAccessibilityGranted
        }
        .onChange(of: appState.desiredTab) { _, newTab in
            if let newTab {
                selectedTab = newTab
                appState.desiredTab = nil
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            appState.currentTab = newTab
            appState.updateIdlePillVisibility()
        }
        .onDisappear {
            // Auto-accept hotkey changes when window closes
            if selectedTab == .settings {
                appState.acceptHotkeyChanges()
            }
        }
        .alert("Unsaved Hotkey Changes", isPresented: $showUnsavedAlert) {
            Button("Keep Changes") {
                appState.acceptHotkeyChanges()
                if let tab = pendingTab {
                    selectedTab = tab
                    pendingTab = nil
                }
            }
            Button("Revert") {
                appState.revertHotkeyChanges()
                if let tab = pendingTab {
                    selectedTab = tab
                    pendingTab = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTab = nil
            }
        } message: {
            Text("You have unsaved hotkey changes. Would you like to keep or revert them?")
        }
    }

    @ViewBuilder
    private var serverStatusIndicator: some View {
        let state = appState.serverManager.state
        switch state {
        case .running:
            Image(systemName: "server.rack")
                .font(.caption2)
                .foregroundStyle(.green)
            Text("Server")
                .font(.caption2)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
            Text("Server error")
                .font(.caption2)
                .foregroundStyle(.red)
        case .stopped:
            Text("Server stopped")
                .font(.caption2)
                .foregroundStyle(.orange)
        default:
            ProgressView()
                .controlSize(.mini)
            Text(state.displayString)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isTranscribing {
            return .orange
        } else {
            return .green
        }
    }

    private var homeTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)

                    Text("OpenWhisper")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Voice-to-text, locally and privately")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 12)
                .overlay(alignment: .topTrailing) {
                    Text("Build 2026.03.21-U")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }

                // Permission banners
                if !micAuthorized || !accessibilityGranted {
                    VStack(spacing: 8) {
                        if !micAuthorized {
                            permissionBanner(
                                icon: "mic.slash.fill",
                                title: "Microphone Access Required",
                                description: "Microphone access is required to record your voice.",
                                buttonLabel: "Grant Microphone Access"
                            ) {
                                Permissions.requestMicrophone()
                            }
                        }

                        if !accessibilityGranted {
                            accessibilityBanner
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                Divider()

                // Instructions
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(
                        step: 1,
                        title: "Press your hotkey to start recording",
                        detail: "Press again to stop and transcribe"
                    )
                    instructionRow(
                        step: 2,
                        title: "Text is pasted automatically",
                        detail: "Transcribed text is typed into your active text field"
                    )
                    instructionRow(
                        step: 3,
                        title: "Runs in your menu bar",
                        detail: "Look for the waveform icon in the menu bar"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Hotkey reference
                Divider()

                HStack(spacing: 24) {
                    hotkeyLabel("Start/stop", for: .toggleRecording)
                    hotkeyLabel("Push-to-talk", for: .pushToTalkRecording)
                    hotkeyLabel("Cancel", for: .cancelRecording)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility Access Required")
                    .font(.subheadline.weight(.semibold))
                Text("Accessibility access is required to paste transcribed text and for the global hotkey to work in all apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Button("Open Accessibility Settings") {
                        Permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)

                    Button("Reveal App in Finder") {
                        Permissions.revealAppInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }

                HStack(spacing: 6) {
                    Button("Reset & Re-Prompt") {
                        Permissions.resetAndRePromptAccessibility()
                    }
                    .controlSize(.small)
                    .font(.caption)
                    .help("Clears a stale Accessibility entry (e.g. after a rebuild) and re-prompts.")

                    Text(Permissions.appBundlePath)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func permissionBanner(
        icon: String,
        title: String,
        description: String,
        buttonLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(buttonLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hotkeyLabel(_ label: String, for name: KeyboardShortcuts.Name) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            let shortcutText = KeyboardShortcuts.getShortcut(for: name)?.displayString
                ?? name.defaultShortcut?.displayString
                ?? "Not set"
            Text(shortcutText)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func instructionRow(step: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
