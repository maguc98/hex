import Foundation

/// What the keyboard's capture page last said of its audio context and microphone track.
nonisolated struct KeyboardCapturePageState: Equatable, Sendable {
    var cause: String
    var context: String
    var muted: Bool
    var ended: Bool
    var at: TimeInterval

    var isInterrupted: Bool { context != "running" || muted || ended }

    var summary: String {
        "context \(context), track \(ended ? "ended" : muted ? "muted" : "live")"
    }
}

/// Tracks microphone progress while WebKit is interrupted, so a notification doesn't look like
/// the end of a dictation. The watchdog resumes counting from when the capture comes back.
nonisolated struct KeyboardCaptureWatch: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case interrupted
        case resumed(after: TimeInterval)
    }

    private(set) var lastAudio: TimeInterval
    private(set) var interruptedSince: TimeInterval?

    init(startedAt: TimeInterval) {
        lastAudio = startedAt
    }

    mutating func heardAudio(at time: TimeInterval) {
        lastAudio = max(lastAudio, time)
    }

    mutating func page(_ state: KeyboardCapturePageState, at time: TimeInterval) -> Change? {
        if state.isInterrupted {
            guard interruptedSince == nil else { return nil }
            interruptedSince = time
            return .interrupted
        }
        guard let since = interruptedSince else { return nil }
        interruptedSince = nil
        lastAudio = max(lastAudio, time)
        return .resumed(after: time - since)
    }

    func isStalled(now: TimeInterval) -> Bool {
        KeyboardJobWatchdog.isStalled(.recording, lastProgress: lastAudio, interruptedSince: interruptedSince, now: now)
    }
}
