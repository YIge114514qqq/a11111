# LectureBuddy —— iPad 课堂实时翻译 + 笔记

对标 Coursedude 的课堂闭环：**实时双语字幕 → 课堂转写 → 结构化笔记 → 复习卡 → 针对这节课提问**。
原生 SwiftUI App，不是网页；不需要 Mac，也不需要 688 元的开发者账号。

## 怎么装到 iPad 上（约 3 分钟）

1. App Store 搜 **Swift Playgrounds**，免费装到 iPad（要 iPadOS 17 以上）。
2. 把这个文件夹里的 `LectureBuddy.swiftpm` 传到 iPad：
   - 用 iCloud 云盘 / 微信文件传输 / AirDrop 都行，只要 iPad 的「文件」App 能打开它。
3. 在 iPad「文件」里长按 `LectureBuddy.swiftpm` → 共享 → 用 **Swift Playgrounds** 打开。
4. 点左上角 **▶ 运行**，App 直接以全屏方式跑起来。
5. 想留在主屏上长期用：Swift Playgrounds 里点右上角「⋯」→ App 设置，或直接分享 → 添加到主屏幕。

> 也可以用 Mac 上的 Xcode 打开同一个工程，签上自己的 Apple ID 后装到真机 / 上架 App Store。
> 工程文件是标准的 `.swiftpm` 格式，Xcode 15+ 可直接打开。

## 只有 iPhone、没有 iPad 怎么办

Swift Playgrounds 只有 iPad 和 Mac 版，iPhone 用不了。
这时走 **GitHub 云端编译 + Sideloadly 签名安装**，全程不需要 Mac：
详见 [CI/README-iphone.md](CI/README-iphone.md)（Windows 电脑 + iPhone + 免费 Apple ID 即可，
代价是免费签名每 7 天要重装一次）。

## 第一次使用

1. 打开「设置」页，点一个常用服务（DeepSeek / 通义千问 / Kimi / 智谱 / OpenAI），再填自己的 **API Key**。
2. 点「测试连接」，看到 `OK 连接正常` 就通了。
3. 选「老师讲」的语言和「翻译成」的语言。
4. 回「听课」页，点右上角「开始」，把 iPad 放在桌上即可。

## 功能

- **实时双语字幕**：麦克风 → 语音识别（设备端优先，课堂内容尽量不离开设备）→ 断句 → 批量翻译。
- **全屏大字幕**：点左上角箭头，字放到 40pt，抬头就能看。
- **课堂录音**：同时存成本地 m4a，课后在「转写」页可以回放。
- **结构化笔记**：下课打开这节课，自动整理出概述、章节要点、术语表和 5-8 张复习问题。
- **复习卡 / 术语表**：考前自测用。
- **针对这节课提问**：答案只来自你自己的转写和笔记，不会瞎编。
- **本地保存**：所有课程存在 App 的 Documents 里，删 App 才删数据。

## 说明

- 语音识别用的是系统 `SFSpeechRecognizer`，部分语言需要联网，设备端支持的语言会自动离线跑。
- 翻译和笔记走 OpenAI 兼容的 `/chat/completions`，任何兼容服务都能用；只有文字会发出去，音频不出设备。
- 一门课大约消耗几千 token，按 DeepSeek 的价格不到一分钱。

## 目录

```
LectureBuddy.swiftpm/
├── Package.swift            # Swift Playgrounds / Xcode 工程描述，麦克风与语音识别权限在这里声明
└── Sources/
    ├── App.swift            # 入口、Tab 结构、字幕行视图
    ├── LiveView.swift       # 听课页：字幕流 + 控制栏 + 全屏大字幕
    ├── LiveSession.swift    # 录音、语音识别、断句、翻译调度
    ├── LessonDetailView.swift # 笔记 / 转写 / 复习卡 / 术语 / 提问
    ├── LibraryView.swift    # 课程列表与搜索
    ├── SettingsView.swift   # API、语言、笔记语言设置
    ├── AIService.swift      # OpenAI 兼容接口、翻译、笔记、问答
    ├── Models.swift         # 数据模型与句子切分
    └── Store.swift          # 设置持久化、课程本地存储
```