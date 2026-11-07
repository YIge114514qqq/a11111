import SwiftUI

@main
struct LectureBuddyApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = LessonStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
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
            if settings.showSource {
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