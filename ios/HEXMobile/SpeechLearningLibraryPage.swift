import SwiftUI
import AVFoundation

/// 本机保存的语音句子学习记录。
struct SpeechLearningLibraryPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var records = SpeechLearningStore().samples()
    @State private var player: AVAudioPlayer?
    @State private var playingID: String?
    @State private var deleteTarget: SpeechLearningSample?
    @State private var showingDeleteConfirmation = false

    private var store: SpeechLearningStore { SpeechLearningStore() }

    var body: some View {
        SettingsPageScaffold(title: "学习") {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(HexTheme.success)
                        .frame(width: 48, height: 48)
                        .background(HexTheme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("句子学习")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                        Text("已保存 \(records.count) 条 · 最多保存 12 条")
                            .font(.system(size: 12))
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    Spacer()
                }
                .padding(16)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("使用方法")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HexTheme.textBase)
                    learningStep(number: "1", title: "完成语音听写", detail: "在 Hex 中说出一句话，等待文字和翻译结果出现。")
                    learningStep(number: "2", title: "检查识别和翻译", detail: "确认原句及译文正确后，再保存到学习库。")
                    learningStep(number: "3", title: "点击「加入学习」", detail: "按钮就在听写结果卡片下方，不需要跳转页面。")
                    learningStep(number: "4", title: "在这里复习", detail: "保存后可查看原句、译文，并播放当时的录音。")
                    Text("在其他 App 使用 Hex 键盘听写时，也可以点击键盘顶部的「学习」按钮保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(HexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(16)
            }

            if records.isEmpty {
                SettingsCard {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 28))
                            .foregroundStyle(HexTheme.textMuted)
                        Text("还没有学习记录")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(HexTheme.textBase)
                        Text("完成听写并确认译文后，点击结果下方的「加入学习」，这句话就会保存在这里。")
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(HexTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
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
                    Text("学习记录保存在本机，并由 Hex 和 Hex 键盘共享。只有你主动加入学习的句子才会长期保存录音。")
                        .font(.system(size: 12))
                        .foregroundStyle(HexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("删除这条学习记录？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let sample = deleteTarget {
                    if playingID == sample.id {
                        player?.stop()
                        player = nil
                        playingID = nil
                    }
                    _ = store.deleteSample(id: sample.id)
                    reload()
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("这句话及其录音都会被删除，且无法恢复。")
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
                    Text(languageName(sample.language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HexTheme.textMuted)
                    Spacer()
                    Text(formattedDate(sample.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(HexTheme.textMuted)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("原句")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HexTheme.textMuted)
                    Text(sample.text)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(HexTheme.textBase)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let translation = sample.translatedText, !translation.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("译文")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HexTheme.textMuted)
                        Text(translation)
                            .font(.system(size: 14))
                            .foregroundStyle(HexTheme.textBase)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let heard = sample.heard, heard != sample.text, !heard.isEmpty {
                    Text("识别结果：\(heard)")
                        .font(.system(size: 12))
                        .foregroundStyle(HexTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if store.audioURL(for: sample) != nil {
                        Button {
                            play(sample)
                        } label: {
                            Label(
                                playingID == sample.id ? "暂停播放" : "播放录音",
                                systemImage: playingID == sample.id ? "pause.fill" : "play.fill"
                            )
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("录音文件不可用", systemImage: "waveform.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(HexTheme.textMuted)
                    }

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
                    .accessibilityLabel("删除记录")
                }
            }
            .padding(16)
        }
    }

    private func languageName(_ identifier: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forIdentifier: identifier) ?? identifier
    }

    private func formattedDate(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
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
        guard let url = store.audioURL(for: sample),
              let audio = try? AVAudioPlayer(contentsOf: url) else { return }
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
