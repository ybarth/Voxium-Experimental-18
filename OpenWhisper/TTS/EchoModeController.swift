import AppKit
import SwiftUI

@MainActor
final class EchoModeController {
    private var panel: EchoModePanel?
    private let state: EchoModeState
    private let speechifyService: SpeechifyService
    private let logger = TranscriptionLogger.shared

    /// The NSTextView used for Speechify text selection in the echo panel.
    /// Positioned off-screen (not hidden via isHidden, which removes it from the accessibility tree).
    private var echoTextView: NSTextView?
    private var hostingView: NSHostingView<EchoModePanelContent>?

    private static let panelSize = NSSize(width: 380, height: 120)

    init(state: EchoModeState, speechifyService: SpeechifyService) {
        self.state = state
        self.speechifyService = speechifyService
    }

    // MARK: - Panel lifecycle

    func showPanel() {
        guard panel == nil else {
            panel?.orderFront(nil)
            return
        }

        let frame = dockFrame(for: state.dockPosition)
        let newPanel = EchoModePanel(contentRect: frame)

        // Create an off-screen NSTextView for Speechify text selection.
        // Do NOT use isHidden — hidden views are removed from the accessibility tree.
        let textView = NSTextView(frame: NSRect(x: -9999, y: -9999, width: 1, height: 1))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.alphaValue = 0
        newPanel.contentView?.addSubview(textView)
        echoTextView = textView

        let hosting = NSHostingView(
            rootView: EchoModePanelContent(
                entry: state.currentEntry,
                onClose: { [weak self] in self?.hidePanel() }
            )
        )
        newPanel.contentView?.addSubview(hosting, positioned: .below, relativeTo: textView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if let contentView = newPanel.contentView {
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        self.hostingView = hosting

        // Use orderFrontRegardless to show without stealing key window status
        newPanel.orderFrontRegardless()
        self.panel = newPanel
        logger.info("Echo Mode panel shown", category: .tts)
    }

    func hidePanel() {
        if let panel {
            state.lastUserPosition = panel.frame.origin
        }
        panel?.orderOut(nil)
        panel = nil
        echoTextView = nil
        hostingView = nil
        logger.info("Echo Mode panel hidden", category: .tts)
    }

    /// Update the panel content and trigger Speechify read.
    func displayEntry(_ entry: TranscriptionEntry) {
        state.currentEntry = entry

        guard let panel else { return }

        // Update SwiftUI content via rootView property (avoids recreating the hosting view)
        hostingView?.rootView = EchoModePanelContent(
            entry: entry,
            onClose: { [weak self] in self?.hidePanel() }
        )

        // Select text in the off-screen text view and trigger Speechify
        if let textView = echoTextView {
            textView.string = entry.text
            panel.makeKey()
            panel.makeFirstResponder(textView)
            textView.selectAll(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.speechifyService.triggerRead()

                // Clean up selection after Speechify has grabbed it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        }

        logger.info("Echo Mode: reading entry \(entry.id)", category: .tts)
    }

    // MARK: - Docking

    func updateDockPosition(_ position: DockPosition) {
        state.dockPosition = position
        state.lastUserPosition = nil
        if let panel {
            let frame = dockFrame(for: position)
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    private func dockFrame(for position: DockPosition) -> NSRect {
        // Use last user position if available
        if let lastPos = state.lastUserPosition {
            return NSRect(origin: lastPos, size: Self.panelSize)
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = Self.panelSize
        let margin: CGFloat = 20

        let origin: NSPoint
        switch position {
        case .bottom:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + margin
            )
        case .top:
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - margin
            )
        case .left:
            origin = NSPoint(
                x: visible.minX + margin,
                y: visible.midY - size.height / 2
            )
        case .right:
            origin = NSPoint(
                x: visible.maxX - size.width - margin,
                y: visible.midY - size.height / 2
            )
        }

        return NSRect(origin: origin, size: size)
    }
}
