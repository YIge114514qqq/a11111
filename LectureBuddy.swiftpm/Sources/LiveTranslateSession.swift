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
        request.addValue("Bearer \(settings.dashscopeKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        startedAt = Date()
        elapsed = 0
        isRecording = true
        startTicker()

        receiveLoop(task)
        sendSessionUpdate(settings)
        startCapture()
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        savedAudioName = capture?.fileName
        capture?.stop()
        capture = nil
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
        let b64 = data.base64EncodedString()
        send("{\"event_id\":\"\(nextID())\",\"type\":\"input_audio_buffer.append\",\"audio\":\"\(b64)\"}")
    }

    /// 用 async 循环收消息：比递归 receive 更稳，也不会堆栈溢出
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                guard let self else { return }
                let stillRecording = await MainActor.run { self.isRecording }
                if !stillRecording { return }

                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    if case .string(let text) = message {
                        await MainActor.run { self.handle(text) }
                    }
                } catch {
                    guard let self else { return }
                    await MainActor.run {
                        if self.isRecording {
                            self.errorMessage = "连接断开：\(error.localizedDescription)"
                            self.stop()
                        }
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
                errorMessage = friendly(code, msg)
                stop()
            }
            return
        }

        switch type {
        case "session.created", "session.updated":
            break

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
            errorMessage = friendly(code, msg)
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
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let onChunk: (Data) -> Void

    private var fileHandle: FileHandle?
    private(set) var fileName: String?
    private var dataBytes: UInt32 = 0
    /// 音频回调在后台线程，stop() 在主线程；写文件全部串行到这条队列，避免竞态
    private let writeQueue = DispatchQueue(label: "lecturebuddy.wav")

    init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)!
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [])

        openWav()

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1600, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        try? engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // 等队列里排队的写入全部完成后，再回填 WAV 头，否则长度会少算
        writeQueue.sync { self.closeWav() }
    }

    // MARK: - 转换

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }

        let bytesPerFrame = Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        let size = frames * bytesPerFrame
        guard let ptr = converted.int16ChannelData?[0] else { return }

        let data = Data(bytes: ptr, count: size)
        onChunk(data)
        writeQueue.async { [weak self] in self?.writeWav(data) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = buffer.format
        if inFormat.sampleRate == targetFormat.sampleRate,
           inFormat.channelCount == targetFormat.channelCount,
           inFormat.commonFormat == .pcmFormatInt16 {
            return buffer
        }
        if converter == nil || converter?.inputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
        }
        guard let conv = converter else { return nil }

        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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