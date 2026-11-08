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
    var isConfigured: Bool { useLiveTranslate || !apiKey.isEmpty }

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

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("lessons.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Lesson].self, from: data) else {
            lessons = []
            return
        }
        lessons = saved.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(lessons) else { return }
        try? data.write(to: fileURL, options: .atomic)
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