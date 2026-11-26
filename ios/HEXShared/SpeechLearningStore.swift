import Foundation

nonisolated struct SpeechLearningSample: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// What was actually spoken, in `language`; this is the phrase used as a recognition hint.
    let text: String
    let heard: String?
    let language: String
    /// The paired translation, when the user dictated with Translate what I say enabled.
    let translatedText: String?
    let translatedLanguage: String?
    let createdAt: TimeInterval
    let duration: TimeInterval
    let audioFileName: String
}

nonisolated struct SpeechLearningPending: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let heard: String?
    let language: String
    let translatedText: String?
    let translatedLanguage: String?
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let duration: TimeInterval
    let audioFileName: String
}

/// User-confirmed speech examples shared by the app and keyboard through their App Group.
/// A translated dictation keeps its spoken sentence and translation together; recognition hints
/// always use the spoken-language sentence, never the translated text.
nonisolated struct SpeechLearningStore {
    static let pendingLifetime: TimeInterval = 30 * 60
    static let maximumSamples = 12
    static let maximumSampleDuration: TimeInterval = 180
    static let maximumAudioBytes = 8 * 1_048_576
    static let maximumHintCount = 20
    static let maximumHintLength = 64

    private enum Key {
        static let pending = "speechLearning.pending.v1"
        static let samples = "speechLearning.samples.v1"
    }

    private let defaults: UserDefaults?
    private let fileManager: FileManager
    private let suppliedDirectoryURL: URL?
    private let now: () -> TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup),
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        suppliedDirectoryURL = directoryURL
        self.now = now
    }

    /// Copies this result's original WAV into a short-lived App Group staging area.
    /// The source can then be deleted by the transcription pipeline as it was before.
    @discardableResult
    func stagePendingAudio(
        from sourceURL: URL,
        resultID: String,
        text: String,
        heard: String?,
        translatedText: String? = nil,
        translatedLanguage: String? = nil,
        language: String,
        duration: TimeInterval
    ) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairedTranslation = cleanTranslation?.isEmpty == false ? cleanTranslation : nil
        guard validID(resultID), !cleanText.isEmpty,
              duration > 0, duration <= Self.maximumSampleDuration,
              fileManager.fileExists(atPath: sourceURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumAudioBytes,
              let directory = directory(named: "Pending", create: true) else { return false }

        pruneExpiredPending()
        let fileName = resultID + ".wav"
        let destination = directory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            return false
        }

        let record = SpeechLearningPending(
            id: resultID,
            text: cleanText,
            heard: heard,
            language: language,
            translatedText: pairedTranslation,
            translatedLanguage: pairedTranslation == nil ? nil : translatedLanguage,
            createdAt: now(),
            expiresAt: now() + Self.pendingLifetime,
            duration: max(0, duration),
            audioFileName: fileName
        )
        var records = readPending().filter { $0.id != resultID }
        records.append(record)
        write(records, forKey: Key.pending)
        return true
    }

    /// Removes expired, unconfirmed recordings. Safe to call periodically while the keyboard is visible.
    func cleanupExpiredPending() {
        pruneExpiredPending()
    }

    /// True only while the matching audio sample is still staged and can be confirmed.
    func hasPending(resultID: String) -> Bool {
        pruneExpiredPending()
        guard validID(resultID), let record = readPending().first(where: { $0.id == resultID }) else {
            return false
        }
        guard record.expiresAt > now(),
              let directory = directory(named: "Pending", create: false),
              fileManager.fileExists(atPath: directory.appendingPathComponent(record.audioFileName).path)
        else {
            removePending(record)
            return false
        }
        return true
    }

    /// Promotes the exact audio/transcript pair only after the user taps Learn.
    @discardableResult
    func confirmPending(resultID: String) -> Bool {
        guard hasPending(resultID: resultID),
              let record = readPending().first(where: { $0.id == resultID }),
              let pendingDirectory = directory(named: "Pending", create: false),
              let samplesDirectory = directory(named: "Samples", create: true) else { return false }

        let source = pendingDirectory.appendingPathComponent(record.audioFileName)
        let destinationName = record.id + ".wav"
        let destination = samplesDirectory.appendingPathComponent(destinationName)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            return false
        }

        let sample = SpeechLearningSample(
            id: record.id,
            text: record.text,
            heard: record.heard,
            language: record.language,
            translatedText: record.translatedText,
            translatedLanguage: record.translatedLanguage,
            createdAt: record.createdAt,
            duration: record.duration,
            audioFileName: destinationName
        )
        var allSamples = readSamples().filter { $0.id != sample.id }
        allSamples.append(sample)
        allSamples.sort { $0.createdAt > $1.createdAt }

        let retained = Array(allSamples.prefix(Self.maximumSamples))
        let retainedNames = Set(retained.map(\.audioFileName))
        for old in allSamples where !retainedNames.contains(old.audioFileName) {
            try? fileManager.removeItem(at: samplesDirectory.appendingPathComponent(old.audioFileName))
        }
        write(retained, forKey: Key.samples)
        removePending(record)
        return true
    }

    /// Recent confirmed phrases are supplied as recognition context; no transcript is force-replaced.
    func recognitionHints(language: String?) -> [String] {
        let requestedLanguage = language.map(Self.languageFamily)
        var seen = Set<String>()
        var hints: [String] = []
        for sample in readSamples().sorted(by: { $0.createdAt > $1.createdAt }) {
            if let requestedLanguage, Self.languageFamily(sample.language) != requestedLanguage { continue }
            let phrase = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard phrase.count >= 2, phrase.count <= Self.maximumHintLength else { continue }
            let key = phrase.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            hints.append(phrase)
            if hints.count == Self.maximumHintCount { break }
        }
        return hints
    }

    func samples() -> [SpeechLearningSample] {
        readSamples().sorted { $0.createdAt > $1.createdAt }
    }

    func audioURL(for sample: SpeechLearningSample) -> URL? {
        guard let dir = directory(named: "Samples", create: false) else { return nil }
        let url = dir.appendingPathComponent(sample.audioFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func deleteSample(id: String) -> Bool {
        guard let sample = readSamples().first(where: { $0.id == id }) else { return false }
        if let dir = directory(named: "Samples", create: false) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(sample.audioFileName))
        }
        write(readSamples().filter { $0.id != id }, forKey: Key.samples)
        return true
    }

    private func readPending() -> [SpeechLearningPending] {
        guard let data = defaults?.data(forKey: Key.pending) else { return [] }
        return (try? decoder.decode([SpeechLearningPending].self, from: data)) ?? []
    }

    private func readSamples() -> [SpeechLearningSample] {
        guard let data = defaults?.data(forKey: Key.samples) else { return [] }
        return (try? decoder.decode([SpeechLearningSample].self, from: data)) ?? []
    }

    private func write<T: Encodable>(_ values: [T], forKey key: String) {
        guard let data = try? encoder.encode(values) else { return }
        defaults?.set(data, forKey: key)
    }

    private func removePending(_ record: SpeechLearningPending) {
        if let directory = directory(named: "Pending", create: false) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(record.audioFileName))
        }
        write(readPending().filter { $0.id != record.id }, forKey: Key.pending)
    }

    private func pruneExpiredPending() {
        for record in readPending() where record.expiresAt <= now() {
            removePending(record)
        }
    }

    private func directory(named name: String, create: Bool) -> URL? {
        let root: URL
        if let suppliedDirectoryURL {
            root = suppliedDirectoryURL
        } else {
            guard let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup
            ) else { return nil }
            root = container.appendingPathComponent("Library/Application Support/HEXSpeechLearning", isDirectory: true)
        }
        let url = root.appendingPathComponent(name, isDirectory: true)
        if create {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return url
    }

    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }

    private static func languageFamily(_ identifier: String) -> String {
        identifier.lowercased().split(separator: "-").first.map(String.init) ?? identifier.lowercased()
    }
}
