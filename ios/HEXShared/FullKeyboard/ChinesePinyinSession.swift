import Foundation
import InputxCoreC

/// Offline Mandarin full-Pinyin session backed by Inputx's native Rust engine.
///
/// Inputx's Session is not thread-safe. The lock serializes every FFI call because
/// its cold-path warmup runs on a utility queue while normal typing stays on main.
final class ChinesePinyinSession: @unchecked Sendable {
    private static let learningKey = "keyboard.pinyin.learning.v1"
    private let defaults = UserDefaults(suiteName: KeyboardBridge.appGroup)
    private let sessionLock = NSRecursiveLock()
    /// The native session's first-key preparation can take about half a second. Keep that
    /// work off the keyboard's main thread, and let the view wait without blocking touches.
    private let warmupGroup = DispatchGroup()
    private var handle: OpaquePointer?
    private var pendingCommit = ""

    var isAvailable: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return handle != nil
    }

    init() {
        guard let session = inputx_session_new() else {
            handle = nil
            return
        }
        handle = session
        // InputxEngineMode.pinyinOnly = 2; InputxInputMode.cjk = 0.
        _ = inputx_session_set_engine_mode(session, 2)
        _ = inputx_session_set_input_mode(session, 0)
        // Hex owns candidate selection and commits through the suggestion strip.
        // Never let Inputx auto-commit internally: that would clear its preedit
        // before Swift receives the candidate/commit and can silently lose text.
        _ = inputx_session_set_auto_commit_policy(session, 0)
        if let saved = defaults?.string(forKey: Self.learningKey) {
            saved.withCString { _ = inputx_session_import_l0_json(session, 1, $0) }
        }

        // Inputx documents a ~500 ms cold path (dictionary/FST and Pinyin indexes).
        // Warm the same session before the first key; all FFI access is lock-serialized.
        warmupGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { warmupGroup.leave() }
            sessionLock.lock()
            defer { sessionLock.unlock() }
            guard let handle else { return }
            inputx_session_warmup(handle)
        }
    }

    /// True only when the shared session lock is no longer occupied by cold-path warmup.
    /// This check is intentionally nonblocking because callers run on the keyboard's main thread.
    var isWarmupComplete: Bool {
        warmupGroup.wait(timeout: .now()) == .success
    }

    /// Calls back off the main thread when the native session has finished warming.
    func whenWarmupCompletes(_ completion: @escaping @Sendable () -> Void) {
        guard !isWarmupComplete else {
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = warmupGroup.wait(timeout: .distantFuture)
            completion()
        }
    }

    deinit {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let handle {
            inputx_session_free(handle)
            self.handle = nil
        }
    }

    private func withSession<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let handle else { return fallback }
        return body(handle)
    }

    /// Inputx requires the host to drain a commit after each consumed key event.
    /// Auto-commit is disabled for this UI, but preserve any native commit just in case.
    private func drainPendingCommit(from session: OpaquePointer) {
        guard let value = inputx_session_take_commit(session) else { return }
        defer { inputx_string_free(value) }
        let text = String(cString: value)
        if !text.isEmpty { pendingCommit += text }
    }

    func takePendingCommit() -> String? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !pendingCommit.isEmpty else { return nil }
        let value = pendingCommit
        pendingCommit = ""
        return value
    }

    var isComposing: Bool {
        withSession(false) { session in
            guard let value = inputx_session_preedit(session) else { return false }
            defer { inputx_string_free(value) }
            return !String(cString: value).isEmpty
        }
    }

    var preedit: String {
        withSession("") { session in
            guard let value = inputx_session_preedit(session) else { return "" }
            defer { inputx_string_free(value) }
            return String(cString: value)
        }
    }

    var candidates: [String] {
        withSession([]) { session in
            let count = min(Int(inputx_session_candidate_count(session)), 2)
            guard count > 0 else { return [] }
            return (0..<count).compactMap { index in
                guard let value = inputx_session_candidate(session, UInt(index)) else { return nil }
                defer { inputx_string_free(value) }
                return String(cString: value)
            }
        }
    }

    @discardableResult
    func insert(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return withSession(false) { session in
            let consumed = inputx_session_key_event(session, scalar.value, 0) != 0
            if consumed { drainPendingCommit(from: session) }
            return consumed
        }
    }

    @discardableResult
    func backspace() -> Bool {
        withSession(false) { session in
            let consumed = inputx_session_key_event(session, 0x08, 0) != 0
            if consumed { drainPendingCommit(from: session) }
            return consumed
        }
    }

    func commit(at index: Int) -> String? {
        guard index >= 0 else { return nil }
        return withSession(nil) { session in
            guard let value = inputx_session_commit_index(session, UInt(index)) else { return nil }
            defer { inputx_string_free(value) }
            let text = String(cString: value)
            persistLearning(from: session)
            return text
        }
    }

    private func persistLearning(from session: OpaquePointer) {
        guard let json = inputx_session_export_l0_json(session, 1) else { return }
        defer { inputx_string_free(json) }
        defaults?.set(String(cString: json), forKey: Self.learningKey)
    }

    func commitFirst() -> String? {
        commit(at: 0)
    }

    func clear() {
        withSession(()) { session in
            inputx_session_clear(session)
            pendingCommit = ""
        }
    }
}
