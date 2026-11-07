import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showKey = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                apiSection
                languageSection
                notesSection
                aboutSection
            }
            .navigationTitle("设置")
        }
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