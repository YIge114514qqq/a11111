import Foundation
import AVFoundation
import Speech
import Combine

/// 音频层：只跑在音频线程上，不碰界面状态。
/// 识别请求和录音文件都由它持有，避免音频回调里访问主线程属性。
final class AudioPump {
    let engine = AVAudioEngine()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var audioFile: AVAudioFile?
    private(set) var tapInstalled = false

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        try? audioFile?.write(from: buffer)
    }

    /// 先按 inputFormat 建好录音文件，再启动引擎，
    /// 这样音频线程一开始跑就已经可写。
    func prepareRecording(to url: URL, using format: AVAudioFormat) throws {
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func start() throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LiveSessionError.audioUnavailable
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        request?.endAudio()
        request = nil
        // 先停引擎和 tap，确认音频线程不再回调，再释放录音文件
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioFile = nil
    }
}

enum LiveSessionError: LocalizedError {
    case audioUnavailable
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            return "麦克风拿不到音频，可能被其它 App 占用，先关掉再试。"
        case .recordingUnavailable:
            return "录音文件创建失败，字幕仍可正常使用。"
        }
    }
}
/// 一节课的实时流程：
/// 麦克风 -> 语音识别（设备端优先）-> 断句 -> 批量翻译 -> 双语字幕
/// 同时把音频录成本地 m4a，课后可以回听。
@MainActor
final class LiveSession: NSObject, ObservableObject {

    @Published var lines: [CaptionLine] = []
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var isTranslating = false
    @Published var translationError: String?

    private let pump = AudioPump()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    private var sourceLanguage = "en-US"
    private var targetLanguage = "zh-CN"
    /// 开始时固定下来的翻译配置，中途改设置不影响正在进行的这节课
    private var translator: AIService?
    private var targetTitle = "简体中文"
    private var startedAt: Date?
    private var audioFileName: String?

    private var ticker: Timer?
    private var restartTimer: Timer?

    /// 每次重开识别请求 +1，用来丢弃旧请求迟到的回调
    private var generation = 0
    private var committedInRequest = 0
    private var currentRequestText = ""

    private var pendingIDs: [UUID] = []
    private var translateLoop: Task<Void, Never>?
    private var idleTicks = 0

    override init() { super.init() }

    // MARK: - 权限

    static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        return (mic, speechStatus == .authorized)
    }

    // MARK: - 开始 / 结束

    func start(settings: AppSettings) async {
        guard !isRecording else { return }
        lines = []
        errorMessage = nil
        translationError = nil
        elapsed = 0
        pendingIDs = []
        idleTicks = 0
        sourceLanguage = settings.sourceLanguage
        targetLanguage = settings.targetLanguage
        translator = AIService(settings: settings)
        targetTitle = settings.targetTitle

        let permissions = await Self.requestPermissions()
        guard permissions.mic else {
            errorMessage = "没有麦克风权限，请到 iPad 的设置里给 LectureBuddy 打开麦克风。"
            return
        }
        guard permissions.speech else {
            errorMessage = "没有语音识别权限，请到 iPad 的设置里给 LectureBuddy 打开语音识别。"
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: sourceLanguage)) else {
            errorMessage = "这台设备不支持这个语言的语音识别，换一种授课语言试试。"
            return
        }
        recognizer.delegate = self
        guard recognizer.isAvailable else {
            errorMessage = "语音识别暂时不可用，检查网络或稍后重试。"
            return
        }
        self.recognizer = recognizer

        // 必须先激活音频会话，inputNode 才会给出有效格式
        do {
            try configureAudioSession()
        } catch {
            errorMessage = "音频会话启动失败：\(error.localizedDescription)"
            return
        }

        let format = pump.inputFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = LiveSessionError.audioUnavailable.errorDescription
            return
        }

        // 录音失败不影响字幕，只是没法回听。
        // 开关关掉就真的不建文件：以前这个开关只存不读，关了也照录。
        audioFileName = nil
        if settings.recordAudio {
            let name = "lesson-\(Int(Date().timeIntervalSince1970)).m4a"
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
            do {
                try pump.prepareRecording(to: url, using: format)
                audioFileName = name
            } catch {
                audioFileName = nil
                errorMessage = LiveSessionError.recordingUnavailable.errorDescription
            }
        }

        do {
            try pump.start()
        } catch {
            pump.stop()
            audioFileName = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "启动录音失败：\(error.localizedDescription)"
            return
        }

        isRecording = true
        startedAt = Date()

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        // 单条识别请求有时长上限，定时重开，音频流不中断
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restartRecognition() }
        }

        beginRecognition()
    }

    func stop() -> Lesson {
        let lessonElapsed = elapsed
        let captured = lines
        stopEverything()
        return Lesson(
            title: Self.defaultTitle(),
            createdAt: Date(),
            duration: lessonElapsed,
            lines: captured,
            notes: nil,
            audioFileName: audioFileName,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm 的课"
        return formatter.string(from: Date())
    }

    private func stopEverything() {
        isRecording = false
        generation += 1
        ticker?.invalidate()
        ticker = nil
        restartTimer?.invalidate()
        restartTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        pump.stop()
        translateLoop?.cancel()
        translateLoop = nil
        pendingIDs.removeAll()
        isTranslating = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])
    }
    // MARK: - 识别

    private func beginRecognition() {
        guard let recognizer, isRecording else { return }
        generation += 1
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // 课堂内容尽量不离开设备
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        pump.request = request
        currentRequestText = ""
        committedInRequest = 0

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRecording, gen == self.generation else { return }
                if let result {
                    self.handle(result)
                }
                if error != nil {
                    // 多半是超时或被系统取消，等一下再重开，避免忙循环
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard self.isRecording, gen == self.generation else { return }
                    self.restartRecognition()
                }
            }
        }
    }

    private func restartRecognition() {
        guard isRecording else { return }
        commitRemainder()
        pump.request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        pump.request = nil
        beginRecognition()
    }

    private func handle(_ result: SFSpeechRecognitionResult) {
        errorMessage = nil
        currentRequestText = result.bestTranscription.formattedString
        let sentences = Self.splitSentences(currentRequestText).sentences
        while committedInRequest < sentences.count {
            append(sentences[committedInRequest])
            committedInRequest += 1
        }
        if result.isFinal { commitRemainder() }
    }

    private func commitRemainder() {
        let (sentences, rest) = Self.splitSentences(currentRequestText)
        while committedInRequest < sentences.count {
            append(sentences[committedInRequest])
            committedInRequest += 1
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 2 { append(trimmed) }
        currentRequestText = ""
        committedInRequest = 0
    }

    /// 按中英文句末标点切句，末尾没说完的部分留着继续等
    static func splitSentences(_ text: String) -> (sentences: [String], rest: String) {
        var sentences: [String] = []
        var buffer = ""
        for character in text {
            buffer.append(character)
            if ".!?。！？".contains(character) {
                let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count > 1 { sentences.append(sentence) }
                buffer = ""
            }
        }
        return (sentences, buffer)
    }

    private func append(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1 else { return }
        if lines.last?.text == clean { return }
        let line = CaptionLine(
            text: clean,
            translation: nil,
            offset: Date().timeIntervalSince(startedAt ?? Date())
        )
        lines.append(line)
        pendingIDs.append(line.id)
        startTranslatingIfNeeded()
    }

    // MARK: - 翻译

    private func startTranslatingIfNeeded() {
        guard translateLoop == nil, let service = translator else { return }
        let target = targetTitle

        translateLoop = Task { [weak self] in
            // 先等一会儿，攒几句一起翻：省调用次数，句子之间也更连贯
            try? await Task.sleep(nanoseconds: 900_000_000)
            while true {
                guard let self, !Task.isCancelled else { return }
                if self.pendingIDs.isEmpty {
                    self.isTranslating = false
                    self.idleTicks += 1
                    if self.idleTicks > 20 {
                        self.translateLoop = nil
                        return
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                self.idleTicks = 0

                let ids = Array(self.pendingIDs.prefix(6))
                self.pendingIDs.removeFirst(ids.count)
                let batch = self.lines.filter { ids.contains($0.id) }
                guard !batch.isEmpty else { continue }

                self.isTranslating = true
                do {
                    let translated = try await service.translate(lines: batch.map(\.text), target: target)
                    guard !Task.isCancelled else { return }
                    for (index, line) in batch.enumerated() where index < translated.count {
                        if let i = self.lines.firstIndex(where: { $0.id == line.id }) {
                            self.lines[i].translation = translated[index]
                        }
                    }
                    self.translationError = nil
                } catch {
                    self.translationError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - 导出

    func transcriptForClipboard() -> String {
        lines.map { line in
            if let t = line.translation, !t.isEmpty {
                return "\(line.text)\n\(t)"
            }
            return line.text
        }.joined(separator: "\n\n")
    }
}

extension LiveSession: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            if !available && self.isRecording {
                self.errorMessage = "语音识别暂时不可用，稍后会自动重试。"
            }
        }
    }
}