import Foundation

/// Small helpers for turning raw samples into loudness numbers.
public enum AudioLevel {
    /// Root-mean-square amplitude of `samples` (0 for an empty slice).
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func rms(_ samples: [Float]) -> Float {
        rms(samples[...])
    }

    /// Converts an RMS amplitude to dBFS, never returning less than `floor`.
    public static func decibels(fromRMS rms: Float, floor: Float = -100) -> Float {
        guard rms.isFinite, rms > 0 else { return floor }
        return max(floor, Float(20 * log10(Double(rms))))
    }

    /// Maps a dBFS value onto 0...1 for level meters.
    public static func meterValue(decibels: Float, floor: Float = -60) -> Float {
        guard decibels.isFinite, decibels > floor else { return 0 }
        return min(1, (decibels - floor) / -floor)
    }
}
