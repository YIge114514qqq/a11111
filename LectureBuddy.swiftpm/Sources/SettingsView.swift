import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: LessonStore
    @State private var showKey = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var buildingTerms = false
    @State private var termsError: String?
    @State private var showImporter = false
    @State private var shareURL: URL?
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                realtimeSection
                topicSection
                termsSection
                providerSection
                apiSection
                languageSection
                notesSection
                backupSection
                aboutSection
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(item: Binding(
                get: { shareURL.map(ShareFile.init) },
                set: { if $0 == nil { shareURL = nil } })) { file in
                ShareSheet(items: [file.url])
            }
        }
    }

    private var realtimeSection: some View {
        Section {
            TextField("DashScope API Key", text: $settings.dashscopeKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("业务空间地址", text: $settings.dashscopeURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("模型", text: $settings.asrModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("同时保存课堂录音", isOn: $settings.recordAudio)
            Toggle("降噪（教室噪声大时建议开）", isOn: $settings.noiseSuppression)
        } header: {
            Text("实时语音翻译（推荐）")
        } footer: {
            Text("语音直接翻成中文，说完立刻出字幕。地址填 https://dashscope.aliyuncs.com/api/v1")
        }
    }

    private var topicSection: some View {
        Section {
            TextField("例：公司法 股东会决议效力", text: $settings.courseTopic)
            Button {
                Task { await buildTerms() }
            } label: {
                HStack(spacing: 8) {
                    if buildingTerms { ProgressView().controlSize(.small) }
                    Text("根据主题自动生成术语表")
                }
            }
            .disabled(buildingTerms || settings.courseTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            if let termsError {
                Text(termsError).font(.footnote).foregroundStyle(.pink)
            }
        } header: {
            Text("今天上什么课")
        } footer: {
            Text("填一句今天的内容，会联网把这节课的专业术语整理成术语表。")
        }
    }

    private var termsSection: some View {
        Section {
            TextEditor(text: $settings.termsText)
                .frame(minHeight: 110)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("专业术语表")
        } footer: {
            Text("每行一条，写成 原文=译文。共 \(termCount) 条。")
        }
    }

    private var termCount: Int {
        settings.termsText.components(separatedBy: "\n").filter { $0.contains("=") }.count
    }

    private func buildTerms() async {
        buildingTerms = true
        termsError = nil
        do {
            let list = try await AIService(settings: settings).buildTermList(
                topic: settings.courseTopic,
                sourceLang: settings.sourceTitle,
                targetLang: settings.targetTitle
            )
            if list.isEmpty {
                termsError = "没搜到可用术语，换个说法再试一下。"
            } else {
                settings.termsText = list
            }
        } catch {
            termsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        buildingTerms = false
    }


    private var providerSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["DeepSeek", "通义千问", "Kimi", "智谱", "OpenAI"], id: \.self) { name in
                        Button(name) { settings.preset(name) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("一键填入常用服务")
        } footer: {
            Text("这些服务都兼容 OpenAI 格式，任何兼容的服务填地址和模型名也能用。")
        }
    }

    private var apiSection: some View {
        Section("AI 接口") {
            TextField("Base URL", text: $settings.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                if showKey {
                    TextField("API Key", text: $settings.apiKey)
                } else {
                    SecureField("API Key", text: $settings.apiKey)
                }
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("模型名，例如 deepseek-chat", text: $settings.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task { await test() }
            } label: {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Text("测试连接")
                }
            }
            .disabled(testing)

            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testResult.hasPrefix("OK") ? Color.green : Color.pink)
            }
        }
    }

    private var languageSection: some View {
        Section("上课语言") {
            Picker("老师讲", selection: $settings.sourceLanguage) {
                ForEach(LangOption.sources) { option in
                    Text(option.title).tag(option.id)
                }
            }
            Picker("翻译成", selection: $settings.targetLanguage) {
                ForEach(LangOption.targets) { option in
                    Text(option.title).tag(option.id)
                }
            }
            Toggle("字幕里同时显示原文", isOn: $settings.showSource)
        }
    }

    private var notesSection: some View {
        Section("笔记语言") {
            Picker("笔记和问题用", selection: $settings.notesLanguage) {
                ForEach(["简体中文", "繁體中文", "English", "日本語"], id: \.self) { language in
                    Text(language).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("导出全部课程备份", systemImage: "square.and.arrow.up")
            }
            .disabled(store.lessons.isEmpty)

            Button {
                showImporter = true
            } label: {
                Label("从备份文件导入", systemImage: "square.and.arrow.down")
            }

            if let backupMessage {
                Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("换新 IPA / 换机前先备份")
        } footer: {
            Text("换签名或重装不一定保留数据。先导出备份，装完再导入，按课程合并；录音不包含在 JSON 里。")
        }
    }

    private func exportBackup() {
        do {
            let url = try store.exportURL()
            shareURL = url
            backupMessage = "已生成备份文件，选择「存储到文件」保存即可。"
        } catch {
            backupMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try store.importLessons(from: url)
                backupMessage = "导入完成，共 \(store.lessons.count) 节课。"
            } catch {
                backupMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            backupMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("App", value: "LectureBuddy 1.0")
            LabeledContent("语音识别", value: "设备端优先")
            Text("录音、转写和笔记都保存在这台 iPad 上。只有翻译和生成笔记时，才会把文字发送到你填的那个 AI 服务。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func test() async {
        testing = true
        testResult = nil
        do {
            let service = AIService(settings: settings)
            let reply = try await service.complete(messages: [
                ChatMessage(role: "user", content: "只回复两个字：可用")
            ])
            testResult = "OK 连接正常：" + reply.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            testResult = "失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        testing = false
    }
}

/// 包一层，方便用 .sheet(item:) 弹出分享面板
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
