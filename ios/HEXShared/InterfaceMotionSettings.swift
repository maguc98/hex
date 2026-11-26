import Foundation

/// Global interface-animation preference shared by Hex's app and keyboard.
nonisolated struct InterfaceMotionSettings {
    static let enabledKey = "settings.interfaceAnimationsEnabled"
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: "group.anomaly.hex.mobile")) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults?.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults?.set(newValue, forKey: Self.enabledKey) }
    }
}
