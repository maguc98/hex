import Foundation

/// An in-keyboard recording the keyboard closed during: the screen locked, or another app came
/// forward. A keyboard extension cannot record or run in the background, so its file stays under
/// this App Group record until the next keyboard transcribes and holds its text.
nonisolated struct KeyboardInterruptedRecording: Codable, Equatable, Sendable {
    let jobID: String
    /// The recording's file name in the keyboard's temporary folder.
    let fileName: String
    let document: UUID?
    let seconds: TimeInterval
    /// Whether the keyboard closed while it was recording, rather than transcribing.
    let cutShort: Bool
    let at: TimeInterval

    static let keptFor: TimeInterval = 24 * 60 * 60
    private static let key = "keyboard.interruptedRecording"

    var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    func isExpired(at now: TimeInterval) -> Bool {
        now - at > Self.keptFor
    }

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) -> Self? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        if let data = try? JSONEncoder().encode(self) {
            defaults?.set(data, forKey: Self.key)
        }
    }

    /// Deletes this recording only if the stored record still belongs to jobID.
    static func clear(jobID: String, defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        guard let record = load(defaults: defaults), record.jobID == jobID else { return }
        try? FileManager.default.removeItem(at: record.url)
        defaults?.removeObject(forKey: key)
    }

    static func note(stoppedAfter seconds: TimeInterval) -> (title: String, detail: String) {
        let whole = max(0, Int(seconds))
        let point = String(format: "%d:%02d", whole / 60, whole % 60)
        return (
            String(localized: "Stopped at \(point)"),
            String(localized: "The screen locked or you left the app")
        )
    }
}
