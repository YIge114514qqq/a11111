import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}

let raw = """
模型回复：
```json
{"summary":"课堂总结","sections":[{"title":"主题","points":["要点",7]},{"title":""},{"points":[]}],"cards":[{"question":"问题","answer":"答案"},{"q":"别名问题","a":"别名答案"},{"question":"缺答案"},{"question":""}],"glossary":[{"term":"术语","meaning":"解释"},{"term":""}]}
```
结束
"""
guard let notes = LessonNotes.parse(from: raw) else { fatalError("FAIL: fenced notes must parse") }
expect(notes.summary == "课堂总结", "summary preserves Unicode")
expect(notes.sections.count == 1, "invalid sections are filtered")
expect(notes.sections.first?.title == "主题", "section title")
expect(notes.sections.first?.points == ["要点"], "non-string points are filtered")
expect(notes.cards.map(\.question) == ["问题", "别名问题", "缺答案"], "card aliases and invalid questions")
expect(notes.cards.map(\.answer) == ["答案", "别名答案", ""], "card answers and default")
expect(notes.glossary.count == 1, "empty glossary terms are filtered")
expect(notes.glossary.first?.explain == "解释", "glossary meaning alias")
for invalid in ["", "plain text", "{bad json}", "{}", "{\"summary\":12}", "{\"sections\":[],\"cards\":[]}"] {
    expect(LessonNotes.parse(from: invalid) == nil, "reject unusable notes: \(invalid)")
}
expect(LessonNotes.parse(from: "{\"sections\":[{\"title\":\"独立主题\"}]}")?.sections.count == 1, "sections without summary")
expect(LessonNotes.parse(from: "{\"cards\":[{\"q\":\"独立问题\"}]}")?.cards.count == 1, "cards without summary")
expect(LessonNotes.fallback(from: " \n 原始笔记 \t").summary == "原始笔记", "fallback trims whitespace")

expect(Lesson(title: "empty").transcriptText == "", "empty transcript")
let lesson = Lesson(title: "test", lines: [
    CaptionLine(text: "Hello", translation: "你好"),
    CaptionLine(text: "No translation", translation: nil),
    CaptionLine(text: "Empty translation", translation: "")
])
expect(lesson.transcriptText == "Hello\n[译文] 你好\nNo translation\nEmpty translation", "transcript ordering and translation formatting")
for (seconds, expected) in [(-10.0, "00:00"), (0, "00:00"), (59.4, "00:59"), (59.5, "01:00"), (3599.5, "1:00:00"), (3932, "1:05:32")] {
    expect(timeString(seconds) == expected, "timeString(\(seconds)) == \(expected)")
}

// MARK: - 新增结构：框架 / 知识点 / 练习

let full = """
{"summary":"讲股东会决议效力","framework":{"problem":"什么样的决议算有效","bigPicture":"先讲决议性质，再讲瑕疵类型，最后讲救济","flow":[{"title":"决议性质","role":"承上启下","keyPoints":["法律行为","集体意思"]},{"title":"瑕疵类型"}]},"knowledgePoints":[{"title":"决议瑕疵","detail":"老师强调不是合同","confusion":"为什么不是合同？","example":"股东会投票像议会表决"}],"practice":{"quickChecks":[{"question":"决议是什么？","answer":"集体意思表示","explanation":"不是单方行为"},{"question":"瑕疵有几类？"}],"problems":[{"q":"举例说明","a":"...","explanation":"..."}]},"glossary":[{"term":"决议","explain":"集体的意思表示"}]}
"""
guard let rich = LessonNotes.parse(from: full) else { fatalError("FAIL: full structured notes must parse") }
expect(rich.framework.problem == "什么样的决议算有效", "framework.problem")
expect(rich.framework.flow.count == 2, "framework flow count")
expect(rich.framework.flow[0].role == "承上启下", "framework role")
expect(rich.framework.flow[0].keyPoints == ["法律行为", "集体意思"], "framework keyPoints")
expect(rich.knowledgePoints.count == 1, "knowledge point count")
expect(rich.knowledgePoints[0].confusion == "为什么不是合同？", "knowledge confusion")
expect(rich.knowledgePoints[0].example.contains("议会"), "knowledge example")
expect(rich.practice.quickChecks.count == 2, "quick check count")
expect(rich.practice.quickChecks[0].answer == "集体意思表示", "quick check answer")
expect(rich.practice.quickChecks[1].answer == "", "missing answer defaults to empty")
expect(rich.practice.problems.count == 1, "problem alias q/a/explanation")
expect(rich.practice.problems[0].question == "举例说明", "problem question alias")
expect(rich.needsRefresh == false, "rich notes do not need refresh")

// 旧格式（只有 summary/sections/cards）必须仍然可解析
let legacy = """
{"summary":"旧笔记","sections":[{"title":"章节","points":["点"]}],"cards":[{"question":"问","answer":"答"}]}
"""
guard let old = LessonNotes.parse(from: legacy) else { fatalError("FAIL: legacy notes must parse") }
expect(old.framework.isEmpty, "legacy has empty framework")
expect(old.needsRefresh, "legacy notes flagged for refresh")
expect(old.sections.count == 1 && old.cards.count == 1, "legacy content preserved")
expect(old.isEmpty == false, "legacy notes not considered empty")

// 纯字符串练习也要接住
expect(PracticeSet.parseItems(["题目一"]).first?.question == "题目一", "string exercise accepted")
expect(PracticeSet.parseItems(nil).isEmpty, "nil exercise list")
expect(PracticeSet.parseItems([["question": ""]]).isEmpty, "blank exercise dropped")

// 旧版 lessons.json 缺新字段也必须能解码（这是升级不丢数据的保证）
let legacyLessonJSON = """
[{"id":"11111111-1111-1111-1111-111111111111","title":"旧课","duration":60,"lines":[{"id":"22222222-2222-2222-2222-222222222222","text":"hi","offset":0}],"notes":{"summary":"旧","sections":[],"cards":[],"glossary":[],"generatedAt":700000000}}]
"""
do {
    let decoded = try JSONDecoder().decode([Lesson].self, from: Data(legacyLessonJSON.utf8))
    expect(decoded.count == 1, "legacy lesson decodes")
    expect(decoded[0].notes?.summary == "旧", "legacy note kept")
    expect(decoded[0].notes?.practice.isEmpty == true, "missing practice defaults")
    expect(decoded[0].notes?.framework.isEmpty == true, "missing framework defaults")
} catch {
    fatalError("FAIL: legacy lessons.json no longer decodes: \(error)")
}

// 更碎的数据：缺 id / createdAt / timestamp 这种也不能整库挂掉
let sparseJSON = """
[{"title":"几乎没有字段的课","lines":[{"text":"只有文本"}]}]
"""
do {
    let sparse = try JSONDecoder().decode([Lesson].self, from: Data(sparseJSON.utf8))
    expect(sparse.count == 1, "sparse lesson decodes")
    expect(sparse[0].title == "几乎没有字段的课", "sparse title kept")
    expect(sparse[0].lines.first?.text == "只有文本", "sparse caption kept")
    expect(sparse[0].id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"), "sparse id generated")
} catch {
    fatalError("FAIL: sparse lessons.json must still decode: \(error)")
}

print("PASS: \(checks) model checks")
