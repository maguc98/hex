import Foundation

nonisolated struct SpeechLearningSample: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// What was actually spoken, in \`language\`; this is the phrase used as a recognition hint.
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

private struct SpeechLearningDiskState: Codable, Equatable, Sendable {
    var pending: [SpeechLearningPending] = []
    var samples: [SpeechLearningSample] = []
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
    private let manifestName = "learning-store-v1.json"

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

    /// Copies the original audio when possible and persists the sentence independently.
    /// A missing/unavailable WAV must never prevent the text and translation being saved.
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
        guard validID(resultID), !cleanText.isEmpty else { return false }

        var audioFileName = ""
        if duration.isFinite, duration > 0, duration <= Self.maximumSampleDuration,
           fileManager.fileExists(atPath: sourceURL.path),
           let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 0, size.intValue <= Self.maximumAudioBytes,
           let directory = directory(named: "Pending", create: true) {
            let candidateName = resultID + ".wav"
            let destination = directory.appendingPathComponent(candidateName)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
                audioFileName = candidateName
            } catch {
                audioFileName = ""
            }
        }

        let createdAt = now()
        let record = SpeechLearningPending(
            id: resultID,
            text: cleanText,
            heard: heard,
            language: language,
            translatedText: pairedTranslation,
            translatedLanguage: pairedTranslation == nil ? nil : translatedLanguage,
            createdAt: createdAt,
            expiresAt: createdAt + Self.pendingLifetime,
            duration: min(max(duration.isFinite ? duration : 0, 0), Self.maximumSampleDuration),
            audioFileName: audioFileName
        )

        var expiredAudioFiles: [String] = []
        let committed = updateState { state -> Bool? in
            expiredAudioFiles = state.pending
                .filter { $0.expiresAt <= createdAt }
                .map(\.audioFileName)
                .filter { !$0.isEmpty }
            state.pending.removeAll { $0.expiresAt <= createdAt || $0.id == resultID }
            state.pending.append(record)
            return true
        } ?? false

        if !committed, !audioFileName.isEmpty, let directory = directory(named: "Pending", create: false) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(audioFileName))
        }
        removeAudioFiles(expiredAudioFiles, from: "Pending")
        return committed && hasPending(resultID: resultID)
    }

    /// Removes expired, unconfirmed recordings. Safe to call periodically while the keyboard is visible.
    func cleanupExpiredPending() {
        pruneExpiredPending()
    }

    /// True only while the matching text/translation candidate is still staged.
    /// If its WAV vanished, convert it to a text-only candidate instead of dropping it.
    func hasPending(resultID: String) -> Bool {
        guard validID(resultID) else { return false }

        var expiredAudioFile: String?
        let present = updateState { state -> Bool? in
            guard let index = state.pending.firstIndex(where: { $0.id == resultID }) else {
                return false
            }
            let record = state.pending[index]
            guard record.expiresAt > now() else {
                expiredAudioFile = record.audioFileName
                state.pending.remove(at: index)
                return false
            }

            if !record.audioFileName.isEmpty {
                let pendingDirectory = directory(named: "Pending", create: false)
                let audioExists = pendingDirectory.map {
                    fileManager.fileExists(atPath: $0.appendingPathComponent(record.audioFileName).path)
                } ?? false
                if !audioExists {
                    state.pending[index] = SpeechLearningPending(
                        id: record.id,
                        text: record.text,
                        heard: record.heard,
                        language: record.language,
                        translatedText: record.translatedText,
                        translatedLanguage: record.translatedLanguage,
                        createdAt: record.createdAt,
                        expiresAt: record.expiresAt,
                        duration: record.duration,
                        audioFileName: ""
                    )
                }
            }
            return true
        } ?? false

        if let expiredAudioFile, !expiredAudioFile.isEmpty {
            removeAudioFiles([expiredAudioFile], from: "Pending")
        }
        return present
    }

    /// Commits a pending sample atomically, then verifies it by reading the shared store again.
    /// The pending record is retained until the new sample manifest has been written and verified.
    @discardableResult
    func confirmPending(resultID: String) -> Bool {
        guard validID(resultID) else { return false }
        if isSavedSample(id: resultID) { return true }
        guard hasPending(resultID: resultID),
              let pending = readState().pending.first(where: { $0.id == resultID }) else { return false }

        var savedAudioFileName = ""
        var copiedAudioURL: URL?
        if !pending.audioFileName.isEmpty,
           let pendingDirectory = directory(named: "Pending", create: false),
           let samplesDirectory = directory(named: "Samples", create: true) {
            let source = pendingDirectory.appendingPathComponent(pending.audioFileName)
            let destinationName = pending.id + ".wav"
            let destination = samplesDirectory.appendingPathComponent(destinationName)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.copyItem(at: source, to: destination)
                savedAudioFileName = destinationName
                copiedAudioURL = destination
            } catch {
                // Save the study sentence even if its optional audio cannot be copied.
                savedAudioFileName = ""
            }
        }

        var pendingAudioFileToRemove: String?
        var obsoleteSampleAudioFiles: [String] = []
        let committed = updateState { state -> Bool? in
            if state.samples.contains(where: { $0.id == resultID }) {
                return true
            }
            guard let index = state.pending.firstIndex(where: { $0.id == resultID }) else {
                return nil
            }
            let current = state.pending[index]
            guard current.expiresAt > now() else { return nil }

            pendingAudioFileToRemove = current.audioFileName
            let finalAudioName = savedAudioFileName.isEmpty ? "" : savedAudioFileName
            let sample = SpeechLearningSample(
                id: current.id,
                text: current.text,
                heard: current.heard,
                language: current.language,
                translatedText: current.translatedText,
                translatedLanguage: current.translatedLanguage,
                createdAt: current.createdAt,
                duration: current.duration,
                audioFileName: finalAudioName
            )

            var allSamples = state.samples.filter { $0.id != sample.id }
            allSamples.append(sample)
            allSamples.sort { $0.createdAt > $1.createdAt }
            let retained = Array(allSamples.prefix(Self.maximumSamples))
            let retainedIDs = Set(retained.map(\.id))
            obsoleteSampleAudioFiles = allSamples
                .filter { !retainedIDs.contains($0.id) }
                .map(\.audioFileName)
                .filter { !$0.isEmpty }

            state.samples = retained
            state.pending.removeAll { $0.id == resultID }
            return true
        } ?? false

        guard committed, isSavedSample(id: resultID) else {
            if let copiedAudioURL {
                try? fileManager.removeItem(at: copiedAudioURL)
            }
            return false
        }

        if let pendingAudioFileToRemove, !pendingAudioFileToRemove.isEmpty {
            removeAudioFiles([pendingAudioFileToRemove], from: "Pending")
        }
        removeAudioFiles(obsoleteSampleAudioFiles, from: "Samples")
        return true
    }

    /// Recent confirmed phrases are supplied as recognition context; no transcript is force-replaced.
    func recognitionHints(language: String?) -> [String] {
        let requestedLanguage = language.map(Self.languageFamily)
        var seen = Set<String>()
        var hints: [String] = []
        for sample in readState().samples.sorted(by: { $0.createdAt > $1.createdAt }) {
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
        readState().samples.sorted { $0.createdAt > $1.createdAt }
    }

    func isSavedSample(id: String) -> Bool {
        readState().samples.contains { $0.id == id }
    }

    func audioURL(for sample: SpeechLearningSample) -> URL? {
        guard !sample.audioFileName.isEmpty,
              let directory = directory(named: "Samples", create: false) else { return nil }
        let url = directory.appendingPathComponent(sample.audioFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func deleteSample(id: String) -> Bool {
        var removedAudioFile: String?
        let removed = updateState { state -> Bool? in
            guard let sample = state.samples.first(where: { $0.id == id }) else { return nil }
            removedAudioFile = sample.audioFileName
            state.samples.removeAll { $0.id == id }
            return true
        } ?? false
        guard removed, !isSavedSample(id: id) else { return false }
        if let removedAudioFile, !removedAudioFile.isEmpty {
            removeAudioFiles([removedAudioFile], from: "Samples")
        }
        return true
    }

    private func readState() -> SpeechLearningDiskState {
        if let url = manifestURL(create: false),
           let data = try? Data(contentsOf: url),
           let state = try? decoder.decode(SpeechLearningDiskState.self, from: data) {
            return state
        }
        return legacyDefaultsState()
    }

    /// Performs a cross-process coordinated, atomic manifest update and reads it back before
    /// returning success. The keyboard and app always consult this same App Group file.
    private func updateState<T>(_ update: (inout SpeechLearningDiskState) -> T?) -> T? {
        guard let manifest = manifestURL(create: true) else { return nil }
        if !fileManager.fileExists(atPath: manifest.path) {
            guard fileManager.createFile(atPath: manifest.path, contents: Data()) else { return nil }
        }

        var result: T?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: manifest, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            var state: SpeechLearningDiskState
            if let data = try? Data(contentsOf: coordinatedURL),
               let decoded = try? decoder.decode(SpeechLearningDiskState.self, from: data) {
                state = decoded
            } else {
                state = legacyDefaultsState()
            }

            guard let value = update(&state),
                  let data = try? encoder.encode(state) else { return }
            do {
                try data.write(to: coordinatedURL, options: .atomic)
                let persistedData = try Data(contentsOf: coordinatedURL)
                let persistedState = try decoder.decode(SpeechLearningDiskState.self, from: persistedData)
                guard persistedState == state else { return }
                result = value
            } catch {
                result = nil
            }
        }
        guard coordinationError == nil else { return nil }
        return result
    }

    private func legacyDefaultsState() -> SpeechLearningDiskState {
        let pending = defaults?.data(forKey: Key.pending)
            .flatMap { try? decoder.decode([SpeechLearningPending].self, from: $0) } ?? []
        let samples = defaults?.data(forKey: Key.samples)
            .flatMap { try? decoder.decode([SpeechLearningSample].self, from: $0) } ?? []
        return SpeechLearningDiskState(pending: pending, samples: samples)
    }

    private func pruneExpiredPending() {
        var expiredAudioFiles: [String] = []
        let changed = updateState { state -> Bool? in
            let retained = state.pending.filter { $0.expiresAt > now() }
            guard retained.count != state.pending.count else { return nil }
            expiredAudioFiles = state.pending
                .filter { $0.expiresAt <= now() }
                .map(\.audioFileName)
                .filter { !$0.isEmpty }
            state.pending = retained
            return true
        }
        if changed == true {
            removeAudioFiles(expiredAudioFiles, from: "Pending")
        }
    }

    private func rootDirectory(create: Bool) -> URL? {
        let root: URL
        if let suppliedDirectoryURL {
            root = suppliedDirectoryURL
        } else {
            guard let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup
            ) else { return nil }
            root = container.appendingPathComponent("Library/Application Support/HEXSpeechLearning", isDirectory: true)
        }
        if create {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return root
    }

    private func manifestURL(create: Bool) -> URL? {
        rootDirectory(create: create)?.appendingPathComponent(manifestName, isDirectory: false)
    }

    private func directory(named name: String, create: Bool) -> URL? {
        guard let root = rootDirectory(create: create) else { return nil }
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

    private func removeAudioFiles(_ names: [String], from directoryName: String) {
        guard !names.isEmpty, let directory = directory(named: directoryName, create: false) else { return }
        for name in names where !name.isEmpty {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
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
