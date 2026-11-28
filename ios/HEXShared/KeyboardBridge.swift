import Foundation

nonisolated enum KeyboardDictationState: String, Codable, Sendable {
    case offline
    case ready
    case starting
    case recording
    case transcribing
    case failed
}

nonisolated enum WarmSessionDuration: String, Codable, CaseIterable, Sendable {
    case off
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        }
    }

    var shortLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .fiveMinutes: String(localized: "5m")
        case .fifteenMinutes: String(localized: "15m")
        case .oneHour: String(localized: "1h")
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "One shot")
        case .fiveMinutes: String(localized: "5 minutes")
        case .fifteenMinutes: String(localized: "15 minutes")
        case .oneHour: String(localized: "1 hour")
        }
    }
}

nonisolated enum KeyboardCommandKind: String, Codable, Sendable {
    case start
    case stop
    case cancel
}

nonisolated struct KeyboardCommand: Codable, Equatable, Sendable {
    let id: String
    let kind: KeyboardCommandKind
    let jobID: String
    let style: DictationStyle
    let sentAt: TimeInterval

    init(
        id: String = UUID().uuidString,
        kind: KeyboardCommandKind,
        jobID: String,
        style: DictationStyle = .polished,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.kind = kind
        self.jobID = jobID
        self.style = style
        self.sentAt = sentAt
    }
}

nonisolated enum KeyboardLaunchRequest: Equatable, Sendable {
    /// Any cold-start recording handoff older than 10 seconds warms the session instead of surprise-recording.
    static let handoffWindow: TimeInterval = 10.0

    /// Opens Hex's keyboard setup screen without starting a session.
    case setup
    /// Opens the Learning page for manual sentence entry and recording.
    case learning
    /// Opens Settings › Dictation, where Translate what I say downloads its languages: the
    /// keyboard's note after a dictation went in as spoken.
    case translationSettings
    case startSession(requestedAt: TimeInterval?)
    case startRecording(
        jobID: String,
        requestedAt: TimeInterval?,
        style: DictationStyle?
    )

    init?(url: URL) {
        guard url.scheme == "hex-dictation", url.host == "keyboard" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []

        func value(_ name: String) -> String? {
            guard let v = query.first(where: { $0.name == name })?.value, !v.isEmpty else {
                return nil
            }
            return v
        }

        let requestedAt = value("ts").flatMap(TimeInterval.init)
        let style = value("style").flatMap(DictationStyle.init(rawValue:))

        switch url.path {
        case "/setup":
            self = .setup
        case "/translation":
            self = .translationSettings
        case "/learning":
            self = .learning
        case "/start":
            self = .startSession(requestedAt: requestedAt)
        case "/record":
            guard let jobID = value("job") else { return nil }
            self = .startRecording(
                jobID: jobID,
                requestedAt: requestedAt,
                style: style
            )
        default:
            return nil
        }
    }

    /// Opens a page of Hex, starting no session.
    var opensPage: Bool {
        switch self {
        case .setup, .translationSettings, .learning: true
        case .startSession, .startRecording: false
        }
    }

    var requestedAt: TimeInterval? {
        switch self {
        case .setup, .translationSettings, .learning:
            nil
        case .startSession(let ts), .startRecording(_, let ts, _):
            ts
        }
    }

    func isHandoffExpired(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let requestedAt else { return false }
        return now - requestedAt > Self.handoffWindow
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "hex-dictation"
        components.host = "keyboard"

        var items: [URLQueryItem] = []
        switch self {
        case .setup:
            components.path = "/setup"

        case .translationSettings:
            components.path = "/translation"
        case .learning:
            components.path = "/learning"

        case .startSession(let requestedAt):
            components.path = "/start"
            if let requestedAt {
                items.append(URLQueryItem(name: "ts", value: String(format: "%.3f", requestedAt)))
            }

        case .startRecording(let jobID, let requestedAt, let style):
            components.path = "/record"
            items.append(URLQueryItem(name: "job", value: jobID))
            if let requestedAt {
                items.append(URLQueryItem(name: "ts", value: String(format: "%.3f", requestedAt)))
            }
            if let style {
                items.append(URLQueryItem(name: "style", value: style.rawValue))
            }
        }

        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url!
    }
}

nonisolated struct KeyboardSnapshot: Codable, Equatable, Sendable {
    let state: KeyboardDictationState
    let heartbeat: TimeInterval
    let expiresAt: TimeInterval
    let recordingStartedAt: TimeInterval?
    let audioLevel: Float
    let loudnessDB: Float?
    let jobID: String?
    let resultID: String?
    let resultExpiresAt: TimeInterval?
    let transcript: String?
    let message: String?
    /// The raw transcript behind `transcript`, before cleanup and formatting, sent only while
    /// Learn how I type is on so the keyboard can tell misheard words from formatting.
    /// Nil when it can't be learned from (translated) or the experiment is off.
    let heard: String?
    /// Record typing logs: what each step of the dictation made of it, sent only while
    /// that experiment is on.
    let stages: DictationStages?
    /// Why `transcript` went in as spoken while Translate what I say was on: the keyboard
    /// says so as it inserts it.
    let translationFailure: TranslationFailure?
    /// When `message` was written (wall clock). The keyboard says it only for
    /// `messageShownFor` after that; nil (an earlier build's) reads as long past.
    let messageAt: TimeInterval?

    init(
        state: KeyboardDictationState,
        heartbeat: TimeInterval,
        expiresAt: TimeInterval,
        recordingStartedAt: TimeInterval? = nil,
        audioLevel: Float = 0,
        loudnessDB: Float? = nil,
        jobID: String? = nil,
        resultID: String? = nil,
        resultExpiresAt: TimeInterval? = nil,
        transcript: String? = nil,
        message: String? = nil,
        heard: String? = nil,
        stages: DictationStages? = nil,
        translationFailure: TranslationFailure? = nil,
        messageAt: TimeInterval? = nil
    ) {
        self.state = state
        self.heartbeat = heartbeat
        self.expiresAt = expiresAt
        self.recordingStartedAt = recordingStartedAt
        self.audioLevel = audioLevel
        self.loudnessDB = loudnessDB
        self.jobID = jobID
        self.resultID = resultID
        self.resultExpiresAt = resultExpiresAt
        self.transcript = transcript
        self.message = message
        self.heard = heard
        self.stages = stages
        self.translationFailure = translationFailure
        self.messageAt = messageAt
    }

    var effectiveLoudnessDB: Float {
        loudnessDB ?? DotScopeSimulation.loudness(fromNormalized: audioLevel)
    }

    static let offline = KeyboardSnapshot(
        state: .offline,
        heartbeat: 0,
        expiresAt: 0
    )

    var isAvailable: Bool {
        isAvailable(at: Date().timeIntervalSince1970)
    }

    /// True while the background warm session or an active capture/transcription heartbeat is live.
    func isAvailable(at now: TimeInterval) -> Bool {
        let heartbeatFresh = now - heartbeat < 3.0 && heartbeat > 0
        guard heartbeatFresh else { return false }
        if state == .starting || state == .recording || state == .transcribing {
            return true
        }
        return expiresAt > now
    }

    /// Accepted jobs keep their completed transcript deliverable even after a one-shot or expiring session closes.
    func hasDeliverableResult(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let resultID, !resultID.isEmpty,
              let transcript, !transcript.isEmpty else {
            return false
        }
        if let resultExpiresAt {
            return resultExpiresAt > now
        }
        return true
    }

    func recordingElapsed(at now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        guard state == .recording, let recordingStartedAt else { return 0 }
        return max(0, now - recordingStartedAt)
    }

    /// Hex heartbeats a keyboard's recording or transcription at least every 0.6 s
    /// (`DictationController`'s keyboard loop). One whose heartbeat is older than this has no
    /// one working on it: Hex ended, crashed or was suspended mid-job.
    static let orphanedJobTimeout: TimeInterval = 6
    /// How long a finished dictation the keyboard didn't insert by itself stays on offer as
    /// Paste dictation. Inserting it, or a newer one, ends the offer.
    static let resultOfferWindow: TimeInterval = 10 * 60

    /// A recording or transcription Hex stopped heartbeating for. Nothing will finish it, and
    /// a new keyboard process reads it the same way: the heartbeat is wall-clock time.
    func isOrphanedJob(at now: TimeInterval) -> Bool {
        guard state == .starting || state == .recording || state == .transcribing else { return false }
        return heartbeat <= 0 || now - heartbeat > Self.orphanedJobTimeout
    }

    /// The snapshot as the keyboard acts on it: an orphaned job reads as offline, so it can't
    /// hold the keyboard in recording or transcribing. A result it carries still arrives.
    func droppingOrphanedJob(at now: TimeInterval) -> KeyboardSnapshot {
        guard isOrphanedJob(at: now) else { return self }
        return KeyboardSnapshot(
            state: .offline,
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            resultID: resultID,
            resultExpiresAt: resultExpiresAt,
            transcript: transcript,
            message: message,
            heard: heard,
            stages: stages,
            translationFailure: translationFailure,
            messageAt: messageAt
        )
    }

    /// How long the keyboard says why Hex's last dictation failed ("Another app is using the
    /// microphone. Try again."), a little longer than its own failures show.
    static let messageShownFor: TimeInterval = 8

    /// A message from more than `messageShownFor` ago, or with no time. Hex writes the
    /// snapshot only while it runs, so a failure stayed in the App Group after Hex was
    /// suspended: every keyboard after showed it, and the full keyboard's Hex key sent its
    /// dictations to a Hex still marked failed, which ignored them, though dictation itself
    /// worked (TestFlight: "showing for me all the time although it's working fine").
    func hasStaleMessage(at now: TimeInterval) -> Bool {
        guard message != nil || state == .failed else { return false }
        guard let messageAt else { return true }
        return now - messageAt > Self.messageShownFor
    }

    /// The snapshot as the keyboard shows it: a stale failure reads as offline and a stale
    /// message is dropped. Whether a warm session is up, and any result, stay as they are.
    func droppingStaleMessage(at now: TimeInterval) -> KeyboardSnapshot {
        guard hasStaleMessage(at: now) else { return self }
        return KeyboardSnapshot(
            state: state == .failed ? .offline : state,
            heartbeat: heartbeat,
            expiresAt: expiresAt,
            recordingStartedAt: recordingStartedAt,
            audioLevel: audioLevel,
            loudnessDB: loudnessDB,
            jobID: jobID,
            resultID: resultID,
            resultExpiresAt: resultExpiresAt,
            transcript: transcript,
            heard: heard,
            stages: stages,
            translationFailure: translationFailure
        )
    }

    /// A finished dictation still on offer as Paste dictation: past its time to insert by
    /// itself (`hasDeliverableResult`), within `resultOfferWindow` of it.
    func hasOfferableResult(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let resultID, !resultID.isEmpty, let transcript, !transcript.isEmpty else { return false }
        guard let resultExpiresAt else { return true }
        return now < resultExpiresAt + Self.resultOfferWindow
    }
}

/// An in-keyboard dictation that finished after the keyboard hid (dismissed, or another app
/// came forward mid-dictation). It's kept in the App Group, so the next keyboard, in this
/// process or a new one, inserts it into the field it was said for while it's fresh, and
/// offers it as Paste dictation anywhere else or later.
nonisolated struct KeyboardHeldDictation: Codable, Equatable, Sendable {
    let id: String
    let text: String
    /// Learn how I type's raw transcript, as `KeyboardSnapshot.heard`.
    let heard: String?
    /// The field it was started in (`UITextDocumentProxy.documentIdentifier`), when UIKit named it.
    let document: UUID?
    let finishedAt: TimeInterval
    /// Where the recording stopped when the keyboard closed during it.
    var stoppedAfter: TimeInterval? = nil

    /// How long after it finished it still goes straight into its own field.
    static let insertWindow: TimeInterval = 30

    enum Delivery: Equatable {
        case insert
        case offer
        case expired
    }

    /// `document` is the field the keyboard is in now. A field either side couldn't name
    /// counts as the same one, as Hex's own results go into whichever field is open.
    func delivery(in document: UUID?, at now: TimeInterval) -> Delivery {
        let age = now - finishedAt
        guard age < KeyboardSnapshot.resultOfferWindow else { return .expired }
        let sameField = self.document == nil || document == nil || self.document == document
        return sameField && age < Self.insertWindow ? .insert : .offer
    }
}

/// When an in-keyboard dictation has stopped making progress, so the keyboard resets to idle
/// instead of showing it forever: its capture went quiet (WebKit's page ended or lost the
/// microphone without saying so), or its transcription never returned.
nonisolated enum KeyboardJobWatchdog {
    enum Stage {
        case recording
        case transcribing
    }

    /// The capture page sends audio about twelve times a second once it starts, and starting
    /// (web view, page, microphone) takes a second or two.
    static let captureSilence: TimeInterval = 6
    /// Apple Speech takes seconds for a long dictation; this is far past any of them.
    static let transcription: TimeInterval = 120
    /// How long a capture the page says another sound interrupted may wait to come back.
    static let captureInterruption: TimeInterval = 15

    /// `interruptedSince` makes the silence watchdog pause while WebKit is waiting for iOS audio.
    static func isStalled(
        _ stage: Stage,
        lastProgress: TimeInterval,
        interruptedSince: TimeInterval? = nil,
        now: TimeInterval
    ) -> Bool {
        if stage == .recording, let interruptedSince {
            return now - interruptedSince > captureInterruption
        }
        return now - lastProgress > (stage == .recording ? captureSilence : transcription)
    }
}

/// What a keyboard saw of Full Access, written from inside the keyboard: iOS tells only the
/// keyboard. `launchedAt` is when that keyboard process started. iOS can keep a keyboard
/// process running, so one started earlier may still say what it saw then.
nonisolated struct KeyboardFullAccessReport: Codable, Equatable, Sendable {
    var isOn: Bool
    var at: TimeInterval
    var launchedAt: TimeInterval
}

/// Whether Hex's keyboard is on screen, from what it writes to the App Group: shown since its
/// view last appeared (after its first frame) and not hidden since, with a sign of life less
/// than `heartbeatWindow` old (that appearance, or the Full Access report it repeats every 5 s
/// while shown), so a keyboard process that ended without hiding doesn't count. Another
/// keyboard, or iOS's dictation, takes Hex's keyboard off screen.
nonisolated enum KeyboardPresence {
    static let heartbeatWindow: TimeInterval = 7

    static func isShown(shownAt: TimeInterval?, hiddenAt: TimeInterval?, heartbeat: TimeInterval?, now: TimeInterval) -> Bool {
        guard let shownAt else { return false }
        if let hiddenAt, hiddenAt >= shownAt { return false }
        return now - max(shownAt, heartbeat ?? 0) < heartbeatWindow
    }
}

/// Full Access as Hex can know it: on once a keyboard ran with it, off only when a keyboard
/// said so since Hex last came to the foreground, and unconfirmed otherwise.
nonisolated enum KeyboardFullAccess: Equatable, Sendable {
    case on
    case off
    case unconfirmed

    /// `activeSince` is when Hex last came to the foreground. Full Access changes only in
    /// Settings, outside Hex, so a keyboard's "off" from before then may predate a grant.
    /// An "off" counts over an "on" only when it is newer and from the same or a later
    /// keyboard process: an older process may still say what it saw before the grant.
    static func resolve(
        on: KeyboardFullAccessReport?,
        off: KeyboardFullAccessReport?,
        activeSince: TimeInterval
    ) -> KeyboardFullAccess {
        if let off, on.map({ off.at > $0.at && off.launchedAt >= $0.launchedAt }) ?? true {
            return off.at >= activeSince ? .off : .unconfirmed
        }
        return on == nil ? .unconfirmed : .on
    }
}

@MainActor
struct KeyboardBridge {
    nonisolated static let appGroup = "group.anomaly.hex.mobile"
    /// Posted by the keyboard each time it reports Full Access (`recordFullAccess`).
    nonisolated static let fullAccessDarwinNotification = "anomaly.hex.mobile.keyboard.fullAccess"
    /// The keyboard's Darwin notification, forwarded on the main thread once
    /// `forwardFullAccessReports()` has run in the app.
    nonisolated static let fullAccessReported = Notification.Name("KeyboardBridge.fullAccessReported")

    private enum Key {
        static let command = "keyboard.command"
        static let modelInstalled = "model.installed"
        static let snapshot = "keyboard.snapshot"
        static let warmDuration = "settings.warmDuration"
        static let style = "settings.dictationStyle"
        static let microphone = "settings.microphone"
        /// Before Settings › Microphone: true allowed Bluetooth microphones (Always use iPhone
        /// microphone off). Read only while Microphone is unset.
        static let allowBluetoothMic = "settings.allowBluetoothMic"
        static let lastInsertedResultID = "keyboard.lastInsertedResultID"
        static let fullAccessSeenAt = "keyboard.fullAccessSeenAt"
        static let fullAccessOn = "keyboard.fullAccessOn"
        static let fullAccessOff = "keyboard.fullAccessOff"
        static let appMicrophoneAllowed = "app.microphoneAllowed"
        static let quickWakeEnabled = "settings.quickWakeEnabled"
        static let noiseReductionEnabled = "settings.noiseReductionEnabled"
        static let nativeStereoChannelAvailable = "keyboard.nativeStereoChannelAvailable"
        static let nativeStereoReferenceLevelDB = "keyboard.nativeStereoReferenceLevelDB"
        static let lastEmptyDictationAt = "keyboard.lastEmptyDictationAt"
        static let heldDictation = "keyboard.heldDictation"
        static let shownAt = "keyboard.shownAt"
        static let hiddenAt = "keyboard.hiddenAt"
    }

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private static let legacyQwenCleanupVersion = "settings.legacyQwenCleanupVersion"
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults? = UserDefaults(suiteName: Self.appGroup)) {
        self.defaults = defaults
        // Remove the API key left by older Qwen3-ASR builds; the engine and setting are gone.
        if let defaults, defaults.integer(forKey: Self.legacyQwenCleanupVersion) < 1 {
            defaults.removeObject(forKey: "settings.qwenAPIKey")
            defaults.set(1, forKey: Self.legacyQwenCleanupVersion)
        }
    }

    func send(
        _ kind: KeyboardCommandKind,
        jobID: String,
        style: DictationStyle? = nil,
        sentAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        let command = KeyboardCommand(
            kind: kind,
            jobID: jobID,
            style: style ?? self.style,
            sentAt: sentAt
        )
        guard let data = try? encoder.encode(command) else { return }
        defaults?.set(data, forKey: Key.command)
    }

    func latestCommand() -> KeyboardCommand? {
        guard let data = defaults?.data(forKey: Key.command) else { return nil }
        return try? decoder.decode(KeyboardCommand.self, from: data)
    }

    var isModelInstalled: Bool {
        defaults?.bool(forKey: Key.modelInstalled) ?? false
    }

    func setModelInstalled(_ installed: Bool) {
        defaults?.set(installed, forKey: Key.modelInstalled)
    }

    var warmDuration: WarmSessionDuration {
        get {
            guard let raw = defaults?.string(forKey: Key.warmDuration),
                  let parsed = WarmSessionDuration(rawValue: raw) else {
                return .fifteenMinutes
            }
            return parsed
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.warmDuration)
        }
    }

    var style: DictationStyle {
        get {
            guard let raw = defaults?.string(forKey: Key.style),
                  let parsed = DictationStyle(rawValue: raw) else {
                return .polished
            }
            return parsed
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.style)
        }
    }

    /// Settings › Microphone. Unset, it is Automatic, or Bluetooth for someone who turned off
    /// Always use iPhone microphone (the switch it replaced).
    var microphone: MicrophoneChoice {
        get {
            if let raw = defaults?.string(forKey: Key.microphone), let choice = MicrophoneChoice(rawValue: raw) {
                return choice
            }
            return defaults?.bool(forKey: Key.allowBluetoothMic) == true ? .bluetooth : .automatic
        }
        nonmutating set {
            defaults?.set(newValue.rawValue, forKey: Key.microphone)
        }
    }

    var lastInsertedResultID: String? {
        get {
            defaults?.string(forKey: Key.lastInsertedResultID)
        }
        nonmutating set {
            defaults?.set(newValue, forKey: Key.lastInsertedResultID)
        }
    }

    /// When the keyboard last ran with Full Access. Without Full Access the keyboard
    /// cannot write to the App Group at all, so only the keyboard sets this.
    var fullAccessSeenAt: TimeInterval? {
        get {
            let value = defaults?.double(forKey: Key.fullAccessSeenAt) ?? 0
            return value > 0 ? value : nil
        }
        nonmutating set {
            if let newValue {
                defaults?.set(newValue, forKey: Key.fullAccessSeenAt)
            } else {
                defaults?.removeObject(forKey: Key.fullAccessSeenAt)
            }
        }
    }

    /// Only the keyboard writes these, and a keyboard without Full Access may not be able to
    /// (an iPhone's App Group can refuse it). An "on" also sets `fullAccessSeenAt`, which
    /// builds before these reports read.
    func recordFullAccess(_ report: KeyboardFullAccessReport) {
        guard let data = try? encoder.encode(report) else { return }
        if report.isOn {
            defaults?.set(data, forKey: Key.fullAccessOn)
            defaults?.set(report.at, forKey: Key.fullAccessSeenAt)
        } else {
            defaults?.set(data, forKey: Key.fullAccessOff)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.fullAccessDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// The last "on". A keyboard from before these reports left only `fullAccessSeenAt`:
    /// it counts as an "on" from the oldest process.
    var fullAccessOnReport: KeyboardFullAccessReport? {
        if let data = defaults?.data(forKey: Key.fullAccessOn),
           let report = try? decoder.decode(KeyboardFullAccessReport.self, from: data) {
            return report
        }
        return fullAccessSeenAt.map { KeyboardFullAccessReport(isOn: true, at: $0, launchedAt: 0) }
    }

    var fullAccessOffReport: KeyboardFullAccessReport? {
        guard let data = defaults?.data(forKey: Key.fullAccessOff) else { return nil }
        return try? decoder.decode(KeyboardFullAccessReport.self, from: data)
    }

    func fullAccess(activeSince: TimeInterval) -> KeyboardFullAccess {
        KeyboardFullAccess.resolve(on: fullAccessOnReport, off: fullAccessOffReport, activeSince: activeSince)
    }

    /// Forwards the keyboard's Darwin notification to `fullAccessReported`, once per process.
    static func forwardFullAccessReports() {
        _ = fullAccessForwarder
    }

    private static let fullAccessForwarder: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: KeyboardBridge.fullAccessReported, object: nil)
                }
            },
            fullAccessDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }()

    /// Whether keyboard-first quick wake is enabled. The keyboard then prefers its in-keyboard
    /// capture path and does not rely on a resident Hex microphone session.
    var quickWakeEnabled: Bool {
        get { defaults?.bool(forKey: Key.quickWakeEnabled) ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.quickWakeEnabled) }
    }

    /// Background-noise suppression for dictation capture, independent of Whisper mode.
    var noiseReductionEnabled: Bool {
        get { defaults?.bool(forKey: Key.noiseReductionEnabled) ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.noiseReductionEnabled) }
    }

    /// Live telemetry from Hex's native recorder. The keyboard reads the actual second-channel
    /// meter when the selected input really supplied stereo; nil means no reference sample.
    var nativeStereoChannelAvailable: Bool {
        get { defaults?.bool(forKey: Key.nativeStereoChannelAvailable) ?? false }
        nonmutating set { defaults?.set(newValue, forKey: Key.nativeStereoChannelAvailable) }
    }

    var nativeStereoReferenceLevelDB: Float? {
        get {
            guard let value = defaults?.object(forKey: Key.nativeStereoReferenceLevelDB) as? NSNumber else { return nil }
            return value.floatValue
        }
        nonmutating set {
            if let newValue {
                defaults?.set(Double(newValue), forKey: Key.nativeStereoReferenceLevelDB)
            } else {
                defaults?.removeObject(forKey: Key.nativeStereoReferenceLevelDB)
            }
        }
    }

    /// Whether Hex has the microphone, as the app last read it. Only the app sets this. A
    /// keyboard process keeps the permission it read when it started (iOS doesn't update it
    /// there), so a keyboard opened before Hex was allowed the microphone needs the app's word.
    var appMicrophoneAllowed: Bool {
        get {
            defaults?.bool(forKey: Key.appMicrophoneAllowed) ?? false
        }
        nonmutating set {
            guard newValue != appMicrophoneAllowed else { return }
            defaults?.set(newValue, forKey: Key.appMicrophoneAllowed)
        }
    }

    /// When the keyboard's own dictation last ended with nothing to insert (no speech, or too
    /// short). The keyboard stays quiet about it; onboarding's practice says it heard nothing.
    var lastEmptyDictationAt: TimeInterval? {
        get {
            let value = defaults?.double(forKey: Key.lastEmptyDictationAt) ?? 0
            return value > 0 ? value : nil
        }
        nonmutating set {
            if let newValue {
                defaults?.set(newValue, forKey: Key.lastEmptyDictationAt)
            } else {
                defaults?.removeObject(forKey: Key.lastEmptyDictationAt)
            }
        }
    }

    /// Only the keyboard writes it: a dictation it finished after it hid, until it's
    /// inserted, pasted from the strip, or expired (`KeyboardHeldDictation`).
    var heldDictation: KeyboardHeldDictation? {
        get {
            guard let data = defaults?.data(forKey: Key.heldDictation) else { return nil }
            return try? decoder.decode(KeyboardHeldDictation.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? encoder.encode(newValue) {
                defaults?.set(data, forKey: Key.heldDictation)
            } else {
                defaults?.removeObject(forKey: Key.heldDictation)
            }
        }
    }

    /// Only the keyboard writes these: when its view last appeared and last went away
    /// (`KeyboardPresence`).
    func recordKeyboardShown(at time: TimeInterval) {
        defaults?.set(time, forKey: Key.shownAt)
    }

    func recordKeyboardHidden(at time: TimeInterval) {
        defaults?.set(time, forKey: Key.hiddenAt)
    }

    /// Hex's keyboard is on screen now (`KeyboardPresence`).
    func isKeyboardShown(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        func time(_ key: String) -> TimeInterval? {
            let value = defaults?.double(forKey: key) ?? 0
            return value > 0 ? value : nil
        }
        return KeyboardPresence.isShown(
            shownAt: time(Key.shownAt),
            hiddenAt: time(Key.hiddenAt),
            heartbeat: fullAccessOnReport?.at,
            now: now
        )
    }

    func publish(_ snapshot: KeyboardSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults?.set(data, forKey: Key.snapshot)
    }

    func snapshot() -> KeyboardSnapshot {
        guard let data = defaults?.data(forKey: Key.snapshot) else { return .offline }
        return (try? decoder.decode(KeyboardSnapshot.self, from: data)) ?? .offline
    }
}


/// An opaque, sRGB colour shared by the app and keyboard extension.
nonisolated struct LiveWaveformRGB: Codable, Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String?) {
        guard let hex else { return nil }
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let packed = UInt32(value, radix: 16) else { return nil }
        self.red = UInt8((packed >> 16) & 0xFF)
        self.green = UInt8((packed >> 8) & 0xFF)
        self.blue = UInt8(packed & 0xFF)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var redUnit: Double { Double(red) / 255.0 }
    var greenUnit: Double { Double(green) / 255.0 }
    var blueUnit: Double { Double(blue) / 255.0 }
}

nonisolated enum LiveWaveformColorState: Sendable {
    case idle
    case recording
    case processing
}

/// All waveform states travel together as one App Group value.
nonisolated struct LiveWaveformPalette: Codable, Equatable, Sendable {
    var idle: LiveWaveformRGB?
    var recording: LiveWaveformRGB?
    var processing: LiveWaveformRGB?

    var isEmpty: Bool {
        idle == nil && recording == nil && processing == nil
    }

    func color(for state: LiveWaveformColorState) -> LiveWaveformRGB? {
        switch state {
        case .idle: idle
        case .recording: recording
        case .processing: processing
        }
    }
}

/// Persists one RGB palette in the shared App Group and migrates the previous HEX keys.
/// Synchronization occurs before the Darwin notification, so the keyboard cannot wake up
/// and immediately read an older cached value.
nonisolated struct LiveWaveformColorSettings {
    static let didChangeNotification = Notification.Name("LiveWaveformColorSettings.didChange")
    private static let darwinNotification = "anomaly.hex.mobile.liveWaveformColor.changed"
    private static let paletteKey = "settings.liveWaveformPalette.v1"

    /// Previous independent keys and the earlier one-colour key, retained for migration.
    static let idleKey = "settings.liveWaveformColor.idle"
    static let recordingKey = "settings.liveWaveformColor.recording"
    static let processingKey = "settings.liveWaveformColor.processing"
    static let key = "settings.liveWaveformColor"

    private static let changeForwarder: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: didChangeNotification, object: nil)
                }
            },
            darwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }()

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardBridge.appGroup)) {
        self.defaults = defaults
    }

    static func observeChanges() {
        _ = changeForwarder
    }

    var palette: LiveWaveformPalette {
        get { readPalette() }
        nonmutating set { writePalette(newValue, notify: true) }
    }

    var idle: LiveWaveformRGB? {
        get { palette.idle }
        nonmutating set { update(\.idle, to: newValue) }
    }

    var recording: LiveWaveformRGB? {
        get { palette.recording }
        nonmutating set { update(\.recording, to: newValue) }
    }

    var processing: LiveWaveformRGB? {
        get { palette.processing }
        nonmutating set { update(\.processing, to: newValue) }
    }

    /// HEX accessors keep source compatibility with builds that used separate string keys.
    var idleHex: String? {
        get { idle?.hex }
        nonmutating set { idle = LiveWaveformRGB(hex: newValue) }
    }

    var recordingHex: String? {
        get { recording?.hex }
        nonmutating set { recording = LiveWaveformRGB(hex: newValue) }
    }

    var processingHex: String? {
        get { processing?.hex }
        nonmutating set { processing = LiveWaveformRGB(hex: newValue) }
    }

    /// Legacy shared-colour property. New writes fan out to idle and recording.
    var hex: String? {
        get {
            _ = defaults?.synchronize()
            return defaults?.string(forKey: Self.key)
        }
        nonmutating set {
            let color = LiveWaveformRGB(hex: newValue)
            var next = palette
            next.idle = color
            next.recording = color
            writePalette(next, notify: true)
        }
    }

    private func update(
        _ keyPath: WritableKeyPath<LiveWaveformPalette, LiveWaveformRGB?>,
        to color: LiveWaveformRGB?
    ) {
        var next = palette
        next[keyPath: keyPath] = color
        writePalette(next, notify: true)
    }

    private func readPalette() -> LiveWaveformPalette {
        guard let defaults else {
            return LiveWaveformPalette(idle: nil, recording: nil, processing: nil)
        }
        _ = defaults.synchronize()

        if let data = defaults.data(forKey: Self.paletteKey),
           let value = try? JSONDecoder().decode(LiveWaveformPalette.self, from: data) {
            return value
        }

        let migrated = LiveWaveformPalette(
            idle: LiveWaveformRGB(hex: defaults.string(forKey: Self.idleKey) ?? defaults.string(forKey: Self.key)),
            recording: LiveWaveformRGB(hex: defaults.string(forKey: Self.recordingKey) ?? defaults.string(forKey: Self.key)),
            processing: LiveWaveformRGB(hex: defaults.string(forKey: Self.processingKey))
        )
        if !migrated.isEmpty {
            writePalette(migrated, notify: false)
        }
        return migrated
    }

    private func writePalette(_ value: LiveWaveformPalette, notify: Bool) {
        guard let defaults, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.paletteKey)
        _ = defaults.synchronize()
        guard notify else { return }

        // Refresh a preview hosted in this process immediately; the Darwin notification
        // below is still required to refresh the separate keyboard-extension process.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotification as CFString),
            nil,
            nil,
            true
        )
    }
}
