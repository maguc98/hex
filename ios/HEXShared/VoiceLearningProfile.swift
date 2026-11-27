import Foundation

/// Stable, language-scoped identifiers for the three locally recorded voice-profile examples.
nonisolated enum VoiceLearningProfile {
    static let samplePrefix = "voice-profile-"
    static let stepCount = 3

    static func sampleID(forStep step: Int, language: String) -> String {
        samplePrefix + languageToken(language) + "-" + String(step)
    }

    static func step(forSampleID id: String) -> Int? {
        guard id.hasPrefix(samplePrefix),
              let step = id.split(separator: "-").last.flatMap({ Int($0) }),
              (1...stepCount).contains(step) else {
            return nil
        }
        return step
    }

    static func isVoiceSample(_ sample: SpeechLearningSample) -> Bool {
        step(forSampleID: sample.id) != nil
    }

    private static func languageToken(_ language: String) -> String {
        let token = language.filter { $0.isLetter || $0.isNumber }
        return String(token.prefix(20)).lowercased()
    }
}
