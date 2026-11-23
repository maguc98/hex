import Foundation
import InputxCoreC

/// Offline Mandarin full-Pinyin session backed by Inputx's native Rust engine.
/// The keyboard owns one session for its lifetime; all calls are serialized
/// on the keyboard's main thread, matching UIInputViewController's event flow.
final class ChinesePinyinSession {
    private static let learningKey = "keyboard.pinyin.learning.v1"
    private let defaults = UserDefaults(suiteName: KeyboardBridge.appGroup)
    private var handle: OpaquePointer?

    var isAvailable: Bool { handle != nil }

    init() {
        guard let session = inputx_session_new() else {
            handle = nil
            return
        }
        handle = session
        // InputxEngineMode.pinyinOnly = 2; InputxInputMode.cjk = 0.
        _ = inputx_session_set_engine_mode(session, 2)
        _ = inputx_session_set_input_mode(session, 0)
        if let saved = defaults?.string(forKey: Self.learningKey) {
            saved.withCString { _ = inputx_session_import_l0_json(session, 1, $0) }
        }
    }

    deinit {
        if let handle {
            inputx_session_free(handle)
        }
    }

    var isComposing: Bool {
        guard let handle, let value = inputx_session_preedit(handle) else { return false }
        defer { inputx_string_free(value) }
        return !String(cString: value).isEmpty
    }

    var preedit: String {
        guard let handle, let value = inputx_session_preedit(handle) else { return "" }
        defer { inputx_string_free(value) }
        return String(cString: value)
    }

    var candidates: [String] {
        guard let handle else { return [] }
        let count = min(Int(inputx_session_candidate_count(handle)), 64)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let value = inputx_session_candidate(handle, UInt(index)) else { return nil }
            defer { inputx_string_free(value) }
            return String(cString: value)
        }
    }

    @discardableResult
    func insert(_ character: Character) -> Bool {
        guard let handle, let scalar = character.unicodeScalars.first else { return false }
        return inputx_session_key_event(handle, scalar.value, 0) != 0
    }

    @discardableResult
    func backspace() -> Bool {
        guard let handle else { return false }
        return inputx_session_key_event(handle, 0x08, 0) != 0
    }

    func commit(at index: Int) -> String? {
        guard let handle, index >= 0,
              let value = inputx_session_commit_index(handle, UInt(index)) else { return nil }
        defer { inputx_string_free(value) }
        let text = String(cString: value)
        persistLearning()
        return text
    }

    private func persistLearning() {
        guard let handle, let json = inputx_session_export_l0_json(handle, 1) else { return }
        defer { inputx_string_free(json) }
        defaults?.set(String(cString: json), forKey: Self.learningKey)
    }

    func commitFirst() -> String? {
        commit(at: 0)
    }

    func clear() {
        guard let handle else { return }
        inputx_session_clear(handle)
    }
}
