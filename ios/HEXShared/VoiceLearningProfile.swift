import Foundation

/// Stable identifiers for the three locally recorded voice-profile examples.
nonisolated enum VoiceLearningProfile {
    static let samplePrefix = "voice-profile-"
    static let stepCount = 3

    static func sampleID(forStep step: Int) -> String {
        samplePrefix + String(step)
    }

    static func step(forSampleID id: String) -> Int? {
        guard id.hasPrefix(samplePrefix),
              let step = Int(id.dropFirst(samplePrefix.count)),
              (1...stepCount).contains(step) else {
            return nil
        }
        return step
    }

    static func isVoiceSample(_ sample: SpeechLearningSample) -> Bool {
        step(forSampleID: sample.id) != nil
    }
}
