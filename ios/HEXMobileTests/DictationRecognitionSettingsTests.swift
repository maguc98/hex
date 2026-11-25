import XCTest
@testable import HEX

final class DictationRecognitionSettingsTests: XCTestCase {
    func testRecognitionModeDefaultsToPreciseAndPersistsAcrossInstances() {
        let suiteName = "hex.tests.dictationRecognition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = DictationRecognitionSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .precise)

        settings.mode = .fast
        XCTAssertEqual(DictationRecognitionSettings(defaults: defaults).mode, .fast)
    }

    func testRealtimeInsertionDefaultsOffAndPersistsAcrossInstances() {
        let suiteName = "hex.tests.realtimeInsertion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = RealtimeInsertionSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)

        settings.isEnabled = true
        XCTAssertTrue(RealtimeInsertionSettings(defaults: defaults).isEnabled)
    }
}
