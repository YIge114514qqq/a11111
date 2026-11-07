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

    private let defaults = UserDefaults.standard

    private init() {
        baseURL = defaults.string(forKey: "baseURL") ?? "https://api.deepseek.com"
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        model = defaults.string(forKey: "model") ?? "deepseek-chat"
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "en-US"
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "zh-CN"
        notesLanguage = defaults.string(forKey: "notesLanguage") ?? "简体中文"
        showSource = defaults.object(forKey: "showSource") as? Bool ?? true
    }

    var sourceTitle: String {
        LangOption.sources.first { $0.id == sourceLanguage }?.title ?? sourceLanguage
    }

    var targetTitle: String {
        LangOption.targets.first { $0.id == targetLanguage }?.title ?? targetLanguage
    }

    var isConfigured: Bool { !apiKey.isEmpty }

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