import Foundation

/// Dictation speed/accuracy preference shared by the app and keyboard.
nonisolated enum DictationRecognitionMode: String, CaseIterable, Sendable {
    case accurate
    case fast

    var title: String {
        switch self {
        case .accurate: String(localized: "Accurate")
        case .fast: String(localized: "Fast")
        }
    }

    var detail: String {
        switch self {
        case .accurate: String(localized: "Prioritize recognition quality; may take longer.")
        case .fast: String(localized: "Prioritize speed; use progressive speech results and Parakeet where supported.")
        }
    }
}

nonisolated struct DictationRecognitionModeSettings {
    static let key = "settings.dictationRecognitionMode"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    var mode: DictationRecognitionMode {
        get {
            guard let raw = defaults?.string(forKey: Self.key),
                  let value = DictationRecognitionMode(rawValue: raw) else {
                return .accurate
            }
            return value
        }
        nonmutating set { defaults?.set(newValue.rawValue, forKey: Self.key) }
    }
}
