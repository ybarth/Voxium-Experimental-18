import Foundation

/// Stateless helpers for silence trimming and phrase-region detection.
/// All methods are static so the enum is never instantiated — safe to call
/// from any actor context.
enum SilenceAnalyzer {

    // MARK: - Configuration

    struct Config {
        /// How many times above the noise floor a window must be to count as speech.
        var noiseFloorMultiplier: Float = 3.0
        /// Absolute minimum RMS threshold (prevents near-zero noise floors from
        /// making everything look like speech).
        var minimumThreshold: Float = 0.02
        /// Number of consecutive windows above threshold required to confirm
        /// speech onset.
        var consecutiveWindows: Int = 3
        /// Margin (ms) kept before detected speech onset when trimming.
        var marginMs: Double = 30
    }

    // MARK: - Trim result

    struct TrimResult {
        let samples: [Float]
        /// Milliseconds removed from the front of the audio.
        let trimOffsetMs: Int
        /// The adaptive threshold that was computed.
        let threshold: Float
    }

    // MARK: - Leading-silence trim

    /// Trims only the leading silence from `samples`.
    /// The end is left untouched because speech naturally trails off and
    /// aggressive end-trimming clips words.
    static func trimLeadingSilence(
        from samples: [Float],
        sampleRate: Double = 16000,
        config: Config = Config()
    ) -> TrimResult {
        let windowSize = Int(sampleRate * 0.02) // 20 ms windows
        guard samples.count > windowSize * 5 else {
            return TrimResult(samples: samples, trimOffsetMs: 0, threshold: config.minimumThreshold)
        }

        let nWindows = samples.count / windowSize

        // RMS per window
        let rms = computeRMS(samples: samples, windowSize: windowSize, windowCount: nWindows)

        // Adaptive threshold
        let threshold = adaptiveThreshold(rms: rms, windowCount: nWindows, config: config)

        // Find speech start: require `consecutiveWindows` consecutive above threshold
        var speechStartWindow = 0
        var run = 0
        for i in 0..<nWindows {
            if rms[i] > threshold {
                run += 1
                if run >= config.consecutiveWindows {
                    speechStartWindow = max(0, i - (config.consecutiveWindows - 1))
                    break
                }
            } else {
                run = 0
            }
        }

        // Convert to sample index with margin
        let marginSamples = Int(sampleRate * config.marginMs / 1000.0)
        let startSample = max(0, speechStartWindow * windowSize - marginSamples)

        guard startSample > 0 else {
            return TrimResult(samples: samples, trimOffsetMs: 0, threshold: threshold)
        }

        let offsetMs = Int(Double(startSample) / sampleRate * 1000)
        return TrimResult(
            samples: Array(samples[startSample...]),
            trimOffsetMs: offsetMs,
            threshold: threshold
        )
    }

    // MARK: - Phrase-region detection

    /// Finds all contiguous speech regions separated by silence gaps.
    ///
    /// Algorithm:
    /// 1. Compute RMS per 20 ms window.
    /// 2. Mark each window as speech (above adaptive threshold) or silence.
    /// 3. Build contiguous runs of speech windows -> raw phrase regions.
    /// 4. Merge regions that are less than 100 ms apart to avoid fragmenting
    ///    natural pauses within sentences.
    static func detectPhraseRegions(
        from samples: [Float],
        sampleRate: Double = 16000,
        config: Config = Config()
    ) -> [PhraseRegion] {
        let windowSize = Int(sampleRate * 0.02) // 20 ms
        guard samples.count > windowSize * 5 else {
            // Too short — treat entire buffer as one region
            let durationMs = Int(Double(samples.count) / sampleRate * 1000)
            guard durationMs > 0 else { return [] }
            return [PhraseRegion(startMs: 0, endMs: durationMs)]
        }

        let nWindows = samples.count / windowSize
        let rms = computeRMS(samples: samples, windowSize: windowSize, windowCount: nWindows)
        let threshold = adaptiveThreshold(rms: rms, windowCount: nWindows, config: config)

        // Classify each window
        var isSpeech = [Bool](repeating: false, count: nWindows)
        for i in 0..<nWindows {
            isSpeech[i] = rms[i] > threshold
        }

        // Build raw regions from contiguous speech windows
        var rawRegions: [(startWindow: Int, endWindow: Int)] = []
        var regionStart: Int?
        for i in 0..<nWindows {
            if isSpeech[i] {
                if regionStart == nil {
                    regionStart = i
                }
            } else {
                if let start = regionStart {
                    rawRegions.append((startWindow: start, endWindow: i))
                    regionStart = nil
                }
            }
        }
        // Close final region if still open
        if let start = regionStart {
            rawRegions.append((startWindow: start, endWindow: nWindows))
        }

        guard !rawRegions.isEmpty else { return [] }

        // Convert windows to milliseconds
        let windowMs = 20 // each window is 20 ms
        var msRegions = rawRegions.map { region in
            (startMs: region.startWindow * windowMs, endMs: region.endWindow * windowMs)
        }

        // Merge regions less than 100 ms apart
        let mergeGapMs = 100
        var merged: [(startMs: Int, endMs: Int)] = [msRegions[0]]
        for i in 1..<msRegions.count {
            let gap = msRegions[i].startMs - merged[merged.count - 1].endMs
            if gap < mergeGapMs {
                merged[merged.count - 1].endMs = msRegions[i].endMs
            } else {
                merged.append(msRegions[i])
            }
        }

        return merged.map { PhraseRegion(startMs: $0.startMs, endMs: $0.endMs) }
    }

    // MARK: - Shared helpers

    /// Computes RMS energy per window.
    private static func computeRMS(
        samples: [Float],
        windowSize: Int,
        windowCount: Int
    ) -> [Float] {
        var rms = [Float](repeating: 0, count: windowCount)
        for i in 0..<windowCount {
            let start = i * windowSize
            let end = start + windowSize
            var sum: Float = 0
            for j in start..<end {
                sum += samples[j] * samples[j]
            }
            rms[i] = sqrt(sum / Float(windowSize))
        }
        return rms
    }

    /// Computes adaptive threshold from noise floor (median of first ~50 ms).
    private static func adaptiveThreshold(
        rms: [Float],
        windowCount: Int,
        config: Config
    ) -> Float {
        let noiseWindows = min(3, windowCount)
        var sortedNoise = Array(rms[0..<noiseWindows])
        sortedNoise.sort()
        let noiseFloor = sortedNoise[noiseWindows / 2] // median
        return max(noiseFloor * config.noiseFloorMultiplier, config.minimumThreshold)
    }
}
