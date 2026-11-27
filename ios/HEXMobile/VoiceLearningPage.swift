import SwiftUI
import AVFoundation

/// A local voice profile made from user-confirmed recordings and their matching text.
/// The text is supplied to supported recognizers as contextual hints; the recordings
/// are retained locally and are not used to fine-tune or clone an acoustic model.
struct VoiceLearningPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var dictation: DictationController

    @AppStorage(AppVoiceProcessingSettings.enabledKey)
    private var noiseReductionEnabled = false

    @State private var phrases: [String]
    @State private var completedSteps: Set<Int>
    @State private var recorder: AVAudioRecorder?
    @State private var recordingStep: Int?
    @State private var pendingStep: Int?
    @State private var pendingAudioURL: URL?
    @State private var pendingDuration: TimeInterval = 0
    @State private var isRecording = false
    @State private var isRequestingPermission = false
    @State private var statusMessage: String?
    @State private var showingClearConfirmation = false
    @State private var isVisible = false
    @State private var sharedStorageDiagnostic = SpeechLearningStore().sharedStorageDiagnostic()

    private var store: SpeechLearningStore { SpeechLearningStore() }
    private let stepTitles = ["自然语速", "轻声说话", "稍快语速"]
    private let stepDetails = [
        "像平时聊天一样，自然地读出这句话。",
        "稍微放轻声音，保持清楚、自然，不需要刻意压低。",
        "比平时稍快一点，保持你日常说话的节奏。"
    ]

    init(dictation: DictationController) {
        self.dictation = dictation
        let language = dictation.transcriptionLanguageID
        let saved = SpeechLearningStore().samples()
        var initialPhrases = Self.defaultPhrases(for: language)
        var completed = Set<Int>()
        for step in 1...VoiceLearningProfile.stepCount {
            if let sample = saved.first(where: {
                $0.id == VoiceLearningProfile.sampleID(forStep: step, language: language)
            }) {
                initialPhrases[step - 1] = sample.text
                completed.insert(step)
            }
        }
        _phrases = State(initialValue: initialPhrases)
        _completedSteps = State(initialValue: completed)
    }

    var body: some View {
        SettingsPageScaffold(title: "声音学习") {
            heroCard
            progressCard

            ForEach(1...VoiceLearningProfile.stepCount, id: \.self) { step in
                sampleCard(step: step)
            }

            noiseReductionCard
            privacyCard

            if !completedSteps.isEmpty {
                SettingsCard {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("清除声音学习档案")
                            Spacer()
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HexTheme.danger)
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusMessage.contains("失败") || statusMessage.contains("请") ? HexTheme.danger : HexTheme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear {
            isVisible = true
            sharedStorageDiagnostic = store.sharedStorageDiagnostic()
            if KeyboardBridge().noiseReductionEnabled {
                noiseReductionEnabled = true
            }
        }
        .onChange(of: noiseReductionEnabled) { _, enabled in
            KeyboardBridge().noiseReductionEnabled = enabled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                isVisible = false
                discardCurrentRecording()
            } else {
                isVisible = true
            }
        }
        .onDisappear {
            isVisible = false
            discardCurrentRecording()
        }
        .confirmationDialog(
            "清除声音学习档案？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部声音样本", role: .destructive) {
                clearProfile()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("三组录音及对应的个人识别提示都会从本机删除。")
        }
        .animation(HexMotion.settleAnimation(reduceMotion: reduceMotion), value: completedSteps.count)
    }

    private var heroCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(HexTheme.warmMic)
                        .frame(width: 50, height: 50)
                        .background(HexTheme.warmMic.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("让 HEX 更熟悉你的声音")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                        Text("建立本机声音档案")
                            .font(.system(size: 12))
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    Spacer(minLength: 0)
                }

                Text("跟着三个小练习录下你的日常发音。HEX 会保存声音样本，并把对应短句加入识别上下文，让支持上下文提示的识别引擎更熟悉你的常用表达。")
                    .font(.system(size: 12))
                    .foregroundStyle(HexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Label("仅保存在本机", systemImage: "iphone")
                    Text("·")
                    Text("约 1 分钟")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HexTheme.success)
            }
            .padding(16)
        }
    }

    private var progressCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("学习进度")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HexTheme.textBase)
                    Spacer()
                    Text("\(completedSteps.count)/\(VoiceLearningProfile.stepCount)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HexTheme.success)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(HexTheme.success)
                            .frame(width: geometry.size.width * CGFloat(completedSteps.count) / CGFloat(VoiceLearningProfile.stepCount))
                    }
                }
                .frame(height: 6)

                Text(completedSteps.count == VoiceLearningProfile.stepCount
                     ? "声音档案已建立。之后可以随时重新录制任意一组。"
                     : "完成三种说话方式，建立更完整的个人语音样本。")
                    .font(.system(size: 11))
                    .foregroundStyle(HexTheme.textMuted)
            }
            .padding(16)
        }
    }

    private func sampleCard(step: Int) -> some View {
        let index = step - 1
        let isThisRecording = recordingStep == step
        let isPending = pendingStep == step
        let isComplete = completedSteps.contains(step)

        return SettingsCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(isComplete ? HexTheme.success.opacity(0.14) : Color.white.opacity(0.07))
                            .frame(width: 30, height: 30)
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(HexTheme.success)
                        } else {
                            Text("\(step)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(HexTheme.textMuted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stepTitles[index])
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                        Text(stepDetails[index])
                            .font(.system(size: 11))
                            .foregroundStyle(HexTheme.textMuted)
                    }
                    Spacer(minLength: 0)
                    if isComplete {
                        Text("已学习")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HexTheme.success)
                    }
                }

                TextField("输入一句你常说的话（建议 2–64 个字符）", text: $phrases[index], axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(HexTheme.textBase)
                    .lineLimit(2...4)
                    .padding(11)
                    .background(HexTheme.bgDeep, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .disabled(isRecording || isPending)

                if isThisRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(HexTheme.danger)
                            .frame(width: 7, height: 7)
                        Text("正在录音，请按上面的提示自然说话")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HexTheme.danger)
                        Spacer()
                        Button("结束") { stopRecording() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HexTheme.danger)
                    }
                } else if isPending {
                    HStack(spacing: 10) {
                        Label("录音完成 · \(String(format: "%.1f", pendingDuration)) 秒", systemImage: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(HexTheme.success)
                        Spacer(minLength: 4)
                        Button("重录") { discardPendingRecording() }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HexTheme.textMuted)
                        Button("保存样本") { savePendingSample() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HexTheme.success)
                    }
                } else {
                    Button {
                        startRecording(step: step)
                    } label: {
                        Label(isComplete ? "重新录制" : "开始录音", systemImage: isComplete ? "arrow.clockwise" : "mic.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRecording || isRequestingPermission || isPending || phrases[index].trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    .opacity(isRecording || isRequestingPermission || isPending || phrases[index].trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? 0.45 : 1)
                }
            }
            .padding(14)
        }
    }

    private var noiseReductionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 11) {
                Toggle(isOn: $noiseReductionEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("嘈杂环境增强")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HexTheme.textBase)
                        Text("开启 iOS 语音处理模式，帮助抑制部分环境噪声。")
                            .font(.system(size: 11))
                            .foregroundStyle(HexTheme.textMuted)
                    }
                }
                .tint(HexTheme.success)

                Text("此设置应用于 HEX App 内后续录音；如果 App Group 共享权限可用，也会同步到键盘的「降噪」设置。实际效果会受麦克风、距离和环境影响。")
                    .font(.system(size: 11))
                    .foregroundStyle(HexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
        }
    }

    private var privacyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("隐私与识别方式", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HexTheme.textBase)
                Text("录音和对应文字保存在本机。Apple Speech 会参考保存的短句作为识别上下文；Parakeet 等不支持上下文提示的引擎不会因此改变模型。当前版本不会用这些录音微调声学模型，也不会克隆你的声音。")
                    .font(.system(size: 11))
                    .foregroundStyle(HexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(sharedStorageDiagnostic == "共享空间可读写"
                     ? "App Group 共享空间可读写，键盘也可以读取这些学习记录。"
                     : "当前 App Group 不可用：声音样本仍保存在 HEX App 本机，并可用于 App 内的识别提示；键盘端暂时无法同步这些记录。")
                    .font(.system(size: 11))
                    .foregroundStyle(sharedStorageDiagnostic == "共享空间可读写" ? HexTheme.textMuted : HexTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Text("开启嘈杂环境增强后，HEX 会在录音时使用 iOS 的 voiceChat 语音处理模式；这不是保证完全消除噪声的独立 AI 分离模型。")
                    .font(.system(size: 11))
                    .foregroundStyle(HexTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
        }
    }

    private func startRecording(step: Int) {
        guard isVisible, !isRecording, !isRequestingPermission else { return }
        guard !dictation.phase.isBusy, dictation.phase != .recording else {
            statusMessage = "请先结束当前听写，再录制声音样本。"
            return
        }
        discardPendingRecording()
        statusMessage = nil
        isRequestingPermission = true

        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { granted in
            DispatchQueue.main.async {
                isRequestingPermission = false
                guard granted else {
                    statusMessage = "没有麦克风权限，请在系统设置中允许 HEX 使用麦克风。"
                    return
                }
                guard isVisible else { return }

                do {
                    if dictation.keyboardSessionEnabled {
                        dictation.endWarmSession()
                    }
                    let mode: AVAudioSession.Mode = noiseReductionEnabled ? .voiceChat : .measurement
                    try session.setCategory(
                        .playAndRecord,
                        mode: mode,
                        options: [.defaultToSpeaker, .allowBluetooth]
                    )
                    try session.setActive(true)

                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("HexVoiceProfile-\(UUID().uuidString).m4a")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                    let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
                    audioRecorder.prepareToRecord()
                    guard audioRecorder.record() else {
                        statusMessage = "录音启动失败，请重试。"
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    recorder = audioRecorder
                    recordingStep = step
                    isRecording = true
                } catch {
                    statusMessage = "无法开始录音：\(error.localizedDescription)"
                }
            }
        }
    }

    private func stopRecording() {
        guard let activeRecorder = recorder, let step = recordingStep else { return }
        let duration = activeRecorder.currentTime
        let url = activeRecorder.url
        activeRecorder.stop()
        recorder = nil
        recordingStep = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard duration >= 0.8 else {
            try? FileManager.default.removeItem(at: url)
            statusMessage = "录音太短，请至少说一句完整的话。"
            return
        }
        pendingAudioURL = url
        pendingDuration = duration
        pendingStep = step
    }

    private func savePendingSample() {
        guard let url = pendingAudioURL,
              let step = pendingStep,
              (1...VoiceLearningProfile.stepCount).contains(step) else { return }
        let text = phrases[step - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...SpeechLearningStore.maximumHintLength).contains(text.count) else {
            statusMessage = "短句请控制在 2–64 个字符。"
            return
        }

        let saved = store.saveManualAudioSample(
            id: VoiceLearningProfile.sampleID(forStep: step, language: dictation.transcriptionLanguageID),
            text: text,
            audioURL: url,
            language: dictation.transcriptionLanguageID,
            duration: pendingDuration
        )
        guard saved else {
            statusMessage = "保存失败，请检查录音文件后重试。"
            return
        }

        try? FileManager.default.removeItem(at: url)
        pendingAudioURL = nil
        pendingStep = nil
        pendingDuration = 0
        completedSteps.insert(step)
        sharedStorageDiagnostic = store.sharedStorageDiagnostic()
        statusMessage = "声音样本已保存，短句已加入个人识别提示。"
    }

    private func discardPendingRecording() {
        if let pendingAudioURL {
            try? FileManager.default.removeItem(at: pendingAudioURL)
        }
        pendingAudioURL = nil
        pendingStep = nil
        pendingDuration = 0
    }

    private func discardCurrentRecording() {
        if let recorder {
            let url = recorder.url
            recorder.stop()
            self.recorder = nil
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        recordingStep = nil
        discardPendingRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clearProfile() {
        discardCurrentRecording()
        for sample in store.samples() where VoiceLearningProfile.isVoiceSample(sample) {
            _ = store.deleteSample(id: sample.id)
        }
        completedSteps.removeAll()
        statusMessage = "声音学习档案已清除。"
        phrases = Self.defaultPhrases(for: dictation.transcriptionLanguageID)
    }

    private static func defaultPhrases(for language: String) -> [String] {
        if language.lowercased().hasPrefix("zh") {
            return [
                "你好，这是我平时自然说话的声音。",
                "请用轻一点的声音说话，也要保持清楚自然。",
                "我现在稍微加快语速，像平时聊天一样表达。"
            ]
        }
        if language.lowercased().hasPrefix("en") {
            return [
                "Hello, this is my natural speaking voice.",
                "I am speaking softly, but clearly.",
                "I am speaking a little faster, as I do in everyday conversation."
            ]
        }
        return ["", "", ""]
    }
}
