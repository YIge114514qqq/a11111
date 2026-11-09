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
print("PASS: \(checks) model checks")
