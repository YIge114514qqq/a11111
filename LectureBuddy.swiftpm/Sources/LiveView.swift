import SwiftUI
import UIKit

struct LiveView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LessonStore
    @StateObject private var session = LiveSession()

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showSettingsAlert = false
    @State private var finishedLesson: Lesson?
    @State private var showLarge = false

    var body: some View {
        NavigationStack {
            layout
                .navigationTitle("实时双语字幕")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            toggleRecording()
                        } label: {
                            Label(session.isRecording ? "结束" : "开始",
                                  systemImage: session.isRecording ? "stop.circle.fill" : "record.circle")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(session.isRecording ? Color.red : Color.indigo)
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showLarge = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(session.lines.isEmpty)
                    }
                }
                .alert("先配置 AI 接口", isPresented: $showSettingsAlert) {
                    Button("知道了", role: .cancel) { }
                } message: {
                    Text("翻译和笔记需要填一个大模型 API Key，去设置里填好就能开始。")
                }
                .sheet(isPresented: $showLarge) {
                    LargeCaptionView(session: session)
                }
                .sheet(item: $finishedLesson) { lesson in
                    NavigationStack {
                        LessonDetailView(lessonID: lesson.id, showsCloseButton: true)
                    }
                }
        }
    }

    @ViewBuilder
    private var layout: some View {
        if sizeClass == .compact {
            VStack(spacing: 0) {
                captionColumn
                Divider().overlay(Color.white.opacity(0.08))
                controlColumn(compact: true)
            }
        } else {
            HStack(spacing: 0) {
                captionColumn
                Divider().overlay(Color.white.opacity(0.08))
                controlColumn(compact: false)
                    .frame(width: 320)
            }
        }
    }

    private func toggleRecording() {
        if session.isRecording {
            let lesson = session.stop()
            finishedLesson = lesson
            store.save(lesson)
        } else {
            guard settings.isConfigured else {
                showSettingsAlert = true
                return
            }
            Task { await session.start(settings: settings) }
        }
    }
    private var captionColumn: some View {
        VStack(spacing: 0) {
            if session.lines.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(session.lines) { line in
                                CaptionText(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: session.lines.count) { _, _ in
                        if let last = session.lines.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let error = session.errorMessage {
                banner(error, icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if let error = session.translationError {
                banner("翻译没成功：" + error, icon: "bolt.slash.fill", color: .pink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("开始一节课")
                .font(.title2.bold())
            Text("点右上角开始，老师说的每句话会实时变成双语字幕。\n下课后自动生成转写、结构化笔记和复习卡片。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if !settings.isConfigured {
                Label("还没填 API Key，去设置里填一下", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    private func controlColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if compact {
                compactControls
            } else {
                regularControls
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, compact ? 10 : 0)
        .frame(maxHeight: compact ? nil : .infinity, alignment: .top)
        .background(Color.white.opacity(0.03))
    }

    private var compactControls: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(session.isRecording ? "正在听课" : "待机")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.isRecording ? Color.red : Color.secondary)
                Text(timeString(session.elapsed))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                if session.isTranslating {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                primaryButton
                Button {
                    UIPasteboard.general.string = session.transcriptForClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(session.lines.isEmpty)
            }
        }
    }

    private var regularControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.isRecording ? "正在听课" : "待机")
                    .font(.headline)
                    .foregroundStyle(session.isRecording ? Color.red : Color.secondary)
                Text(timeString(session.elapsed))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.top, 8)

            Label("\(settings.sourceTitle) 翻译成 \(settings.targetTitle)",
                  systemImage: "arrow.right")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if session.isTranslating {
                Label("翻译中", systemImage: "waveform.badge.mic")
                    .font(.footnote)
                    .foregroundStyle(.indigo)
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 10) {
                Text("最近一句").font(.caption).foregroundStyle(.secondary)
                if let last = session.lines.last, let translation = last.translation {
                    Text(translation)
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(6)
                } else {
                    Text("-").foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                primaryButton
                Button {
                    UIPasteboard.general.string = session.transcriptForClipboard()
                } label: {
                    Label("复制双语转写", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(session.lines.isEmpty)
            }
            .padding(.bottom, 16)
        }
    }

    private var primaryButton: some View {
        Button {
            toggleRecording()
        } label: {
            if session.isRecording {
                Label("结束并整理笔记", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            } else {
                Label("开始记录", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(session.isRecording ? Color.red : Color.indigo)
        .controlSize(.large)
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.12))
    }
}
/// 全屏大字幕：把 iPad 架在桌上，抬头就能看
struct LargeCaptionView: View {
    @ObservedObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(session.lines.suffix(40)) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                if let t = line.translation, !t.isEmpty {
                                    Text(t)
                                        .font(.system(size: 40, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                Text(line.text)
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .id(line.id)
                        }
                    }
                    .padding(28)
                }
                .onChange(of: session.lines.count) { _, _ in
                    if let last = session.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(20)
            }
        }
    }
}