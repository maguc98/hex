import AVFAudio
import Foundation
import os
import Speech
import UIKit
import WebKit

/// Experiment: record and transcribe inside the keyboard extension, so dictation
/// needs no Hex app process. Each step is logged to the App Group container
/// (`keyboard-capture-probe.log`) to measure permission and memory limits.
@MainActor
final class KeyboardLocalDictation {
    private enum Phase {
        case idle
        /// The Hex key's touch-down, before the touch is a tap, a hold or a slide: capturing,
        /// unseen (no snapshot), until `start` keeps it or `discard` drops it.
        case armed(jobID: String, startedAt: TimeInterval)
        /// The microphone was requested; recording is shown only after its first audio buffer.
        case starting(jobID: String, startedAt: TimeInterval)
        case recording(jobID: String, startedAt: TimeInterval)
        case transcribing(jobID: String)
        case finished(
            jobID: String,
            resultID: String,
            transcript: String,
            heard: String?,
            stages: DictationStages?,
            translationFailure: TranslationFailure?
        )
        case failed(message: String, until: TimeInterval)
    }

    /// The job being captured or transcribed, shared with its transcription task: whether the
    /// keyboard hid before it finished (its text is then held in the App Group for the next
    /// keyboard, `KeyboardHeldDictation`) and the field it was started in.
    private final class Job {
        let id: String
        let document: UUID?
        var interrupted = false
        /// The completed recording's file name and length, retained if iOS closes the keyboard.
        var recording: (fileName: String, seconds: TimeInterval)?
        /// The point at which the keyboard closed while recording, if it cut the recording short.
        var stoppedAfter: TimeInterval?

        init(id: String, document: UUID?) {
            self.id = id
            self.document = document
        }
    }

    private var phase: Phase = .idle {
        didSet {
            if case .idle = phase { liveText?.end() } else if case .failed = phase { liveText?.end() }
            if visibleStage(of: phase) != visibleStage(of: oldValue) { onPhaseChange?() }
        }
    }
    /// Refresh the keyboard immediately when the first real microphone buffer arrives.
    var onPhaseChange: (() -> Void)?
    /// Levels from a separately reported second audio channel, when the route supplies one.
    var onNoiseReferenceUpdate: ((Float?, Bool) -> Void)?

    private enum VisibleStage: Equatable { case idle, starting, recording, transcribing, finished, failed }
    private func visibleStage(of phase: Phase) -> VisibleStage {
        switch phase {
        case .idle, .armed: .idle
        case .starting: .starting
        case .recording: .recording
        case .transcribing: .transcribing
        case .finished: .finished
        case .failed: .failed
        }
    }
    private var job: Job?
    /// The words so far while recording (`KeyboardLiveDictation`), for the keyboard to show.
    var liveText: LiveDictationText?
    private var live: KeyboardLiveDictation?
    /// Wall-clock time of the first real PCM buffer for this job; nil until audio arrives.
    private var firstAudioAt: TimeInterval?
    /// When the job last showed progress: its start, its capture's last audio, or the start of
    /// its transcription (`KeyboardJobWatchdog`).
    private var lastProgressAt: TimeInterval = 0
    /// Audio progress and WebKit interruption state for the current capture.
    private var watch = KeyboardCaptureWatch(startedAt: 0)
    /// One capture web view shared across presentations in this extension process: making a new
    /// `WKWebView` on every presentation and leaving it attached to the old `KeyboardInputView`
    /// kept every dismissed keyboard's view hierarchy alive through WebKit's layout and observer
    /// references. Detached from its host view whenever a keyboard hides or deallocates.
    private static var sharedCapture: KeyboardWebCapture?
    private static var ownership = KeyboardCaptureOwnership()
    private static var dedicatedCaptures: [Int: KeyboardWebCapture] = [:]
    private static var lastOwnerID = 0
    private let ownerID: Int = {
        KeyboardLocalDictation.lastOwnerID += 1
        return KeyboardLocalDictation.lastOwnerID
    }()
    private var capture: KeyboardWebCapture?
    private var pcmFile: KeyboardPCMFile?
    private var loudness: Float = -62
    private var transcription: Task<Void, Never>?
    /// The current start's steps, logged once its first audio arrives.
    private var timeline: CaptureTimeline?
    /// A failure while armed, shown only if the touch is kept: a slide to the menu drops it.
    private var armedFailure: (message: String, detail: String?)?
    /// Another app played audio as this capture began, which WebKit's capture interrupts.
    private var otherAudioAtStart = false
    /// The job whose page start waits on the audio session's queue (`begin`).
    private var startPending: String?
    /// After a capture ends, long enough for WebKit to have let its audio session go.
    static let resumeOtherAudioDelay: TimeInterval = 0.5
    private static let audioSessionQueue = DispatchQueue(label: "anomaly.hex.keyboard.audio-session", qos: .userInitiated)

    /// Keyboard dictation sets this process's audio session to record (WebKit captures for
    /// it), and iOS mutes a recording session's haptics by default: key haptics stay on. Set
    /// once per process on the audio session's queue: it waits on the audio server, which the
    /// keyboard's main thread must not do while iOS waits for its first frame.
    static func allowHapticsWhileRecording() {
        audioSessionQueue.async { _ = hapticsAllowed }
    }

    nonisolated private static let hapticsAllowed: Void = {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }()
    /// A touch-down capture neither kept nor dropped by then is dropped, so a lost touch never
    /// leaves the microphone open. A hold keeps it at 0.35 s.
    static let armedTimeout: TimeInterval = 3
    /// Learn how I type's dictation fixes, read when a dictation starts; empty while off.
    var corrections: () -> [DictationCorrection] = { [] }
    /// The field the keyboard is in, read when a dictation starts.
    var currentDocument: () -> UUID? = { nil }
    private var activeCorrections: [DictationCorrection] = []

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Memory left below iOS's limit for this keyboard that the first dictation needs to start:
    /// the capture web view, its page and WebKit's first use (7–11 MB in the simulator with
    /// the recording screen), the Metal scope's device and pipeline (about 3.5 MB of GPU
    /// memory the simulator doesn't count) and drawables, with margin. iOS ends a keyboard
    /// that passes its limit, which varies by model (testers' 4 GB iPhones hit it), and
    /// switches to the system keyboard; short of this, Dictate opens Hex instead.
    static let startHeadroomNeeded = 32 * 1_048_576
    /// Later dictations reuse the loaded web view, so only the capture and recording screen
    /// start (1–5 MB in the simulator on the dictation bar; up to 8 MB on the full keyboard,
    /// which rebuilds its recording strip and briefly peaks leaving it).
    static let restartHeadroomNeeded = 24 * 1_048_576

    /// Whether in-keyboard dictation can start without passing the memory limit. Where iOS
    /// doesn't say (0, the simulator), it can.
    deinit {
        let id = ownerID
        Task { @MainActor in KeyboardLocalDictation.ownerDidDeinit(id) }
    }

    var hasMemoryToStart: Bool {
        let headroom = os_proc_available_memory()
        let warm = (capture ?? Self.sharedCapture) != nil
        return headroom == 0 || headroom >= (warm ? Self.restartHeadroomNeeded : Self.startHeadroomNeeded)
    }

    var isActive: Bool {
        switch phase {
        case .armed, .starting, .recording, .transcribing: true
        default: false
        }
    }

    /// The capture for `jobID` is the one running, armed or recording.
    private func isCapturing(_ jobID: String) -> Bool {
        switch phase {
        case .armed(let current, _), .starting(let current, _), .recording(let current, _): current == jobID
        default: false
        }
    }

    func snapshot(now: TimeInterval) -> KeyboardSnapshot? {
        switch phase {
        case .idle, .armed:
            return nil
        case .starting(let jobID, let startedAt):
            return KeyboardSnapshot(
                state: .starting,
                heartbeat: now,
                expiresAt: now + 60,
                recordingStartedAt: startedAt,
                jobID: jobID
            )
        case .recording(let jobID, let startedAt):
            return KeyboardSnapshot(
                state: .recording,
                heartbeat: now,
                expiresAt: now + 60,
                recordingStartedAt: startedAt,
                loudnessDB: loudness,
                jobID: jobID
            )
        case .transcribing(let jobID):
            return KeyboardSnapshot(state: .transcribing, heartbeat: now, expiresAt: now + 60, jobID: jobID)
        case .finished(let jobID, let resultID, let transcript, let heard, let stages, let translationFailure):
            return KeyboardSnapshot(
                state: .ready,
                heartbeat: now,
                expiresAt: now + 1,
                jobID: jobID,
                resultID: resultID,
                transcript: transcript,
                heard: heard,
                stages: stages,
                translationFailure: translationFailure
            )
        case .failed(let message, let until):
            guard until > now else {
                phase = .idle
                return nil
            }
            return KeyboardSnapshot(state: .failed, heartbeat: now, expiresAt: until, message: message, messageAt: now)
        }
    }

    func markDelivered(resultID: String) {
        if case .finished(_, let current, _, _, _, _) = phase, current == resultID {
            job = nil
            phase = .idle
        }
    }

    /// Makes the capture web view and loads its page before the first dictation, so the Hex
    /// key only has the microphone left to open. Nothing here asks for the microphone or the
    /// audio session, so no orange dot shows until a dictation starts. Skipped while short of
    /// the memory a first dictation needs (it would open Hex instead) and without the
    /// microphone allowed (it would fail).
    func prepare(in host: UIView) {
        guard Self.isSupported, capture == nil, !isActive, Self.ownership.canAcquire(by: ownerID) else { return }
        let headroom = os_proc_available_memory()
        let needed = Self.sharedCapture == nil ? Self.startHeadroomNeeded : Self.restartHeadroomNeeded
        guard headroom == 0 || headroom >= needed else { return }
        guard Self.microphoneAllowed else { return }
        if let reused = Self.sharedCapture {
            Self.ownership.acquireIdle(by: ownerID)
            reused.attach(to: host)
            listenWhileIdle(reused)
            capture = reused
            return
        }
        let started = Date()
        let created = KeyboardWebCapture(host: host)
        Self.sharedCapture = created
        Self.ownership.acquireIdle(by: ownerID)
        capture = created
        listenWhileIdle(created)
        KeyboardProbeLog.shared.write("capture prepared in \(Int(Date().timeIntervalSince(started) * 1000)) ms \(KeyboardProbeLog.memory())")
    }

    private func acquireCaptureForStart(in host: UIView) -> KeyboardWebCapture {
        if let own = capture, own !== Self.sharedCapture {
            own.attach(to: host)
            return own
        }
        if Self.ownership.canAcquire(by: ownerID) {
            let shared = Self.sharedCapture ?? KeyboardWebCapture(host: host)
            shared.attach(to: host)
            Self.sharedCapture = shared
            Self.ownership.beginCapture(by: ownerID)
            capture = shared
            return shared
        }
        // Another live keyboard is actively recording with the shared web view: use a dedicated
        // one here rather than stealing its stream.
        let dedicated = KeyboardWebCapture(host: host)
        capture = dedicated
        Self.dedicatedCaptures[ownerID] = dedicated
        return dedicated
    }

    private func noteCaptureStopped() {
        live?.stop()
        live = nil
        onNoiseReferenceUpdate?(nil, false)
        if capture === Self.sharedCapture {
            Self.ownership.endCapture(by: ownerID)
        }
    }

    /// Detaches the capture web view when this keyboard hides, only if this keyboard still owns
    /// the shared capture (or nobody does). When a newer keyboard already took ownership, this
    /// keyboard drops only its own pointer.
    private func parkCapture() {
        guard let current = capture else { return }
        capture = nil
        guard current === Self.sharedCapture else {
            Self.dedicatedCaptures.removeValue(forKey: ownerID)
            current.tearDown()
            return
        }
        guard Self.ownership.park(by: ownerID) else { return }
        current.detach()
        Self.listenWhileParked(current)
    }

    private static func ownerDidDeinit(_ id: Int) {
        if let dedicated = dedicatedCaptures.removeValue(forKey: id) {
            dedicated.stop()
            dedicated.tearDown()
        }
        guard ownership.ownerDidDeinit(id), let capture = sharedCapture else { return }
        capture.stop()
        capture.detach()
        listenWhileParked(capture)
    }

    func handleMemoryWarning() {
        live?.memoryWarning()
        KeyboardParakeet.shared.handleMemoryWarning()
        guard !isActive else { return }
        let current = capture
        capture = nil
        if let current, current !== Self.sharedCapture {
            Self.dedicatedCaptures.removeValue(forKey: ownerID)
            current.tearDown()
        }
        guard Self.ownership.evictForMemoryWarning(by: ownerID) else { return }
        let evicted = Self.sharedCapture
        Self.sharedCapture = nil
        evicted?.tearDown()
    }

    /// The page between dictations: a prepared page loading, or one whose content process
    /// ends, which the next start replaces.
    private func listenWhileIdle(_ capture: KeyboardWebCapture) {
        capture.onEvent = { [weak self, weak capture] event in
            guard let self, let capture else { return }
            self.handleIdle(event, capture: capture)
        }
    }

    private static func listenWhileParked(_ capture: KeyboardWebCapture) {
        capture.onEvent = { [weak capture] event in
            guard let capture else { return }
            switch event {
            case .loaded:
                let ms = Int((Date().timeIntervalSince1970 - capture.createdAt) * 1000)
                KeyboardProbeLog.shared.write("capture page loaded in \(ms) ms \(KeyboardProbeLog.memory())")
            case .processTerminated:
                if sharedCapture === capture, ownership.dropTerminated(by: nil) {
                    sharedCapture = nil
                    Task { @MainActor in capture.tearDown() }
                }
            case .started:
                capture.stop()
            default:
                break
            }
        }
    }

    private func handleIdle(_ event: KeyboardWebCapture.Event, capture: KeyboardWebCapture) {
        switch event {
        case .loaded:
            let ms = Int((Date().timeIntervalSince1970 - capture.createdAt) * 1000)
            KeyboardProbeLog.shared.write("capture page loaded in \(ms) ms \(KeyboardProbeLog.memory())")
        case .processTerminated:
            if capture === self.capture || capture === Self.sharedCapture { dropEndedCapture() }
        case .started:
            // A dropped start that got its microphone anyway: close it.
            capture.stop()
        default:
            break
        }
    }

    /// The web view's content process ended: the next start makes a new one, and this one
    /// leaves the keyboard's view once WebKit's callback has returned.
    private func dropEndedCapture() {
        let current = capture
        capture = nil
        if let current, current !== Self.sharedCapture {
            Self.dedicatedCaptures.removeValue(forKey: ownerID)
            Task { @MainActor in current.tearDown() }
            return
        }
        guard Self.ownership.dropTerminated(by: ownerID) else { return }
        let ended = Self.sharedCapture
        Self.sharedCapture = nil
        Task { @MainActor in ended?.tearDown() }
    }

    /// The keyboard extension itself may not record (audiomxd: "it is an extension and
    /// doesn't have entitlements to record audio"), so capture runs in WebKit's media
    /// process through getUserMedia, attributed to Hex's microphone permission.
    /// The page asks for Settings › Microphone's input by name (`microphone(for:)`): left to
    /// itself, WebKit takes the input of the route already playing, the iPhone's microphone
    /// while a car or headphones play over A2DP, whatever the setting.
    /// WebKit's capture session doesn't mix: other apps' video and music pause while it
    /// records, and `releaseAudioSession` asks them to resume afterwards.
    /// `pressedAt` is the Hex key's touch-down (wall clock), where the start's timeline begins.
    /// A capture armed at touch-down becomes this dictation.
    func start(in host: UIView, microphone: MicrophoneChoice, pressedAt: TimeInterval? = nil) {
        if case .armed(let jobID, let startedAt) = phase {
            keepArmed(jobID: jobID, startedAt: startedAt)
            return
        }
        guard !isActive else { return }
        begin(in: host, microphone: microphone, pressedAt: pressedAt, armed: false)
    }

    /// Touch-down on the Hex key: capture starts now, unseen, so the first words aren't lost
    /// while the touch becomes a tap or a hold (`start` keeps it) or a slide or a cancelled
    /// touch (`discard` drops it, with nothing transcribed). The microphone opens here.
    func arm(in host: UIView, microphone: MicrophoneChoice, pressedAt: TimeInterval) {
        // Without the microphone, the tap's own start says so.
        guard !isActive, Self.microphoneAllowed else { return }
        guard let jobID = begin(in: host, microphone: microphone, pressedAt: pressedAt, armed: true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armedTimeout) { [weak self] in
            guard let self, case .armed(let current, _) = self.phase, current == jobID else { return }
            self.discard(reason: "never kept")
        }
    }

    /// The touch became a slide (the style menu) or was cancelled: the touch-down capture
    /// stops, its audio is deleted, and nothing is transcribed.
    func discard(reason: String = "slide or cancelled touch") {
        guard case .armed(_, let startedAt) = phase else { return }
        noteCaptureStopped()
        if let capture, capture !== Self.sharedCapture || Self.ownership.owner == ownerID {
            listenWhileIdle(capture)
            capture.stop()
        }
        if let url = pcmFile?.url { try? FileManager.default.removeItem(at: url) }
        pcmFile = nil
        timeline = nil
        armedFailure = nil
        job = nil
        phase = .idle
        releaseAudioSession()
        KeyboardProbeLog.shared.write("touch-down capture discarded after \(Int((Date().timeIntervalSince1970 - startedAt) * 1000)) ms (\(reason))")
    }

    private func keepArmed(jobID: String, startedAt: TimeInterval) {
        phase = if let firstAudioAt {
            .recording(jobID: jobID, startedAt: firstAudioAt)
        } else {
            .starting(jobID: jobID, startedAt: startedAt)
        }
        KeyboardProbeLog.shared.write("touch-down capture kept after \(Int((Date().timeIntervalSince1970 - startedAt) * 1000)) ms")
        if let failure = armedFailure {
            armedFailure = nil
            fail(failure.message, detail: failure.detail)
        }
    }

    /// This process keeps the permission it read when it started, so a keyboard opened before
    /// Hex was allowed the microphone (onboarding's practice field) still reads it as not
    /// allowed: Hex's own reading counts too. WebKit still checks (NotAllowedError).
    private static var microphoneAllowed: Bool {
        AVAudioApplication.shared.recordPermission == .granted || KeyboardBridge().appMicrophoneAllowed
    }

    /// Opens the microphone for a new job, armed (touch-down) or recording; nil when it can't.
    @discardableResult
    private func begin(in host: UIView, microphone: MicrophoneChoice, pressedAt: TimeInterval?, armed: Bool) -> String? {
        let log = KeyboardProbeLog.shared
        let appAllowed = KeyboardBridge().appMicrophoneAllowed
        guard Self.microphoneAllowed else {
            log.write("start(web\(armed ? ", touch-down" : "")): mic=\(Self.describe(AVAudioApplication.shared.recordPermission)) app=no")
            fail("Allow the microphone in Hex first")
            return nil
        }
        let jobID = UUID().uuidString
        let requestedAt = Date()
        job = Job(id: jobID, document: currentDocument())
        lastProgressAt = requestedAt.timeIntervalSince1970
        watch = KeyboardCaptureWatch(startedAt: lastProgressAt)
        activeCorrections = corrections()
        loudness = -62
        armedFailure = nil
        firstAudioAt = nil
        onNoiseReferenceUpdate?(nil, false)
        phase = armed
            ? .armed(jobID: jobID, startedAt: requestedAt.timeIntervalSince1970)
            : .starting(jobID: jobID, startedAt: requestedAt.timeIntervalSince1970)
        timeline = CaptureTimeline(
            pressedAt: min(pressedAt ?? requestedAt.timeIntervalSince1970, requestedAt.timeIntervalSince1970),
            requestedAt: requestedAt.timeIntervalSince1970
        )
        let capture = acquireCaptureForStart(in: host)
        capture.onEvent = { [weak self] event in
            self?.handle(event, jobID: jobID, requestedAt: requestedAt)
        }
        // The audio session's calls are round trips to the audio server, which can be slow to
        // answer (a call, another app's audio, a capture that just ended): on the main thread
        // they held every key until it did. They run on the session's queue, after any earlier
        // capture's release there, and the page starts once they're back, unless the job was
        // dropped, stopped or replaced meanwhile.
        startPending = jobID
        let label = armed ? ", touch-down" : ""
        Self.audioSessionQueue.async { [weak self, weak capture] in
            log.write("start(web\(label)): mic=\(Self.describe(AVAudioApplication.shared.recordPermission)) app=\(appAllowed ? "granted" : "no") speech=\(Self.describe(SFSpeechRecognizer.authorizationStatus())) \(KeyboardProbeLog.memory())")
            let input = Self.microphone(for: microphone)
            let otherAudio = AVAudioSession.sharedInstance().isOtherAudioPlaying
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let capture, self.capture === capture,
                          self.startPending == jobID, self.isCapturing(jobID) else { return }
                    self.startPending = nil
                    self.otherAudioAtStart = self.otherAudioAtStart || otherAudio
                    // Without a name to ask for, every choice but Bluetooth asks for the iPhone's own.
                    capture.start(
                        microphone: input?.name,
                        builtInFallback: microphone != .bluetooth,
                        noiseReduction: KeyboardBridge().noiseReductionEnabled
                    )
                }
            }
        }
        return jobID
    }

    /// Asks the video or music the capture interrupted to resume (`InterruptedAudio`), once
    /// WebKit has let its session go and unless another capture has started.
    private func releaseAudioSession() {
        guard otherAudioAtStart else { return }
        otherAudioAtStart = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeOtherAudioDelay) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .armed, .starting, .recording:
                // Another capture started: its end asks instead.
                self.otherAudioAtStart = true
                return
            default:
                break
            }
            Self.audioSessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                guard InterruptedAudio.shouldAskToResume(playingAtStart: true, playingNow: session.isOtherAudioPlaying) else {
                    KeyboardProbeLog.shared.write("other audio kept playing through the capture")
                    return
                }
                do {
                    try InterruptedAudio.askToResume(session)
                    KeyboardProbeLog.shared.write("asked the audio the capture interrupted to resume")
                } catch {
                    let ns = error as NSError
                    KeyboardProbeLog.shared.write("asking interrupted audio to resume failed: \(ns.domain) \(ns.code)")
                }
            }
        }
    }

    /// The input Settings › Microphone takes on this route (`MicrophoneRoute.capture`), read
    /// from the keyboard's own session with the category Hex records in: CarPlay's and
    /// Bluetooth hands-free inputs are listed only there. WebKit records in its own session,
    /// which only getUserMedia's `deviceId` steers (WebKit then prefers that input), so the
    /// page asks for this input by its name, the label WebKit gives it.
    nonisolated private static func microphone(for choice: MicrophoneChoice) -> Microphone? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: MicrophoneRoute.categoryOptions(allowingBluetooth: choice.allowsBluetooth)
            )
            let inputs = session.microphones
            let input = MicrophoneRoute.capture(choice, from: inputs)
            try? session.prefer(input)
            let listed = inputs.map { "\($0.name) (\($0.port.rawValue))" }.joined(separator: ", ")
            KeyboardProbeLog.shared.write("microphone \(choice.rawValue): \(input?.name ?? "none") of [\(listed)]")
            return input
        } catch {
            KeyboardProbeLog.shared.write("microphone \(choice.rawValue) unknown: \(describe(error))")
            return nil
        }
    }

    private func handle(_ event: KeyboardWebCapture.Event, jobID: String, requestedAt: Date) {
        let log = KeyboardProbeLog.shared
        switch event {
        case .started(let sampleRate, let device, let steps, let noiseSuppression, let autoGainControl, let channelCount):
            log.write("web capture started in \(Int(Date().timeIntervalSince(requestedAt) * 1000)) ms at \(Int(sampleRate)) Hz from \(device), channels=\(channelCount) \(KeyboardProbeLog.memory())")
            let requestedNoiseReduction = KeyboardBridge().noiseReductionEnabled
            let suppression = noiseSuppression.map { $0 ? "on" : "off" } ?? "not reported"
            let gainControl = autoGainControl.map { $0 ? "on" : "off" } ?? "not reported"
            log.write("audio processing: requested noise reduction=\(requestedNoiseReduction), WebKit noise suppression=\(suppression), auto gain=\(gainControl)")
            if let capture {
                timeline?.noteStarted(capture: capture, steps: steps, sampleRate: sampleRate)
            }
            guard isCapturing(jobID) else {
                // Done came before the microphone did: nothing to record.
                capture?.stop()
                return
            }
            onNoiseReferenceUpdate?(nil, channelCount > 1)
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-\(jobID).wav")
                pcmFile = try KeyboardPCMFile(url: url, sampleRate: sampleRate)
                live = KeyboardLiveDictation.start(sampleRate: sampleRate, text: liveText)
            } catch {
                capture?.stop()
                fail(UserFacingError.Context.microphone.fallback, detail: "Could not create audio file: \(Self.describe(error))")
            }
        case .samples(let data, let peak, let referencePeak):
            // Old WebKit pages can deliver late callbacks; only this job's non-empty PCM counts.
            guard isCapturing(jobID), !data.isEmpty, pcmFile != nil else { return }
            if let referencePeak {
                let referenceDB = referencePeak > 0 ? max(-60, min(0, 20 * log10(referencePeak))) : -60
                onNoiseReferenceUpdate?(referenceDB, true)
            } else {
                onNoiseReferenceUpdate?(nil, false)
            }
            let now = Date().timeIntervalSince1970
            if firstAudioAt == nil {
                firstAudioAt = now
                if case .starting(let current, _) = phase, current == jobID {
                    phase = .recording(jobID: current, startedAt: now)
                }
            }
            if let line = timeline?.firstBuffer(at: now) {
                log.write("\(line) \(KeyboardProbeLog.memory())")
                timeline = nil
            }
            // Whisper mode adds conservative, peak-limited gain before both the WAV
            // recorder and live recogniser receive the samples.
            let whisper = KeyboardWhisperSettings().isEnabled
            let audio = whisper ? WhisperAudioProcessor.amplify(data) : data
            let displayedPeak = min(1.0, peak * (whisper ? WhisperAudioProcessor.defaultGain : 1.0))
            pcmFile?.append(audio)
            live?.append(audio)
            lastProgressAt = now
            watch.heardAudio(at: now)

            let rawDB = displayedPeak > 0 ? 20 * log10(displayedPeak) : -62
            if KeyboardBridge().noiseReductionEnabled {
                // Meter-only voice gate: the recorder/recognizer still receive the
                // complete processed audio stream, but low-level background ambience
                // stays invisible in the waveform. Speech above the gate is expanded
                // for a clearer, more responsive visual meter.
                let voiceThresholdDB: Float = -43
                if rawDB < voiceThresholdDB {
                    loudness = -62
                } else {
                    loudness = min(0, max(-42, (rawDB - voiceThresholdDB) * 1.35 - 42))
                }
            } else {
                loudness = max(-62, rawDB)
            }
        case .state(let state):
            guard isCapturing(jobID) else { return }
            let now = Date().timeIntervalSince1970
            let into = String(format: "%.1f", state.at - requestedAt.timeIntervalSince1970)
            log.write("page \(state.cause) at +\(into) s: \(state.summary)")
            switch watch.page(state, at: now) {
            case .interrupted:
                log.write("capture interrupted: waiting up to \(Int(KeyboardJobWatchdog.captureInterruption)) s for it to come back")
            case .resumed(let after):
                log.write("capture back after \(String(format: "%.1f", after)) s: the same dictation goes on")
            case nil:
                break
            }
        case .stopped:
            finishRecording(jobID: jobID)
        case .failed(let message):
            guard isCapturing(jobID) else { return }
            capture?.stop()
            pcmFile = nil
            fail(
                message.hasPrefix("NotAllowedError") ? "Allow the microphone in Hex first" : UserFacingError.Context.microphone.fallback,
                detail: "Web capture: \(message)"
            )
        case .processTerminated:
            // The next start needs a new web view; this one leaves the keyboard's view too,
            // instead of staying behind with its page.
            dropEndedCapture()
            // Only a capture loses anything: a later dictation's page may end while idle.
            guard isCapturing(jobID) else {
                KeyboardProbeLog.shared.write("capture process ended while idle")
                return
            }
            pcmFile = nil
            fail(UserFacingError.Context.microphone.fallback, detail: "WebKit capture process ended")
        case .loaded:
            break
        }
    }

    /// Reports why Quick wake could not start without handing the user off to the containing app.
    func reportUnavailable(_ message: String) {
        guard !isActive else { return }
        fail(message, detail: "Quick wake unavailable")
    }

    func cancel() {
        startPending = nil
        transcription?.cancel()
        transcription = nil
        timeline = nil
        armedFailure = nil
        noteCaptureStopped()
        if let capture, capture !== Self.sharedCapture || Self.ownership.owner == ownerID {
            listenWhileIdle(capture)
            capture.stop()
        }
        if let url = pcmFile?.url { try? FileManager.default.removeItem(at: url) }
        pcmFile = nil
        job = nil
        phase = .idle
        releaseAudioSession()
        KeyboardProbeLog.shared.write("cancelled")
    }

    func stop() {
        switch phase {
        case .starting:
            stopUnstartedCapture(reason: "stopped before audio arrived")
        case .recording(let jobID, _):
            guard startPending != jobID else {
                startPending = nil
                finishRecording(jobID: jobID)
                return
            }
            capture?.stop()
        default:
            break
        }
    }

    private func stopUnstartedCapture(reason: String) {
        guard case .starting(let jobID, _) = phase else { return }
        if startPending == jobID { startPending = nil }
        timeline = nil
        onNoiseReferenceUpdate?(nil, false)
        if let capture, capture !== Self.sharedCapture || Self.ownership.owner == ownerID {
            listenWhileIdle(capture)
            capture.stop()
        }
        if let url = pcmFile?.url { try? FileManager.default.removeItem(at: url) }
        pcmFile = nil
        firstAudioAt = nil
        job = nil
        endQuietly(reason)
    }

    /// The keyboard is going away mid-dictation (dismissed, or another app came forward).
    /// A touch still deciding is dropped; a recording stops and keeps what was said, without
    /// waiting for the page (WebKit may not answer once the keyboard is gone); and the job's
    /// text is held for the next keyboard instead of being lost with this one.
    func keyboardWillHide() {
        switch phase {
        case .armed:
            discard(reason: "keyboard hidden")
        case .starting:
            stopUnstartedCapture(reason: "keyboard hidden before audio arrived")
        case .recording(let jobID, _):
            job?.interrupted = true
            KeyboardProbeLog.shared.write("keyboard hidden while recording: finishing with what was said")
            if let capture, capture !== Self.sharedCapture || Self.ownership.owner == ownerID {
                listenWhileIdle(capture)
                capture.stop()
            }
            finishRecording(jobID: jobID)
        case .transcribing:
            if let job, !job.interrupted {
                job.interrupted = true
                KeyboardProbeLog.shared.write("keyboard hidden while transcribing: holding its text for the next keyboard")
                Self.leaveRecording(of: job)
            }
        case .finished(_, let resultID, let transcript, let heard, _, _):
            // Shown but not yet inserted: the next keyboard inserts it.
            Self.hold(resultID: resultID, text: transcript, heard: heard, document: job?.document)
            job = nil
            phase = .idle
        case .idle, .failed:
            break
        }
        parkCapture()
    }

    /// Self-heal, on every poll while the keyboard shows: a capture that went quiet finishes
    /// with what it heard, and a transcription that never returns is given up, so the
    /// keyboard never stays in recording or transcribing with nothing behind it.
    func healIfStalled(now: TimeInterval) {
        switch phase {
        case .starting(let jobID, _) where watch.isStalled(now: now):
            KeyboardProbeLog.shared.write("capture timed out before first audio")
            if let capture, capture !== Self.sharedCapture || Self.ownership.owner == ownerID {
                listenWhileIdle(capture)
                capture.stop()
            }
            fail(UserFacingError.Context.microphone.fallback, detail: "capture timed out before first audio")
        case .recording(let jobID, _) where watch.isStalled(now: now):
            if let since = watch.interruptedSince {
                KeyboardProbeLog.shared.write("capture interrupted for \(Int(now - since)) s: finishing with what it heard")
            } else {
                KeyboardProbeLog.shared.write("capture silent for \(Int(now - watch.lastAudio)) s: finishing with what it heard")
            }
            if let capture {
                listenWhileIdle(capture)
                capture.stop()
            }
            finishRecording(jobID: jobID)
        case .transcribing where KeyboardJobWatchdog.isStalled(.transcribing, lastProgress: lastProgressAt, now: now):
            KeyboardProbeLog.shared.write("transcription stuck for \(Int(now - lastProgressAt)) s: giving up")
            transcription?.cancel()
            transcription = nil
            job = nil
            phase = .idle
        case .idle:
            recoverLeftRecording(now: now)
        default:
            break
        }
    }

    private static func hold(
        resultID: String, text: String, heard: String?, document: UUID?, stoppedAfter: TimeInterval? = nil
    ) {
        KeyboardBridge().heldDictation = KeyboardHeldDictation(
            id: resultID,
            text: text,
            heard: heard,
            document: document,
            finishedAt: Date().timeIntervalSince1970,
            stoppedAfter: stoppedAfter
        )
        KeyboardProbeLog.shared.write("held a dictation for the next keyboard: \(text.count) chars")
    }

    /// The jobs this keyboard process is currently transcribing; a poll must not start a second
    /// transcription of the same recording while the first one is still alive.
    private static var transcribingJobs: Set<String> = []

    /// Keeps a recording for the next keyboard if iOS ends this keyboard before transcription
    /// finishes (most commonly after the screen locks and the extension is frozen).
    private static func leaveRecording(of job: Job) {
        guard let recording = job.recording else { return }
        KeyboardInterruptedRecording(
            jobID: job.id,
            fileName: recording.fileName,
            document: job.document,
            seconds: recording.seconds,
            cutShort: job.stoppedAfter != nil,
            at: Date().timeIntervalSince1970
        ).save()
    }

    /// Transcribes a WAV file left by an earlier keyboard process and holds its words for the
    /// next input field. The file stays in tmp until the transcript is held or expires.
    private func recoverLeftRecording(now: TimeInterval) {
        guard #available(iOS 26.0, *), let record = KeyboardInterruptedRecording.load(),
              !Self.transcribingJobs.contains(record.jobID) else { return }
        guard !record.isExpired(at: now), FileManager.default.fileExists(atPath: record.url.path) else {
            KeyboardInterruptedRecording.clear(jobID: record.jobID)
            return
        }
        Self.transcribingJobs.insert(record.jobID)
        let vocabulary = CustomVocabularySettings().activeTerms
        let learnedPhrases = SpeechLearningStore().recognitionHints(
            language: LanguageSettings().effectiveDictationLanguage
        )
        let fixes = corrections()
        let hints = DictationCorrections.recognitionHints(
            vocabulary: learnedPhrases + vocabulary,
            corrections: fixes,
            language: LanguageSettings().effectiveDictationLanguage
        )
        let style = KeyboardBridge().style
        let lowercase = DictationLowercaseSettings().isEnabled
        let formatLists = DictationListSettings().isEnabled
        let spokenPunctuation = DictationPunctuationSettings().isEnabled
        let hinglish = HinglishSettings().isEnabled
        let greeklish = GreeklishSettings().isEnabled
        let endsWithPeriod = DictationPeriodSettings().isEnabled
        KeyboardProbeLog.shared.write("transcribing a recording an earlier keyboard left: \(String(format: "%.1f", record.seconds)) s")
        Task {
            defer {
                Self.transcribingJobs.remove(record.jobID)
                KeyboardInterruptedRecording.clear(jobID: record.jobID)
            }
            do {
                let (heard, language, engine) = try await KeyboardTranscription.transcribe(
                    record.url, hints: hints, audioSeconds: record.seconds
                )
                let steps = await DictationPipeline(
                    style: style,
                    language: language.identifier,
                    vocabulary: vocabulary,
                    corrections: fixes,
                    lowercase: lowercase,
                    formatLists: formatLists,
                    spokenPunctuation: spokenPunctuation,
                    hinglish: hinglish,
                    greeklish: greeklish,
                    endsWithPeriod: endsWithPeriod
                ).run(heard, translationSource: language.locale.language)
                guard !steps.formatted.isEmpty else { return }
                let resultID = UUID().uuidString
                let spokenSentence = steps.translated == nil ? steps.formatted : steps.cleaned
                if !spokenSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let staged = SpeechLearningStore().stagePendingAudio(
                        from: record.url,
                        resultID: resultID,
                        text: spokenSentence,
                        heard: steps.heard,
                        translatedText: steps.translated == nil ? nil : steps.formatted,
                        translatedLanguage: steps.translatedLanguage,
                        language: language.identifier,
                        duration: record.seconds
                    )
                    KeyboardProbeLog.shared.write("recovered dictation Learning candidate staged=\(staged)")
                }
                Self.hold(
                    resultID: resultID,
                    text: steps.formatted,
                    heard: steps.translated == nil ? steps.heard : nil,
                    document: record.document,
                    stoppedAfter: record.cutShort ? record.seconds : nil
                )
                KeyboardProbeLog.shared.write("recovered interrupted keyboard dictation: \(steps.formatted.count) chars via \(engine)")
            } catch {
                KeyboardProbeLog.shared.write("a left recording didn't transcribe: \(Self.describe(error))")
            }
        }
    }

    private func finishRecording(jobID: String) {
        if case .starting(let current, _) = phase, current == jobID {
            stopUnstartedCapture(reason: "stopped before audio arrived")
            return
        }
        guard case .recording(let current, let startedAt) = phase, current == jobID else { return }
        noteCaptureStopped()
        guard let file = pcmFile else {
            endQuietly("stopped before the microphone started")
            return
        }
        let job = self.job
        pcmFile = nil
        releaseAudioSession()
        let seconds = Date().timeIntervalSince1970 - startedAt
        let frames = file.close()
        KeyboardProbeLog.shared.write("stopped after \(String(format: "%.1f", seconds)) s, frames=\(frames) \(KeyboardProbeLog.memory())")
        guard !EmptyCapture.isTooShort(frames: frames, sampleRate: file.sampleRate) else {
            try? FileManager.default.removeItem(at: file.url)
            endQuietly("too short to hold a word")
            return
        }
        guard #available(iOS 26.0, *) else { return }
        phase = .transcribing(jobID: jobID)
        lastProgressAt = Date().timeIntervalSince1970
        let url = file.url
        job?.recording = (url.lastPathComponent, seconds)
        if let job, job.interrupted {
            job.stoppedAfter = seconds
            Self.leaveRecording(of: job)
        }
        let fixes = activeCorrections
        let vocabulary = CustomVocabularySettings().activeTerms
        let learnedPhrases = SpeechLearningStore().recognitionHints(
            language: LanguageSettings().effectiveDictationLanguage
        )
        let hints = DictationCorrections.recognitionHints(
            vocabulary: learnedPhrases + vocabulary,
            corrections: fixes,
            language: LanguageSettings().effectiveDictationLanguage
        )
        Self.transcribingJobs.insert(jobID)
        transcription = Task { [weak self] in
            defer {
                Self.transcribingJobs.remove(jobID)
                if !(job?.interrupted ?? false) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let started = Date()
            do {
                let (heard, language, engine) = try await KeyboardTranscription.transcribe(url, hints: hints, audioSeconds: seconds)
                let locale = language.identifier
                let style = KeyboardBridge().style
                // The app's steps (but Apple Intelligence's cleanup), its style, Format lists,
                // Spoken punctuation, End with a period and Lowercase included.
                let pipeline = DictationPipeline(
                    style: style,
                    language: locale,
                    vocabulary: vocabulary,
                    corrections: fixes,
                    lowercase: DictationLowercaseSettings().isEnabled,
                    formatLists: DictationListSettings().isEnabled,
                    spokenPunctuation: DictationPunctuationSettings().isEnabled,
                    hinglish: HinglishSettings().isEnabled,
                    greeklish: GreeklishSettings().isEnabled,
                    endsWithPeriod: DictationPeriodSettings().isEnabled
                )
                let steps = await pipeline.run(heard, translationSource: language.locale.language)
                let translated = steps.translated
                let text = steps.formatted
                KeyboardProbeLog.shared.write("transcribed in \(String(format: "%.2f", Date().timeIntervalSince(started))) s: \(text.count) chars \(KeyboardProbeLog.memory())")
                if let failure = steps.translationFailure {
                    KeyboardProbeLog.shared.write("pasted as spoken: \(failure.source)->\(failure.target) \(failure.reason.rawValue) \(failure.detail ?? "")")
                }
                guard !Task.isCancelled else { return }
                // A translation cannot be compared with the spoken words for typing corrections,
                // but the spoken sentence, translation and original audio are still a useful study sample.
                let resultID = UUID().uuidString
                let learnable = translated == nil ? steps.heard : nil
                let spokenSentence = translated == nil ? text : steps.cleaned
                if !spokenSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let staged = SpeechLearningStore().stagePendingAudio(
                        from: url,
                        resultID: resultID,
                        text: spokenSentence,
                        heard: steps.heard,
                        translatedText: translated == nil ? nil : text,
                        translatedLanguage: steps.translatedLanguage,
                        language: locale,
                        duration: seconds
                    )
                    KeyboardProbeLog.shared.write("local dictation Learning candidate staged=\(staged), duration=\(String(format: "%.1f", seconds))s")
                }
                guard let self, !(job?.interrupted ?? false) else {
                    // The keyboard hid before it finished, or is gone: the next one delivers it.
                    if !text.isEmpty {
                        Self.hold(
                            resultID: resultID, text: text, heard: learnable,
                            document: job?.document, stoppedAfter: job?.stoppedAfter
                        )
                    }
                    try? FileManager.default.removeItem(at: url)
                    if let job { KeyboardInterruptedRecording.clear(jobID: job.id) }
                    if let self, self.job === job {
                        self.job = nil
                        self.phase = .idle
                    }
                    return
                }
                // Record typing logs keeps every step; nothing is kept while it is off.
                let stages: DictationStages? = TypingLogSettings().isEnabled
                    ? DictationStages(
                        engine: engine,
                        locale: locale,
                        style: style.rawValue,
                        recordedMS: Int((seconds * 1000).rounded()),
                        transcribeMS: Int((Date().timeIntervalSince(started) * 1000).rounded()),
                        raw: heard,
                        fixed: steps.fixed,
                        spelled: vocabulary.isEmpty ? nil : steps.spelled,
                        tagged: CleanupTaggerSettings().isEnabled && style != .verbatim ? steps.tagged : nil,
                        translated: translated,
                        formatted: steps.formatted
                    )
                    : nil
                self.phase = .finished(
                    jobID: jobID,
                    resultID: resultID,
                    transcript: text,
                    heard: learnable,
                    stages: stages,
                    translationFailure: steps.translationFailure
                )
            } catch {
                if !(job?.interrupted == true && Task.isCancelled) {
                    try? FileManager.default.removeItem(at: url)
                    if let job { KeyboardInterruptedRecording.clear(jobID: job.id) }
                }
                guard let self, !Task.isCancelled,
                      case .transcribing(let current) = self.phase, current == jobID else { return }
                if EmptyCapture.endsQuietly(error) {
                    self.endQuietly("no speech")
                } else {
                    self.fail(
                        UserFacingError.message(for: error, context: .transcription),
                        detail: "Transcription failed: \(Self.describe(error))"
                    )
                }
            }
        }
    }

    /// `message` is what the keyboard shows; `detail`, for the log only, may carry codes.
    private func fail(_ message: String, detail: String? = nil) {
        noteCaptureStopped()
        if case .armed = phase {
            // Shown only if the touch is kept.
            armedFailure = (message, detail)
            releaseAudioSession()
            KeyboardProbeLog.shared.write("FAILED at touch-down (held): \(detail ?? message) \(KeyboardProbeLog.memory())")
            return
        }
        startPending = nil
        timeline = nil
        if let url = pcmFile?.url { try? FileManager.default.removeItem(at: url) }
        pcmFile = nil
        firstAudioAt = nil
        job = nil
        releaseAudioSession()
        KeyboardProbeLog.shared.write("FAILED: \(detail ?? message) \(KeyboardProbeLog.memory())")
        phase = .failed(message: message, until: Date().timeIntervalSince1970 + 6)
    }

    /// Nothing to insert and nothing wrong: back to idle without a message.
    private func endQuietly(_ reason: String) {
        noteCaptureStopped()
        releaseAudioSession()
        KeyboardProbeLog.shared.write("ended quietly: \(reason)")
        // For onboarding's practice only; the keyboard shows nothing.
        KeyboardBridge().lastEmptyDictationAt = Date().timeIntervalSince1970
        phase = .idle
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    }

    nonisolated private static func describe(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }
}

/// What the page timed while starting (wall clock): the device list, the first
/// getUserMedia, the stream kept (after a second one for the chosen microphone) and the
/// audio context running.
struct CaptureSteps {
    var listedAt: TimeInterval?
    var openedAt: TimeInterval?
    var microphoneAt: TimeInterval?
    var audioAt: TimeInterval?
}

/// One in-keyboard start, from the Hex key's touch-down (or the start call without one) to
/// the first audio, as one probe log line. Times are wall clock, so a web view or page made
/// before the touch reads negative.
@MainActor
private struct CaptureTimeline {
    let pressedAt: TimeInterval
    let requestedAt: TimeInterval
    private var stages: [(String, TimeInterval?)] = []
    private var bufferSeconds: TimeInterval = 4096.0 / 48_000

    init(pressedAt: TimeInterval, requestedAt: TimeInterval) {
        self.pressedAt = pressedAt
        self.requestedAt = requestedAt
    }

    mutating func noteStarted(capture: KeyboardWebCapture, steps: CaptureSteps, sampleRate: Double) {
        bufferSeconds = 4096 / max(8_000, sampleRate)
        stages = [
            ("start", requestedAt),
            ("web view", capture.createdAt),
            ("page", capture.loadedAt),
            ("script", capture.scriptAt),
            ("devices", steps.listedAt),
            ("getUserMedia", steps.openedAt),
            ("microphone", steps.microphoneAt),
            ("audio", steps.audioAt),
            ("started", Date().timeIntervalSince1970),
        ]
    }

    /// The line for the first buffer, which holds the 4,096 samples before it.
    func firstBuffer(at time: TimeInterval) -> String {
        func ms(_ t: TimeInterval?) -> String {
            guard let t else { return "-" }
            let value = Int(((t - pressedAt) * 1000).rounded())
            return value >= 0 ? "+\(value)" : "\(value)"
        }
        let steps = (stages + [("first buffer", time)]).map { "\($0.0) \(ms($0.1))" }.joined(separator: ", ")
        return "first audio \(ms(time - bufferSeconds)) ms after touch-down (\(steps))"
    }
}

/// A Hex-key start through a warm Hex session (Keep mic warm): from touch-down to Hex's
/// recorder running, logged once the keyboard sees it.
struct WarmStartTimeline {
    let jobID: String
    let pressedAt: TimeInterval
    let sentAt: TimeInterval

    /// Logs and returns true once the snapshot shows this job recording, or gives up after 10 s.
    func observe(_ snapshot: KeyboardSnapshot, now: TimeInterval) -> Bool {
        if snapshot.state == .recording, snapshot.jobID == jobID {
            func ms(_ t: TimeInterval?) -> String { t.map { "+\(Int((($0 - pressedAt) * 1000).rounded()))" } ?? "-" }
            KeyboardProbeLog.shared.write(
                "warm start: recorder running \(ms(snapshot.recordingStartedAt)) ms after touch-down (sent \(ms(sentAt)), seen \(ms(now)))"
            )
            return true
        }
        return now - sentAt > 10
    }
}

/// 16-bit mono PCM chunks from the page, written as a WAV file.
@MainActor
private final class KeyboardPCMFile {
    let url: URL
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var frames: AVAudioFramePosition = 0

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw CocoaError(.featureUnsupported)
        }
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func append(_ data: Data) {
        let count = data.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let target = buffer.int16ChannelData?[0] else { return }
            memcpy(target, base, count * 2)
        }
        try? file?.write(from: buffer)
        frames += AVAudioFramePosition(count)
    }

    var sampleRate: Double { format.sampleRate }

    func close() -> AVAudioFramePosition {
        file = nil
        return frames
    }
}

@MainActor
private final class KeyboardWebCapture: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Event {
        case started(
            sampleRate: Double,
            device: String,
            steps: CaptureSteps,
            noiseSuppression: Bool?,
            autoGainControl: Bool?,
            channelCount: Int
        )
        case samples(Data, peak: Float, referencePeak: Float?)
        /// The page's AudioContext or microphone track changed.
        case state(KeyboardCapturePageState)
        case stopped
        case loaded
        case failed(String)
        case processTerminated
    }

    var onEvent: ((Event) -> Void)?
    private let webView: WKWebView
    private var isLoaded = false
    private var startWhenLoaded = false
    /// When the web view was made, its page loaded and the page last asked to start (wall clock).
    let createdAt = Date().timeIntervalSince1970
    private(set) var loadedAt: TimeInterval?
    private(set) var scriptAt: TimeInterval?

    init(host: UIView) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "hex")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.02
        host.addSubview(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://keyboard.hex.local/"))
    }

    private var microphone: String?
    private var builtInFallback = true
    private var noiseReduction = false

    /// Records from the input labelled `microphone` (`KeyboardLocalDictation.microphone(for:)`),
    /// else, with `builtInFallback`, the iPhone's own microphone, else WebKit's default.
    func start(microphone: String?, builtInFallback: Bool, noiseReduction: Bool) {
        self.microphone = microphone
        self.builtInFallback = builtInFallback
        self.noiseReduction = noiseReduction
        guard isLoaded else {
            startWhenLoaded = true
            return
        }
        scriptAt = Date().timeIntervalSince1970
        let label = microphone
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        webView.evaluateJavaScript("hexStart(\(label), \(builtInFallback), \(noiseReduction))")
    }

    func attach(to host: UIView) {
        if webView.superview !== host {
            host.addSubview(webView)
        }
    }

    func detach() {
        startWhenLoaded = false
        webView.removeFromSuperview()
    }

    func stop() {
        startWhenLoaded = false
        webView.evaluateJavaScript("hexStop()")
    }

    /// Takes the web view out of the keyboard, after its content process ended, so it doesn't
    /// stay behind next to the new one the next dictation makes.
    func tearDown() {
        onEvent = nil
        startWhenLoaded = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "hex")
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        loadedAt = Date().timeIntervalSince1970
        onEvent?(.loaded)
        if startWhenLoaded {
            startWhenLoaded = false
            start(
                microphone: microphone,
                builtInFallback: builtInFallback,
                noiseReduction: noiseReduction
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        onEvent?(.processTerminated)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "started":
            onEvent?(.started(
                sampleRate: (body["rate"] as? Double) ?? 48_000,
                device: (body["device"] as? String) ?? "unknown",
                steps: CaptureSteps(
                    listedAt: (body["listed"] as? Double).map { $0 / 1000 },
                    openedAt: (body["opened"] as? Double).map { $0 / 1000 },
                    microphoneAt: (body["mic"] as? Double).map { $0 / 1000 },
                    audioAt: (body["audio"] as? Double).map { $0 / 1000 }
                ),
                noiseSuppression: body["noiseSuppression"] as? Bool,
                autoGainControl: body["autoGainControl"] as? Bool,
                channelCount: (body["channels"] as? Int) ?? 1
            ))
        case "pcm":
            guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else { return }
            onEvent?(.samples(
                data,
                peak: Float((body["peak"] as? Double) ?? 0),
                referencePeak: (body["referencePeak"] as? Double).map(Float.init)
            ))
        case "state":
            onEvent?(.state(KeyboardCapturePageState(
                cause: (body["cause"] as? String) ?? "unknown",
                context: (body["context"] as? String) ?? "unknown",
                muted: (body["muted"] as? Bool) ?? false,
                ended: (body["ended"] as? Bool) ?? false,
                at: ((body["at"] as? Double) ?? 0) / 1000
            )))
        case "stopped":
            onEvent?(.stopped)
        case "error":
            onEvent?(.failed((body["message"] as? String) ?? "unknown"))
        default:
            break
        }
    }

    private static let page = """
    <!doctype html><meta charset="utf-8"><script>
    let ctx, stream, source, node, running = false, generation = 0, revive = null;
    // A stop waiting for the ScriptProcessor's final audio buffer, and its completion.
    let flushed = null, stopping = null;
    // Reopening the microphone after iOS suspends or ends WebKit's capture track.
    let constraints = null, mutedAt = 0, reopening = false, nextReopen = 0, backoff = 1000, reported = "";
    const post = (m) => webkit.messageHandlers.hex.postMessage(m);
    const release = (s, c) => {
      if (s) s.getTracks().forEach((t) => t.stop());
      if (c) c.close().catch(() => {});
    };
    // The input named `label`, else (with `builtIn`) the iPhone's own. Labels stay empty
    // until this page has had the microphone once.
    async function chosenMicrophone(label, builtIn) {
      const inputs = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "audioinput");
      const found = (label && inputs.find((d) => d.label === label))
        || (builtIn && inputs.find((d) => /iphone|ipad|built-in/i.test(d.label)));
      return found ? found.deviceId : null;
    }
    const track = () => stream && stream.getAudioTracks()[0];
    function report(cause) {
      if (!running || !ctx) return;
      const t = track();
      const state = { context: ctx.state, muted: !!(t && t.muted), ended: !t || t.readyState === "ended" };
      const key = state.context + state.muted + state.ended;
      if (key === reported && cause === "check") return;
      reported = key;
      post({ type: "state", cause, ...state, at: Date.now() });
    }
    function listen(t) {
      t.onmute = () => { if (t === track()) mutedAt = Date.now(); report("mute"); };
      t.onunmute = () => report("unmute");
      t.onended = () => report("ended");
    }
    function heal() {
      if (!running || !ctx) return;
      report("check");
      if (ctx.state !== "running") {
        if (ctx.state !== "closed") ctx.resume().catch(() => {});
        return;
      }
      const t = track();
      const ended = !t || t.readyState === "ended";
      if (!ended && !(t.muted && Date.now() - mutedAt >= 3000)) return;
      if (reopening || Date.now() < nextReopen) return;
      reopen(ended ? "ended" : "muted");
    }
    async function reopen(why) {
      reopening = true;
      const start = generation;
      report("opening the microphone again, track " + why);
      try {
        const s = await navigator.mediaDevices.getUserMedia(constraints);
        if (start !== generation || !running) return release(s);
        const old = stream;
        try { source.disconnect(); } catch (e) {}
        stream = s;
        source = ctx.createMediaStreamSource(s);
        source.connect(node);
        listen(track());
        mutedAt = Date.now();
        if (!track().muted) backoff = 1000;
        release(old);
        report("microphone opened again");
      } catch (error) {
        report("opening the microphone again failed: " + ((error && error.name) || String(error)));
      } finally {
        reopening = false;
        nextReopen = Date.now() + backoff;
        backoff = Math.min(8000, backoff * 2);
      }
    }
    async function hexStart(label, builtIn, noiseReduction) {
      while (stopping) await stopping;
      if (running) return;
      running = true;
      // A hexStop while this start waits (a slide off the Hex key right after touch-down)
      // makes it stale: it releases what it opened instead of going on.
      const start = ++generation;
      const stale = () => start !== generation;
      let s = null, c = null;
      try {
        const base = {
          // Ask for stereo where the active input route supports it. The returned channel
          // count is verified below; mono remains a valid fallback.
          channelCount: { ideal: 2 },
          echoCancellation: false,
          noiseSuppression: !!noiseReduction,
          autoGainControl: !!noiseReduction
        };
        const choosing = !!label || builtIn;
        let id = choosing ? await chosenMicrophone(label, builtIn) : null;
        if (stale()) return;
        const listed = Date.now();
        s = await navigator.mediaDevices.getUserMedia({ audio: id ? { ...base, deviceId: { exact: id } } : base });
        if (stale()) return release(s);
        const opened = Date.now();
        if (choosing && !id) {
          id = await chosenMicrophone(label, builtIn);
          if (stale()) return release(s);
          if (id && s.getAudioTracks()[0].getSettings().deviceId !== id) {
            s.getTracks().forEach((t) => t.stop());
            s = await navigator.mediaDevices.getUserMedia({ audio: { ...base, deviceId: { exact: id } } });
            if (stale()) return release(s);
          }
        }
        const mic = Date.now();
        c = new AudioContext();
        await c.resume();
        if (stale()) return release(s, c);
        stream = s;
        ctx = c;
        constraints = { audio: id ? { ...base, deviceId: { ideal: id } } : base };
        mutedAt = Date.now();
        listen(track());
        c.onstatechange = () => report("statechange");
        source = ctx.createMediaStreamSource(stream);
        const initialSettings = track().getSettings ? track().getSettings() : {};
        const inputChannels = Math.max(1, Math.min(2, Number(initialSettings.channelCount) || 1));
        node = ctx.createScriptProcessor(4096, inputChannels, 1);
        node.onaudioprocess = (event) => {
          if (!running && !flushed) return;
          const inputBuffer = event.inputBuffer;
          const input = inputBuffer.getChannelData(0);
          const currentSettings = track() && track().getSettings ? track().getSettings() : {};
          const hasReference = Number(currentSettings.channelCount || 1) > 1 && inputBuffer.numberOfChannels > 1;
          const reference = hasReference ? inputBuffer.getChannelData(1) : null;
          const pcm = new Int16Array(input.length);
          let peak = 0;
          let referencePeak = 0;
          for (let i = 0; i < input.length; i++) {
            const s = Math.max(-1, Math.min(1, input[i]));
            peak = Math.max(peak, Math.abs(s));
            pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
            if (reference) referencePeak = Math.max(referencePeak, Math.abs(reference[i]));
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          post({ type: "pcm", data: btoa(binary), peak, referencePeak: reference ? referencePeak : null });
          if (flushed) flushed();
        };
        source.connect(node);
        node.connect(ctx.destination);
        revive = setInterval(heal, 250);
        const applied = track().getSettings ? track().getSettings() : {};
        post({
          type: "started",
          rate: ctx.sampleRate,
          device: track().label,
          channels: Math.max(1, Math.min(2, Number(applied.channelCount) || inputChannels)),
          listed,
          opened,
          mic,
          audio: Date.now(),
          noiseSuppression: typeof applied.noiseSuppression === "boolean" ? applied.noiseSuppression : null,
          autoGainControl: typeof applied.autoGainControl === "boolean" ? applied.autoGainControl : null
        });
      } catch (error) {
        if (stale()) return release(s, c);
        running = false;
        // What it opened before taking it on; hexStop releases what it took.
        if (s !== stream) release(s, c);
        post({ type: "error", message: (error && (error.name + ": " + error.message)) || String(error) });
      }
    }
    async function hexStop() {
      generation++;
      const wasRunning = running;
      running = false;
      if (revive) { clearInterval(revive); revive = null; }
      // The processor may still hold the last 4,096 samples (about 85 ms at 48 kHz).
      // Let it post that buffer before disconnecting and releasing the microphone.
      if (flushed) flushed();
      let done = () => {};
      if (wasRunning) stopping = new Promise((resolve) => (done = resolve));
      if (wasRunning && node && ctx && ctx.state === "running") {
        await new Promise((resolve) => {
          const timer = setTimeout(() => flushed && flushed(), 250);
          flushed = () => { clearTimeout(timer); flushed = null; resolve(); };
        });
      }
      try { node && node.disconnect(); source && source.disconnect(); } catch (e) {}
      if (stream) stream.getTracks().forEach((t) => t.stop());
      if (ctx) { try { await ctx.close(); } catch (e) {} }
      ctx = stream = source = node = constraints = null;
      reopening = false;
      nextReopen = 0;
      backoff = 1000;
      reported = "";
      if (wasRunning) post({ type: "stopped" });
      if (wasRunning) stopping = null;
      done();
    }
    </script>
    """
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@available(iOS 26.0, *)
enum KeyboardSpeech {
    enum Failure: HexDescribedError, NoSpeechError {
        case noLocale
        case empty

        var errorDescription: String? {
            switch self {
            case .noLocale: String(localized: "Apple's speech recognition can't dictate this language on this iPhone.")
            case .empty: String(localized: "No speech heard.")
            }
        }

        var meansNoSpeech: Bool {
            if case .empty = self { return true }
            return false
        }
    }

    /// The transcript and the language it was transcribed in.
    static func transcribe(_ url: URL, hints: [String]) async throws -> (String, SpeechLanguage) {
        let log = KeyboardProbeLog.shared
        // The same rule as the app's (Settings › Dictation language, else Automatic), so the
        // keyboard uses the assets Hex downloaded.
        let settings = LanguageSettings()
        guard let picked = await AppleSpeechLanguages.resolve(settings: settings) else {
            // Only Speech listing languages, none of them the iPhone's, means it lacks yours.
            guard await AppleSpeechLanguages.listsNone() else { throw Failure.noLocale }
            log.write("speech lists no languages in the keyboard: handing over to Hex")
            throw SpeechModelNeedsHex.handOff(settings.effectiveDictationLanguage ?? "en-US", settings: settings)
        }
        log.write("speech locale=\(picked.identifier) module=\(picked.module.rawValue) available=\(SpeechTranscriber.isAvailable)")
        // The model the app uses, else the same language on `DictationTranscriber`. One the
        // keyboard can't get (released since Hex downloaded it, or a download that failed here)
        // is Hex's to download: the Hex key opens Hex until it installs.
        let started = Date()
        let language: SpeechLanguage
        do {
            // The keyboard's failures set nothing aside for Hex (`setsAside`): they are often
            // the keyboard's own reservation, not the language.
            language = try await AppleSpeechAssets.install(picked, settings: settings, setsAside: false, log: { log.write($0) })
        } catch {
            throw SpeechModelNeedsHex.keyboardError(for: error, language: picked.identifier, settings: settings)
        }
        if language != picked || Date().timeIntervalSince(started) > 0.5 {
            log.write("speech assets ready (\(language.module.rawValue) \(language.identifier)) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s \(KeyboardProbeLog.memory())")
        }
        let speech = AppleSpeechModule(language)

        // Experiments › Two-language dictation: the same recording read by a second installed
        // language too, merged word by word; the pipeline still runs as the primary language.
        let twoLanguage = TwoLanguageDictationSettings()
        if twoLanguage.isEnabled,
           let pair = await AppleSpeechTwoLanguage.usablePair(for: language) {
            let merged = await AppleSpeechTwoLanguage.transcribe(
                url,
                pair: pair,
                vocabulary: hints,
                lingeringModels: false,
                mode: DictationRecognitionModeSettings().mode
            )
            // Don't launch a single-language fallback after the user cancelled both readings.
            try Task.checkCancellation()
            if let merged {
                guard !merged.text.isEmpty else { throw Failure.empty }
                log.write("two-language \(pair.secondary.identifier(.bcp47)) won=\(merged.winner.rawValue) \(KeyboardProbeLog.memory())")
                return (merged.text, language)
            }
        }

        let analyzer = SpeechAnalyzer(
            modules: [speech.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let file = try AVAudioFile(forReading: url)
        // Learn how I type's meant words, best effort, as the app does for custom vocabulary.
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)
        }
        let text = try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            try Task.checkCancellation()
            log.write("analyzer started \(KeyboardProbeLog.memory())")
            return try await speech.finalText()
        } onCancel: {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        guard !text.isEmpty else { throw Failure.empty }
        return (text, language)
    }
}

final class KeyboardProbeLog: @unchecked Sendable {
    static let shared = KeyboardProbeLog()

    private let logger = Logger(subsystem: "anomaly.hex.mobile.keyboard", category: "capture-probe")
    private let lock = NSLock()
    private let url = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridge.appGroup)?
        .appendingPathComponent("keyboard-capture-probe.log")

    /// Past this size the log keeps only its newest `trimmedBytes`, so it never grows
    /// without limit in the App Group.
    static let maximumBytes: UInt64 = 512 * 1024
    static let trimmedBytes = 256 * 1024

    func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        guard let url else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                let size = handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
                if size + UInt64(line.utf8.count) > Self.maximumBytes {
                    Self.trim(url)
                }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Keeps the newest `trimmedBytes`, from the first whole line in them.
    static func trim(_ url: URL, keeping bytes: Int = trimmedBytes) {
        guard let data = try? Data(contentsOf: url), data.count > bytes else { return }
        var tail = data.suffix(bytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }

    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        // The highest footprint this keyboard process has reached, for what iOS's limit saw.
        let peak = result == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
        let available = Double(os_proc_available_memory()) / 1_048_576
        return String(format: "[footprint %.1f MB, peak %.1f MB, headroom %.1f MB]", footprint, peak, available)
    }
}
