import Foundation

struct WaveformData: Codable {
    /// Downsampled peak amplitudes normalized to [0,1], ~300 bars
    let peaks: [Float]
    /// Contiguous speech regions in ms (relative to ORIGINAL audio)
    let phraseRegions: [PhraseRegion]
    let originalDurationMs: Int
    let trimmedDurationMs: Int
    /// How much was removed from the front
    let trimOffsetMs: Int
    /// Silence threshold used
    let trimThreshold: Float
}

struct PhraseRegion: Codable, Identifiable {
    let startMs: Int
    let endMs: Int
    var id: Int { startMs } // unique enough for display
}
