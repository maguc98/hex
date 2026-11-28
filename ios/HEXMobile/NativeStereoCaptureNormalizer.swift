import AVFAudio
import Foundation

/// Reads the native input's real channel layout, performs conservative two-channel
/// reference cancellation when requested, then writes the mono PCM format used by speech.
nonisolated enum NativeStereoCaptureNormalizer {
    private struct Report {
        let channelCount: Int
        let sampleRate: Double
        let frames: Int64
        let leftRMS: Double
        let rightRMS: Double
        let correlation: Double
        let cancellationBlocks: Int
        let cancelledFrames: Int64
        let cancellationPeak: Double
        let whisperGainApplied: Bool

        var summary: String {
            String(
                format: "Native audio capture: channels=%d, rate=%.0f Hz, frames=%lld, L-R RMS=%.4f/%.4f, correlation=%.4f, cancellation blocks=%d, affected frames=%lld, peak reduction=%.4f, whisper gain=%@, output=mono",
                channelCount,
                sampleRate,
                frames,
                leftRMS,
                rightRMS,
                correlation,
                cancellationBlocks,
                cancelledFrames,
                cancellationPeak,
                whisperGainApplied ? "on" : "off"
            )
        }
    }

    /// Converts native stereo to mono for speech, optionally applying whisper gain.
    /// A mono capture is left untouched unless whisper gain was explicitly requested.
    static func normalizeToMono(
        at url: URL,
        noiseReduction: Bool = false,
        amplifyWhisper: Bool = false
    ) -> String {
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).mono-\(UUID().uuidString).wav")
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("capture-original.wav")

        do {
            let report = try renderInput(
                at: url,
                to: temporaryURL,
                noiseReduction: noiseReduction,
                amplifyWhisper: amplifyWhisper
            )
            guard report.channelCount >= 2 || amplifyWhisper else {
                return "Native audio capture remained mono; no second channel was available."
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
            return "Native audio processing failed; original recording retained: \(error.localizedDescription)"
        }
    }

    private static func renderInput(
        at url: URL,
        to outputURL: URL,
        noiseReduction: Bool,
        amplifyWhisper: Bool
    ) throws -> Report {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = input.processingFormat
        let channelCount = Int(inputFormat.channelCount)
        guard channelCount >= 2 || amplifyWhisper else {
            return Report(
                channelCount: channelCount,
                sampleRate: inputFormat.sampleRate,
                frames: 0,
                leftRMS: 0,
                rightRMS: 0,
                correlation: 0,
                cancellationBlocks: 0,
                cancelledFrames: 0,
                cancellationPeak: 0,
                whisperGainApplied: false
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

        let filterTaps = 64
        let filterMu: Float = 0.025
        let filterEpsilon: Float = 1e-5
        var referenceHistory = [Float](repeating: 0, count: filterTaps)
        var adaptiveWeights = [Float](repeating: 0, count: filterTaps)
        var historyIndex = 0

        let blockSize: AVAudioFrameCount = 2_048
        var totalFrames: Int64 = 0
        var leftSquareSum = 0.0
        var rightSquareSum = 0.0
        var crossSum = 0.0
        var cancellationBlocks = 0
        var cancelledFrames: Int64 = 0
        var cancellationPeak = 0.0

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

            let primaryChannel = channels[0]
            let hasReference = channelCount >= 2
            let referenceChannel = hasReference ? channels[1] : channels[0]

            var primarySumSq = 0.0
            var referenceSumSq = 0.0
            var cross = 0.0
            var differenceSumSq = 0.0

            for frame in 0..<frames {
                let primary = Double(primaryChannel[frame])
                let reference = Double(referenceChannel[frame])
                primarySumSq += primary * primary
                if hasReference {
                    referenceSumSq += reference * reference
                    cross += primary * reference
                    let difference = primary - reference
                    differenceSumSq += difference * difference
                }
            }

            let divisor = Double(max(frames, 1))
            let primaryRMS = sqrt(primarySumSq / divisor)
            let referenceRMS = hasReference ? sqrt(referenceSumSq / divisor) : 0
            let blockCorrelation = hasReference && primarySumSq > 1e-12 && referenceSumSq > 1e-12
                ? cross / sqrt(primarySumSq * referenceSumSq) : 0
            let differenceRMS = hasReference ? sqrt(differenceSumSq / divisor) : 0
            let duplicatedChannels = hasReference
                && abs(blockCorrelation) > 0.995
                && differenceRMS < max(0.002, primaryRMS * 0.035)
            let validReference = noiseReduction
                && hasReference
                && referenceRMS > 0.003
                && !duplicatedChannels
            let speechDominant = primaryRMS > referenceRMS * 1.30 + 0.012
            let allowCancellation = validReference && !speechDominant
            if allowCancellation { cancellationBlocks += 1 }

            let mono = outputChannels[0]
            outputBuffer.frameLength = AVAudioFrameCount(frames)

            for frame in 0..<frames {
                let primary = max(-1, min(1, primaryChannel[frame]))
                let reference = max(-1, min(1, referenceChannel[frame]))
                // Bypass means keep the target microphone untouched; do not blend a weak,
                // duplicate, or speech-contaminated reference back into the signal.
                var result = primary

                if allowCancellation {
                    referenceHistory[historyIndex] = reference
                    var estimate: Float = 0
                    var norm = filterEpsilon
                    var cursor = historyIndex

                    for tap in 0..<filterTaps {
                        let sample = referenceHistory[cursor]
                        estimate += adaptiveWeights[tap] * sample
                        norm += sample * sample
                        cursor = cursor == 0 ? filterTaps - 1 : cursor - 1
                    }

                    let error = primary - estimate
                    if abs(reference) > 0.004 {
                        let step = filterMu * error / norm
                        cursor = historyIndex
                        for tap in 0..<filterTaps {
                            adaptiveWeights[tap] += step * referenceHistory[cursor]
                            cursor = cursor == 0 ? filterTaps - 1 : cursor - 1
                        }
                    }

                    result = error
                    historyIndex = (historyIndex + 1) % filterTaps
                    if abs(estimate) > 0.001 { cancelledFrames += 1 }
                    cancellationPeak = max(cancellationPeak, Double(abs(primary - result)))
                }

                result = max(-1, min(1, result))
                if amplifyWhisper {
                    result = WhisperAudioProcessor.amplify(result)
                }
                mono[frame] = result
            }

            for frame in 0..<frames {
                let left = Double(primaryChannel[frame])
                leftSquareSum += left * left
                if hasReference {
                    let right = Double(referenceChannel[frame])
                    rightSquareSum += right * right
                    crossSum += left * right
                }
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
            correlation: correlation,
            cancellationBlocks: cancellationBlocks,
            cancelledFrames: cancelledFrames,
            cancellationPeak: cancellationPeak,
            whisperGainApplied: amplifyWhisper
        )
    }
}
