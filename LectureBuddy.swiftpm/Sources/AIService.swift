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
        // 长课不再直接报错：先分段提炼，再用提炼结果生成完整笔记。
        // 一节课两三个小时很常见，直接截断会丢掉后半节课。
        let material = transcript.count <= 24000
            ? transcript
            : try await condense(transcript, language: language)
        let system = """
        你是坐在学生旁边、帮他把课上内容真正学懂的助教。输出语言：\(language)。

        【最重要的原则】学生先要能看懂这节课的骨架，然后才看细节。
        所以不要一上来就罗列细节，不要只把老师的话换个说法复述。
        你的任务是：把课听成一条清楚的主线 → 再展开老师怎么讲这条主线 → 再给出自己的分析、举例和练习。

        只输出一个 JSON 对象，字段固定为：
        {
          "summary": "整节课 3-5 句概述，说清讲什么、为什么重要",
          "framework": {
            "problem": "这节课到底想解决什么问题（1-2 句）",
            "bigPicture": "不看细节也能听懂的主线：3-5 句，按因果/递进串起来，学生读完能自己复述",
            "flow": [{"title": "第一环名称", "role": "它在整节课里的作用（1 句）", "keyPoints": ["这一环的关键点"]}]
          },
          "knowledgePoints": [{"title": "知识点名称", "detail": "老师实际怎么讲的（保留原话要点）", "confusion": "学生最容易卡住的疑问（用问句）", "example": "一个具体例子或类比，最好直接用课上讲过的"}],
          "practice": {
            "quickChecks": [{"question": "概念快测（能一句话回答）", "answer": "答案", "explanation": "为什么，以及最常见的错法"}],
            "problems": [{"question": "需要动笔的综合题，考能不能用这节课的思路解题", "answer": "参考答案（分步骤）", "explanation": "解题思路点评"}]
          },
          "glossary": [{"term": "术语原文", "explain": "中文解释"}],
          "cards": [{"question": "考前自测问题", "answer": "答案"}],
          "sections": [{"title": "按讲课顺序的章节", "points": ["要点"]}]
        }

        【质量要求】
        1. framework.flow 要按讲课顺序，3-6 环；每环的 role 必须说明它为什么接在前一环后面。
        2. knowledgePoints 只收真正重要的点，3-8 个；detail 写老师说的关键内容，不要空话。
        3. confusion 和 example 必须基于这节课的实际内容；不要写“多练习就会了”这种空话。
        4. quickChecks 出 4-6 题，problems 出 2-3 题；答案和讲解分开写。
        5. sections 保留原有结构，作为回到课堂原始细节的索引。
        6. 所有内容必须来自转写稿，不要编造老师没讲的知识点。
        7. 不要输出 JSON 以外的任何文字。
        """
        let answer = try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: material)
        ], temperature: 0.3)
        if let notes = LessonNotes.parse(from: answer) { return notes }
        return LessonNotes.fallback(from: answer)
    }

    /// 长课分块提炼：每块单独压缩成要点，再把要点串起来给主笔记用。
    /// 块之间保留「第几块」标记，避免模型把前后段搞混。
    private func condense(_ transcript: String, language: String) async throws -> String {
        let chunkSize = 8000
        var chunks: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let end = transcript.index(start, offsetBy: chunkSize, limitedBy: transcript.endIndex)
                ?? transcript.endIndex
            // 尽量在换行处断开，不把一句话切成两半
            let slice = transcript[start..<end]
            if end == transcript.endIndex {
                chunks.append(String(slice))
                break
            }
            let cut = slice.lastIndex(of: "\n") ?? slice.index(before: end)
            chunks.append(String(transcript[start..<cut]))
            start = transcript.index(after: cut)
        }
        guard chunks.count > 1 else { return transcript }

        let system = """
        你在帮学生整理一节很长的课。把下面的片段压成要点，输出语言：\(language)。
        保留：老师讲的定义、推导、例子、强调的结论。
        丢掉：口头禅、重复、无关闲聊。
        只输出要点列表，不要前言。
        """

        var parts: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let answer = try await complete(messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: "第 \(index + 1)/\(chunks.count) 段：\n" + chunk)
            ], temperature: 0.2)
            parts.append("【第 \(index + 1) 段要点】\n" + answer)
        }
        return parts.joined(separator: "\n\n")
    }

    func ask(question: String, lesson: Lesson) async throws -> String {
        var context = lesson.transcriptText
        if let notes = lesson.notes {
            context += "\n\n【已整理的课堂笔记】\n" + notes.summary
            if !notes.framework.isEmpty {
                context += "\n\n【课程主线】\n" + notes.framework.bigPicture
                if !notes.framework.problem.isEmpty {
                    context += "\n要解决的问题：" + notes.framework.problem
                }
                let flow = notes.framework.flow.map { $0.title }.joined(separator: " → ")
                if !flow.isEmpty { context += "\n结构：" + flow }
            }
            for point in notes.knowledgePoints {
                context += "\n" + point.title + "：" + point.detail
            }
            for section in notes.sections {
                context += "\n" + section.title + "：" + section.points.joined(separator: "；")
            }
        }
        // 提问时允许用整节课的内容；过长就保留前面部分并注明，而不是直接报错。
        var questionContext = context
        if questionContext.count > 24000 {
            questionContext = String(questionContext.prefix(24000))
                + "\n\n（课堂内容过长，以上为前面部分；涉及后面的内容请重新生成笔记后再问。）"
        }
        let system = """
        你是留学生的课堂助教。只根据下面这节课的内容回答，找不到依据就说"这节课没讲到"。
        回答按这个顺序组织，用中文写：
        1. 先定位：这个问题在整节课的框架里属于哪一环（一句话）。
        2. 一句话结论。
        3. 老师原话怎么说的（引一句）。
        4. 用大白话解释清楚。
        5. 举一个具体例子或类比，最好直接用课上讲过的（这一条不能省）。
        6. 如果这是个容易混淆的难点，指出易错点。
        语言要像学长给学妹讲题，直接、有耐心，不要堆术语。
        """
        return try await complete(messages: [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: "【课堂内容】\n" + questionContext + "\n\n【问题】\n" + question)
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