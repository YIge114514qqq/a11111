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


// MARK: - 网络错误可读化

let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
expect(friendlyErrorMessage(lost).contains("切到别的 App"), "connection lost explains the cause")
expect(friendlyErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).contains("超时"), "timeout message")
expect(friendlyErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).contains("没有连网"), "offline message")
expect(friendlyErrorMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)).contains("证书"), "TLS message")
expect(friendlyErrorMessage(NSError(domain: "MyApp", code: 7, userInfo: [NSLocalizedDescriptionKey: "自定义错误"])) == "自定义错误", "non-URL errors keep their own wording")
expect(friendlyErrorMessage(NSError(domain: NSURLErrorDomain, code: -9999)).contains("-9999"), "unknown code is surfaced")

// MARK: - 重试判定

expect(isRetryableNetworkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)), "connection lost is retryable")
expect(isRetryableNetworkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)), "timeout is retryable")
expect(isRetryableNetworkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)), "offline is retryable")
expect(!isRetryableNetworkError(NSError(domain: "MyApp", code: 401)), "app-level error is not retried")
expect(!isRetryableNetworkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), "cancelled is not retried")
expect(!isRetryableNetworkError(NSError(domain: NSURLErrorDomain, code: NSURLErrorUserCancelledAuthentication)), "cancelled auth is not retried")

// MARK: - 实时字幕事件配对

do {
    var stream = LiveCaptionStream()
    stream.apply(type: "input_audio_buffer.speech_started", event: ["item_id": "asr-1", "audio_start_ms": 1000], offset: 1)
    stream.apply(type: "conversation.item.created", event: [
        "previous_item_id": "asr-1",
        "item": ["id": "translation-1", "role": "assistant"]
    ], offset: 1.1)
    stream.apply(type: "response.text.text", event: [
        "response_id": "response-1", "item_id": "translation-1", "text": "下周", "stash": "有考试"
    ], offset: 1.2)
    expect(stream.lines.map(\.translation) == ["下周有考试"], "partial translation appears before ASR")

    stream.apply(type: "input_audio_buffer.speech_started", event: ["item_id": "asr-2", "audio_start_ms": 2000], offset: 2)
    stream.apply(type: "conversation.item.input_audio_transcription.text", event: [
        "item_id": "asr-2", "text": "과제는", "stash": " 금요일까지"
    ], offset: 2.1)
    stream.apply(type: "conversation.item.created", event: [
        "previous_item_id": "asr-2",
        "item": ["id": "translation-2", "role": "assistant"]
    ], offset: 2.2)
    stream.apply(type: "response.text.done", event: [
        "response_id": "response-2", "item_id": "translation-2", "text": "作业周五前交。"
    ], offset: 2.3)

    stream.apply(type: "response.text.done", event: [
        "response_id": "response-1", "item_id": "translation-1", "text": "下周没有考试。"
    ], offset: 2.4)
    expect(stream.lines.map(\.translation) == ["下周没有考试。", "作业周五前交。"], "final translation publishes immediately without ASR")
    stream.apply(type: "conversation.item.input_audio_transcription.completed", event: [
        "item_id": "asr-1", "transcript": "다음 주에는 시험이 없습니다."
    ], offset: 2.5)
    stream.apply(type: "conversation.item.input_audio_transcription.completed", event: [
        "item_id": "asr-2", "transcript": "과제는 금요일까지 제출하세요."
    ], offset: 2.6)

    stream.apply(type: "response.text.text", event: [
        "response_id": "response-1", "item_id": "translation-1", "text": "下周有考试"
    ], offset: 2.7)
    stream.apply(type: "conversation.item.input_audio_transcription.text", event: [
        "item_id": "asr-2", "text": "과제는 금요일까지"
    ], offset: 2.8)
    expect(stream.lines.map(\.text) == ["다음 주에는 시험이 없습니다.", "과제는 금요일까지 제출하세요."], "late ASR maps to the correct turn and final ASR survives stale partials")
    expect(stream.lines.map(\.translation) == ["下周没有考试。", "作业周五前交。"], "interleaved final translations stay paired and survive stale partials")
}

do {
    var stream = LiveCaptionStream()
    stream.apply(type: "response.text.done", event: [
        "response_id": "response-late", "item_id": "translation-late", "text": "今天不布置作业。"
    ], offset: 1)
    expect(stream.lines.map(\.translation) == ["今天不布置作业。"], "standalone final translation appears before association")
    stream.apply(type: "conversation.item.input_audio_transcription.completed", event: [
        "item_id": "asr-late", "transcript": "오늘은 과제가 없습니다."
    ], offset: 1.1)

    let association = [
        "previous_item_id": "asr-late",
        "item": ["id": "translation-late", "role": "assistant"]
    ] as [String: Any]
    stream.apply(type: "conversation.item.created", event: association, offset: 1.2)
    stream.apply(type: "conversation.item.created", event: association, offset: 1.3)
    expect(stream.lines.map(\.text) == ["오늘은 과제가 없습니다."], "late repeated association merges already received results into a single row")
    expect(stream.lines.map(\.translation) == ["今天不布置作业。"], "late association preserves final translation")
}

print("PASS: \(checks) model checks")

runTutorTests()

runTutorLogTests()
