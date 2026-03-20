import Foundation
import SwiftUI

// MARK: - Color stop for gradients

struct ColorStop: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    let location: Double // 0.0 - 1.0

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    static func solid(_ color: NSColor) -> [ColorStop] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [ColorStop(
            red: Double(c.redComponent),
            green: Double(c.greenComponent),
            blue: Double(c.blueComponent),
            alpha: Double(c.alphaComponent),
            location: 0.5
        )]
    }
}

// MARK: - Shape presets

enum ShapePreset: String, Codable, CaseIterable {
    case rounded = "Rounded"
    case square = "Square"
    case hexagon = "Hexagon"
    case diamond = "Diamond"
    case chevron = "Chevron"
}

// MARK: - Texture patterns

enum TexturePattern: String, Codable, CaseIterable {
    case none = "None"
    case striped = "Striped"
    case checkered = "Checkered"
    case polkaDot = "Polka Dot"
    case starred = "Starred"
    case crosshatch = "Crosshatch"
    case diagonalLines = "Diagonal Lines"
    case herringbone = "Herringbone"
    case honeycomb = "Honeycomb"
}

// MARK: - Appearance struct (used for both bars and entry rows)

struct BarAppearance: Codable, Equatable {
    var colorStops: [ColorStop]
    var gradientAngle: Double       // degrees, 0 = horizontal left-to-right
    var cornerRadius: Double        // 0.0 = square, 1.0 = full pill
    var shapePreset: ShapePreset
    var texture: TexturePattern
    var textureOpacity: Double      // 0.0 - 1.0

    static let defaultBar = BarAppearance(
        colorStops: ColorStop.solid(NSColor(red: 0.39, green: 0.40, blue: 0.95, alpha: 1.0)), // indigo
        gradientAngle: 0,
        cornerRadius: 1.0,
        shapePreset: .rounded,
        texture: .none,
        textureOpacity: 0.3
    )

    static let defaultEntry = BarAppearance(
        colorStops: ColorStop.solid(NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)), // dark bg
        gradientAngle: 0,
        cornerRadius: 0.4,
        shapePreset: .rounded,
        texture: .none,
        textureOpacity: 0.2
    )

    /// Resolve colors for drawing. Returns a single color if solid, or gradient stops.
    var isSolid: Bool { colorStops.count <= 1 }

    var primaryNSColor: NSColor {
        colorStops.first?.nsColor ?? NSColor.controlAccentColor
    }
}

// MARK: - Per-entry overrides

/// Optional per-entry overrides. nil fields fall back to global defaults.
struct EntryAppearanceOverride: Codable {
    var barAppearance: BarAppearance?
    var entryAppearance: BarAppearance?

    /// Resolve bar appearance: per-entry override or global default.
    var resolvedBar: BarAppearance {
        barAppearance ?? AppearanceStore.globalBarAppearance
    }

    /// Resolve entry appearance: per-entry override or global default.
    var resolvedEntry: BarAppearance {
        entryAppearance ?? AppearanceStore.globalEntryAppearance
    }
}

// MARK: - Luminance helpers

extension BarAppearance {
    /// Average luminance of the color stops (0 = black, 1 = white).
    var luminance: Double {
        guard !colorStops.isEmpty else { return 0.5 }
        let sum = colorStops.reduce(0.0) { acc, stop in
            acc + 0.299 * stop.red + 0.587 * stop.green + 0.114 * stop.blue
        }
        return sum / Double(colorStops.count)
    }
}

// MARK: - Persistence + smart contrast

enum AppearanceStore {
    private static let barKey = "globalBarAppearance"
    private static let entryKey = "globalEntryAppearance"
    private static let barLockedKey = "barAppearanceUserSet"
    private static let entryLockedKey = "entryAppearanceUserSet"

    static var globalBarAppearance: BarAppearance {
        get { load(key: barKey) ?? .defaultBar }
        set { save(newValue, key: barKey) }
    }

    static var globalEntryAppearance: BarAppearance {
        get { load(key: entryKey) ?? .defaultEntry }
        set { save(newValue, key: entryKey) }
    }

    /// Whether the user has explicitly set bar appearance (vs auto-computed).
    static var barIsUserSet: Bool {
        get { UserDefaults.standard.bool(forKey: barLockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: barLockedKey) }
    }

    /// Whether the user has explicitly set entry appearance.
    static var entryIsUserSet: Bool {
        get { UserDefaults.standard.bool(forKey: entryLockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: entryLockedKey) }
    }

    /// Call when the user changes bar appearance. Auto-adjusts entry for contrast
    /// unless the user has explicitly set the entry appearance.
    static func setBarAppearance(_ bar: BarAppearance) {
        globalBarAppearance = bar
        barIsUserSet = true
        if !entryIsUserSet {
            globalEntryAppearance = contrastingEntry(for: bar)
        }
    }

    /// Call when the user changes entry appearance. Auto-adjusts bar for contrast
    /// unless the user has explicitly set the bar appearance.
    static func setEntryAppearance(_ entry: BarAppearance) {
        globalEntryAppearance = entry
        entryIsUserSet = true
        if !barIsUserSet {
            globalBarAppearance = contrastingBar(for: entry)
        }
    }

    /// Reset both to defaults and clear user-set flags.
    static func resetToDefaults() {
        globalBarAppearance = .defaultBar
        globalEntryAppearance = .defaultEntry
        barIsUserSet = false
        entryIsUserSet = false
    }

    // MARK: - Contrast computation

    /// Generate a contrasting entry appearance for a given bar appearance.
    private static func contrastingEntry(for bar: BarAppearance) -> BarAppearance {
        let barLum = bar.luminance
        // If bar is bright, entry should be dark; if bar is dark, entry stays dark but lighter
        let entryColor: NSColor
        if barLum > 0.5 {
            entryColor = NSColor(white: 0.08, alpha: 1.0)
        } else {
            entryColor = NSColor(white: 0.12, alpha: 1.0)
        }

        // Pick a contrasting texture: if bar has a texture, entry should have none (or vice versa)
        let entryTexture: TexturePattern = bar.texture != .none ? .none : .none

        return BarAppearance(
            colorStops: ColorStop.solid(entryColor),
            gradientAngle: 0,
            cornerRadius: 0.4,
            shapePreset: .rounded,
            texture: entryTexture,
            textureOpacity: 0.15
        )
    }

    /// Generate a contrasting bar appearance for a given entry appearance.
    private static func contrastingBar(for entry: BarAppearance) -> BarAppearance {
        let entryLum = entry.luminance
        let barColor: NSColor
        if entryLum < 0.3 {
            // Dark entry → vibrant bar
            barColor = NSColor(red: 0.39, green: 0.40, blue: 0.95, alpha: 1.0)
        } else {
            // Light entry → deeper bar
            barColor = NSColor(red: 0.25, green: 0.26, blue: 0.75, alpha: 1.0)
        }

        let barTexture: TexturePattern = entry.texture != .none ? .none : .none

        return BarAppearance(
            colorStops: ColorStop.solid(barColor),
            gradientAngle: 0,
            cornerRadius: 1.0,
            shapePreset: .rounded,
            texture: barTexture,
            textureOpacity: 0.3
        )
    }

    // MARK: - Storage

    private static func load(key: String) -> BarAppearance? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BarAppearance.self, from: data)
    }

    private static func save(_ appearance: BarAppearance, key: String) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
