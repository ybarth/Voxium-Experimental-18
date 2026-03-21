import SwiftUI

struct CareModelSettingsView: View {
    let appState: AppState

    private var service: CareModelService { appState.careModelService }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            GroupBox("Care Model") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Runs a small AI model in the background to predict which AI tasks you're likely to need, and pre-loads them for faster response.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Enable Care Model",
                        isOn: Binding(
                            get: { service.isEnabled },
                            set: { newValue in
                                service.isEnabled = newValue
                                if newValue {
                                    service.start()
                                } else {
                                    service.stop()
                                }
                            }
                        )
                    )
                }
                .padding(.vertical, 4)
            }

            if service.isEnabled {
                GroupBox("Timing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(
                            value: Binding(
                                get: { Int(service.pollInterval) },
                                set: { service.pollInterval = TimeInterval($0) }
                            ),
                            in: 1...60,
                            step: 1
                        ) {
                            LabeledContent("Poll Interval") {
                                Text("\(Int(service.pollInterval))s")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("How often the care model assesses context to predict upcoming tasks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Stepper(
                            value: Binding(
                                get: { Int(service.keepAliveTimeout) },
                                set: { service.keepAliveTimeout = TimeInterval($0) }
                            ),
                            in: 30...3600,
                            step: 30
                        ) {
                            LabeledContent("Keep-Alive Timeout") {
                                Text("\(Int(service.keepAliveTimeout))s")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("How long to keep a pre-loaded model in memory without use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Status") {
                    HStack {
                        if service.isAssessing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Assessing context...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if service.lastPredictions.isEmpty {
                            Text("No predictions yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last predictions:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(service.lastPredictions.prefix(5), id: \.task) { prediction in
                                    HStack(spacing: 6) {
                                        ConfidenceBar(value: prediction.confidence)
                                            .frame(width: 40, height: 6)
                                        Text(prediction.task.displayName)
                                            .font(.caption)
                                        Text(String(format: "%.0f%%", prediction.confidence * 100))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                if !service.predictionLog.isEmpty {
                    GroupBox("Recent Prediction Log") {
                        VStack(spacing: 0) {
                            ForEach(service.predictionLog.suffix(5).reversed()) { entry in
                                HStack {
                                    Text(entry.date, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 60, alignment: .leading)
                                    Text(entry.predictions.map { $0.task.displayName }.joined(separator: ", "))
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(entry.predictions.count) tasks")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                                if entry.id != service.predictionLog.suffix(5).first?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geo.size.width * min(value, 1.0))
            }
        }
    }

    private var barColor: Color {
        if value > 0.7 { return .green }
        if value > 0.4 { return .orange }
        return .secondary
    }
}
