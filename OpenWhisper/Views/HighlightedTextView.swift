import AppKit
import QuartzCore
import SwiftUI

// MARK: - NSViewRepresentable bridge

struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let activeWordIndex: Int
    let wordTimestamps: [WordTimestamp]
    let onWordTapped: ((Int) -> Void)?
    var lineLimit: Int? = nil

    func makeNSView(context: Context) -> HighlightedTextNSView {
        let view = HighlightedTextNSView()
        view.setLineLimit(lineLimit)
        view.setText(text, timestamps: wordTimestamps)
        view.onWordTapped = onWordTapped
        return view
    }

    func updateNSView(_ nsView: HighlightedTextNSView, context: Context) {
        nsView.onWordTapped = onWordTapped
        nsView.setLineLimit(lineLimit)
        nsView.updateHighlight(activeIndex: activeWordIndex, animated: true)
    }
}

// MARK: - HighlightedTextNSView

final class HighlightedTextNSView: NSView {
    var onWordTapped: ((Int) -> Void)?

    private let textView: NSTextView
    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private let highlightLayer = CALayer()
    private let clickOverlay: ClickOverlayView

    /// Cached rect for each word index.
    private var wordRects: [Int: CGRect] = [:]
    private var timestamps: [WordTimestamp] = []
    private var currentActiveIndex: Int = -1

    override init(frame frameRect: NSRect) {
        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer()

        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        clickOverlay = ClickOverlayView()

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.isGeometryFlipped = true

        addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false

        // Transparent overlay on top of the text view for click handling
        addSubview(clickOverlay)
        clickOverlay.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clickOverlay.topAnchor.constraint(equalTo: topAnchor),
            clickOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        clickOverlay.onClick = { [weak self] point in
            self?.handleClick(at: point)
        }

        // Set up highlight layer
        highlightLayer.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.25).cgColor
        highlightLayer.cornerRadius = 4
        highlightLayer.isHidden = true
        highlightLayer.zPosition = -1

        textView.wantsLayer = true
        textView.layer?.isGeometryFlipped = true
        textView.layer?.addSublayer(highlightLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Public

    func setLineLimit(_ limit: Int?) {
        textContainer.maximumNumberOfLines = limit ?? 0
        textView.textContainer?.maximumNumberOfLines = limit ?? 0
    }

    func setText(_ text: String, timestamps: [WordTimestamp]) {
        self.timestamps = timestamps

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    func updateHighlight(activeIndex: Int, animated: Bool) {
        guard currentActiveIndex != activeIndex else { return }
        currentActiveIndex = activeIndex

        guard activeIndex >= 0, let rect = wordRects[activeIndex] else {
            highlightLayer.isHidden = true
            return
        }

        highlightLayer.isHidden = false

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
            highlightLayer.frame = rect
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.frame = rect
            CATransaction.commit()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        recalculateWordRects()

        // Snap highlight to current position without animation after relayout
        if currentActiveIndex >= 0, let rect = wordRects[currentActiveIndex] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.frame = rect
            CATransaction.commit()
        }
    }

    override var intrinsicContentSize: NSSize {
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }

    // MARK: - Click handling

    private func handleClick(at point: NSPoint) {
        for (index, rect) in wordRects {
            if rect.contains(point) {
                onWordTapped?(index)
                return
            }
        }
    }

    // MARK: - Private

    private func recalculateWordRects() {
        wordRects.removeAll()

        let fullText = textStorage.string
        guard !fullText.isEmpty, !timestamps.isEmpty else { return }

        layoutManager.ensureLayout(for: textContainer)

        var searchStart = fullText.startIndex

        for ts in timestamps {
            guard let range = fullText.range(
                of: ts.word,
                range: searchStart..<fullText.endIndex
            ) else {
                continue
            }

            let nsRange = NSRange(range, in: fullText)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: nsRange,
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )

            // Add visual padding
            rect = rect.insetBy(dx: -2, dy: -1)

            wordRects[ts.id] = rect
            searchStart = range.upperBound
        }

        invalidateIntrinsicContentSize()
    }
}

// MARK: - Transparent click overlay

/// Sits on top of the NSTextView to intercept clicks (since NSTextView
/// swallows mouse events even when non-editable/non-selectable).
/// Draws nothing — purely a hit-test layer.
/// Uses flipped coordinates so click points match NSLayoutManager word rects.
private final class ClickOverlayView: NSView {
    var onClick: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onClick?(point)
    }

    // Return self for all hits so we intercept clicks over the entire area
    override func hitTest(_ aPoint: NSPoint) -> NSView? {
        let local = convert(aPoint, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
