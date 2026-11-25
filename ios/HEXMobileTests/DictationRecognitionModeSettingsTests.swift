import Foundation
import XCTest

final class DictationRecognitionModeSettingsTests: XCTestCase {
    func testDefaultsToAccurateAndPersistsSelection() {
        let suiteName = "DictationRecognitionModeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = DictationRecognitionModeSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .accurate)

        settings.mode = .fast
        XCTAssertEqual(DictationRecognitionModeSettings(defaults: defaults).mode, .fast)
    }
}
