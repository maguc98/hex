import SwiftUI
import AVFoundation

/// A standalone library of user-confirmed speech-learning records.
struct SpeechLearningLibraryPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var records = SpeechLearningStore().samples()
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var deleteTarget: SpeechLearningSample?
    @State private var showingDeleteConfirmation = false

    private var store: SpeechLearningStore { SpeechLearningStore() }

    var body: some View {
        SettingsPageScaffold(title: "Learning") {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(HexTheme.success)
                        .frame(width: 48, height: 48)
                        .background(HexTheme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sentence learning")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                        Text("\(records.count) saved records · up to 12")
                            .font(.system(size: 12))
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    Spacer()
                }
                .padding(16)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("How to use")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HexTheme.textBase)
                    learningStep(number: "1", title: "Switch to Hex Keyboard", detail: "Return to any text field and select the Hex keyboard.")
                    learningStep(number: "2", title: "Dictate a sentence", detail: "Speak a sentence and finish dictation so the text is inserted.")
                    learningStep(number: "3", title: "Tap “学习”", detail: "Tap the “学习 ✨” chip in the keyboard's top row within about 45 seconds.")
                    learningStep(number: "4", title: "Come back here", detail: "The saved sentence, translation (if available), and audio will appear in this library.")
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("The Learn chip is temporary. If it disappears, dictate the sentence again.")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HexTheme.warning)
                }
                .padding(16)
            }

            if records.isEmpty {
                SettingsCard {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 26))
                            .foregroundStyle(HexTheme.textMuted)
                        Text("No learning records yet")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(HexTheme.textBase)
                        Text("Nothing is saved yet. Follow the steps above to add your first sentence.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(records) { record in
                    recordCard(record)
                }
            }

            SettingsCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(HexTheme.textMuted)
                    Text("Records are stored locally on this device and shared between Hex and Hex Keyboard. Audio is kept only for saved records.")
                        .font(.system(size: 12))
                        .foregroundStyle(HexTheme.textMuted)
                }
                .padding(16)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete this learning record?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let sample = deleteTarget {
                    _ = store.deleteSample(id: sample.id)
                    reload()
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("The sentence and its audio recording will be removed.")
        }
        .animation(HexMotion.settleAnimation(reduceMotion: reduceMotion), value: records.count)
    }

    private func learningStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HexTheme.accent)
                .frame(width: 24, height: 24)
                .background(HexTheme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(HexTheme.textBase)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(HexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recordCard(_ sample: SpeechLearningSample) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(sample.language.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(HexTheme.textMuted)
                    Spacer()
                    Text(Date(timeIntervalSince1970: sample.createdAt), style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(HexTheme.textMuted)
                }
                Text(sample.text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(HexTheme.textBase)
                    .fixedSize(horizontal: false, vertical: true)
                if let translation = sample.translatedText, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 14))
                        .foregroundStyle(HexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let heard = sample.heard, heard != sample.text, !heard.isEmpty {
                    Text("Recognized: \(heard)")
                        .font(.system(size: 12))
                        .foregroundStyle(HexTheme.textMuted)
                }
                HStack(spacing: 10) {
                    Button {
                        play(sample)
                    } label: {
                        Label(playingID == sample.id ? "Playing" : "Play audio", systemImage: playingID == sample.id ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(role: .destructive) {
                        deleteTarget = sample
                    showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(HexTheme.textMuted)
                            .frame(width: 36, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete record")
                }
            }
            .padding(16)
        }
    }

    private func reload() {
        records = store.samples()
    }

    private func play(_ sample: SpeechLearningSample) {
        if playingID == sample.id {
            player?.pause()
            playingID = nil
            return
        }
        guard let url = store.audioURL(for: sample), let audio = try? AVAudioPlayer(contentsOf: url) else { return }
        player = audio
        audio.play()
        playingID = sample.id
        audio.delegate = AudioPlaybackDelegate { [weak audio] in
            if audio === self.player { self.playingID = nil }
        }
    }
}

private final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
}
