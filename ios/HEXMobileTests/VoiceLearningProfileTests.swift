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
}
