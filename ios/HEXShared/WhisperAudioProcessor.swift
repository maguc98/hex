import Foundation

/// Gentle gain for whispered speech, with a smooth limiter instead of hard clipping.
/// Samples remain signed 16-bit little-endian PCM, matching the keyboard capture WAV.
nonisolated enum WhisperAudioProcessor {
    static let defaultGain: Float = 2.4

    /// Linear amplification below the soft-knee threshold; above it, the signal compresses
    /// continuously toward 90% full scale. This preserves quiet consonants without flattening
    /// louder syllable peaks into a square wave.
    private static let knee: Float = 0.65
    private static let kneeWidth: Float = 0.25
    private static let safetyCeiling: Int32 = 30_000

    static func amplify(_ data: Data, gain: Float = defaultGain) -> Data {
        guard data.count >= 2, gain.isFinite, gain > 0 else { return data }

        var bytes = Array(data)
        for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let sample = Int16(bitPattern: bits)
            let magnitude = abs(Float(sample)) / 32_768
            let driven = magnitude * gain
            let limited: Float
            if driven <= knee {
                limited = driven
            } else {
                let overKnee = driven - knee
                limited = knee + overKnee / (1 + overKnee / kneeWidth)
            }

            let outputMagnitude = Int32((limited * 32_768).rounded())
            let signedOutput = sample < 0 ? -outputMagnitude : outputMagnitude
            let output = UInt16(bitPattern: Int16(
                max(-safetyCeiling, min(safetyCeiling, signedOutput))
            ))
            bytes[offset] = UInt8(truncatingIfNeeded: output)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: output >> 8)
        }
        return Data(bytes)
    }
}
