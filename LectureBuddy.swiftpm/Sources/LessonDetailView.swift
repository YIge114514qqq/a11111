import SwiftUI
import UIKit
import AVFoundation

struct LessonDetailView: View {
    let lessonID: UUID
    var showsCloseButton: Bool = false

    @EnvironmentObject var store: LessonStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Int = 0
    @State private var generating = false
    @State private var generateError: String?
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @State private var revealAnswers = false
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var shareAudioURL: URL?
    @State private var shareError: String?

    private var lesson: Lesson? {
        store.lessons.first { $0.id == lessonID }
    }

    var body: some View {
        Group {
            if let lesson {
                content(lesson)
            } else {
                Text("课程已删除").foregroundStyle(.secondary)
            }
        }
    }

    private func content(_ lesson: Lesson) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("笔记").tag(0)
                Text("转写").tag(1)
                Text("练习").tag(2)
                Text("复习卡").tag(3)
                Text("提问").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            if let error = generateError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.pink)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            Group {
                switch tab {
                case 0: notesTab(lesson)
                case 1: transcriptTab(lesson)
                case 2: practiceTab(lesson)
                case 3: cardsTab(lesson)
                default: askTab(lesson)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("无法导出", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } })) {
            Button("好") { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
        .sheet(item: Binding(
            get: { shareAudioURL.map(ShareFile.init) },
            set: { if $0 == nil { shareAudioURL = nil } })) { file in
            ShareSheet(items: [file.url])
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                menu(for: lesson)
            }
        }
        .task {
            // 下课后第一次打开时自动整理笔记，只跑一次
            guard lesson.notes == nil, !lesson.lines.isEmpty, settings.hasAIConfiguration else { return }
            await generate(for: lesson)
        }
    }
    private func menu(for lesson: Lesson) -> some View {
        Menu {
            Button {
                UIPasteboard.general.string = lesson.transcriptText
            } label: {
                Label("复制转写", systemImage: "doc.on.doc")
            }
            if let notes = lesson.notes {
                Button {
                    UIPasteboard.general.string = Self.notesPlainText(notes)
                } label: {
                    Label("复制笔记", systemImage: "text.alignleft")
                }
            }
            Button {
                Task { await generate(for: lesson) }
            } label: {
                Label("重新生成笔记", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(generating || lesson.lines.isEmpty || !settings.hasAIConfiguration)
            Button {
                revealAnswers.toggle()
            } label: {
                Label(revealAnswers ? "隐藏答案" : "显示答案", systemImage: "eye")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - 笔记

    private func notesTab(_ lesson: Lesson) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if generating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在整理这节课的笔记").font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notes = lesson.notes {
                    if !notes.summary.isEmpty {
                        block(title: "一句话说清这节课") {
                            Text(notes.summary).font(.body)
                        }
                    }

                    // 第一层：先看懂骨架。默认展开，后面的细节默认收起。
                    if !notes.framework.isEmpty {
                        frameworkBlock(notes.framework)
                    }

                    // 第二层：再看细节，带上学生的疑问和例子
                    if !notes.knowledgePoints.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader("二、老师具体怎么讲",
                                          subtitle: "看懂框架后再看这里，对照老师原话")
                            ForEach(notes.knowledgePoints) { point in
                                knowledgeBlock(point)
                            }
                        }
                    }

                    // 第三层：自己动手，才能真吸收
                    if !notes.practice.isEmpty {
                        practiceSummary(notes.practice)
                    }

                    if !notes.sections.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(notes.sections) { section in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(section.title).font(.subheadline.bold())
                                        ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("•").foregroundStyle(.indigo)
                                                Text(point).font(.callout)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            sectionHeader("三、按课堂顺序的原始章节",
                                          subtitle: "想回到老师原话时看这里")
                        }
                    }

                    if notes.needsRefresh {
                        HStack(spacing: 8) {
                            Text("这节课的笔记是旧版本生成的，只有章节要点。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }

                    if !notes.cards.isEmpty {
                        Text("已生成 \(notes.cards.count) 张复习卡，去「复习卡」自测。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if !generating {
                    notesPlaceholder(lesson)
                }
            }
            .padding(20)
        }
    }

    private func notesPlaceholder(_ lesson: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这节还没生成笔记").font(.headline)
            Text("按转写内容整理出章节要点、术语和复习问题。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await generate(for: lesson) }
            } label: {
                Label("生成笔记", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(lesson.lines.isEmpty || !settings.hasAIConfiguration)
            if !settings.hasAIConfiguration {
                Text("先去设置里填 API Key").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
    private func generate(for lesson: Lesson) async {
        guard !generating, !lesson.lines.isEmpty, settings.hasAIConfiguration else { return }
        generating = true
        generateError = nil
        do {
            let service = AIService(settings: settings)
            let notes = try await service.generateNotes(
                transcript: lesson.transcriptText,
                language: settings.notesLanguage
            )
            var updated = lesson
            updated.notes = notes
            store.save(updated)
        } catch {
            generateError = friendlyErrorMessage(error)
        }
        generating = false
    }

    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.indigo)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 笔记的新结构

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).foregroundStyle(.indigo)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 第一层：大框架。先看到全貌，再往下看细节。
    private func frameworkBlock(_ framework: Framework) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("一、先看懂这节课的骨架", subtitle: "看完这一块，就能自己复述这节课在讲什么")

            if !framework.problem.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("这节课要解决的问题").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(framework.problem).font(.body)
                }
            }

            if !framework.bigPicture.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("主线").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(framework.bigPicture).font(.body)
                }
            }

            if !framework.flow.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("怎么一步步展开").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(framework.flow.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .frame(width: 22, height: 22)
                                .background(Color.indigo.opacity(0.25), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline.bold())
                                if !item.role.isEmpty {
                                    Text(item.role).font(.callout).foregroundStyle(.secondary)
                                }
                                if !item.keyPoints.isEmpty {
                                    Text(item.keyPoints.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 第二层：知识点 = 老师怎么讲 + 学生容易卡在哪 + 具体例子
    private func knowledgeBlock(_ point: KnowledgePoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(point.title).font(.subheadline.bold())
            if !point.detail.isEmpty {
                Text(point.detail).font(.callout).foregroundStyle(.secondary)
            }
            if !point.confusion.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.circle").font(.caption)
                    Text(point.confusion).font(.callout)
                }
                .foregroundStyle(.orange)
            }
            if !point.example.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("举个例子").font(.caption.bold()).foregroundStyle(.indigo)
                    Text(point.example).font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 第三层：练习入口，具体做题在「练习」页
    private func practiceSummary(_ practice: PracticeSet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("三、自己动手，才算真学会", subtitle: "先自己做，再对答案")
            Text("概念快测 \(practice.quickChecks.count) 题 · 综合题 \(practice.problems.count) 道")
                .font(.callout)
            Button {
                tab = 5
            } label: {
                Label("去做练习", systemImage: "pencil.and.list.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 转写

    private func transcriptTab(_ lesson: Lesson) -> some View {
        VStack(spacing: 0) {
            if let name = lesson.audioFileName {
                HStack(spacing: 12) {
                    Button {
                        toggleAudio(lesson: lesson, name: name)
                    } label: {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playing ? "正在回放课堂录音" : "回放课堂录音").font(.subheadline)
                        Text(timeString(lesson.duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 录音能直接导出去：发给同学、归档、或换机前存一份
                    Button {
                        shareAudio(named: name)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    .accessibilityLabel("导出课堂录音")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(lesson.lines) { line in
                        transcriptRow(line)
                    }
                }
                .padding(20)
            }
        }
    }

    private func transcriptRow(_ line: CaptionLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timeString(line.offset))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let t = line.translation, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 17, weight: .medium))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func toggleAudio(lesson: Lesson, name: String) {
        if playing {
            player?.pause()
            playing = false
            return
        }
        if player == nil {
            let url = store.audioURL(named: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        player?.play()
        playing = true
    }
    // MARK: - 练习

    private func practiceTab(_ lesson: Lesson) -> some View {
        Group {
            if let practice = lesson.notes?.practice, !practice.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("先自己做，再看答案").font(.headline)
                            Text("做错的题才是真正要回头再看笔记的地方。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }

                        if !practice.quickChecks.isEmpty {
                            exerciseGroup(title: "概念快测",
                                          subtitle: "看到题先在脑子里答一句，再展开",
                                          items: practice.quickChecks)
                        }
                        if !practice.problems.isEmpty {
                            exerciseGroup(title: "综合题",
                                          subtitle: "拿纸笔写，再对照答案和讲解",
                                          items: practice.problems)
                        }

                        if let glossary = lesson.notes?.glossary, !glossary.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("这节课的术语").font(.headline)
                                ForEach(glossary) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(item.term).font(.callout.bold())
                                        Text(item.explain).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                emptyHint(
                    "还没有练习题",
                    (lesson.notes?.needsRefresh ?? false)
                        ? "这节课的笔记是旧版本生成的，去笔记页点「重新生成笔记」就会有练习。"
                        : "先在笔记页生成笔记，会自动附上概念快测和综合题。"
                )
            }
        }
    }

    private func exerciseGroup(title: String, subtitle: String, items: [ExerciseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.indigo)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ExerciseCard(index: index + 1, item: item)
            }
        }
    }

    // MARK: - 复习卡

    private func cardsTab(_ lesson: Lesson) -> some View {
        Group {
            if let notes = lesson.notes, !notes.cards.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        Toggle("显示答案", isOn: $revealAnswers)
                            .padding(.horizontal, 4)
                        ForEach(notes.cards) { card in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(card.question).font(.headline)
                                if revealAnswers || card.answer.isEmpty {
                                    Text(card.answer.isEmpty ? "-" : card.answer)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("打开上面的开关看答案")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .padding(20)
                }
            } else {
                emptyHint("还没有复习卡", "先在笔记里生成笔记")
            }
        }
    }


    // MARK: - 提问

    private func askTab(_ lesson: Lesson) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if answer.isEmpty && !asking {
                        Text("问这节课的任何问题，比如「第三个定义是什么意思」或者「老师举的例子在说明什么」。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if asking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在结合这节课的内容回答").font(.footnote)
                        }
                    }
                    if !answer.isEmpty {
                        Text(answer)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("针对这节课提问", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    Task { await ask(lesson) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            .padding(16)
        }
    }

    private func ask(_ lesson: Lesson) async {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        asking = true
        answer = ""
        do {
            answer = try await AIService(settings: settings).ask(question: text, lesson: lesson)
        } catch {
            answer = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        asking = false
    }

    private func emptyHint(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func notesPlainText(_ notes: LessonNotes) -> String {
        var out = "概述\n" + notes.summary + "\n\n"
        for section in notes.sections {
            out += section.title + "\n"
            for point in section.points { out += "- " + point + "\n" }
            out += "\n"
        }
        if !notes.cards.isEmpty {
            out += "复习问题\n"
            for card in notes.cards {
                out += "问：" + card.question + "\n答：" + card.answer + "\n"
            }
            out += "\n"
        }
        if !notes.glossary.isEmpty {
            out += "术语\n"
            for item in notes.glossary {
                out += item.term + " - " + item.explain + "\n"
            }
        }
        return out
    }

    // MARK: - 导出录音

    private func shareAudio(named name: String) {
        let url = store.audioURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            shareError = "录音文件找不到了（换机或重装后旧录音不会跟过来）。"
            return
        }
        shareError = nil
        shareAudioURL = url
    }
}
/// 一道练习题：默认只给题，答案和讲解点开才看，逼学生先自己答
struct ExerciseCard: View {
    let index: Int
    let item: ExerciseItem
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index).")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(.indigo)
                Text(item.question).font(.body)
            }

            if revealed {
                if !item.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("答案").font(.caption.bold()).foregroundStyle(.green)
                        Text(item.answer).font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !item.explanation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("讲解").font(.caption.bold()).foregroundStyle(.orange)
                        Text(item.explanation).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.answer.isEmpty && item.explanation.isEmpty {
                    Text("这道题没有附答案，去「提问」页问这节课的助教。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { revealed.toggle() }
            } label: {
                Label(revealed ? "收起" : "看答案和讲解",
                      systemImage: revealed ? "chevron.up" : "chevron.down")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
