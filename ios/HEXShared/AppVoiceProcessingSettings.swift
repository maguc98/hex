import Foundation

/// App-local voice processing preference for recordings started inside Hex.
/// The keyboard keeps its existing App Group setting; the app-local value also works
/// when a sideloaded build cannot access the App Group container.
nonisolated enum AppVoiceProcessingSettings {
    static let enabledKey = "settings.appVoiceProcessingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
