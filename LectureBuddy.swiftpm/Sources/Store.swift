import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "apiKey") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var sourceLanguage: String { didSet { defaults.set(sourceLanguage, forKey: "sourceLanguage") } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: "targetLanguage") } }
    @Published var notesLanguage: String { didSet { defaults.set(notesLanguage, forKey: "notesLanguage") } }
    @Published var showSource: Bool { didSet { defaults.set(showSource, forKey: "showSource") } }

    // 阿里云实时语音翻译（端到端，最快）
    @Published var dashscopeKey: String { didSet { defaults.set(dashscopeKey, forKey: "dashscopeKey") } }
    @Published var dashscopeURL: String { didSet { defaults.set(dashscopeURL, forKey: "dashscopeURL") } }
    @Published var asrModel: String { didSet { defaults.set(asrModel, forKey: "asrModel") } }

    /// 今天这节课的主题，用来联网生成术语表
    @Published var courseTopic: String { didSet { defaults.set(courseTopic, forKey: "courseTopic") } }
    /// 专业术语表：每行「原文=译文」，提升专业词翻译准确率
    @Published var termsText: String { didSet { defaults.set(termsText, forKey: "termsText") } }
    /// 是否同时保存课堂录音
    @Published var recordAudio: Bool { didSet { defaults.set(recordAudio, forKey: "recordAudio") } }
    private let defaults = UserDefaults.standard

    private init() {
        baseURL = defaults.string(forKey: "baseURL") ?? "https://api.deepseek.com"
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        model = defaults.string(forKey: "model") ?? "deepseek-chat"
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "en-US"
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "zh-CN"
        notesLanguage = defaults.string(forKey: "notesLanguage") ?? "简体中文"
        showSource = defaults.object(forKey: "showSource") as? Bool ?? true
        dashscopeKey = defaults.string(forKey: "dashscopeKey") ?? ""
        // 默认就填好官方地址：以前这里默认空串，新用户只填 Key 不填地址，
        // useLiveTranslate 就为 false，点开始直接被拦或走错引擎。
        dashscopeURL = defaults.string(forKey: "dashscopeURL") ?? "https://dashscope.aliyuncs.com/api/v1"
        asrModel = defaults.string(forKey: "asrModel") ?? "qwen3.5-livetranslate-flash-realtime"
        courseTopic = defaults.string(forKey: "courseTopic") ?? ""
        termsText = defaults.string(forKey: "termsText") ?? ""
        recordAudio = defaults.object(forKey: "recordAudio") as? Bool ?? true
    }

    var sourceTitle: String {
        LangOption.sources.first { $0.id == sourceLanguage }?.title ?? sourceLanguage
    }

    var targetTitle: String {
        LangOption.targets.first { $0.id == targetLanguage }?.title ?? targetLanguage
    }

    /// 只要能听课就算配置好了：
    /// 云端实时翻译只需要 DashScope，课后笔记/提问才需要另一个 AI Key。
    /// 以前这里只看 apiKey，只填了 DashScope 的用户点开始会误报「请填 Key」。
    var isConfigured: Bool { useLiveTranslate || hasAIConfiguration }

    /// 课后笔记和提问需要单独配置 AI Key。
    var hasAIConfiguration: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 云端实时翻译是否可用
    var useLiveTranslate: Bool {
        !dashscopeKey.isEmpty && !dashscopeURL.isEmpty
    }

    func preset(_ name: String) {
        switch name {
        case "DeepSeek":
            baseURL = "https://api.deepseek.com"
            model = "deepseek-chat"
        case "通义千问":
            baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            model = "qwen-plus"
        case "Kimi":
            baseURL = "https://api.moonshot.cn/v1"
            model = "moonshot-v1-8k"
        case "智谱":
            baseURL = "https://open.bigmodel.cn/api/paas/v4"
            model = "glm-4-flash"
        case "OpenAI":
            baseURL = "https://api.openai.com/v1"
            model = "gpt-4o-mini"
        default:
            break
        }
    }
}

/// 本地保存所有课程，JSON 落在 App 的 Documents 里，不上传任何地方
final class LessonStore: ObservableObject {
    @Published private(set) var lessons: [Lesson] = []
    /// 数据文件读不出来时置为 true：此时绝对不能写回，否则会把旧数据覆盖掉
    @Published private(set) var loadError: String?
    private var loadedSuccessfully = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("lessons.json")
    }

    init() { load() }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // 第一次启动（或者用户删了数据）：空库是正常状态，可以正常写
            lessons = []
            loadError = nil
            loadedSuccessfully = true
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            markLoadFailed("课程数据文件读不出来")
            return
        }
        do {
            let saved = try JSONDecoder().decode([Lesson].self, from: data)
            lessons = saved.sorted { $0.createdAt > $1.createdAt }
            loadError = nil
            loadedSuccessfully = true
        } catch {
            // 旧版本升级、字段对不上、文件被写坏都会走到这里。
            // 以前直接设成空数组，下一次保存就把整库覆盖了——这才是真正会
            // “更新后以前的课都没了”的原因。现在只报告错误，不写回。
            markLoadFailed("课程数据解析失败：\(error.localizedDescription)")
        }
    }

    private func markLoadFailed(_ message: String) {
        lessons = []
        loadedSuccessfully = false
        loadError = message
    }

    private func persist() {
        // 没成功读过就绝不写，避免用空数据覆盖用户原来的课程
        guard loadedSuccessfully else { return }
        guard let data = try? JSONEncoder().encode(lessons) else { return }
        // 每次写之前先留一份上一版：万一新版写坏，还能回滚
        backupCurrentFile()
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 上一版数据的备份，升级出问题时可以人工救回
    var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("lessons.backup.json")
    }

    private func backupCurrentFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    /// 导出全部课程（含笔记）成一个 JSON 文件。
    /// 先写到 Documents（开了文件共享后，「文件」App 里能直接看到），
    /// 同时给分享面板一份，两条路都能把备份拿出去。
    func exportURL() throws -> URL {
        let data = try JSONEncoder().encode(lessons)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("LectureBuddy-backup.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 导入备份：按 id 合并，不会把现有的课删掉
    func importLessons(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let incoming = try JSONDecoder().decode([Lesson].self, from: data)
        for lesson in incoming {
            if let index = lessons.firstIndex(where: { $0.id == lesson.id }) {
                lessons[index] = lesson
            } else {
                lessons.append(lesson)
            }
        }
        lessons.sort { $0.createdAt > $1.createdAt }
        loadedSuccessfully = true
        persist()
    }

    func save(_ lesson: Lesson) {
        if let index = lessons.firstIndex(where: { $0.id == lesson.id }) {
            lessons[index] = lesson
        } else {
            lessons.insert(lesson, at: 0)
        }
        persist()
    }

    func delete(_ lesson: Lesson) {
        lessons.removeAll { $0.id == lesson.id }
        if let name = lesson.audioFileName {
            try? FileManager.default.removeItem(at: audioURL(named: name))
        }
        persist()
    }

    func audioURL(named name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }
}