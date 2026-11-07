# 在 iPad 上运行 LectureBuddy（不需要开发者账号）

## 为什么这条路可行

项目用的是 **App Playground** 格式（`Package.swift` 里是 `AppleProductTypes` + `.iOSApplication`）。
Swift Playgrounds 能直接把它编译成一个真正的 App 装到 iPad 上，**不需要 $99 开发者账号，不需要 Mac，不需要签名证书**。

## 你需要

- 一台 iPad（iPadOS 17 或更新）
- App Store 里免费下载的 **Swift Playgrounds**
- 一根能传文件的线，或者 iCloud 云盘 / 隔空投送

## 步骤

### 1. 把项目传到 iPad

任选一种：

- **iCloud 云盘**：把 `LectureBuddy.swiftpm` 整个文件夹放到 iCloud 云盘，在 iPad 的「文件」App 里能看到
- **隔空投送**：把文件夹压缩成 zip 后 AirDrop 过去，在 iPad 上解压
- **USB 线**：连上电脑，用「文件」App 拖进去

> 注意：要传**整个文件夹**，不能只传里面的 `Sources`。

### 2. 用 Swift Playgrounds 打开

在「文件」App 里点这个文件夹，选择「用 Swift Playgrounds 打开」。
第一次打开会花几十秒建索引。

### 3. 运行

点左上角的 **▶ 播放按钮**。
第一次会问你要麦克风权限，选「允许」。

### 4. 配置（只做一次）

进「设置」页，按顺序填：

| 项目 | 填什么 |
|---|---|
| DashScope API Key | 你的 `sk-ws-...` 开头那串 |
| 业务空间地址 | `https://dashscope.aliyuncs.com/api/v1` |
| 模型 | `qwen3.5-livetranslate-flash-realtime` |

再往下有「今天上什么课」，填一句今天的内容，比如：

```
宏观经济学 货币政策与利率
```

点「根据主题自动生成术语表」，等十几秒，会自动生成几十条韩语→中文的专业术语。
这一步能明显提升专业词的翻译准确率。

> 上面那个「AI 接口」区块是给课后笔记和提问用的，另填一个 OpenAI 兼容的 Key（DeepSeek、通义、Kimi 都行）。

### 5. 开始听课

回到「听课」页，点右上角的「开始」。

- 屏幕上会出现**韩语原文 + 中文译文**两行
- 说完一句话，中文大约 0.1–0.2 秒就出来
- 点右上角「结束」，会自动保存这节课，并生成笔记、复习卡、术语表
- 录音会自动存成 WAV，课程详情里能回放

## 如果编译报错

我没有 Mac/iPad，这份 Swift 代码是照着安卓真机验证过的逻辑写的，**没有实际编译过**。
第一次运行有报错很正常，把报错原文发我，我按行修。

常见报错和处理方向：

| 报错 | 原因 |
|---|---|
| `AVAudioApplication 不可用` | 需要 iOS 17+，或改用 `AVAudioSession.requestRecordPermission` |
| `@MainActor` 隔离报错 | 音频回调里访问了主线程属性，需要 `Task { @MainActor in ... }` |
| `URLSessionWebSocketTask` 相关 | 需要 `import Foundation`，检查闭包捕获 |
| `Cannot find 'X' in scope` | 文件没被算进 target，确认放在 `Sources/` 目录 |

## 和安卓版的差别

| 功能 | 安卓 | iPad |
|---|---|---|
| 端到端实时翻译 | ✅ 实测 | ✅ 已写，待编译验证 |
| 双语字幕 | ✅ 实测 | ✅ 已写 |
| 边录边译 + WAV | ✅ 实测文件头 | ✅ 已写 |
| 术语表 + 主题生成 | ✅ 实测 35 条 | ✅ 已写 |
| 课后笔记/复习卡 | ✅ 实测 | ✅ 原有功能 |
| 提问举例讲懂 | ✅ 实测五段式 | ✅ 提示词已同步 |