import AppKit
import QuartzCore
import SwiftUI

// MARK: - NSViewRepresentable bridge

struct WaveformBarView: NSViewRepresentable {
    let waveformData: WaveformData
    let currentTimeMs: Int
    let durationMs: Int
    let isPlaying: Bool
    var showSilentRegions: Bool = false
    var barAppearance: BarAppearance = AppearanceStore.globalBarAppearance
    var entryAppearance: BarAppearance = AppearanceStore.globalEntryAppearance
    let onSeek: ((Int) -> Void)?

    func makeNSView(context: Context) -> WaveformBarNSView {
        let view = WaveformBarNSView()
        view.barAppearance = barAppearance
        view.entryAppearance = entryAppearance
        view.setWaveformData(waveformData, showSilent: showSilentRegions)
        view.onSeek = onSeek
        view.updatePlayhead(currentTimeMs: currentTimeMs, durationMs: durationMs, animated: false)
        return view
    }

    func updateNSView(_ nsView: WaveformBarNSView, context: Context) {
        nsView.onSeek = onSeek
        nsView.barAppearance = barAppearance
        nsView.entryAppearance = entryAppearance
        nsView.setWaveformData(waveformData, showSilent: showSilentRegions)
        nsView.updatePlayhead(currentTimeMs: currentTimeMs, durationMs: durationMs, animated: isPlaying)
    }
}

// MARK: - WaveformBarNSView

final class WaveformBarNSView: NSView {
    var onSeek: ((Int) -> Void)?
    var barAppearance: BarAppearance = .defaultBar { didSet { invalidateBars() } }
    var entryAppearance: BarAppearance = .defaultEntry { didSet { invalidateBars() } }

    private var waveformData: WaveformData?
    private var showSilentRegions = false
    private var cachedBarImage: NSImage?
    private var lastBoundsWidth: CGFloat = 0

    private let playheadLayer = CALayer()
    private var currentDurationMs: Int = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        playheadLayer.backgroundColor = NSColor.white.cgColor
        playheadLayer.shadowColor = NSColor.black.cgColor
        playheadLayer.shadowOpacity = 0.6
        playheadLayer.shadowRadius = 2
        playheadLayer.shadowOffset = .zero
        playheadLayer.isHidden = true
        layer?.addSublayer(playheadLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func setWaveformData(_ data: WaveformData, showSilent: Bool) {
        let dataChanged = waveformData?.peaks.count != data.peaks.count
        waveformData = data
        if showSilent != showSilentRegions || dataChanged {
            showSilentRegions = showSilent
            invalidateBars()
        }
    }

    func updatePlayhead(currentTimeMs: Int, durationMs: Int, animated: Bool) {
        currentDurationMs = max(durationMs, 1)
        let fraction = CGFloat(currentTimeMs) / CGFloat(currentDurationMs)
        let x = fraction * bounds.width

        let newFrame = CGRect(x: x - 1, y: 0, width: 2, height: bounds.height)
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.0 / 30.0)
            playheadLayer.frame = newFrame
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playheadLayer.frame = newFrame
            CATransaction.commit()
        }
        playheadLayer.isHidden = currentTimeMs <= 0 && !animated
    }

    private func invalidateBars() {
        cachedBarImage = nil
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let data = waveformData, !data.peaks.isEmpty else { return }

        if cachedBarImage == nil || lastBoundsWidth != bounds.width {
            cachedBarImage = renderBars(data: data, size: bounds.size)
            lastBoundsWidth = bounds.width
        }
        cachedBarImage?.draw(in: bounds)
    }

    private func renderBars(data: WaveformData, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // Draw entry background
        let bgRect = CGRect(origin: .zero, size: size)
        drawFill(entryAppearance, in: bgRect, context: ctx, cornerRadius: entryAppearance.cornerRadius * 8)
        if entryAppearance.texture != .none {
            TextureRenderer.draw(
                entryAppearance.texture, in: bgRect,
                color: .white, opacity: CGFloat(entryAppearance.textureOpacity),
                context: ctx
            )
        }

        let barCount = data.peaks.count
        guard barCount > 0 else { image.unlockFocus(); return image }

        // Group bars into phrase blocks — draw each phrase as a filled pill with waveform inside
        let phraseRegions = data.phraseRegions.isEmpty
            ? [PhraseRegion(startMs: 0, endMs: data.originalDurationMs)]
            : data.phraseRegions

        let totalMs = Double(data.originalDurationMs)
        guard totalMs > 0 else { image.unlockFocus(); return image }

        for region in phraseRegions {
            let startFrac = Double(region.startMs) / totalMs
            let endFrac = Double(region.endMs) / totalMs
            let x = CGFloat(startFrac) * size.width
            let w = CGFloat(endFrac - startFrac) * size.width
            let pillRect = CGRect(x: x, y: 2, width: w, height: size.height - 4)

            // Draw pill background
            let cr = CGFloat(barAppearance.cornerRadius) * min(pillRect.height, pillRect.width) / 2
            drawFill(barAppearance, in: pillRect, context: ctx, cornerRadius: cr)

            // Draw texture on pill
            if barAppearance.texture != .none {
                ctx.saveGState()
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: cr, cornerHeight: cr, transform: nil)
                ctx.addPath(pillPath)
                ctx.clip()
                TextureRenderer.draw(
                    barAppearance.texture, in: pillRect,
                    color: .white, opacity: CGFloat(barAppearance.textureOpacity),
                    context: ctx
                )
                ctx.restoreGState()
            }

            // Draw waveform peaks inside the pill
            let startBar = Int(startFrac * Double(barCount))
            let endBar = min(Int(endFrac * Double(barCount)), barCount)
            guard endBar > startBar else { continue }

            let peakBarWidth: CGFloat = max(1, (w / CGFloat(endBar - startBar)) * 0.6)
            let peakSpacing = w / CGFloat(endBar - startBar)
            let maxHeight = pillRect.height - 4
            let centerY = pillRect.midY

            ctx.saveGState()
            let clipPath = CGPath(roundedRect: pillRect, cornerWidth: cr, cornerHeight: cr, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()

            ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            for i in startBar..<endBar {
                let peak = CGFloat(data.peaks[i])
                let barH = max(2, peak * maxHeight)
                let localX = CGFloat(i - startBar) * peakSpacing + (peakSpacing - peakBarWidth) / 2 + pillRect.minX
                let peakRect = CGRect(x: localX, y: centerY - barH / 2, width: peakBarWidth, height: barH)
                let peakPath = NSBezierPath(roundedRect: peakRect, xRadius: peakBarWidth / 2, yRadius: peakBarWidth / 2)
                peakPath.fill()
            }
            ctx.restoreGState()
        }

        // Draw silent regions if toggled
        if showSilentRegions {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
            // Fill gaps between phrase regions
            var prevEnd = 0
            for region in phraseRegions {
                if region.startMs > prevEnd {
                    let gapStartFrac = Double(prevEnd) / totalMs
                    let gapEndFrac = Double(region.startMs) / totalMs
                    let gx = CGFloat(gapStartFrac) * size.width
                    let gw = CGFloat(gapEndFrac - gapStartFrac) * size.width
                    ctx.fill(CGRect(x: gx, y: 2, width: gw, height: size.height - 4))
                }
                prevEnd = region.endMs
            }
            if prevEnd < data.originalDurationMs {
                let gapStartFrac = Double(prevEnd) / totalMs
                let gx = CGFloat(gapStartFrac) * size.width
                let gw = size.width - gx
                ctx.fill(CGRect(x: gx, y: 2, width: gw, height: size.height - 4))
            }
        }

        image.unlockFocus()
        return image
    }

    /// Fill a rect with the appearance's color (solid or gradient).
    private func drawFill(_ appearance: BarAppearance, in rect: CGRect, context: CGContext, cornerRadius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        if appearance.isSolid {
            context.saveGState()
            context.addPath(path)
            context.setFillColor(appearance.primaryNSColor.cgColor)
            context.fillPath()
            context.restoreGState()
        } else {
            // Gradient fill
            context.saveGState()
            context.addPath(path)
            context.clip()

            let colors = appearance.colorStops.map { $0.nsColor.cgColor } as CFArray
            let locations = appearance.colorStops.map { CGFloat($0.location) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else {
                context.restoreGState()
                return
            }

            let angleRad = CGFloat(appearance.gradientAngle) * .pi / 180
            let dx = cos(angleRad) * rect.width / 2
            let dy = sin(angleRad) * rect.height / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)

            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: center.x - dx, y: center.y - dy),
                end: CGPoint(x: center.x + dx, y: center.y + dy),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        }
    }

    override func layout() {
        super.layout()
        if lastBoundsWidth != bounds.width { invalidateBars() }
    }

    // MARK: - Click to seek

    override func mouseDown(with event: NSEvent) { handleSeek(with: event) }
    override func mouseDragged(with event: NSEvent) { handleSeek(with: event) }

    private func handleSeek(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, point.x / bounds.width))
        let ms = Int(fraction * Double(currentDurationMs))
        onSeek?(ms)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 48)
    }
}
