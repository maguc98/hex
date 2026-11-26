import Foundation
import XCTest
@testable import HEX

final class SpeechLearningStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "SpeechLearningStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-learning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testTranslatedSentenceKeepsSpokenTextAndTranslationTogether() throws {
        let audioURL = directory.appendingPathComponent("capture.wav")
        try Data(repeating: 0, count: 64).write(to: audioURL)
        let libraryURL = directory.appendingPathComponent("library", isDirectory: true)
        let store = SpeechLearningStore(defaults: defaults, directoryURL: libraryURL)

        XCTAssertTrue(store.stagePendingAudio(
            from: audioURL,
            resultID: "translated-1",
            text: "こんにちは、元気ですか？",
            heard: "こんにちは、元気ですか",
            translatedText: "Hello, how are you?",
            translatedLanguage: "en",
            language: "ja-JP",
            duration: 2.4
        ))
        XCTAssertTrue(store.hasPending(resultID: "translated-1"))
        XCTAssertTrue(store.confirmPending(resultID: "translated-1"))

        let sample = try XCTUnwrap(store.samples().first)
        XCTAssertEqual(sample.text, "こんにちは、元気ですか？")
        XCTAssertEqual(sample.language, "ja-JP")
        XCTAssertEqual(sample.translatedText, "Hello, how are you?")
        XCTAssertEqual(sample.translatedLanguage, "en")
        XCTAssertEqual(
            store.recognitionHints(language: "ja-JP"),
            ["こんにちは、元気ですか？"],
            "recognition learns the sentence that was spoken, not its translation"
        )
        XCTAssertTrue(store.recognitionHints(language: "en").isEmpty)
    }

    func testUntranslatedSamplesStillWorkWithoutTranslationMetadata() throws {
        let audioURL = directory.appendingPathComponent("capture.wav")
        try Data(repeating: 0, count: 64).write(to: audioURL)
        let store = SpeechLearningStore(
            defaults: defaults,
            directoryURL: directory.appendingPathComponent("library", isDirectory: true)
        )

        XCTAssertTrue(store.stagePendingAudio(
            from: audioURL,
            resultID: "spoken-1",
            text: "See you tomorrow.",
            heard: "see you tomorrow",
            language: "en-US",
            duration: 1.8
        ))
        XCTAssertTrue(store.confirmPending(resultID: "spoken-1"))

        let sample = try XCTUnwrap(store.samples().first)
        XCTAssertEqual(sample.text, "See you tomorrow.")
        XCTAssertNil(sample.translatedText)
        XCTAssertNil(sample.translatedLanguage)
    }

    func testLegacySavedSamplesDecodeWithoutTranslationFields() throws {
        let legacy = """
        [{"id":"legacy-1","text":"Good morning","heard":"good morning","language":"en-US","createdAt":1,"duration":1.2,"audioFileName":"legacy-1.wav"}]
        """
        defaults.set(Data(legacy.utf8), forKey: "speechLearning.samples.v1")
        let store = SpeechLearningStore(defaults: defaults, directoryURL: directory)

        let sample = try XCTUnwrap(store.samples().first)
        XCTAssertEqual(sample.text, "Good morning")
        XCTAssertNil(sample.translatedText)
        XCTAssertNil(sample.translatedLanguage)
    }
}
