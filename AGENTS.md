# 给 AI 助手的项目守则

这个文件会被自动读取。**开始工作前先读完。**

---

## 这是什么

iOS/iPadOS App **LectureBuddy**，给在韩国上学的中国留学生用：
韩语讲课实时翻中文字幕、自动生成结构化笔记、导入课件批注、圈选不懂的地方让 AI 讲解。

完整现状见 `HANDOFF.md`（先从头读完）。验证方式见 `VERIFY.md`。

**这个仓库里只有 iOS 项目是活的。** `android/`、`*.png`、`fix-*.bat`、`tools/`、
`platform-tools/`、`ui-preview/` 全是历史遗留，不要参考、不要改、不要清理。

---

## 一、代码在哪

真正要改的只有这里：

```
LectureBuddy.swiftpm/Sources/*.swift     16 个文件，约 5300 行
CI/Tests/*.swift                         纯逻辑测试
CI/Info.plist                            麦克风权限、文件共享
project.yml                              XcodeGen 配置
.github/workflows/build-ipa.yml          CI
```

---

## 二、怎么验证（唯一途径）

**本机没有 Swift，也装不了**——代码依赖 SwiftUI/UIKit/PencilKit/PDFKit/AVFoundation，
这些只有 macOS 才有。不要试着安装工具链，不要跑 `swiftc`。

流程：

```bash
# 1. 改完代码，提交推送
git add -A && git commit -m "说明改了什么"
git push origin main

# 2. 等 5-8 分钟，然后
./check-ci.sh
```

`check-ci.sh` 可以从任何目录运行，会自动读凭据、打印结果。

**通过的标准**，最后一行必须是 `>>> 通过`，且列出：

```
PASS: 65 model checks
PASS: tutor chain checks
PASS: tutor log checks
** BUILD SUCCEEDED **      ← 两次
PASS: plist 关键项齐全
```

失败时脚本会打印真实编译错误。改掉再推。

`>>> 被取消` 不是失败（CI 队列被打断），重推即可。

---

## 三、绝不许做的事

### 1. 不许简化宽容解码

`Models.swift` 里每个 `Codable` 结构都有手写的 `init(from:)`，逐字段
`decodeIfPresent` + 默认值。**这不是洁癖，是修过真实数据丢失事故的。**

Swift 自动合成的 Codable 不用属性默认值：少一个 key，整个 `[Lesson]` 数组解析失败，
用户所有课程永久丢失。历史上真实发生过。

加字段时照抄 `HANDOFF.md` 第 5 节的模板，并补一条"缺字段也能解码"的测试。

### 2. 不许删除与数据保存相关的逻辑

`LessonStore` 的 `loadedSuccessfully` 保护、每次写入前的 `lessons.backup.json` 备份、
`persist()` 在读取失败时拒绝写入——这些都在防丢数据。看不懂就问，不要删。

### 3. 不许一口气改多个文件然后说"应该没问题"

一次只做一件事。做完报告：改了什么、CI 结果、还有什么不确定。

### 4. 不许清理无关文件

`android/`、调试截图、旧脚本都是垃圾但不要动。要清理先问用户。

### 5. 不许 `git push --force`

---

## 四、这个目录现在归你

之前的助手（LynShen）已经完成交接，不再参与这个目录。**没人跟你抢文件**。

但仍要遵守：

- **开改前先 `git status`**，确认工作区干净。有未提交的改动，说明上一轮没收尾，先弄清楚再动。
- 不要 `git reset --hard`、不要 `git checkout .`、不要删掉你看不懂的文件。
- `git log` 里有历史，想不通为什么某行代码长那样，就去看引入它的那次提交。

交接文件（都是给你的，不要删）：

| 文件 | 作用 |
|---|---|
| `AGENTS.md` | 本文件，规矩 |
| `HANDOFF.md` | 项目全貌，12 节，权威 |
| `VERIFY.md` | 验证流程细节 |
| `check-ci.sh` | 一行命令看 CI 结果 |
| `HAND-TO-CODEX.txt` | 已经用过，历史存档，可不管 |

---

## 五、怎么汇报

用户不懂 Swift。每次汇报必须包含：

1. 改了哪个文件、为什么改（用中文说清原理，不要只贴代码）
2. `./check-ci.sh` 的原始输出
3. 哪些需要用户真机验证，**具体看什么**
4. 你还不确定的地方

不确定就说不确定，**不要编造测试结果**。

---

## 六、当前优先级

1. **课件批注可能丢最后一页**——只在翻页时保存，直接退出就没存
2. 视觉模型从没真跑过（没有 API Key，只验证了能编译）
3. 手指圈选的跟手程度，真机反馈还没回来

详细待办见 `HANDOFF.md` 第 10 节。想改优先级先提出来商量。
