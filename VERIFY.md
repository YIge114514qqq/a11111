# 怎么验证（在 Windows 上）

## 结论先说

**这台机器上没有 Swift，也装不了能用的 Swift。**

- `swiftc` / `swift` / `xcodebuild` 全部不存在
- 别去装 Swift for Windows：它编译不了这个项目，因为代码用了 `SwiftUI`、`UIKit`、
  `PencilKit`、`PDFKit`、`AVFoundation` —— 这些框架**只有 macOS 上才有**
- 装上了也只会得到一堆 `no such module 'SwiftUI'`，浪费一两个小时

所以**不要试图在本机编译**。本机能做的只有：改代码、跑几何/逻辑的纸面推演、提交。

## 唯一的真实验证途径：推到 GitHub，让云 Mac 跑

仓库 `https://github.com/YIge114514qqq/a11111` 配了 GitHub Actions，
每次 push 到 `main` 都会在 **macos-15** 上自动跑完整流水线：

```
1. swiftc 编译 3 个纯逻辑文件 + 测试       ← 模型/解析逻辑对不对
2. xcodegen 生成 Xcode 工程
3. xcodebuild 真机构建                     ← 能不能编译整个 App
4. xcodebuild 模拟器构建
5. 模拟器冒烟启动                          ← 启动不崩
6. 校验 Info.plist 关键项                  ← 麦克风权限、文件共享
7. 打包无签名 ipa（artifact）
```

**这是唯一能证明"你改的东西能编译、逻辑测试还过"的手段。**

### 怎么触发

```bash
git add -A
git commit -m "……"
git push origin main
```

推送经常失败（网络），重试即可：

```bash
H=$(git rev-parse --short HEAD)
for i in $(seq 1 15); do
  git push origin main >/dev/null 2>&1
  R=$(git ls-remote origin main 2>/dev/null | cut -c1-7)
  [ "$R" = "$H" ] && { echo "pushed $H"; break; }
  sleep 12
done
```

### 怎么看结果

需要 GitHub token（向用户要，**不要写进任何文件，这个仓库是公开的**）：

```bash
export GH_TOKEN="<向用户要>"
gh run list  --repo YIge114514qqq/a11111 --limit 3
gh run watch --repo YIge114514qqq/a11111        # 实时跟
gh run view  --repo YIge114514qqq/a11111 --log   # 看全部日志
```

只看关键行：

```bash
gh run view --repo YIge114514qqq/a11111 --log \
  | grep -iE "PASS:|FAIL|BUILD SUCCEEDED|BUILD FAILED|error:|OK: plist"
```

### 什么算通过

必须**同时**看到这四类：

```
PASS: 65 model checks          ← 数字可能变了，但必须是 PASS 不是 FAIL
PASS:  tutor chain checks
PASS: tutor log checks
** BUILD SUCCEEDED **          ← 出现两次（真机 + 模拟器）
OK: plist 关键项齐全
```

少任何一条都算没通过，包括：
- job 状态 `cancelled`（队列被打断，**重跑**，不是失败）
- 日志拿不到（`BlobNotFound`，等几分钟再看）
- 只看到 `BUILD SUCCEEDED` 一次

### 收敛迭代

一次 CI 大约 5–11 分钟。所以：

1. **一次只改一个主题**，别攒一堆改动一起推
2. 本地能做的检查（括号配平、明显的类型问题、调用点是否都改了）先自己过一遍
3. 编译错误一次可能只暴露第一个，做好跑 2–3 轮的准备

## 绝对不要做的事

- ❌ 不要声称"测试通过"——除非你真的在日志里看到了 `PASS:`
- ❌ 不要为了让它编译过而删掉宽容解码、重试、会话校验
- ❌ 不要在没法验证的情况下一次改 5 个文件然后说"应该没问题"
- ❌ 不要 `git push --force`

## 没法在 CI 里验证的（只能用户真机装 ipa 试）

- 手指圈选跟不跟手、缩放后对不对得上
- 麦克风是否真产出 16k PCM
- 真实 DashScope 长连接的翻译效果
- 视觉模型（需要用户提供 Key）
- 降噪开关的实际听感
- 录音导出的文件名和分享面板

这些改动做完，**明确告诉用户"需要你在真机上试这一项，具体看什么"**，不要含糊过去。
