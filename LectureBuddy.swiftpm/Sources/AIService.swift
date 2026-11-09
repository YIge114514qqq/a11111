import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String
}

enum AIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String)
    case empty
    case badFormat
    case courseTooLong

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没填 API Key，去「设置」里填一个就能用。"
        case .badURL:
            return "API 地址不对，检查「设置」里的 Base URL。"
        case .http(let code, let body):
            return "接口返回 \(code)：\(body.prefix(180))"
        case .empty:
            return "接口没有返回内容。"
        case .badFormat:
            return "返回格式看不懂，可以重试一次。"
        case .courseTooLong:
            return "课堂内容超过 24000 字符，暂时无法完整生成笔记或回答问题。为避免遗漏内容，本次未发送请求；请使用较短的课程记录。"
        }
    }
}

/// 只依赖 OpenAI 兼容的 /chat/completions 接口，
/// 所以 DeepSeek / 通义 / Kimi / OpenAI 这些都能直接填。
struct AIService {
    let baseURL: String
    let apiKey: String
    let model: String

    init(settings: AppSettings) {
        self.baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpoint() throws -> URL {
        guard var url = URL(string: baseURL), url.scheme != nil else { throw AIError.badURL }
        if !url.path.hasSuffix("/chat/completions") {
            url = url.appendingPathComponent("chat/completions")
        }
        return url
    }

    func complete(messages: [ChatMessage], temperature: Double = 0.2) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, text)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.empty
        }
        return content
    }

    /// 批量翻译若干句话，条数保持一致
    func translate(lines: [String], target: String) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let system = """
        你是坐在学生旁边的朝鲜语/外语课堂同传。把每句原文翻译成\(target)。

        翻译要求：
        1. 说人话。像同学课后给你转述老师的话，不要书面腔、不要机翻腔。
        2. 口语词就按口语译，按语境翻成自然的中文口头语。
        3. 专业术语要准。学科里的固定译法要用通行译名，拿不准的保留原文并括号补中文。
        4. 长句拆成符合中文语序的短句，但不合并、不增删信息。
        5. 不要添加解释、不要加“老师说道”这类旁白。

        格式：逐句对应，不合并、不省略。
        只输出一个 JSON 字符串数组，长度必须等于原文句数，不要输出任何其他文字。
        """
        let answer = try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: numbered)
        ])
        guard let arr = Self.jsonStringArray(from: answer) else { throw AIError.badFormat }
        guard arr.count == lines.count else {
            // 条数对不上时按行兜底，避免字幕错位
            let split = answer.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if split.count == lines.count { return split }
            throw AIError.badFormat
        }
        return arr
    }

    static func jsonStringArray(from raw: String) -> [String]? {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return nil }
        let jsonText = String(raw[start...end])
        guard let data = jsonText.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return arr
    }

    func generateNotes(transcript: String, language: String) async throws -> LessonNotes {
        guard transcript.count <= 24000 else { throw AIError.courseTooLong }
        let system = """
        你是留学生的学习助教。根据课堂转写整理复习资料，输出语言为\(language)。
        只输出一个 JSON 对象，字段固定为：
        {"summary": "整节课 3-5 句概述",
         "sections": [{"title": "章节标题", "points": ["要点"]}],
         "cards": [{"question": "复习问题", "answer": "答案"}],
         "glossary": [{"term": "术语原文", "explain": "中文解释"}]}
        要求：sections 按讲课顺序划分，每节 2-5 个要点；cards 输出 5-8 张，问题要能直接用来考前自测；
        glossary 只收这门课的专业术语。不要输出 JSON 以外的任何文字。
        """
        let answer = try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: transcript)
        ], temperature: 0.3)
        if let notes = LessonNotes.parse(from: answer) { return notes }
        return LessonNotes.fallback(from: answer)
    }

    func ask(question: String, lesson: Lesson) async throws -> String {
        var context = lesson.transcriptText
        if let notes = lesson.notes {
            context += "\n\n【已整理的课堂笔记】\n" + notes.summary
            for section in notes.sections {
                context += "\n" + section.title + "：" + section.points.joined(separator: "；")
            }
        }
        guard context.count <= 24000 else { throw AIError.courseTooLong }
        let system = """
        你是留学生的课堂助教。只根据下面这节课的内容回答，找不到依据就说"这节课没讲到"。
        回答按这个顺序组织，用中文写：
        1. 一句话结论。
        2. 老师原话怎么说的（引一句）。
        3. 用大白话解释清楚。
        4. 举一个具体例子或类比，让学生真正听懂（这一条不能省）。
        5. 如果这是个容易混淆的难点，指出易错点。
        语言要像学长给学妹讲题，直接、有耐心，不要堆术语。
        """
        return try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: "【课堂内容】\n" + context + "\n\n【问题】\n" + question)
        ], temperature: 0.3)
    }

    /// 根据「今天上什么课」生成专业术语表（每行「原文=译文」）
    func buildTermList(topic: String, sourceLang: String, targetLang: String) async throws -> String {
        let system = """
        你是给同声传译做准备的专业术语助手。
        用户会告诉你今天上课的主题和授课语言。请你：

        1. 先想清楚这门课/这个主题下，教授最可能反复使用的专业术语（含缩写、人名理论名、公式名、教材常见词）。
        2. 每个术语给出 \(targetLang) 里学界通行的正式译名；没有通行译名的保留原文。
        3. 覆盖 25-40 条，从最核心的概念往外扩，不要凑数、不要写例句。

        只输出「原文=译文」，一行一条，不要编号、不要解释、不要任何多余文字。
        原文用授课语言（\(sourceLang)）写，译文用 \(targetLang) 写。
        """
        let answer = try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: "今天这节课：" + topic.trimmingCharacters(in: .whitespaces))
        ], temperature: 0.3)
        // 只保留 xxx=yyy，过滤模型偶尔多写的说明
        let lines = answer.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: "- ", with: "").replacingOccurrences(of: "* ", with: "") }
            .filter { $0.contains("=") && $0.count >= 3 && $0.count <= 120 }
        return lines.joined(separator: "\n")
    }
}