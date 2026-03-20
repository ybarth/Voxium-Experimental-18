import Foundation

/// Generates `WaveformData` from raw audio samples.
/// Stateless — all methods are static on an uninhabitable enum.
enum WaveformDataGenerator {

    /// Builds a complete `WaveformData` value from original and trimmed samples.
    ///
    /// - Parameters:
    ///   - originalSamples: The full, untrimmed audio buffer.
    ///   - trimmedSamples:  Audio after leading silence was removed.
    ///   - trimOffsetMs:    Milliseconds removed from the front.
    ///   - sampleRate:      Sample rate (typically 16 000).
    ///   - barCount:        Number of waveform bars to produce (~300).
    ///   - silenceConfig:   Config forwarded to `SilenceAnalyzer`.
    /// - Returns: A fully populated `WaveformData`.
    static func generate(
        originalSamples: [Float],
        trimmedSamples: [Float],
        trimOffsetMs: Int,
        sampleRate: Double,
        barCount: Int = 300,
        silenceConfig: SilenceAnalyzer.Config = .init()
    ) -> WaveformData {
        let peaks = computePeaks(
            from: originalSamples,
            barCount: barCount
        )

        let phraseRegions = SilenceAnalyzer.detectPhraseRegions(
            from: originalSamples,
            sampleRate: sampleRate,
            config: silenceConfig
        )

        let originalDurationMs = Int(Double(originalSamples.count) / sampleRate * 1000)
        let trimmedDurationMs = Int(Double(trimmedSamples.count) / sampleRate * 1000)

        // Recompute the threshold so we can store it for reference
        let threshold = recomputeThreshold(
            from: originalSamples,
            sampleRate: sampleRate,
            config: silenceConfig
        )

        return WaveformData(
            peaks: peaks,
            phraseRegions: phraseRegions,
            originalDurationMs: originalDurationMs,
            trimmedDurationMs: trimmedDurationMs,
            trimOffsetMs: trimOffsetMs,
            trimThreshold: threshold
        )
    }

    // MARK: - Peak computation

    /// Divides samples into `barCount` equal buckets and returns the
    /// peak absolute amplitude per bucket, normalized to [0, 1].
    private static func computePeaks(
        from samples: [Float],
        barCount: Int
    ) -> [Float] {
        guard !samples.isEmpty, barCount > 0 else { return [] }

        let samplesPerBar = max(1, samples.count / barCount)
        var rawPeaks = [Float](repeating: 0, count: barCount)
        var globalMax: Float = 0

        for bar in 0..<barCount {
            let start = bar * samplesPerBar
            let end = min(start + samplesPerBar, samples.count)
            guard start < end else { continue }

            var peak: Float = 0
            for i in start..<end {
                let v = abs(samples[i])
                if v > peak { peak = v }
            }
            rawPeaks[bar] = peak
            if peak > globalMax { globalMax = peak }
        }

        // Normalize to [0, 1]
        guard globalMax > 0 else { return rawPeaks }
        for i in 0..<rawPeaks.count {
            rawPeaks[i] /= globalMax
        }
        return rawPeaks
    }

    // MARK: - Threshold helper

    /// Recomputes the adaptive silence threshold so it can be stored in
    /// `WaveformData.trimThreshold` without duplicating the algorithm.
    private static func recomputeThreshold(
        from samples: [Float],
        sampleRate: Double,
        config: SilenceAnalyzer.Config
    ) -> Float {
        let windowSize = Int(sampleRate * 0.02)
        guard samples.count > windowSize * 5 else { return config.minimumThreshold }

        let nWindows = samples.count / windowSize
        let noiseWindows = min(3, nWindows)

        // Compute RMS for just the first few windows (noise floor estimation)
        var noiseRMS = [Float](repeating: 0, count: noiseWindows)
        for i in 0..<noiseWindows {
            let start = i * windowSize
            let end = start + windowSize
            var sum: Float = 0
            for j in start..<end {
                sum += samples[j] * samples[j]
            }
            noiseRMS[i] = sqrt(sum / Float(windowSize))
        }
        noiseRMS.sort()
        let noiseFloor = noiseRMS[noiseWindows / 2]
        return max(noiseFloor * config.noiseFloorMultiplier, config.minimumThreshold)
    }
}
