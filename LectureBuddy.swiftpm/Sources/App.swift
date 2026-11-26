import SwiftUI

@main
struct LectureBuddyApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = LessonStore()

    var body: some Scene {
        WindowGroup {
            initialView
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var initialView: some View {
        #if DEBUG
        // 模拟器回归测试直接打开预置课件，避免导航栏的可访问性差异影响圈选测试。
        if ProcessInfo.processInfo.arguments.contains("-test-courseware"),
           let lesson = store.lessons.first(where: { $0.title == "圈选回归课程" }) {
            NavigationStack { CoursewareView(lessonID: lesson.id) }
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("听课", systemImage: "waveform") }
            LibraryView()
                .tabItem { Label("课程", systemImage: "books.vertical") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(.indigo)
    }
}

/// 一条双语字幕
struct CaptionText: View {
    let line: CaptionLine
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 端到端翻译拿不到原语原文时，原文列会和译文一样，就不重复显示
            if settings.showSource, !line.text.isEmpty, line.text != line.translation {
                Text(line.text)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(.secondary)
            }
            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("翻译中").font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
