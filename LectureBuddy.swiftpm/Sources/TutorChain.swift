import Foundation

/// 「讲解链」：把一次圈选提问变成结构化的六步讲解，而不是甩一大段话。
///
/// 为什么要有结构：学生圈住一块课件，往往不是要「这段话什么意思」，
/// 而是要「它在整节课里是干嘛的、为什么这么写、我怎么才能用上」。
/// 单段回答读起来像翻译，六步读起来像有人坐在旁边讲。
enum TutorChain {

    /// 是否该升级到视觉模型。
    ///
    /// 文字 OCR 便宜、快，但遇到公式、图表、手写、复杂排版就会错得很离谱。
    /// 阈值 0.75 是经验值：Apple 的 VNRecognizeText 对印刷体通常给 0.9+，
    /// 对手写和公式会给 0.5 以下。低于这个值还硬用文字，等于让模型猜。
    static func shouldUseVision(ocrConfidence: Double,
                                hasFormulaOrDiagram: Bool,
                                hasImage: Bool) -> Bool {
        guard hasImage else { return false }
        if ocrConfidence < 0.75 { return true }
        return hasFormulaOrDiagram
    }

    /// 粗略判断一段 OCR 文本里是否含公式/图表特征。
    /// 不用很准，只需要把「明显不是自然语言」的情况挑出来。
    static func looksLikeFormulaOrDiagram(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        // 数学符号密度高就当作公式
        let symbols = CharacterSet(charactersIn: "=+−-×÷∑∫√≤≥≈≠θαβγλμπσΔΩ^_{}[]|/\<>")
        let symbolCount = trimmed.unicodeScalars.filter { symbols.contains($0) }.count
        let ratio = Double(symbolCount) / Double(max(trimmed.count, 1))
        if ratio > 0.12 { return true }
        // 中文/韩文/英文字母很少，说明多半是符号堆
        let letters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        return Double(letters) / Double(max(trimmed.count, 1)) < 0.35
    }

    /// 六步讲解的 prompt。
    /// - Parameters:
    ///   - selectionText: 圈选区域 OCR 出来的文字（视觉模式下可能为空）
    ///   - frameworkSummary: 这节课的主线，帮助模型把知识点放回框架里
    static func buildPrompt(subject: String,
                            selectionText: String,
                            frameworkSummary: String,
                            pageIndex: Int) -> (system: String, user: String) {
        let system = """
        你是坐在这个学生旁边的助教，正在帮他看懂课件上的某一小块内容。
        用中文回答，语气像学长给学妹讲题：直接、有耐心、不说空话。

        【必须按这个结构回答，用小标题分开】
        ① 这是什么：先判断类型——定义、公式、例子、图表、还是步骤说明。
        ② 拆解：把它拆成几个组成部分，逐块说清。
        ③ 关联：它是整节课主线里的哪一环，和前面讲的什么有关。
        ④ 讲解：先给直觉（大白话），再给严谨说法。
        ⑤ 举例：一个具体例子或类比，最好直接用课件上出现过的。
        ⑥ 追问：出一道能检验他是否真懂的小题，只出题，不给答案。

        【底线】
        - 只能依据课件内容回答。看不清、信息不够，就直接说「这里看不清，建议放大或补充上下文」，绝对不要猜。
        - 不要编造课件里没有的术语和结论。
        - 如果这块内容和整节课关系不大，就直说，不要硬扯。
        """

        var user = "【课程主题】\(subject.isEmpty ? "未填写" : subject)\n"
        user += "【课件第 \(pageIndex) 页，学生圈出的部分】\n"
        if selectionText.isEmpty {
            user += "（这一块主要是图形/公式，文字识别不出内容，请看图片）\n"
        } else {
            user += selectionText + "\n"
        }
        if !frameworkSummary.isEmpty {
            user += "\n【这节课的主线，帮助你把知识点放回框架】\n" + frameworkSummary + "\n"
        }
        return (system, user)
    }

    /// 宽容地把模型回复拆成六步。
    /// 模型经常不老实按 ①②③ 来，所以退一步按「1. 2. 3.」、再退一步按空行切。
    /// 永远返回可用的结果，绝不因为格式不对就丢掉整段回答。
    static func parse(_ raw: String) -> (steps: [TutorStep], followUp: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ([], "") }

        let markers: [Character] = ["①", "②", "③", "④", "⑤", "⑥"]
        var pieces: [String] = []

        let hasCircled = markers.contains { text.contains($0) }
        if hasCircled {
            var current = ""
            for ch in text {
                if markers.contains(ch) {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pieces.append(current)
                    }
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(current)
            }
        } else {
            // 退化路径：按「1.」「2.」这类编号切
            let lines = text.components(separatedBy: .newlines)
            let looksNumbered = lines.filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.count > 2 && t.first?.isNumber == true
                    && (t.dropFirst().first == "." || t.dropFirst().first == "、"
                        || t.dropFirst().first == ")")
            }.count >= 3

            if looksNumbered {
                var current = ""
                for line in lines {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    let isNew = t.count > 2 && t.first?.isNumber == true
                        && (t.dropFirst().first == "." || t.dropFirst().first == "、"
                            || t.dropFirst().first == ")")
                    if isNew {
                        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            pieces.append(current)
                        }
                        current = t
                    } else {
                        current += "\n" + line
                    }
                }
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pieces.append(current)
                }
            } else {
                pieces = [text]
            }
        }

        // 干净化：去掉模型爱加的前缀，比如「① 这是什么：」
        var steps: [TutorStep] = []
        for piece in pieces {
            var body = piece
            for marker in ["①", "②", "③", "④", "⑤", "⑥"] {
                body = body.replacingOccurrences(of: marker, with: "")
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            // 第一行如果是短标题（带冒号），当作 title
            var title = ""
            if let newline = body.firstIndex(of: "\n") {
                let head = String(body[..<newline])
                if head.count <= 20 {
                    title = head.trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
                    body = String(body[body.index(after: newline)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if let colon = body.firstIndex(of: "："), body.distance(from: body.startIndex, to: colon) <= 12 {
                title = String(body[..<colon])
                let rest = String(body[body.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { body = rest }
            }

            if body.isEmpty && title.isEmpty { continue }
            steps.append(TutorStep(title: title.isEmpty ? "讲解" : title, body: body))
        }

        // 最后一步如果是追问，单独拎出来，界面上做成「自测」卡片
        var followUp = ""
        if let last = steps.last,
           last.body.contains("？") || last.body.contains("?") || last.title.contains("追问") {
            followUp = last.body
            steps.removeLast()
        }

        if steps.isEmpty {
            // 兜底：格式完全不认识，至少别丢内容
            return ([TutorStep(title: "讲解", body: text)], "")
        }
        return (steps, followUp)
    }
}
