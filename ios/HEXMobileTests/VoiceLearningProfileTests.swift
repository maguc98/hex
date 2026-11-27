import Foundation
import XCTest
@testable import HEX

final class VoiceLearningProfileTests: XCTestCase {
    func testVoiceSamplesUseStableStepAndLanguageIdentifiers() {
        XCTAssertEqual(
            VoiceLearningProfile.sampleID(forStep: 1, language: "zh-CN"),
            "voice-profile-zhcn-1"
        )
        XCTAssertEqual(
            VoiceLearningProfile.sampleID(forStep: 3, language: "en-US"),
            "voice-profile-enus-3"
        )
    }

    func testVoiceSampleStepCanBeRecoveredFromItsIdentifier() {
        XCTAssertEqual(VoiceLearningProfile.step(forSampleID: "voice-profile-zhcn-1"), 1)
        XCTAssertEqual(VoiceLearningProfile.step(forSampleID: "voice-profile-enus-3"), 3)
        XCTAssertNil(VoiceLearningProfile.step(forSampleID: "voice-profile-zhcn-4"))
        XCTAssertNil(VoiceLearningProfile.step(forSampleID: "sentence-learning-1"))
    }

    func testPersonalVoicePhrasesStayAheadOfNewerSentenceSamples() throws {
        let suite = "VoiceLearningProfileTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        var now: TimeInterval = 1
        let store = SpeechLearningStore(
            defaults: defaults,
            directoryURL: directory,
            now: { now }
        )
        let voiceID = VoiceLearningProfile.sampleID(forStep: 1, language: "en-US")
        XCTAssertTrue(store.saveTextSample(
            id: voiceID,
            text: "My personal voice phrase",
            language: "en-US"
        ))

        for index in 0..<SpeechLearningStore.maximumHintCount + 5 {
            now += 1
            XCTAssertTrue(store.saveTextSample(
                id: "recent-\\(index)",
                text: "Recent sentence \\(index)",
                language: "en-US"
            ))
        }

        XCTAssertEqual(
            store.recognitionHints(language: "en-US").first,
            "My personal voice phrase"
        )
    }
}
