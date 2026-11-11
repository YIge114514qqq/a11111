import Foundation
import AVFoundation
import Combine

/// 阿里云 Qwen-LiveTranslate 端到端实时语音翻译（iPad / iPhone）。
///
/// 一条音频流同时拿回两样东西：
///   conversation.item.input_audio_transcription.*  → 老师原话（韩语等）
///   response.text.*                                → 中文译文
///
/// 所以字幕能做成「原文 + 译文」双语，而且不用再调一次大模型，
/// 说完一句话基本同一时刻两边都出来（实测 0.1–0.2 秒）。
@MainActor
final class LiveTranslateSession: ObservableObject {

    @Published var isRecording = false
    @Published var lines: [CaptionLine] = []
    @Published var errorMessage: String?
    @Published var elapsed: TimeInterval = 0
    /// 停止后能拿到的录音文件名（WAV）
    @Published var savedAudioName: String?
    struct Completion {
        let id: UUID
        let lines: [CaptionLine]
        let duration: TimeInterval
        let audioFileName: String?
    }
    @Published private(set) var completion: Completion?
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    private var sessionID = UUID()
    /// 电话/其他 App 抢走音频时也要收尾保存，否则整节课会静默中断
    private var interruptionObserver: NSObjectProtocol?

    private var socket: URLSessionWebSocketTask?
    private var capture: AudioCapture?
    private var ticker: Timer?
    private var startedAt = Date()
    private var eventSeq = 0
    /// WebSocket 是否真的连通了。Android 那边踩过同样的坑：
    /// socket.resume() 只是开始握手，立刻发 session.update / 音频会被丢掉。
    private var isOpen = false
    /// 没连通前先缓存的音频块，连通后再补发
    private var pendingChunks: [Data] = []
    private let maxPending = 200
    /// 等合帧后再发的小块（降低每帧开销）
    private var outBuffer: [Data] = []
    private var flushTask: Task<Void, Never>?
    private var audioFramesSent = 0
    /// 服务端在关闭连接前发回的原始错误（如鉴权失败），报真正原因而不是笼统的「连接断开」
    private var lastErrorBody = ""
    /// 给人看的当前进度：出问题时能直接看出卡在哪一步
    @Published var status = ""
    /// 本次已采集到的音频字节数（自检用：为 0 就说明麦克风根本没出声）
    @Published var audioBytes = 0

    // 当前这句话的原文 / 译文
    private var curSource = ""
    private var curTranslation = ""
    private var liveID: UUID?

    private let defaults = UserDefaults.standard

    // MARK: - 对外接口

    func start() async {
        guard !isRecording, !isStarting, !isStopping else { return }
        isStarting = true
        let id = UUID()
        sessionID = id
        defer { if sessionID == id { isStarting = false } }
        errorMessage = nil

        let settings = AppSettings.shared
        guard !settings.dashscopeKey.isEmpty, !settings.dashscopeURL.isEmpty else {
            errorMessage = "请先在设置里填写 DashScope Key 和业务空间地址"
            return
        }

        // 1. 麦克风权限
        let granted = await requestMic()
        guard sessionID == id, isStarting else { return }
        guard granted else {
            errorMessage = "没有麦克风权限，去「设置 → LectureBuddy」里打开"
            return
        }

        // 2. 建立 WebSocket
        guard let url = buildURL(settings) else {
            errorMessage = "业务空间地址格式不对，要类似 https://dashscope.aliyuncs.com/api/v1"
            return
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(settings.dashscopeKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        socket = task

        lines = []
        curSource = ""
        curTranslation = ""
        liveID = nil
        savedAudioName = nil
        lastErrorBody = ""
        startedAt = Date()
        elapsed = 0
        isOpen = false
        pendingChunks.removeAll()
        outBuffer.removeAll()
        flushTask?.cancel()
        flushTask = nil
        audioFramesSent = 0
        isRecording = true
        audioBytes = 0
        status = "正在连接服务器…"
        startTicker()

        // 顺序很重要：先发 connect，等 receiveLoop 拿到第一帧（握手完成）再发 session.update。
        // 以前 resume() 后立刻发，握手还没完成，配置和开头几百毫秒音频全被丢掉了。
        task.resume()
        receiveLoop(task)
        startCapture()
        observeInterruptions()
    }

    /// 电话、闹钟或别的 App 抢走音频时，麦克风会被系统停掉但 WebSocket 还开着，
    /// 看起来像「录音中」，其实再也没有字幕。收到中断就立刻收尾并保存。
    private func observeInterruptions() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.errorMessage = "音频被电话或其它 App 打断，已自动结束并保存这节课。"
                    self.stop()
                }
            }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }

    /// 用户手动清掉错误提示
    func clearError() {
        errorMessage = nil
    }

    /// 实时翻译模式的转写文本。以前复制按钮一律读 session 的，
    /// 但走 DashScope 时字幕在 live.lines 里，复制出来是空的。
    func transcriptForClipboard() -> String {
        lines.map { line in
            if let t = line.translation, !t.isEmpty {
                return line.text == t ? t : "\(line.text)\n\(t)"
            }
            return line.text
        }.joined(separator: "\n\n")
    }

    /// 关掉录音。故意不用 `guard isRecording else { return }`：
    /// start() 中途失败时 isRecording 已经置 true，这个 guard 会让 UI 卡在录音态；
    /// 而且错误分支调用 stop() 会直接把已录到的字幕丢掉。
    func stop() {
        if isStarting && !isRecording {
            // 还在连服务器/等权限时被取消：没有音频也没有字幕，
            // 但要保证把已经建好的 socket / capture 拆干净，否则下一节会撞车。
            isStarting = false
            capture?.stop()
            capture = nil
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            isOpen = false
            pendingChunks.removeAll()
            status = ""
            removeInterruptionObserver()
            sessionID = UUID()
            return
        }
        guard !isStopping, isRecording || capture != nil || socket != nil else { return }
        isStopping = true
        isRecording = false
        elapsed = Date().timeIntervalSince(startedAt)
        ticker?.invalidate()
        ticker = nil
        capture?.stop()
        savedAudioName = capture?.fileName
        capture = nil
        let id = sessionID
        // 先把合并缓冲里剩下的音频发出去，再结束，否则最后几十毫秒会被丢掉
        flushAudio()
        if isOpen { send(#"{"event_id":"\#(nextID())","type":"session.finish"}"#) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.completeSession(id)
        }
    }

    private func completeSession(_ id: UUID) {
        guard sessionID == id, isStopping else { return }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isOpen = false
        pendingChunks.removeAll()
        status = ""
        removeInterruptionObserver()
        completion = Completion(id: id, lines: lines, duration: elapsed, audioFileName: savedAudioName)
        isStopping = false
        sessionID = UUID()
    }

    // MARK: - URL

    private func buildURL(_ settings: AppSettings) -> URL? {
        let model = settings.asrModel.isEmpty ? "qwen3.5-livetranslate-flash-realtime" : settings.asrModel
        var base = settings.dashscopeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/api/v1") { base = String(base.dropLast(7)) }
        base = base.replacingOccurrences(of: "https://", with: "wss://")
                   .replacingOccurrences(of: "http://", with: "ws://")
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        return URL(string: "\(base)/api-ws/v1/realtime?model=\(encoded)")
    }

    // MARK: - 会话配置

    private func sendSessionUpdate(_ settings: AppSettings) {
        let src = shortLang(settings.sourceLanguage)
        let dst = shortLang(settings.targetLanguage)
        let corpus = corpusFragment(settings)

        // 必须是紧凑单行 JSON：带换行缩进会让服务端校验失败，整个 session.update 被忽略
        var json = "{"
        json += "\"event_id\":\"\(nextID())\","
        json += "\"type\":\"session.update\","
        json += "\"session\":{"
        json += "\"modalities\":[\"text\"],"
        json += "\"input_audio_format\":\"pcm\","
        json += "\"sample_rate\":16000,"
        json += "\"input_audio_transcription\":{\"model\":\"qwen3-asr-flash-realtime\",\"language\":\"\(src)\"},"
        json += "\"translation\":{\"language\":\"\(dst)\"\(corpus)},"
        json += "\"turn_detection\":{\"type\":\"server_vad\",\"threshold\":0.0,\"silence_duration_ms\":800}"
        json += "}}"

        send(json)
    }

    /// 把术语表拼成 translation.corpus；没有就返回空串
    private func corpusFragment(_ settings: AppSettings) -> String {
        let raw = settings.termsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        var pairs: [String] = []
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("=") else { continue }
            let parts = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let k = escape(parts[0])
            let v = escape(parts[1])
            pairs.append("\"\(k)\":\"\(v)\"")
        }
        guard !pairs.isEmpty else { return "" }
        return ",\"corpus\":{\"phrases\":{\(pairs.joined(separator: ","))}}"
    }

    private func escape(_ s: String) -> String {
        // 手拼 JSON 就必须把控制字符也转义：术语表里粘进 tab/回车，
        // 不转义会让整个 session.update JSON 非法，服务端直接忽略配置，
        // 表现就是“连上了但什么都不翻译”。
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if let ascii = ch.asciiValue, ascii < 0x20 {
                    out += String(format: "\\u%04x", ascii)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    private func shortLang(_ tag: String) -> String {
        let head = tag.split(separator: "-").first.map(String.init) ?? tag
        return head.isEmpty ? "en" : head.lowercased()
    }

    // MARK: - 收发

    private func send(_ text: String) {
        socket?.send(.string(text)) { _ in }
    }

    private func sendAudio(_ data: Data) {
        // 还没连通就先存着，等 session.created 到了再补发（对齐 Android 的 pending 队列）
        guard isOpen else {
            pendingChunks.append(data)
            while pendingChunks.count > maxPending { pendingChunks.removeFirst() }
            return
        }
        // 两个 tap 回调（约 20-40ms 一块）合并成一帧再发，
        // 减少 JSON/base64 构造和主线程切换的次数，延迟反而更低。
        if outBuffer.isEmpty {
            scheduleFlush()
        }
        outBuffer.append(data)
        if outBuffer.count >= 3 { flushAudio() }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            // 40ms 一帧：足够快，又不会把每块都单独打包。
            try? await Task.sleep(nanoseconds: 40_000_000)
            self?.flushAudio()
        }
    }

    private func flushAudio() {
        flushTask?.cancel()
        flushTask = nil
        guard isOpen, !outBuffer.isEmpty else { return }
        var merged = Data()
        merged.reserveCapacity(outBuffer.reduce(0) { $0 + $1.count })
        for chunk in outBuffer { merged.append(chunk) }
        let count = outBuffer.count
        outBuffer.removeAll(keepingCapacity: true)
        let b64 = merged.base64EncodedString()
        send("{\"event_id\":\"\(nextID())\",\"type\":\"input_audio_buffer.append\",\"audio\":\"\(b64)\"}")
        audioFramesSent += count
    }

    /// 握手完成：发配置并补发缓冲音频
    private func onOpen() {
        guard !isOpen else { return }
        isOpen = true
        lastErrorBody = ""
        status = "已连上，等待识别…"
        let settings = AppSettings.shared
        sendSessionUpdate(settings)
        let queued = pendingChunks
        pendingChunks.removeAll()
        for chunk in queued { sendAudio(chunk) }
        if isStopping { send(#"{"event_id":"\#(nextID())","type":"session.finish"}"#) }
    }

    /// 用 async 循环收消息：比递归 receive 更稳，也不会堆栈溢出
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        let id = sessionID
        // 停止时继续收尾帧；完成或超时后由会话 ID 隔离旧回调。
        Task { [self] in
            while true {
                guard self.sessionID == id, self.isRecording || self.isStopping else { return }

                do {
                    let message = try await task.receive()
                    guard self.sessionID == id else { return }
                    switch message {
                    case .string(let text):
                        // 收到第一帧就说明握手已完成
                        let opened = self.isOpen
                        if !opened { self.onOpen() }
                        self.handle(text)
                    case .data(let raw):
                        let opened2 = self.isOpen
                        if !opened2 { self.onOpen() }
                        if let text = String(data: raw, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        break
                    }
                } catch {
                    guard self.sessionID == id else { return }
                    if self.isStopping { self.completeSession(id); return }
                    if self.isRecording {
                        let detail = self.lastErrorBody
                        self.errorMessage = detail.isEmpty
                            ? "连接断开：\(error.localizedDescription)"
                            : detail
                        self.stop()
                    }
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // 鉴权/权限错误不带 type，直接是 {"code":...,"message":...}
        guard let type = obj["type"] as? String else {
            let code = obj["code"] as? String ?? ""
            let msg = obj["message"] as? String ?? ""
            if !code.isEmpty || !msg.isEmpty {
                lastErrorBody = friendly(code, msg)
                errorMessage = lastErrorBody
                stop()
            }
            return
        }

        switch type {
        case "session.created", "session.updated":
            // session.updated 到了说明配置真的生效了（紧凑单行 JSON 才不会被忽略）
            status = "已就绪，正在听…"

        case "input_audio_buffer.speech_started":
            curSource = ""
            curTranslation = ""

        case "response.text.text":
            let confirmed = obj["text"] as? String ?? ""
            let stash = obj["stash"] as? String ?? ""
            curTranslation = (confirmed + stash).trimmingCharacters(in: .whitespaces)
            if !curTranslation.isEmpty { upsert(final: false) }

        case "response.text.done":
            let done = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !done.isEmpty { curTranslation = done }
            // 等原文追上来再定稿，避免两者错配
            let id = sessionID
            let captionID = liveID
            Task { @MainActor in
                var waited = 0
                // 最多等 1.5 秒；若这期间已经 stop()，就直接放弃，
                // 否则会往已经清空的字幕里写孤行。
                while waited < 15 && self.curSource.isEmpty && self.sessionID == id && self.liveID == captionID {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                guard self.sessionID == id, self.liveID == captionID, self.isRecording || self.isStopping else { return }
                if !self.curTranslation.isEmpty { self.upsert(final: true) }
            }

        case "conversation.item.input_audio_transcription.text":
            let confirmed = obj["text"] as? String ?? ""
            let stash = obj["stash"] as? String ?? ""
            curSource = (confirmed + stash).trimmingCharacters(in: .whitespaces)
            if !curSource.isEmpty { upsert(final: false) }

        case "conversation.item.input_audio_transcription.completed":
            let t = (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                curSource = t
                upsert(final: false)
            }

        case "session.finished":
            if !isStopping { stop() }
            completeSession(sessionID)

        case "error":
            let err = obj["error"] as? [String: Any]
            let code = err?["code"] as? String ?? ""
            let msg = err?["message"] as? String ?? "语音翻译报错"
            lastErrorBody = friendly(code, msg)
            errorMessage = lastErrorBody
            stop()

        default:
            break
        }
    }

    // MARK: - 字幕落地

    private func upsert(final: Bool) {
        let src = curSource.trimmingCharacters(in: .whitespaces)
        let dst = curTranslation.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty || !dst.isEmpty else { return }

        let offset = Date().timeIntervalSince(startedAt)
        let text = src.isEmpty ? dst : src

        if let id = liveID, let idx = lines.firstIndex(where: { $0.id == id }) {
            lines[idx].text = text
            lines[idx].translation = dst.isEmpty ? nil : dst
        } else {
            var line = CaptionLine(text: text, translation: dst.isEmpty ? nil : dst)
            line.offset = offset
            lines.append(line)
            liveID = line.id
        }

        if final {
            liveID = nil
        }
    }

    private func friendly(_ code: String, _ message: String) -> String {
        let model = AppSettings.shared.asrModel
        if code.contains("Unpurchased") || code.contains("AccessDenied") {
            return "这个业务空间没开通语音翻译模型「\(model)」，请到百炼控制台开通后再试"
        }
        if code.contains("InvalidApiKey") || code.contains("Unauthorized") {
            return "API Key 无效或与业务空间地址不匹配"
        }
        return message.isEmpty ? "语音翻译服务报错（\(code)）" : message
    }

    // MARK: - 计时

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    private func nextID() -> String {
        eventSeq += 1
        return "event_\(eventSeq)_\(UUID().uuidString.prefix(8))"
    }

    // MARK: - 麦克风

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    private func startCapture() {
        let id = sessionID
        let cap = AudioCapture { [weak self] chunk in
            guard let self else { return }
            // 音频回调在别的线程，转发回主线程发 WebSocket
            Task { @MainActor in
                if self.sessionID == id && self.isRecording {
                    self.audioBytes += chunk.count
                    self.sendAudio(chunk)
                }
            }
        }
        do {
            try cap.start()
            capture = cap
        } catch {
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            stop()
        }
    }
}

/// 采集 16k / 16bit / 单声道 PCM。
/// 同一路音频既送去识别，也顺手写成 WAV，所以复习时能回听，且不需要第二个麦克风。
final class AudioCapture {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let onChunk: (Data) -> Void
    /// 是否同时写 WAV。设置里「同时保存课堂录音」关掉时为 false，
    /// 只送识别不落盘，省存储。
    private let saveAudio: Bool

    /// 目标格式：16k / 单声道 / 16bit，阿里云要的就是这个
    private let targetFormat: AVAudioFormat?

    private var fileHandle: FileHandle?
    /// tap 是否已装上：start() 中途抛错时不会再被执行，若不记标记，下次 start 会重复 installTap 直接崩
    private var tapInstalled = false
    /// 本次采集是否开启了系统降噪（在 start() 里从设置读）
    private var noiseSuppression = false
    private(set) var fileName: String?
    private var dataBytes: UInt32 = 0
    /// 音频回调在后台线程，stop() 在主线程；写文件全部串行到这条队列，避免竞态
    private let writeQueue = DispatchQueue(label: "lecturebuddy.wav")

    init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
        self.saveAudio = AppSettings.shared.recordAudio
        // 不用 ! 强制解包：构造失败就让调用方报错，而不是崩溃
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)
    }

    func start() throws {
        guard let targetFormat else {
            throw NSError(domain: "LectureBuddy", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 16kHz 音频格式"])
        }

        // 1. 配置音频会话
        // 引擎是长期持有的实例，上一次 stop() 后它内部还挂着旧会话，
        // 直接 start 会打印「associating with audio session (0x0), error -10879」并且拿不到音频。
        // 先把它停干净，再激活会话，然后才取 inputNode 的格式。
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let session = AVAudioSession.sharedInstance()
        // mode 用 .measurement：关掉系统为“打电话/录音”做的音效处理，
        // 语音识别更准。之前用 .default，系统会给麦克风加自动增益和降噪，
        // 教室里的远场人声容易被压成忽大忽小，识别结果就抖。
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth])
        // 使用设备输入格式采集，再由 AVAudioConverter 转为 16k PCM。
        try session.setActive(true, options: [])

        // 系统级降噪：对远场（教授在前排、你在后排）效果最明显。
        // 只在用户开了开关时启用；不支持时静默跳过，不影响录音。
        self.noiseSuppression = AppSettings.shared.noiseSuppression
        if noiseSuppression, session.isInputAvailable {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                // 模拟器或不支持的设备会报错，忽略即可
            }
        }

        // 2. 开录音文件（关掉「保存录音」时跳过，不落盘）
        if saveAudio { openWav() }

        // 3. 按输入节点的输出格式安装 tap。
        let input = engine.inputNode
        // 会话激活后格式可能已变，这里再取一次，且以 outputFormat 为准
        let tapFormat = input.outputFormat(forBus: 0)

        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw NSError(domain: "LectureBuddy", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风不可用，检查是否有其他 App 在占用"])
        }

        // 转换器在 tap 回调外先建好，避免每帧重建
        converter = AVAudioConverter(from: tapFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // 启动失败要把 tap 拆干净，否则下一次点开始会因重复安装 tap 而崩溃
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            throw error
        }
    }

    func stop() {
        // removeTap 在没有 tap 时会抛异常，先判断
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // 等队列里排队的写入全部完成后，再回填 WAV 头，否则长度会少算
        writeQueue.sync { self.closeWav() }
    }

    // MARK: - 转换

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let targetFormat, let converted = convert(buffer, to: targetFormat) else { return }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let size = frames * bytesPerFrame
        guard let ptr = converted.int16ChannelData?[0] else { return }

        let data = Data(bytes: ptr, count: size)
        onChunk(data)
        if saveAudio {
            writeQueue.async { [weak self] in self?.writeWav(data) }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inFormat = buffer.format
        // 已经是目标格式，直接用
        if inFormat.sampleRate == target.sampleRate,
           inFormat.channelCount == target.channelCount,
           inFormat.commonFormat == .pcmFormatInt16 {
            return buffer
        }
        if converter == nil {
            converter = AVAudioConverter(from: inFormat, to: target)
        }
        guard let conv = converter else { return nil }

        let ratio = target.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        return out
    }

    // MARK: - WAV 直写

    private func openWav() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "lesson-\(UUID().uuidString).wav"
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // 先占 44 字节头，停止时回填
        handle.write(Data(repeating: 0, count: 44))
        fileHandle = handle
        fileName = name
        dataBytes = 0
    }

    private func writeWav(_ data: Data) {
        guard let handle = fileHandle else { return }
        handle.write(data)
        dataBytes &+= UInt32(data.count)
    }

    private func closeWav() {
        guard let handle = fileHandle else { return }
        defer {
            try? handle.close()
            fileHandle = nil
        }
        guard dataBytes > 0 else { return }

        var header = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }

        header.append(contentsOf: Array("RIFF".utf8))
        put32(36 + dataBytes)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)              // PCM
        put16(1)              // 单声道
        put32(16000)
        put32(16000 * 2)     // byte rate
        put16(2)              // block align
        put16(16)             // bits
        header.append(contentsOf: Array("data".utf8))
        put32(dataBytes)

        try? handle.seek(toOffset: 0)
        handle.write(header)
    }
}
