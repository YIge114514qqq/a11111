import Foundation

struct CaptionLine: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    var translation: String?
    var timestamp: Date = Date()
    var offset: TimeInterval = 0
}

struct NoteSection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var points: [String] = []
}

struct StudyCard: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var question: String
    var answer: String
}

struct GlossaryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var term: String
    var explain: String
}

struct LessonNotes: Codable, Hashable {
    var summary: String = ""
    var sections: [NoteSection] = []
    var cards: [StudyCard] = []
    var glossary: [GlossaryItem] = []
    var generatedAt: Date = Date()

    var isEmpty: Bool {
        summary.isEmpty && sections.isEmpty && cards.isEmpty
    }

    /// 宽容地解析模型返回的 JSON（可能带 ```json 围栏或前后废话）
    static func parse(from raw: String) -> LessonNotes? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonText = String(raw[start...end])
        guard let data = jsonText.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { return nil }

        var notes = LessonNotes()
        notes.summary = (obj["summary"] as? String) ?? ""

        if let sections = obj["sections"] as? [[String: Any]] {
            notes.sections = sections.compactMap { item in
                guard let title = item["title"] as? String, !title.isEmpty else { return nil }
                let points = (item["points"] as? [Any])?.compactMap { $0 as? String } ?? []
                return NoteSection(title: title, points: points)
            }
        }

        if let cards = obj["cards"] as? [[String: Any]] {
            notes.cards = cards.compactMap { item in
                let q = (item["question"] as? String) ?? (item["q"] as? String)
                let a = (item["answer"] as? String) ?? (item["a"] as? String)
                guard let question = q, !question.isEmpty else { return nil }
                return StudyCard(question: question, answer: a ?? "")
            }
        }

        if let glossary = obj["glossary"] as? [[String: Any]] {
            notes.glossary = glossary.compactMap { item in
                guard let term = item["term"] as? String, !term.isEmpty else { return nil }
                let explain = (item["explain"] as? String) ?? (item["meaning"] as? String) ?? ""
                return GlossaryItem(term: term, explain: explain)
            }
        }

        return notes.isEmpty ? nil : notes
    }

    /// 模型没按格式返回时，至少把内容保留成一段笔记
    static func fallback(from raw: String) -> LessonNotes {
        var notes = LessonNotes()
        notes.summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes
    }
}

struct Lesson: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var duration: TimeInterval = 0
    var lines: [CaptionLine] = []
    var notes: LessonNotes?
    var audioFileName: String?
    var sourceLanguage: String = ""
    var targetLanguage: String = ""

    var transcriptText: String {
        lines.map { line in
            if let t = line.translation, !t.isEmpty {
                return "\(line.text)\n[译文] \(t)"
            }
            return line.text
        }.joined(separator: "\n")
    }
}

struct LangOption: Identifiable, Hashable {
    let id: String
    let title: String

    static let sources: [LangOption] = [
        LangOption(id: "en-US", title: "英语（美国）"),
        LangOption(id: "en-GB", title: "英语（英国）"),
        LangOption(id: "ja-JP", title: "日语"),
        LangOption(id: "ko-KR", title: "韩语"),
        LangOption(id: "de-DE", title: "德语"),
        LangOption(id: "fr-FR", title: "法语"),
        LangOption(id: "es-ES", title: "西班牙语"),
        LangOption(id: "it-IT", title: "意大利语"),
        LangOption(id: "ru-RU", title: "俄语"),
        LangOption(id: "zh-CN", title: "中文（普通话）")
    ]

    static let targets: [LangOption] = [
        LangOption(id: "zh-CN", title: "简体中文"),
        LangOption(id: "zh-TW", title: "繁体中文"),
        LangOption(id: "en-US", title: "英语 English"),
        LangOption(id: "ja-JP", title: "日语 日本語"),
        LangOption(id: "ko-KR", title: "韩语 한국어")
    ]
}

/// 秒数 -> 05:32 或 1:05:32
func timeString(_ time: TimeInterval) -> String {
    let total = max(0, Int(time.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}