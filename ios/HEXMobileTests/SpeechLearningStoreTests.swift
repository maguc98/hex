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

    func testLearningSentenceCanBeSavedWhenAudioFileIsUnavailable() throws {
        let missingAudioURL = directory.appendingPathComponent("missing-capture.wav")
        let store = SpeechLearningStore(
            defaults: defaults,
            directoryURL: directory.appendingPathComponent("library", isDirectory: true)
        )

        XCTAssertTrue(store.stagePendingAudio(
            from: missingAudioURL,
            resultID: "text-only-1",
            text: "今天我们开始学习。",
            heard: "今天我们开始学习",
            translatedText: "Today we begin learning.",
            translatedLanguage: "en",
            language: "zh-CN",
            duration: 5
        ))
        XCTAssertTrue(store.hasPending(resultID: "text-only-1"))
        XCTAssertTrue(store.confirmPending(resultID: "text-only-1"))

        let sample = try XCTUnwrap(store.samples().first)
        XCTAssertEqual(sample.text, "今天我们开始学习。")
        XCTAssertEqual(sample.translatedText, "Today we begin learning.")
        XCTAssertTrue(sample.audioFileName.isEmpty)
        XCTAssertNil(store.audioURL(for: sample))
        XCTAssertTrue(store.deleteSample(id: sample.id))
    }

    func testLearningAudioCanBeStagedForLongerDictations() throws {
        let audioURL = directory.appendingPathComponent("long-capture.wav")
        try Data(repeating: 1, count: 64).write(to: audioURL)
        let store = SpeechLearningStore(
            defaults: defaults,
            directoryURL: directory.appendingPathComponent("library", isDirectory: true)
        )

        XCTAssertTrue(store.stagePendingAudio(
            from: audioURL,
            resultID: "long-1",
            text: "This is a longer dictated learning sentence.",
            heard: nil,
            language: "en-US",
            duration: 60
        ))
        XCTAssertTrue(store.hasPending(resultID: "long-1"))
        XCTAssertTrue(store.confirmPending(resultID: "long-1"))
        let sample = try XCTUnwrap(store.samples().first)
        XCTAssertEqual(sample.duration, 60)
        XCTAssertNotNil(store.audioURL(for: sample))
    }

    func testSeparateAppAndKeyboardStoresShareVerifiedManifest() throws {
        let audioURL = directory.appendingPathComponent("shared-capture.wav")
        try Data(repeating: 7, count: 128).write(to: audioURL)
        let libraryURL = directory.appendingPathComponent("shared-library", isDirectory: true)
        let appStore = SpeechLearningStore(defaults: defaults, directoryURL: libraryURL)
        let keyboardStore = SpeechLearningStore(defaults: nil, directoryURL: libraryURL)

        XCTAssertTrue(appStore.stagePendingAudio(
            from: audioURL,
            resultID: "shared-1",
            text: "保存后两个进程都应该读到。",
            heard: "保存后两个进程都应该读到",
            translatedText: "Both processes should see this after saving.",
            translatedLanguage: "en",
            language: "zh-CN",
            duration: 3
        ))

        XCTAssertTrue(keyboardStore.confirmPending(resultID: "shared-1"))
        XCTAssertTrue(appStore.isSavedSample(id: "shared-1"))
        XCTAssertEqual(appStore.samples().map(\.id), ["shared-1"])
        XCTAssertTrue(keyboardStore.confirmPending(resultID: "shared-1"), "Confirming the same result twice is idempotent.")
        XCTAssertEqual(keyboardStore.samples().count, 1)
    }

    func testConfirmedRecordRemainsPendingUntilManifestCanBeReadBack() throws {
        let audioURL = directory.appendingPathComponent("verification-capture.wav")
        try Data(repeating: 9, count: 128).write(to: audioURL)
        let libraryURL = directory.appendingPathComponent("verification-library", isDirectory: true)
        let appStore = SpeechLearningStore(defaults: defaults, directoryURL: libraryURL)
        let separateReader = SpeechLearningStore(defaults: nil, directoryURL: libraryURL)

        XCTAssertTrue(appStore.stagePendingAudio(
            from: audioURL,
            resultID: "verified-1",
            text: "这条记录必须能被重新读取。",
            heard: nil,
            language: "zh-CN",
            duration: 2
        ))
        XCTAssertTrue(appStore.confirmPending(resultID: "verified-1"))
        XCTAssertTrue(separateReader.isSavedSample(id: "verified-1"))
        XCTAssertFalse(separateReader.hasPending(resultID: "verified-1"))
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
