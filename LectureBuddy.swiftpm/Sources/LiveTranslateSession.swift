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
    /// 服务端在关闭连接前发回的原始错误（如鉴权失败），报真正原因而不是笼统的「连接断开」
    private var lastErrorBody = ""
    /// 给人看的当前进度：出问题时能直接看出卡在哪一步
    @Published var status = ""

    // 当前这句话的原文 / 译文
    private var curSource = ""
    private var curTranslation = ""
    private var liveID: UUID?

    private let defaults = UserDefaults.standard

    // MARK: - 对外接口

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil

        let settings = AppSettings.shared
        guard !settings.dashscopeKey.isEmpty, !settings.dashscopeURL.isEmpty else {
            errorMessage = "请先在设置里填写 DashScope Key 和业务空间地址"
            return
        }

        // 1. 麦克风权限
        let granted = await requestMic()
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

        startedAt = Date()
        elapsed = 0
        isOpen = false
        pendingChunks.removeAll()
        isRecording = true
        status = "正在连接服务器…"
        startTicker()

        // 顺序很重要：先发 connect，等 receiveLoop 拿到第一帧（握手完成）再发 session.update。
        // 以前 resume() 后立刻发，握手还没完成，配置和开头几百毫秒音频全被丢掉了。
        task.resume()
        receiveLoop(task)
        startCapture()
    }

    /// 关掉录音。故意不用 `guard isRecording else { return }`：
    /// start() 中途失败时 isRecording 已经置 true，这个 guard 会让 UI 卡在录音态；
    /// 而且错误分支调用 stop() 会直接把已录到的字幕丢掉。
    func stop() {
        if capture == nil && socket == nil && !isRecording { return }
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        savedAudioName = capture?.fileName
        capture?.stop()
        capture = nil
        isOpen = false
        pendingChunks.removeAll()
        status = ""
        send(#"{"event_id":"\#(nextID())","type":"session.finish"}"#)
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
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
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
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
        let b64 = data.base64EncodedString()
        send("{\"event_id\":\"\(nextID())\",\"type\":\"input_audio_buffer.append\",\"audio\":\"\(b64)\"}")
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
    }

    /// 用 async 循环收消息：比递归 receive 更稳，也不会堆栈溢出
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        // 不用 [weak self]：循环在 stop() 后立即退出，不会长期持有
        Task { [self] in
            while true {
                let stillRecording = await self.isRecording
                if !stillRecording { return }

                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        // 收到第一帧就说明握手已完成
                        let opened = await self.isOpen
                        if !opened { self.onOpen() }
                        await self.handle(text)
                    case .data(let raw):
                        let opened2 = await self.isOpen
                        if !opened2 { self.onOpen() }
                        if let text = String(data: raw, encoding: .utf8) { await self.handle(text) }
                    @unknown default:
                        break
                    }
                } catch {
                    if await self.isRecording {
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
            Task { @MainActor in
                var waited = 0
                while waited < 15 && self.curSource.isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
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
            stop()

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
        let cap = AudioCapture { [weak self] chunk in
            guard let self else { return }
            // 音频回调在别的线程，转发回主线程发 WebSocket
            Task { @MainActor in
                if self.isRecording { self.sendAudio(chunk) }
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

    /// 目标格式：16k / 单声道 / 16bit，阿里云要的就是这个
    private let targetFormat: AVAudioFormat?

    private var fileHandle: FileHandle?
    /// tap 是否已装上：start() 中途抛错时不会再被执行，若不记标记，下次 start 会重复 installTap 直接崩
    private var tapInstalled = false
    private(set) var fileName: String?
    private var dataBytes: UInt32 = 0
    /// 音频回调在后台线程，stop() 在主线程；写文件全部串行到这条队列，避免竞态
    private let writeQueue = DispatchQueue(label: "lecturebuddy.wav")

    init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(16000)
        try session.setActive(true, options: [])

        // 2. 开录音文件
        openWav()

        // 3. 安装 tap —— 这是最容易崩的地方：
        //    必须用 outputFormat，不能用 inputFormat（两者不一致时会抛 ObjC 异常，Swift try 抓不到）
        let input = engine.inputNode
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
        writeQueue.async { [weak self] in self?.writeWav(data) }
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
        let name = "lesson-\(Int(Date().timeIntervalSince1970)).wav"
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
