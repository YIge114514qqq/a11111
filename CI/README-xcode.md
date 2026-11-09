# 用 Xcode 打开 LectureBuddy（给开发者）

## 你需要

- 一台 Mac
- Xcode 15 或更新（iOS 17 SDK 以上）
- 真机调试的话，一个 Apple ID（免费账号即可，App 7 天过期）

## 两条路，选一条

### A. 直接开 Swift Playgrounds 工程（最快，1 分钟）

1. 双击 `LectureBuddy.swiftpm`，Xcode 会直接以 App Playground 方式打开。
2. 左上角选一个模拟器（例如 iPhone 16 Pro Max），按 ⌘R 运行。
3. 想上真机：选中这个 scheme，在 Signing & Capabilities 里选自己的 Apple ID 团队。

> 注意：`Package.swift` 里的 bundleIdentifier 是占位的
> `com.example.lecturebuddy`，真机安装前要改成你自己的，
> 否则会和别人装的版本冲突。

### B. 用 XcodeGen 生成标准 .xcodeproj（要上架/要配置签名时用）

```bash
brew install xcodegen
cd <项目根目录>
xcodegen generate          # 生成 LectureBuddy.xcodeproj
open LectureBuddy.xcodeproj
```

工程配置在 `project.yml` 里：

- Bundle ID: `com.lecturebuddy.app`
- Deployment Target: iOS 17.0
- Info.plist: `CI/Info.plist`（**不要换成 Xcode 自动生成**，否则
  `UILaunchScreen` 和麦克风权限说明会丢，表现为上下黑边 + 开始录音闪退）

真机运行前，在 Xcode 的 Signing & Capabilities 里：
- 勾上 Automatically manage signing
- Team 选你自己的 Apple ID
- 如果 Bundle ID 冲突，改成 `com.<你的名字>.lecturebuddy`

## 第一次运行要填的东西

App 不自带任何 Key，必须自己填。进「设置」页：

| 必填 | 说明 |
|---|---|
| **DashScope API Key** | 阿里云百炼控制台 → API-KEY 管理。这是实时字幕的 Key，**只填这一个就能用** |
| 业务空间地址 | 默认已填 `https://dashscope.aliyuncs.com/api/v1`，用官方账号不用改 |
| 模型 | 默认 `qwen3.5-livetranslate-flash-realtime`。必须先在百炼控制台**开通这个模型**，否则连上也会被拒 |

可选（只有生成课后笔记、术语表、问答题才需要）：

| 选填 | 说明 |
|---|---|
| Base URL / API Key / 模型名 | 任何 OpenAI 兼容接口都行（DeepSeek / 通义 / Kimi / 智谱 / OpenAI） |

填完先点「测试连接」，看到 `OK 连接正常` 就通了。

## 两个引擎的区别（重要）

代码里有两套实时字幕实现，按设置自动切换：

| 条件 | 走哪套 | 代码 |
|---|---|---|
| 填了 DashScope Key | 端到端语音翻译，说完直接出中文，**推荐** | `LiveTranslateSession.swift` |
| 只填了普通 AI Key | 本机 Speech 识别 + 批量调 AI 翻译，慢一些 | `LiveSession.swift` |

- `LiveTranslateSession`：WebSocket 直连阿里云，麦克风 → 16k PCM → 服务端。
- `LiveSession`：`SFSpeechRecognizer` 断句 → 攒几句一起翻。

## 常见问题

**连上就断、底部橙色条报 401 / InvalidApiKey**
Key 错了，或者 Key 和业务空间地址不是同一个区域的。

**报「这个业务空间没开通语音翻译模型」**
去百炼控制台开通 `qwen3.5-livetranslate-flash-realtime`。

**一直是「正在连接服务器…」**
检查网络。WebSocket 走 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`，
公司网络可能会拦 WebSocket。

**有原文但没有译文**
两套引擎都显示双语字幕。先查看界面错误及 Xcode 控制台，再检查模型权限、语言配置和网络；不能单凭转圈判断为术语表错误。

**模拟器上录不到声音**
云端运行器可能没有可用音频输入设备。`-10879` 或 `!dev` 日志本身不足以判定真机故障；需要检查实际采集数据。
模拟器用于 UI、网络失败分支等检查；持续录音、蓝牙、中断恢复必须真机验证。

## 代码结构

```
LectureBuddy.swiftpm/
├── Package.swift                 # App Playground 清单
└── Sources/
    ├── App.swift                 # 入口 + TabView + CaptionText
    ├── Models.swift              # Lesson / CaptionLine / 笔记解析
    ├── Store.swift               # AppSettings（UserDefaults）+ LessonStore（JSON 落盘）
    ├── AIService.swift           # OpenAI 兼容接口：翻译 / 笔记 / 术语表 / 提问
    ├── LiveTranslateSession.swift # 【主引擎】DashScope WebSocket + 音频采集
    ├── LiveSession.swift          # 【备用引擎】Speech 识别 + 批量翻译
    ├── LiveView.swift             # 听课页
    ├── LibraryView.swift          # 课程列表
    ├── LessonDetailView.swift     # 笔记 / 转写 / 复习卡 / 术语 / 提问
    └── SettingsView.swift         # 设置页
```

数据全部落在本地 Sandbox：`Documents/lessons.json` + 录音文件。
没有自建后端。DashScope 模式会把麦克风音频发送到阿里云；备用引擎可能使用 Apple 语音服务。翻译、笔记及问答会向配置的 AI 接口发送文字。

## 已知限制

- 录音只支持单声道 16kHz（云端识别要求）。
- 仅备用的 Apple Speech 引擎每 50 秒重新创建识别请求，切换时可能影响句尾；DashScope 不使用这个计时器。
- 上课中途改语言不会生效，要结束再重新开始。
- 免费 Apple ID 签名的 App 7 天后失效，需要重新装。
