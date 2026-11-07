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
                Text("复习卡").tag(2)
                Text("术语").tag(3)
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
                case 2: cardsTab(lesson)
                case 3: glossaryTab(lesson)
                default: askTab(lesson)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
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
            guard lesson.notes == nil, !lesson.lines.isEmpty, settings.isConfigured else { return }
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
            .disabled(generating || lesson.lines.isEmpty)
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
                        block(title: "本节课概述") {
                            Text(notes.summary).font(.body)
                        }
                    }
                    ForEach(notes.sections) { section in
                        block(title: section.title) {
                            ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•").foregroundStyle(.indigo)
                                    Text(point).font(.body)
                                }
                            }
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
            .disabled(lesson.lines.isEmpty || !settings.isConfigured)
            if !settings.isConfigured {
                Text("先去设置里填 API Key").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
    private func generate(for lesson: Lesson) async {
        guard !generating, !lesson.lines.isEmpty else { return }
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
            generateError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func glossaryTab(_ lesson: Lesson) -> some View {
        Group {
            if let notes = lesson.notes, !notes.glossary.isEmpty {
                List(notes.glossary) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.term).font(.headline)
                        Text(item.explain).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.insetGrouped)
            } else {
                emptyHint("还没有术语表", "生成笔记后会自动提炼这节课的专业词")
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
}