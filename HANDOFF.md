# LectureBuddy 交接文档

给接手的人（Codex / GPT / 其他 AI 或开发者）看的现状说明。
最后更新：2026-11-20。

---

## 0. 仓库边界（最先读这段）

这个仓库里**只有 iOS 项目是活的**。其余都是历史遗留，不要参考、不要改：

| 路径 | 状态 |
|---|---|
| `LectureBuddy.swiftpm/` `CI/` `project.yml` `.github/` `HANDOFF.md` | ✅ 现在的项目，只改这些 |
| `android/` `build-apk.ps1` `dist/` | ❌ 早期尝试过的安卓版，已废弃 |
| `*.png` `*.jpg` `ui*.xml` `tmp-settings.pb` | ❌ 调试截图/临时文件，不是资产 |
| `fix-*.bat` `start-sideloadly-admin.bat` `push.ps1` | ❌ Windows 临时脚本，与代码无关 |
| `platform-tools/` `tools/` `ui-preview/` | ❌ 安卓工具链残留 |

想清理仓库的话**先问用户**，不要自作主张删。



---

## 1. 这是什么

一个 iOS/iPadOS 课堂 App，给**在韩国上学的中国留学生**用：

1. 上课时把韩国教授的韩语讲课**实时翻成中文字幕**
2. 课后自动生成**结构化笔记**（先框架后细节 + 练习）
3. 导入课件（PDF/图片），用 **Apple Pencil 或手指批注**
4. **圈选不懂的地方**，AI 给六步结构化讲解
5. 全部数据**本地存储**，不上传任何服务器

技术栈：SwiftUI + Swift 5.9，iOS 17+，无第三方依赖。

---

## 2. 仓库怎么跑

```
LectureBuddy.swiftpm/         Swift Package（可以直接用 Xcode 打开跑）
  Sources/                    16 个源文件，约 5300 行
CI/Info.plist                 真正的 Info.plist（project.yml 引用它）
CI/Tests/                     纯模型测试，用 swiftc 单独编译
project.yml                   XcodeGen 配置，用来出真机 ipa
.github/workflows/build-ipa.yml  云 Mac 构建：测试 + 双构建 + 冒烟 + 打包
```

两条构建路径：

- **Xcode 直接打开** `LectureBuddy.swiftpm` → 选自己 Team → 跑真机（**需要 Mac**）
- **CI**：push 到 main 自动跑，产出无签名 ipa（artifact 名 `unsigned-ipa`）

### ⚠️ 当前开发机是 Windows，没有 Swift

本机 `swiftc` / `swift` / `xcodebuild` **全部不存在**，而且**装不了能用的**——
代码依赖 SwiftUI/UIKit/PencilKit/PDFKit/AVFoundation，这些只在 macOS 上有。

**所以验证只能推到 GitHub 让云 Mac 跑。完整流程见 `VERIFY.md`。**
不要试图在本机装 Swift，也不要声称跑过测试（除非在 CI 日志里看到 `PASS:`）。

CI 里实际执行的测试命令（仅供了解；本机跑不了）：

```bash
swiftc LectureBuddy.swiftpm/Sources/Models.swift \
        LectureBuddy.swiftpm/Sources/NetworkErrorMessage.swift \
        LectureBuddy.swiftpm/Sources/TutorChain.swift \
        CI/Tests/tutor.swift \
        CI/Tests/main.swift -o build-tests/model-tests
```

注意：**测试只编译这三个源文件**。所以 `Models.swift` / `NetworkErrorMessage.swift` / `TutorChain.swift` **不能** import SwiftUI/UIKit，也不能引用 `AppSettings` 等 App 内类型。

---

## 3. 文件职责

| 文件 | 职责 | 别乱动的地方 |
|---|---|---|
| `Models.swift` | 所有数据模型 + 宽容解码 + 笔记 JSON 解析 | **每个 Codable 都必须手写 `init(from:)`**，见第 5 节 |
| `Store.swift` | `AppSettings`（UserDefaults）+ `LessonStore`（lessons.json） | 读失败时**禁止写回** |
| `AIService.swift` | OpenAI 兼容的文本模型客户端；翻译 / 笔记 / 提问 / 术语表 | 重试逻辑 |
| `VisionAIService.swift` | 能发图片的多模态客户端（qwen-vl 等） | 独立于 AppSettings，方便测试 |
| `TutorChain.swift` | 「讲解链」纯逻辑：决定该不该用视觉模型 + 六步 prompt + 解析回复 | **纯逻辑，不许引入 UIKit** |
| `CoursewareView.swift` | 课件阅读、导入、渲染、OCR、圈选→讲解 | 坐标换算，见第 6 节 |
| `PencilCanvasView.swift` | PDF 图层 + PencilKit 叠加、缩放对齐、手指圈选手势 | **画布与内容必须同尺寸同容器**，见第 6 节 |
| `TutorLogView.swift` | 回看历史讲解 | |
| `LiveTranslateSession.swift` | 阿里云 Qwen 实时翻译 WebSocket + 麦克风采集 + WAV 直写 | 会话生命周期，见第 7 节 |
| `LiveSession.swift` | 备用的另一条链路（系统语音识别 + 文本翻译） | |
| `LiveView.swift` / `LibraryView.swift` / `LessonDetailView.swift` / `SettingsView.swift` | 界面 | |
| `NetworkErrorMessage.swift` | 系统网络错误 → 中文人话 | 无依赖，可单测 |

---

## 4. 数据存在哪 & 为什么这样设计

全部在 App 沙盒 `Documents/`：

```
lessons.json               课程 + 转写 + 笔记 + 练习 + 讲解记录
lessons.backup.json        上一版自动备份（每次写入前生成）
LectureBuddy-backup.json   手动导出的备份
lesson-<日期> <标题>.wav    课堂录音
courseware-<UUID>.pdf      课件
tutor-<UUID>.jpg           圈选截图
```

`Info.plist` 开了 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
所以用户能在「文件」App 里直接看到并拷走这些文件。**CI 会检查这两个键**。

### 为什么这么在意「不丢数据」

这个 App 历史上真实发生过「更新 ipa 后以前的课全没了」。根因是：

```swift
// 旧代码（已修）
guard let saved = try? JSONDecoder().decode([Lesson].self, from: data) else {
    lessons = []      // 解析失败当成空库
    return
}
// 用户随便保存一次 → 空数组覆盖原文件 → 永久丢失
```

现在的三条防线：

1. **宽容解码**：每个模型逐字段 `decodeIfPresent` + 默认值
2. **读失败不写回**：`loadedSuccessfully == false` 时 `persist()` 直接 return
3. **自动备份**：每次写入前把旧文件复制成 `lessons.backup.json`

界面在 `loadError != nil` 时显示恢复指引，而不是假装空列表。

---

## 5. 【最重要】加字段时必须手写解码

Swift 自动合成的 `Codable` **不会用属性的默认值**。少一个 key，整个数组解析失败。

所以 `Models.swift` 里每个结构都长这样：

```swift
struct ExampleItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var detail: String = ""

    init() { title = "" }                       // 必须有：否则 memberwise 初始化器会消失

    init(title: String, detail: String = "") {  // 调用点用的便捷初始化器
        self.title = title
        self.detail = detail
    }

    init(from decoder: Decoder) throws {        // 必须有：逐字段宽容解码
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}
```

已这样处理的：`Lesson`、`CaptionLine`、`LessonNotes`、`Framework`、`FrameworkItem`、
`KnowledgePoint`、`PracticeSet`、`ExerciseItem`、`NoteSection`、`StudyCard`、
`GlossaryItem`、`TutorEntry`、`TutorStep`。

**新增模型时照抄这个模式**，并在 `CI/Tests/tutor.swift` 加一条「缺字段也能解码」的断言。

另一个坑：加了自定义 `init` 之后，`compactMap { item in ... }` 的类型推断会失败，
要写成 `compactMap { item -> SomeType? in ... }`。

---

## 6. 课件批注的对齐（最容易做崩的地方）

**问题**：PDF 和画布如果各自滚各自缩放，放大后笔迹就和文字错位。

**现在的解法**（`PencilCanvasView.swift`）：

- 只有一个 `UIScrollView` 负责缩放平移
- 里面一个固定尺寸容器（`595 × 842`，A4 比例）
- 页面 `UIImageView` 和 `PKCanvasView` 是**同尺寸的兄弟视图**
- 缩放时两者一起被 transform，物理上不可能错位

**渲染**：PDF 按 `canvasSize` 渲染成 2x 图片（不是按页面原始尺寸），
这样批注坐标系恒定，换设备也一致。裁剪圈选区域时记得乘 `pageImage.size.width / canvasSize.width`。

**圈选手势**（这里踩过两次坑）：

- ❌ 曾经在圈选模式 `drawingGestureRecognizer.isEnabled = false` → 什么也画不出来
- ❌ 只用 `.anyInput` 也不行，画布会吃掉所有手指触摸，选择框收不到
- ✅ 现在：圈选模式 `drawingPolicy = .pencilOnly`（手指穿透给选择框，笔仍可圈），
  选择框是自己的 `UIPanGestureRecognizer` 挂在 scroll 上，拖出虚线框，松手回调 canvas 坐标

系统 `PKToolPicker` 已隐藏（无笔的 iPad 上会悬在底部遮内容），App 有自己的工具条。

---

## 7. 实时翻译链路

`LiveTranslateSession.swift` 连接阿里云 Qwen 实时翻译（WebSocket）：

- 麦克风 → `AVAudioConverter` → **16kHz / 单声道 / int16 PCM** → base64 → WS
- 音频块合并成约 40ms 一帧再发（减少编码和主线程开销）
- `session.finish` 前先 flush 缓冲，否则最后几十毫秒丢失
- 会话结束时发布**不可变 `Completion`**；手动停、服务端报错、音频中断都会保存且只存一次
- 每条回调校验 `sessionID`，防止停止→立刻重开时旧回调污染新会话

`info.plist` 需要 `NSMicrophoneUsageDescription`，CI 会检查。

---

## 8. AI 讲解：a+b 混合（用户选定的方案）

```
圈选 → 裁图 → 设备端 OCR（Vision，免费）
                    ↓
        置信度 ≥ 0.75 且不像公式 → 文本模型（便宜）
        置信度低 或 像公式/图表 → 视觉模型（贵，准）
```

判定逻辑在 `TutorChain.shouldUseVision()`，阈值 0.75 是经验值。
`looksLikeFormulaOrDiagram()` 用符号密度和字母占比粗略判断。

两条路径共用一个六步 prompt：①这是什么 ②拆解 ③关联整节课主线 ④先直觉后严谨
⑤具体例子 ⑥一道检验理解的小题。prompt 里明确写死「看不清就说看不清，不要猜」。

视觉模型在设置里**单独配置**（默认指向阿里云兼容模式 `qwen-vl-max`），不填就不升级。

---

## 9. 当前状态

### 已验证（云 Mac，commit `2e169d1`）

```
PASS: 65 model checks
PASS:  tutor chain checks
PASS: tutor log checks
** BUILD SUCCEEDED **   真机
** BUILD SUCCEEDED **   模拟器
OK: plist 关键项齐全
```

### 【未验证】——模拟器做不到，只能真机

1. **圈选手感**：手指拖框是否跟手；缩放后圈的区域和内容是否对得上（最可能出问题）
2. **麦克风**：是否真的产出 16k PCM。看状态行的「音频 xxx KB」，为 0 就是采集没通
3. **真实 DashScope 长连接**：字幕滚动是否顺畅
4. **视觉模型**：一次都没跑过（没有 Key），只保证编译和请求体格式正确
5. **降噪开关**（`setVoiceProcessingEnabled`）实际效果
6. **录音导出**的文件名与分享面板

---

## 10. 待办清单

### 用户明确提过、还没做的

- [ ] **数据同步**：用户选了「本地优先」，iCloud（方案 B）和自建服务器（方案 C）**暂缓**。
      如果之后要做，记得课堂录音涉及教授内容，服务器方案要 HTTPS + 强鉴权。
- [ ] **翻译进一步优化**：已经重写过韩语提示词（敬语层级、省略主语、连接词、
      汉字词、指示词），但效果**未经真实课堂验证**。需要真机字幕样本再调。

### 我自己认为该做但没做的

- [ ] **数字笔迹的 `canvasViewDidEndUsingTool` 兜底路径**其实触发不到（圈选时
      `.pencilOnly` 下笔画仍会记录，但 UI 没提示）。要么保留要么删，现在是「能用但含糊」。
- [ ] **课件批注持久化**依赖翻页时 `saveCurrentDrawing`。如果用户直接退出不做翻页，
      最后一页的笔迹可能没存。应该在 `onDisappear` 也存一次。
- [ ] **`TutorChain.parse` 的六步拆分**只测了三种格式（①②③ / 数字编号 / 无格式），
      模型如果返回 markdown 表格会退化成单步。可以加强，但不要为它牺牲「绝不丢内容」。
- [ ] **`liveSession.swift` 那条备用链路**和主链路有重复代码，未来可以合并或删除。

### 已知的脆弱点

- 圈选坐标依赖 `container.bounds`，如果以后改成非固定尺寸画布，裁剪会偏
- `CoursewareView` 目前只支持单页批注的即时保存，多页之间靠翻页触发
- 视觉模型按图片计费，`jpegData(maxEdge: 1400)` 是一刀切，没有针对文字密度优化

---

## 11. 给接手者的建议

1. **先跑一遍 CI 的测试命令**，确认环境能编译。改动模型字段后必须重跑。
2. **不要简化宽容解码**。这不是防御性编程洁癖，是修过真实数据丢失事故的结果。
3. **改画布几何前先读第 6 节**。这里的每一行坐标换算都有原因。
4. **测试文件不能引用 App 内类型**（只编译三个源文件）。
5. 用户是留学生，不是开发者。报错信息一律写成中文、说清下一步该干什么。

---

## 12. 用户的关键决策记录

- 数据：**本地优先**，iCloud / 自建服务器暂缓
- AI 讲解：**a+b 混合**（文字优先，必要时升级视觉）
- 目标语言：中文；源语言主要是**韩语**
- 关于签名：用户用 Sideloadly 一类工具自签，**没有 $99 开发者账号**
