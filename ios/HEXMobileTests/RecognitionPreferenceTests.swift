import XCTest
@testable import HEX

final class RecognitionPreferenceTests: XCTestCase {
    func testRecognitionModeDefaultsToAccurateAndPersistsSelection() {
        let suite = "RecognitionPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = DictationRecognitionModeSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .accurate)

        settings.mode = .fast
        XCTAssertEqual(settings.mode, .fast)
    }

    func testInterfaceAnimationsDefaultToEnabledAndPersistSelection() {
        let suite = "InterfaceMotionPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = InterfaceMotionSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)

        settings.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
    }
}
