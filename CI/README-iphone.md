# 在 iPhone 16 Pro Max 上安装（iOS 18.7.8）

## 为什么不走 Swift Playgrounds

**Swift Playgrounds 只支持 iPad 和 Mac，iPhone 装不了。**
所以 iPhone 必须走「云端编译出 ipa → 用 Sideloadly 装进手机」这条路。

好消息：**不需要 $99 开发者账号，用免费 Apple ID 就行。**

---

## 你需要准备

| 项目 | 说明 |
|---|---|
| Windows 电脑 | 你现在这台 |
| iPhone + 数据线 | iPhone 16 Pro Max / iOS 18.7.8 ✅ 满足 iOS 17+ 要求 |
| Apple ID | 免费账号即可 |
| GitHub 账号 | 免费 |
| iTunes | 官网 Windows 版，让电脑识别 iPhone |
| Sideloadly | https://sideloadly.io 免费下载 |

---

## 第一步：把代码推到 GitHub

项目本地仓库已经初始化好（4 次提交）。在项目文件夹里执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\push.ps1 https://github.com/你的用户名/lecturebuddy.git
```

先去 https://github.com/new 建一个空仓库（**不要**勾 README/.gitignore/license）。

---

## 第二步：让 GitHub 编译

1. 打开仓库 → **Actions** 标签
2. 左边选 **Build unsigned IPA** → 右边 **Run workflow**
3. 等 5–15 分钟
4. 点进这次运行 → 页面底部 **Artifacts** → 下载 `LectureBuddy-unsigned-ipa`
5. 解压得到 `LectureBuddy-unsigned.ipa`

> 如果编译失败，把失败那一步的日志发我。

---

## 第三步：装到 iPhone

1. 装 **iTunes**（让 Windows 能识别 iPhone）
2. 装 **Sideloadly**
3. iPhone 用线连电脑，手机上点「信任此电脑」
4. 打开 Sideloadly：
   - 把 `.ipa` 拖进去
   - 填你的 Apple ID
   - 点 **Start**
   - 开了双重认证的账号，要用 **App 专用密码**（appleid.apple.com 生成），不是登录密码
5. 手机上：**设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书**
6. 桌面出现 LectureBuddy，点开

---

## 首次打开要做的事

进「设置」页，从上到下填：

**第一个区块「实时语音翻译」**（最重要，决定能不能用）

| 字段 | 填什么 |
|---|---|
| DashScope API Key | `sk-ws-...` 开头那串 |
| 业务空间地址 | `https://dashscope.aliyuncs.com/api/v1` |
| 模型 | `qwen3.5-livetranslate-flash-realtime` |
| 同时保存课堂录音 | 打开 |

**第二个区块「今天上什么课」**

填一句今天的内容，例如：

```
宏观经济学 货币政策与利率
```

点「根据主题自动生成术语表」，等十几秒。
会生成几十条**韩语→中文**的专业术语，翻译专业词会准很多。

**第三个区块「AI 接口」**（课后笔记和提问用）

填一个 OpenAI 兼容的服务：DeepSeek、通义千问都行。
这个和上面那个 DashScope 是**两套不同的 Key**，别填混了。

---

## 开始听课

回「听课」页，点右上角「开始」。

- 屏幕上：**韩语原文（小字）+ 中文译文（大字）**
- 说完一句话，中文 0.1–0.2 秒后出现
- 右上角「结束」→ 自动保存 + 生成笔记
- 录音存成 WAV，课程详情里能回放

---

## 免费账号的硬性限制（苹果规定）

| 限制 | 说明 |
|---|---|
| **7 天过期** | 到期 App 打不开，用 Sideloadly 重装一次即可（ipa 留着，不用重新编译） |
| 最多 3 个自签 App | 同时装的其他自签 App 也算 |
| 证书过期 | 同上，重装解决 |

想长期免重装，只有买 $99/年开发者账号。

---

## 关于 xtool

你之前问的 xtool 也能装 iPhone，但**对现在没必要**：

| | Sideloadly（现在这条路） | xtool |
|---|---|---|
| 编译在哪 | GitHub 云端 Mac | 你电脑的 WSL2 |
| 需要下载 | 无 | WSL2 + Swift + **Xcode.xip 约 8GB** |
| 主要障碍 | 无 | **WSL 的 USB 透传，社区公认最难** |
| 产出 | ipa | ipa（一样） |

**两者产出的 ipa 完全一样。** xtool 的价值是「不用云、可以离线、迭代快」，等你需要一天装十几次调试时再上。

---

## 和安卓版的对照

| 功能 | 安卓（已实测） | iPhone（待验证） |
|---|---|---|
| 端到端实时翻译 | ✅ 113–187ms | 已写，待编译 |
| 双语字幕 | ✅ | 已写 |
| 边录边译 + WAV | ✅ 文件头已校验 | 已写 |
| 术语表 + 主题生成 | ✅ 35 条 | 已写 |
| 课后笔记/复习卡 | ✅ | 原有功能 |
| 提问举例讲懂 | ✅ 五段式 | 提示词已同步 |

---

## 我已经修掉的问题（针对 iPhone）

1. **`CI/Info.plist` 缺失** —— workflow 里 `GENERATE_INFOPLIST_FILE: NO`，但 plist 文件从来不存在，云端编译必定失败。已补。
2. **WebSocket 递归接收** —— 原来递归调用 `receive`，长会话会堆栈溢出。改成了 `async while` 循环。
3. **录音线程竞态** —— 音频回调在后台线程写文件，`stop()` 在主线程回填 WAV 头，两边抢同一个 FileHandle。已加串行队列。
4. **双语字幕重复** —— 端到端翻译拿不到原语原文时，原文列和译文一样，已改成不重复显示。