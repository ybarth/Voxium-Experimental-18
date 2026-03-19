import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: RecordingOverlayPanel?
    private let appState: AppState

    // Panel sizes for each phase
    private static let idleSize = NSSize(width: 60, height: 36)
    private static let expandedSize = NSSize(width: 280, height: 80)

    init(appState: AppState) {
        self.appState = appState
        createPanel()
    }

    private func createPanel() {
        let frame = panelFrame(for: .idle)
        let panel = RecordingOverlayPanel(contentRect: frame)

        let hostingView = NSHostingView(
            rootView: RecordingOverlayContent(appState: appState)
        )
        panel.contentView = hostingView
        self.panel = panel
    }

    func showIdlePill() {
        appState.overlayState.phase = .idle
        updateForPhase(.idle)
    }

    func updateForPhase(_ phase: OverlayState.Phase) {
        guard let panel else { return }

        switch phase {
        case .hidden:
            panel.orderOut(nil)
            panel.ignoresMouseEvents = true
        case .idle:
            let frame = panelFrame(for: .idle)
            panel.setFrame(frame, display: true, animate: true)
            panel.ignoresMouseEvents = false  // Allow right-click menu
            panel.orderFront(nil)
        case .recording, .transcribing, .cancelled, .modelDownloading, .accessibilityRequired:
            let frame = panelFrame(for: phase)
            panel.setFrame(frame, display: true, animate: true)
            panel.ignoresMouseEvents = true   // Pass clicks through during active states
            panel.orderFront(nil)
        }
    }

    func show() {
        updateForPhase(appState.overlayState.phase)
    }

    func dismiss() {
        updateForPhase(appState.overlayState.phase)
    }

    // MARK: - Frame calculation

    private func panelFrame(for phase: OverlayState.Phase) -> NSRect {
        let size: NSSize
        switch phase {
        case .hidden, .idle:
            size = Self.idleSize
        default:
            size = Self.expandedSize
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.minY + 40

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
