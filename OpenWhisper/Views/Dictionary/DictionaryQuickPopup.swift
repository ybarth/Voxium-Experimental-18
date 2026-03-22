import AppKit
import SwiftUI

// MARK: - DictionaryQuickPopupPanel

/// A floating, borderless NSPanel for quick word addition to the dictionary.
/// Mirrors the style of RecordingOverlayPanel but accepts mouse events and key input.
final class DictionaryQuickPopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - DictionaryQuickPopupController

/// Creates, shows, and hides the quick-add popup panel.
@MainActor
final class DictionaryQuickPopupController {

    private var panel: DictionaryQuickPopupPanel?
    private let appState: AppState

    private static let panelSize = NSSize(width: 320, height: 200)

    init(appState: AppState) {
        self.appState = appState
    }

    func show(word: String) {
        dismiss()

        let frame = centeredFrame()
        let panel = DictionaryQuickPopupPanel(contentRect: frame)

        let content = DictionaryQuickPopupView(
            initialWord: word,
            dictionaryManager: appState.dictionaryManager,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Private

    private func centeredFrame() -> NSRect {
        let size = Self.panelSize
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.midY - size.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - DictionaryQuickPopupView

private struct DictionaryQuickPopupView: View {

    let initialWord: String
    let dictionaryManager: DictionaryManager
    let onDismiss: () -> Void

    @State private var spelling: String
    @State private var pronunciationRecorder = DictionaryPronunciationRecorder()
    @State private var audioFilename: String?
    @State private var isConfirmed = false

    init(initialWord: String, dictionaryManager: DictionaryManager, onDismiss: @escaping () -> Void) {
        self.initialWord = initialWord
        self.dictionaryManager = dictionaryManager
        self.onDismiss = onDismiss
        _spelling = State(initialValue: initialWord)
    }

    var body: some View {
        ZStack {
            // Frosted glass background
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)

            VStack(spacing: 16) {
                // Title + word field
                VStack(spacing: 6) {
                    Text("Add to Dictionary")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    TextField("Word spelling", text: $spelling)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .font(.title3.weight(.medium))
                        .onSubmit { confirmAndSave() }
                }

                // Pronunciation controls
                pronunciationControls

                // Action buttons
                HStack(spacing: 12) {
                    Button("Cancel") {
                        cleanupUnusedRecording()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button("Add Word") {
                        confirmAndSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(spelling.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(20)
        }
        .frame(width: 320, height: 200)
    }

    // MARK: - Pronunciation Controls

    @ViewBuilder
    private var pronunciationControls: some View {
        HStack(spacing: 10) {
            // Record / Stop button
            CircularIconButton(
                systemImage: pronunciationRecorder.isRecording ? "stop.fill" : "mic.fill",
                tint: pronunciationRecorder.isRecording ? .red : .accentColor,
                action: {
                    if pronunciationRecorder.isRecording {
                        if let filename = pronunciationRecorder.stopRecording() {
                            if let old = audioFilename {
                                pronunciationRecorder.deleteAudio(filename: old)
                            }
                            audioFilename = filename
                        }
                    } else {
                        pronunciationRecorder.startRecording()
                    }
                }
            )
            .help(pronunciationRecorder.isRecording ? "Stop recording" : "Record pronunciation")

            // Play / Stop playback
            if let filename = audioFilename {
                CircularIconButton(
                    systemImage: pronunciationRecorder.isPlaying ? "stop.fill" : "play.fill",
                    tint: .secondary,
                    action: {
                        if pronunciationRecorder.isPlaying {
                            pronunciationRecorder.stopPlayback()
                        } else {
                            pronunciationRecorder.play(filename: filename)
                        }
                    }
                )
                .help(pronunciationRecorder.isPlaying ? "Stop playback" : "Play pronunciation")
            }

            // Duration or status label
            if pronunciationRecorder.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(String(format: "%.1fs", pronunciationRecorder.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if audioFilename != nil {
                Label("Recorded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Optional: record pronunciation")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }

        if let error = pronunciationRecorder.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func confirmAndSave() {
        let trimmed = spelling.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Stop any active recording first
        if pronunciationRecorder.isRecording {
            if let filename = pronunciationRecorder.stopRecording() {
                if let old = audioFilename {
                    pronunciationRecorder.deleteAudio(filename: old)
                }
                audioFilename = filename
            }
        }

        let entry = DictionaryEntry(
            spelling: trimmed,
            audioFilename: audioFilename
        )
        dictionaryManager.addEntry(entry)
        isConfirmed = true
        onDismiss()
    }

    private func cleanupUnusedRecording() {
        if let filename = audioFilename {
            pronunciationRecorder.deleteAudio(filename: filename)
        }
    }
}

// MARK: - CircularIconButton

private struct CircularIconButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
