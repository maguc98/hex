import Foundation

nonisolated struct SpeechLearningSample: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let heard: String?
    let language: String
    let createdAt: TimeInterval
    let duration: TimeInterval
    let audioFileName: String
}

nonisolated struct SpeechLearningPending: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let heard: String?
    let language: String
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let duration: TimeInterval
    let audioFileName: String
}

/// User-confirmed pronunciation examples, shared by the app and keyboard through their App Group.
/// A finished recording is staged briefly; only tapping Learn moves it into the durable local library.
nonisolated struct SpeechLearningStore {
    static let pendingLifetime: TimeInterval = 45
    static let maximumSamples = 12
    static let maximumSampleDuration: TimeInterval = 30
    static let maximumAudioBytes = 3 * 1_048_576
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
        language: String,
        duration: TimeInterval
    ) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
