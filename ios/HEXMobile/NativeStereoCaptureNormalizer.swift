import AVFAudio
import Foundation

/// Inspects an actual native stereo recording and folds it to mono for the speech engines.
/// The per-channel measurements are retained in the report so the next stage can determine
/// whether the channels are meaningfully different before enabling adaptive cancellation.
nonisolated enum NativeStereoCaptureNormalizer {
    private struct Report {
        let channelCount: Int
        let sampleRate: Double
        let frames: Int64
        let leftRMS: Double
        let rightRMS: Double
        let correlation: Double

        var summary: String {
            String(
                format: "Native stereo capture: channels=%d, rate=%.0f Hz, frames=%lld, L-R RMS=%.4f/%.4f, correlation=%.4f, output=mono",
                channelCount,
                sampleRate,
                frames,
                leftRMS,
                rightRMS,
                correlation
            )
        }
    }

    /// Converts a captured stereo PCM file to a mono PCM file at the same sample rate.
    /// If the recorder actually supplied only one channel, the original file is left untouched.
    static func normalizeToMono(at url: URL) -> String {
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).mono-\(UUID().uuidString).wav")
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("stereo-original.wav")

        do {
            let report = try renderStereoInput(at: url, to: temporaryURL)
            guard report.channelCount >= 2 else {
                return "Native audio capture remained mono; no stereo processing was applied."
            }

            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: url, to: backupURL)
            do {
                try fileManager.moveItem(at: temporaryURL, to: url)
                try fileManager.removeItem(at: backupURL)
            } catch {
                try? fileManager.moveItem(at: backupURL, to: url)
                throw error
            }
            return report.summary
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            return "Native stereo normalization failed; original recording retained: \(error.localizedDescription)"
        }
    }

    private static func renderStereoInput(at url: URL, to outputURL: URL) throws -> Report {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = input.processingFormat
        let channelCount = Int(inputFormat.channelCount)
        guard channelCount >= 2 else {
            return Report(
                channelCount: channelCount,
                sampleRate: inputFormat.sampleRate,
                frames: 0,
                leftRMS: 0,
                rightRMS: 0,
                correlation: 0
            )
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let blockSize: AVAudioFrameCount = 2_048
        var totalFrames: Int64 = 0
        var leftSquareSum = 0.0
        var rightSquareSum = 0.0
        var crossSum = 0.0

        while true {
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: blockSize) else {
                throw CocoaError(.coderInvalidValue)
            }
            try input.read(into: inputBuffer)
            let frames = Int(inputBuffer.frameLength)
            guard frames > 0 else { break }
            guard let channels = inputBuffer.floatChannelData,
                  let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: output.processingFormat,
                    frameCapacity: AVAudioFrameCount(frames)
                  ),
                  let outputChannels = outputBuffer.floatChannelData else {
                throw CocoaError(.coderInvalidValue)
            }

            let left = channels[0]
            let right = channels[1]
            let mono = outputChannels[0]
            outputBuffer.frameLength = AVAudioFrameCount(frames)

            for frame in 0..<frames {
                let l = Double(left[frame])
                let r = Double(right[frame])
                leftSquareSum += l * l
                rightSquareSum += r * r
                crossSum += l * r
                mono[frame] = Float((l + r) * 0.5)
            }

            totalFrames += Int64(frames)
            try output.write(from: outputBuffer)
        }

        let denominator = sqrt(leftSquareSum * rightSquareSum)
        let correlation = denominator > 0 ? crossSum / denominator : 0
        let divisor = Double(max(totalFrames, 1))
        return Report(
            channelCount: channelCount,
            sampleRate: inputFormat.sampleRate,
            frames: totalFrames,
            leftRMS: sqrt(leftSquareSum / divisor),
            rightRMS: sqrt(rightSquareSum / divisor),
            correlation: correlation
        )
    }
}
