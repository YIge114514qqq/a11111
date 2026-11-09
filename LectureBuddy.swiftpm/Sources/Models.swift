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

/// 课堂的大框架：先让学生看懂这节课在讲什么、怎么串起来的，再去看细节
struct FrameworkItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// 一句话讲清楚这一环在整节课里的作用
    var role: String = ""
    /// 这一环里的关键点（对应后面章节的细节）
    var keyPoints: [String] = []
}

struct Framework: Codable, Hashable {
    /// 3-5 句说清这节课的主线，学生读完能自己复述
    var bigPicture: String = ""
    /// 按顺序串起来的环节
    var flow: [FrameworkItem] = []
    /// 这节课到底想解决什么问题
    var problem: String = ""
    var isEmpty: Bool { bigPicture.isEmpty && flow.isEmpty }
}

/// 老师讲的知识点，配上学生自己会遇到的疑问和具体例子
struct KnowledgePoint: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// 老师的原话要点（保留课上细节）
    var detail: String = ""
    /// 学生最容易卡住的疑问，用问句
    var confusion: String = ""
    /// 结合课上内容的举例/类比，要具体
    var example: String = ""
    var isEmpty: Bool { title.isEmpty }
}

/// 一道练习：答案和讲解分开，方便先自己做再看
struct ExerciseItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var question: String
    var answer: String = ""
    /// 讲解：为什么是这个答案、常见错法在哪
    var explanation: String = ""
}

/// 课后自测：优先考“能不能用这节课的思路解题”，而不是背原话
struct PracticeSet: Codable, Hashable {
    /// 短题，用来快速确认概念有没有接上
    var quickChecks: [ExerciseItem] = []
    /// 动笔的综合题
    var problems: [ExerciseItem] = []
    var isEmpty: Bool { quickChecks.isEmpty && problems.isEmpty }

    /// 模型给的练习数组可能缺字段、也可能是纯字符串，尽量宽容地接住
    static func parseItems(_ raw: Any?) -> [ExerciseItem] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { element -> ExerciseItem? in
            if let text = element as? String {
                let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return q.isEmpty ? nil : ExerciseItem(question: q)
            }
            guard let item = element as? [String: Any] else { return nil }
            let q = (item["question"] as? String) ?? (item["q"] as? String) ?? ""
            guard !q.isEmpty else { return nil }
            return ExerciseItem(
                question: q,
                answer: (item["answer"] as? String) ?? (item["a"] as? String) ?? "",
                explanation: (item["explanation"] as? String) ?? (item["explain"] as? String) ?? "")
        }
    }
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
    /// 先看大局：这节课的骨架
    var framework: Framework = Framework()
    /// 再看细节：老师讲的点 + 学生的疑问 + 具体例子
    var knowledgePoints: [KnowledgePoint] = []
    /// 最后自测
    var practice: PracticeSet = PracticeSet()

    /// 手写解码：旧版本存下来的 lessons.json 没有新字段，
    /// 用默认值补齐，否则升级 App 后所有历史笔记都会解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sections = try c.decodeIfPresent([NoteSection].self, forKey: .sections) ?? []
        cards = try c.decodeIfPresent([StudyCard].self, forKey: .cards) ?? []
        glossary = try c.decodeIfPresent([GlossaryItem].self, forKey: .glossary) ?? []
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        framework = try c.decodeIfPresent(Framework.self, forKey: .framework) ?? Framework()
        knowledgePoints = try c.decodeIfPresent([KnowledgePoint].self, forKey: .knowledgePoints) ?? []
        practice = try c.decodeIfPresent(PracticeSet.self, forKey: .practice) ?? PracticeSet()
    }

    init() {}

    var isEmpty: Bool {
        summary.isEmpty && sections.isEmpty && cards.isEmpty
            && framework.isEmpty && knowledgePoints.isEmpty && practice.isEmpty
    }

    /// 是否只有旧版数据（方便界面提示“可以重新生成更完整的笔记”）
    var needsRefresh: Bool {
        framework.isEmpty && knowledgePoints.isEmpty && practice.isEmpty
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

        // 1) 大框架：先讲清主线
        if let fw = obj["framework"] as? [String: Any] {
            notes.framework.bigPicture = (fw["bigPicture"] as? String)
                ?? (fw["big_picture"] as? String) ?? ""
            notes.framework.problem = (fw["problem"] as? String) ?? ""
            let flow = (fw["flow"] as? [[String: Any]]) ?? (fw["steps"] as? [[String: Any]]) ?? []
            notes.framework.flow = flow.compactMap { item in
                guard let title = item["title"] as? String, !title.isEmpty else { return nil }
                let points = (item["keyPoints"] as? [Any])?.compactMap { $0 as? String }
                    ?? (item["key_points"] as? [Any])?.compactMap { $0 as? String } ?? []
                return FrameworkItem(title: title,
                                     role: (item["role"] as? String) ?? "",
                                     keyPoints: points)
            }
        }

        // 2) 细节：知识点 + 疑问 + 例子
        if let points = obj["knowledgePoints"] as? [[String: Any]] {
            notes.knowledgePoints = points.compactMap { item in
                guard let title = item["title"] as? String, !title.isEmpty else { return nil }
                return KnowledgePoint(
                    title: title,
                    detail: (item["detail"] as? String) ?? "",
                    confusion: (item["confusion"] as? String) ?? "",
                    example: (item["example"] as? String) ?? "")
            }
        }

        // 3) 练习
        if let p = obj["practice"] as? [String: Any] {
            notes.practice.quickChecks = PracticeSet.parseItems(p["quickChecks"] ?? p["quick_checks"])
            notes.practice.problems = PracticeSet.parseItems(p["problems"] ?? p["longQuestions"])
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