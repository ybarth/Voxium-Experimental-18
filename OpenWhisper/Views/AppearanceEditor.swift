import SwiftUI

/// Inline editor for a `BarAppearance` — color, gradient, shape, texture.
struct AppearanceEditor: View {
    let label: String
    @Binding var appearance: BarAppearance
    @State private var primaryColor: Color
    @State private var secondaryColor: Color
    @State private var useGradient: Bool

    init(label: String, appearance: Binding<BarAppearance>) {
        self.label = label
        self._appearance = appearance
        let a = appearance.wrappedValue
        let primary = a.colorStops.first.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
            ?? Color.indigo
        let secondary = a.colorStops.count > 1
            ? Color(red: a.colorStops[1].red, green: a.colorStops[1].green, blue: a.colorStops[1].blue)
            : Color.cyan
        self._primaryColor = State(initialValue: primary)
        self._secondaryColor = State(initialValue: secondary)
        self._useGradient = State(initialValue: a.colorStops.count > 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Color
            HStack {
                ColorPicker("Color", selection: $primaryColor, supportsOpacity: false)
                    .onChange(of: primaryColor) { _, _ in syncColors() }

                Toggle("Gradient", isOn: $useGradient)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: useGradient) { _, _ in syncColors() }
            }

            if useGradient {
                HStack {
                    ColorPicker("Second color", selection: $secondaryColor, supportsOpacity: false)
                        .onChange(of: secondaryColor) { _, _ in syncColors() }

                    Picker("Direction", selection: Binding(
                        get: { gradientDirection },
                        set: { setGradientDirection($0) }
                    )) {
                        Text("Horizontal").tag(0.0)
                        Text("Vertical").tag(90.0)
                        Text("Diagonal").tag(135.0)
                    }
                    .fixedSize()
                    .font(.caption)
                }
            }

            // Shape
            HStack {
                Picker("Shape", selection: $appearance.shapePreset) {
                    ForEach(ShapePreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .fixedSize()
                .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Roundness: \(Int(appearance.cornerRadius * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $appearance.cornerRadius, in: 0...1)
                        .controlSize(.mini)
                }
            }

            // Texture
            HStack {
                Picker("Texture", selection: $appearance.texture) {
                    ForEach(TexturePattern.allCases, id: \.self) { tex in
                        Text(tex.rawValue).tag(tex)
                    }
                }
                .fixedSize()
                .font(.caption)

                if appearance.texture != .none {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Intensity: \(Int(appearance.textureOpacity * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $appearance.textureOpacity, in: 0.05...0.8)
                            .controlSize(.mini)
                    }
                }
            }

            // Preview swatch
            RoundedRectangle(cornerRadius: CGFloat(appearance.cornerRadius) * 10)
                .fill(previewFill)
                .frame(height: 24)
                .overlay {
                    if appearance.texture != .none {
                        RoundedRectangle(cornerRadius: CGFloat(appearance.cornerRadius) * 10)
                            .fill(.white.opacity(appearance.textureOpacity * 0.5))
                    }
                }
        }
    }

    // MARK: - Helpers

    private var gradientDirection: Double {
        appearance.gradientAngle
    }

    private func setGradientDirection(_ angle: Double) {
        appearance.gradientAngle = angle
    }

    private var previewFill: some ShapeStyle {
        if useGradient {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [primaryColor, secondaryColor],
                    startPoint: gradientStart,
                    endPoint: gradientEnd
                )
            )
        } else {
            return AnyShapeStyle(primaryColor)
        }
    }

    private var gradientStart: UnitPoint {
        switch appearance.gradientAngle {
        case 90: return .top
        case 135: return .topLeading
        default: return .leading
        }
    }

    private var gradientEnd: UnitPoint {
        switch appearance.gradientAngle {
        case 90: return .bottom
        case 135: return .bottomTrailing
        default: return .trailing
        }
    }

    private func syncColors() {
        var stops: [ColorStop] = []

        let pc = NSColor(primaryColor).usingColorSpace(.sRGB) ?? NSColor(primaryColor)
        stops.append(ColorStop(
            red: Double(pc.redComponent), green: Double(pc.greenComponent),
            blue: Double(pc.blueComponent), alpha: 1.0, location: 0.0
        ))

        if useGradient {
            let sc = NSColor(secondaryColor).usingColorSpace(.sRGB) ?? NSColor(secondaryColor)
            stops.append(ColorStop(
                red: Double(sc.redComponent), green: Double(sc.greenComponent),
                blue: Double(sc.blueComponent), alpha: 1.0, location: 1.0
            ))
        }

        appearance.colorStops = stops
    }
}
