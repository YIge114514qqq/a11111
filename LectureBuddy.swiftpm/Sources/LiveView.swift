import SwiftUI
import UIKit
import Foundation

struct LiveView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LessonStore
    @StateObject private var session = LiveSession()
    /// 端到端实时翻译（最快，直接出中文）
    @StateObject private var live = LiveTranslateSession()
    private var showingLive: Bool {
        !session.isRecording && (live.isRecording || live.isStarting || live.isStopping || !live.lines.isEmpty || live.savedAudioName != nil)
    }
    // 界面用的统一入口：端到端翻译优先，其次才是旧的「识别+翻译」
    private var isRecording: Bool { live.isRecording || live.isStarting || session.isRecording }
    private var lines: [CaptionLine] { showingLive ? live.lines : session.lines }
    private var elapsed: TimeInterval { showingLive ? live.elapsed : session.elapsed }
    /// 复制按钮要跟着当前引擎走，否则 DashScope 模式下复制到空字符串
    private func currentTranscript() -> String {
        showingLive ? live.transcriptForClipboard() : session.transcriptForClipboard()
    }
    /// 出错时优先显示端到端引擎的错误：
    /// 否则一 stop()，showingLive 变 false，刚拿到的 401/权限错误就被吞掉，
    /// 用户只看到「一秒就结束、什么都没说」。
    private var liveError: String? {
        if let e = live.errorMessage, !e.isEmpty { return e }
        if live.isRecording || !live.lines.isEmpty { return nil }
        return session.errorMessage
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showSettingsAlert = false
    @State private var finishedLesson: Lesson?
    @State private var showLarge = false
    @State private var savedLiveSessionID: UUID?

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
                            Label(isRecording ? "结束" : "开始",
                                  systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(isRecording ? Color.red : Color.indigo)
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showLarge = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .disabled(lines.isEmpty)
                    }
                }
                .alert("先配置 AI 接口", isPresented: $showSettingsAlert) {
                    Button("知道了", role: .cancel) { }
                } message: {
                    Text("实时字幕只需要填 DashScope Key；课后笔记和提问才需要另一个大模型 Key。去设置里填一下。")
                }
                // 仅用于自动化冒烟测试：模拟器带 -autostart YES 启动时，自己点一次开始
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-autostart") else { return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    toggleRecording()
                }
                .onReceive(live.$completion) { completion in
                    if let completion { saveLiveLesson(completion) }
                }
                .sheet(isPresented: $showLarge) {
                    LargeCaptionView(lines: lines)
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
        guard !live.isStopping else { return }
        if live.isRecording || live.isStarting {
            live.stop()
            return
        }
        if session.isRecording {
            let lesson = session.stop()
            finishedLesson = lesson
            store.save(lesson)
            return
        }
        guard settings.isConfigured else {
            showSettingsAlert = true
            return
        }
        if settings.useLiveTranslate {
            Task { await live.start() }
        } else {
            Task { await session.start(settings: settings) }
        }
    }

    /// 把端到端翻译的结果存成一节课
    private func saveLiveLesson(_ completion: LiveTranslateSession.Completion) {
        guard savedLiveSessionID != completion.id else { return }
        savedLiveSessionID = completion.id
        // 连不上服务器（401/断网）时只有几秒空录音，没有任何字幕：
        // 这种不该在课程列表里多出一条空课，也应该把没人用的录音删掉。
        guard !completion.lines.isEmpty || completion.audioFileName != nil else { return }
        guard !completion.lines.isEmpty else {
            if let name = completion.audioFileName {
                try? FileManager.default.removeItem(at: store.audioURL(named: name))
            }
            return
        }
        var lesson = Lesson(
            title: defaultLessonTitle(),
            duration: completion.duration,
            lines: completion.lines
        )
        lesson.audioFileName = completion.audioFileName
        lesson.sourceLanguage = settings.sourceLanguage
        lesson.targetLanguage = settings.targetLanguage
        if live.errorMessage == nil { finishedLesson = lesson }
        store.save(lesson)
    }

    private func defaultLessonTitle() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm 的课"
        return fmt.string(from: Date())
    }
    private var captionColumn: some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(lines) { line in
                                CaptionText(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let error = liveError {
                // 错误会一直留着直到用户看过，避免“秒退但不知道为啥”
                banner(error, icon: "exclamationmark.triangle.fill", color: .orange)
                    .overlay(alignment: .trailing) {
                        Button {
                            live.clearError()
                            session.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                    }
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
                Text(isRecording ? "正在听课" : "待机")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                // 录音时写出实际进度：连不上、没权限时一眼能看出卡在哪步
                if isRecording, showingLive, !live.status.isEmpty {
                    // 带上已采集的音频量：一直为 0 就说明麦克风没出声（格式/会话问题）
                    Text(live.audioBytes > 0
                         ? "\(live.status) · 音频 \(live.audioBytes / 1024) KB"
                         : live.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(timeString(elapsed))
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
                    UIPasteboard.general.string = currentTranscript()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(lines.isEmpty)
            }
        }
    }

    private var regularControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isRecording ? "正在听课" : "待机")
                    .font(.headline)
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                Text(timeString(elapsed))
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
                if let last = lines.last, let translation = last.translation {
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
                    UIPasteboard.general.string = currentTranscript()
                } label: {
                    Label("复制双语转写", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(lines.isEmpty)
            }
            .padding(.bottom, 16)
        }
    }

    private var primaryButton: some View {
        Button {
            toggleRecording()
        } label: {
            // 用 isRecording（含实时翻译模式），不能只看 session.isRecording：
            // 否则 DashScope 在录时按钮还写「开始记录」，用户会以为没开始，再点一下就结束了。
            if live.isStopping {
                // 停止后会等最多 2 秒收尾，让最后一句字幕能回来。
                // 这期间按钮不能装作可以点，否则用户会以为死机了。
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在收尾…")
                }
                .frame(maxWidth: .infinity)
            } else if isRecording {
                Label(showingLive ? "结束录音" : "结束并整理笔记", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            } else {
                Label("开始记录", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? Color.red : Color.indigo)
        .disabled(live.isStopping)
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
    let lines: [CaptionLine]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(lines.suffix(40)) { line in
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
                .onChange(of: lines.count) { _, _ in
                        if let last = lines.last {
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