import SwiftUI

struct PlaybackControlsView: View {
    let playbackManager: AudioPlaybackManager
    var continuousMode: Binding<Bool>?

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 5.0]

    var body: some View {
        VStack(spacing: 6) {
            // Scrubber — updates word highlighting live during drag
            Slider(
                value: Binding(
                    get: {
                        isDragging ? dragValue : Double(playbackManager.currentTimeMs)
                    },
                    set: { newValue in
                        dragValue = newValue
                        isDragging = true
                        // Live-update highlighting while dragging
                        playbackManager.previewSeek(toMs: Int(newValue))
                    }
                ),
                in: 0...max(Double(playbackManager.durationMs), 1),
                onEditingChanged: { editing in
                    if !editing {
                        // Commit seek to the actual player on release
                        playbackManager.seek(toMs: Int(dragValue))
                        isDragging = false
                    }
                }
            )
            .controlSize(.small)

            HStack {
                // Time labels
                Text(formatTime(playbackManager.currentTimeMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                // Continuous playback toggle
                if let continuous = continuousMode {
                    Button {
                        continuous.wrappedValue.toggle()
                    } label: {
                        Image(systemName: continuous.wrappedValue
                              ? "repeat.circle.fill"
                              : "repeat.circle")
                            .font(.body)
                            .foregroundStyle(continuous.wrappedValue ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(continuous.wrappedValue
                          ? "Continuous playback ON"
                          : "Continuous playback OFF")
                }

                // Play/pause
                Button {
                    playbackManager.togglePlayPause()
                } label: {
                    Image(systemName: playbackManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                }
                .buttonStyle(.borderless)

                Spacer()

                // Speed picker
                Menu {
                    ForEach(Self.speeds, id: \.self) { speed in
                        Button {
                            playbackManager.setRate(speed)
                        } label: {
                            HStack {
                                Text(formatSpeed(speed))
                                if playbackManager.playbackRate == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(formatSpeed(playbackManager.playbackRate))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(formatTime(playbackManager.durationMs))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    private func formatTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatSpeed(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        return String(format: "%.1fx", speed)
    }
}
