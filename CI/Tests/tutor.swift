import Foundation

// 讲解链的纯逻辑测试。单独一个文件，和 main.swift 一起编译。

func runTutorTests() {
    // 视觉升级判定
    assert(TutorChain.shouldUseVision(ocrConfidence: 0.95, hasFormulaOrDiagram: false, hasImage: true) == false)
    assert(TutorChain.shouldUseVision(ocrConfidence: 0.9, hasFormulaOrDiagram: true, hasImage: true) == true)
    assert(TutorChain.shouldUseVision(ocrConfidence: 0.4, hasFormulaOrDiagram: false, hasImage: true) == true)
    assert(TutorChain.shouldUseVision(ocrConfidence: 0.1, hasFormulaOrDiagram: false, hasImage: false) == false)

    // 公式识别
    assert(TutorChain.looksLikeFormulaOrDiagram("x = (-b ± √(b²-4ac)) / 2a"))
    assert(TutorChain.looksLikeFormulaOrDiagram("∑∫ ∂f/∂x ≥ 0"))
    assert(!TutorChain.looksLikeFormulaOrDiagram("股东会决议的效力分为四种情形"))
    assert(!TutorChain.looksLikeFormulaOrDiagram(""))

    // 六步解析：标准带圈数字
    let circled = """
    ① 这是什么：一个定义。
    ② 拆解：两部分。
    ③ 关联：接在上一环后面。
    ④ 讲解：大白话是这样。
    ⑤ 举例：比如 A 和 B。
    ⑥ 追问：如果条件反了会怎样？
    """
    let r1 = TutorChain.parse(circled)
    assert(r1.steps.count == 5, "expected 5 steps, got \(r1.steps.count)")
    assert(r1.followUp.contains("条件反了"))

    // 退化：数字编号
    let numbered = """
    1. 这是什么：定义
    2. 拆解：两个部分
    3. 关联：属于第二环
    4. 讲解：直觉上
    5. 追问：为什么这样？
    """
    let r2 = TutorChain.parse(numbered)
    assert(r2.steps.count >= 3, "numbered fallback should produce steps")
    assert(!r2.followUp.isEmpty)

    // 完全没格式：不能丢内容
    let plain = "这段就是在说一个概念。"
    let r3 = TutorChain.parse(plain)
    assert(r3.steps.count == 1)
    assert(r3.steps[0].body == plain)

    // 空输入不崩
    let r4 = TutorChain.parse("")
    assert(r4.steps.isEmpty)

    // prompt 里必须包含关键约束
    let p = TutorChain.buildPrompt(subject: "公司法", selectionText: "决议", frameworkSummary: "主线", pageIndex: 3)
    assert(p.system.contains("不要猜") || p.system.contains("绝对不要猜"))
    assert(p.user.contains("公司法"))
    assert(p.user.contains("第 3 页"))

    print("PASS: tutor chain checks")
}

// 旧数据里没有 tutorLog，升级后不能因为新字段就解不出来
func runTutorLogTests() {
    let json = """
    [{"id":"33333333-3333-3333-3333-333333333333","title":"没讲解记录的课","createdAt":700000000,"notes":{"summary":"x","framework":{"bigPicture":"主线"}}}]
    """
    do {
        let lessons = try JSONDecoder().decode([Lesson].self, from: Data(json.utf8))
        assert(lessons.count == 1)
        assert(lessons[0].tutorLog.isEmpty, "missing tutorLog must default to empty")
        assert(lessons[0].coursewareFileName == nil, "missing courseware defaults to nil")
        assert(lessons[0].notes?.framework.bigPicture == "主线")
    } catch {
        fatalError("FAIL: lesson without tutorLog must decode: \(error)")
    }

    // 带讲解记录的课要能往返
    var entry = TutorEntry()
    entry.pageIndex = 2
    entry.selectionText = "圈到的字"
    entry.steps = [TutorStep(title: "这是什么", body: "一个定义")]
    entry.followUpQuestion = "为什么要这样？"
    entry.usedVision = true

    var lesson = Lesson(title: "有讲解的课")
    lesson.tutorLog = [entry]
    let data = try! JSONEncoder().encode([lesson])
    let back = try! JSONDecoder().decode([Lesson].self, from: data)
    assert(back[0].tutorLog.count == 1)
    assert(back[0].tutorLog[0].pageIndex == 2)
    assert(back[0].tutorLog[0].steps.first?.title == "这是什么")
    assert(back[0].tutorLog[0].usedVision)

    print("PASS: tutor log checks")
}
