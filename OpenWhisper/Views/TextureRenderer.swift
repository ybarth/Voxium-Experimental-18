import AppKit
import CoreGraphics

/// Draws repeating texture patterns into a CGContext, clipped to a given rect.
enum TextureRenderer {

    /// Draw a texture pattern into the current graphics context at the given rect.
    static func draw(
        _ pattern: TexturePattern,
        in rect: CGRect,
        color: NSColor,
        opacity: CGFloat,
        context: CGContext
    ) {
        guard pattern != .none, opacity > 0 else { return }

        context.saveGState()
        context.clip(to: rect)

        let patternColor = color.withAlphaComponent(opacity)
        patternColor.setStroke()
        patternColor.setFill()

        switch pattern {
        case .none:
            break
        case .striped:
            drawStripes(in: rect, spacing: 6, lineWidth: 2, context: context)
        case .checkered:
            drawCheckers(in: rect, cellSize: 8, context: context)
        case .polkaDot:
            drawPolkaDots(in: rect, dotRadius: 2, spacing: 10, context: context)
        case .starred:
            drawStars(in: rect, starSize: 8, spacing: 14, context: context)
        case .crosshatch:
            drawCrosshatch(in: rect, spacing: 8, lineWidth: 1, context: context)
        case .diagonalLines:
            drawDiagonalLines(in: rect, spacing: 8, lineWidth: 2, context: context)
        case .herringbone:
            drawHerringbone(in: rect, spacing: 10, lineWidth: 1.5, context: context)
        case .honeycomb:
            drawHoneycomb(in: rect, cellSize: 10, context: context)
        }

        context.restoreGState()
    }

    // MARK: - Pattern implementations

    private static func drawStripes(in rect: CGRect, spacing: CGFloat, lineWidth: CGFloat, context: CGContext) {
        context.setLineWidth(lineWidth)
        var x = rect.minX
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        context.strokePath()
    }

    private static func drawCheckers(in rect: CGRect, cellSize: CGFloat, context: CGContext) {
        var y = rect.minY
        var rowEven = true
        while y < rect.maxY {
            var x = rect.minX + (rowEven ? 0 : cellSize)
            while x < rect.maxX {
                let cell = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                context.fill(cell)
                x += cellSize * 2
            }
            y += cellSize
            rowEven.toggle()
        }
    }

    private static func drawPolkaDots(in rect: CGRect, dotRadius: CGFloat, spacing: CGFloat, context: CGContext) {
        var y = rect.minY + spacing / 2
        var rowEven = true
        while y < rect.maxY {
            var x = rect.minX + (rowEven ? spacing / 2 : spacing)
            while x < rect.maxX {
                let dotRect = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fillEllipse(in: dotRect)
                x += spacing
            }
            y += spacing * 0.866 // equilateral triangle packing
            rowEven.toggle()
        }
    }

    private static func drawStars(in rect: CGRect, starSize: CGFloat, spacing: CGFloat, context: CGContext) {
        var y = rect.minY + spacing / 2
        while y < rect.maxY {
            var x = rect.minX + spacing / 2
            while x < rect.maxX {
                drawStar(at: CGPoint(x: x, y: y), size: starSize, context: context)
                x += spacing
            }
            y += spacing
        }
    }

    private static func drawStar(at center: CGPoint, size: CGFloat, context: CGContext) {
        let points = 5
        let r = size / 2
        let innerR = r * 0.4
        context.beginPath()
        for i in 0..<(points * 2) {
            let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : innerR
            let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
        context.closePath()
        context.fillPath()
    }

    private static func drawCrosshatch(in rect: CGRect, spacing: CGFloat, lineWidth: CGFloat, context: CGContext) {
        context.setLineWidth(lineWidth)
        // Forward diagonals
        var offset = rect.minX - rect.height
        while offset < rect.maxX {
            context.move(to: CGPoint(x: offset, y: rect.maxY))
            context.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
            offset += spacing
        }
        // Backward diagonals
        offset = rect.minX - rect.height
        while offset < rect.maxX {
            context.move(to: CGPoint(x: offset + rect.height, y: rect.maxY))
            context.addLine(to: CGPoint(x: offset, y: rect.minY))
            offset += spacing
        }
        context.strokePath()
    }

    private static func drawDiagonalLines(in rect: CGRect, spacing: CGFloat, lineWidth: CGFloat, context: CGContext) {
        context.setLineWidth(lineWidth)
        var offset = rect.minX - rect.height
        while offset < rect.maxX + rect.height {
            context.move(to: CGPoint(x: offset, y: rect.maxY))
            context.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
            offset += spacing
        }
        context.strokePath()
    }

    private static func drawHerringbone(in rect: CGRect, spacing: CGFloat, lineWidth: CGFloat, context: CGContext) {
        context.setLineWidth(lineWidth)
        let segLen = spacing
        var y = rect.minY
        var rowEven = true
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                if rowEven {
                    context.move(to: CGPoint(x: x, y: y + segLen / 2))
                    context.addLine(to: CGPoint(x: x + segLen / 2, y: y))
                    context.addLine(to: CGPoint(x: x + segLen, y: y + segLen / 2))
                } else {
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + segLen / 2, y: y + segLen / 2))
                    context.addLine(to: CGPoint(x: x + segLen, y: y))
                }
                x += segLen
            }
            y += segLen / 2
            rowEven.toggle()
        }
        context.strokePath()
    }

    private static func drawHoneycomb(in rect: CGRect, cellSize: CGFloat, context: CGContext) {
        context.setLineWidth(1)
        let w = cellSize
        let h = cellSize * 0.866
        var row = 0
        var y = rect.minY
        while y < rect.maxY + h {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : w * 0.75)
            while x < rect.maxX + w {
                drawHexagon(at: CGPoint(x: x, y: y), size: w / 2, context: context)
                x += w * 1.5
            }
            y += h
            row += 1
        }
        context.strokePath()
    }

    private static func drawHexagon(at center: CGPoint, size: CGFloat, context: CGContext) {
        context.beginPath()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 6
            let p = CGPoint(x: center.x + cos(angle) * size, y: center.y + sin(angle) * size)
            if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
        }
        context.closePath()
        context.strokePath()
    }
}
