import AppKit
import SwiftUI

@MainActor
final class EchoModeController {
    private var panel: EchoModePanel?
    private let state: EchoModeState
    private let speechifyService: SpeechifyService
    private let logger = TranscriptionLogger.shared

    /// Visible, selectable NSTextView — used for both display and Speechify text selection.
    private var echoTextView: NSTextView?
    private var headerHostingView: NSHostingView<EchoModePanelHeader>?

    private static let panelSize = NSSize(width: 380, height: 140)
    private static let headerHeight: CGFloat = 36

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

        // Container view with material background
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        // Header (SwiftUI)
        let header = NSHostingView(
            rootView: EchoModePanelHeader(
                timestamp: state.currentEntry?.date,
                onClose: { [weak self] in self?.hidePanel() }
            )
        )
        header.frame = NSRect(x: 0, y: frame.height - Self.headerHeight,
                              width: frame.width, height: Self.headerHeight)
        header.autoresizingMask = [.width, .minYMargin]
        container.addSubview(header)
        headerHostingView = header

        // Divider
        let divider = NSBox(frame: NSRect(x: 0, y: frame.height - Self.headerHeight - 1,
                                          width: frame.width, height: 1))
        divider.boxType = .separator
        divider.autoresizingMask = [.width, .minYMargin]
        container.addSubview(divider)

        // Text view (real, visible, selectable — for both display and Speechify)
        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: 0,
            width: frame.width,
            height: frame.height - Self.headerHeight - 1
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor

        if let entry = state.currentEntry {
            textView.string = entry.text
        } else {
            textView.string = "Waiting for transcription..."
            textView.textColor = .secondaryLabelColor
        }

        scrollView.documentView = textView
        container.addSubview(scrollView)
        echoTextView = textView

        newPanel.contentView = container
        newPanel.orderFront(nil)
        self.panel = newPanel
        logger.info("Echo Mode panel shown at frame=\(frame)", category: .tts)
    }

    func hidePanel() {
        if let panel {
            state.lastUserPosition = panel.frame.origin
        }
        panel?.orderOut(nil)
        panel = nil
        echoTextView = nil
        headerHostingView = nil
        logger.info("Echo Mode panel hidden", category: .tts)
    }

    /// Update the panel content and trigger Speechify read.
    func displayEntry(_ entry: TranscriptionEntry) {
        state.currentEntry = entry

        guard let panel else {
            logger.info("Echo Mode: displayEntry called but panel is nil", category: .tts)
            return
        }

        // Update header timestamp
        headerHostingView?.rootView = EchoModePanelHeader(
            timestamp: entry.date,
            onClose: { [weak self] in self?.hidePanel() }
        )

        // Update text and select for Speechify
        guard let textView = echoTextView else {
            logger.info("Echo Mode: displayEntry called but textView is nil", category: .tts)
            return
        }

        textView.textColor = .labelColor
        textView.string = entry.text

        // Activate our app so Speechify can find selected text via Accessibility API.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKey()
        panel.makeFirstResponder(textView)
        textView.selectAll(nil)

        // Wait for activation + Accessibility API to register, then trigger Speechify
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.speechifyService.triggerRead()
            self?.logger.info("Echo Mode: triggered Speechify read for entry \(entry.id)", category: .tts)
        }
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
