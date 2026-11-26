import SwiftUI
import AVFoundation

/// A standalone library of user-confirmed speech-learning records.
struct SpeechLearningLibraryPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var records = SpeechLearningStore().samples()
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var deleteTarget: SpeechLearningSample?

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

            if records.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 30))
                            .foregroundStyle(HexTheme.textMuted)
                        Text("No learning records yet")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(HexTheme.textBase)
                        Text("After dictation, save a sentence to Learning. Your original sentence, translation and short audio recording will appear here.")
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    .padding(22)
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
        .confirmationDialog("Delete this learning record?", item: $deleteTarget, titleVisibility: .visible) { sample in
            Button("Delete", role: .destructive) {
                _ = store.deleteSample(id: sample.id)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { sample in
            Text("The sentence and its audio recording will be removed.")
        }
        .animation(HexMotion.settleAnimation(reduceMotion: reduceMotion), value: records.count)
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
