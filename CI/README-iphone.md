# 在 iPhone 上测试（没有 Mac、没有 iPad 也能做）

Swift Playgrounds 只支持 iPad 和 Mac，**iPhone 装不了它**。
但下面这条路线完全不需要 Mac，Windows 电脑 + iPhone 就能把 App 装到手机里。

---

## 你需要什么

- 一台 Windows 电脑（你现在用的这台就行）
- 你的 iPhone + 一根数据线
- 一个 Apple ID（普通的就行，**不用**付费开发者账号）
- 一个免费的 GitHub 账号

---

## 第一步：把代码传到 GitHub

1. 打开 https://github.com/new ，建一个空仓库，比如叫 `lecturebuddy`，**不要**勾选初始化 README。
2. 在项目文件夹里打开 PowerShell，依次执行（把地址换成你自己的）：

```powershell
cd "C:\Users\Administrator\Desktop\ai翻译"
git init
git add .
git commit -m "LectureBuddy first build"
git branch -M main
git remote add origin https://github.com/你的用户名/lecturebuddy.git
git push -u origin main
```

> 没有 git？先执行 `winget install --id Git.Git -e`，装完重开一个 PowerShell 窗口。

## 第二步：让 GitHub 帮你编译

1. 打开仓库页面 → **Actions** 标签。
2. 左边选 **Build unsigned IPA** → 右边点 **Run workflow** → 绿色按钮。
3. 等 5–10 分钟（第一次要下载工具链，久一点）。
4. 跑完后点进这次运行，页面最下方的 **Artifacts** 里下载 `LectureBuddy-unsigned-ipa`。
5. 解压出来是 `LectureBuddy-unsigned.ipa`。

> 编译失败的话，把报错日志发我，我改代码或配置。

## 第三步：装到 iPhone

1. 装 **iTunes**（Apple 官网的 Windows 版，装它是为了让电脑能识别 iPhone）。
2. 装 **Sideloadly**：https://sideloadly.io
3. iPhone 用数据线连电脑，手机上点「信任此电脑」。
4. 打开 Sideloadly：把 `.ipa` 拖进去 → 填你的 Apple ID → 点 **Start**。
   - 开了双重认证的账号，要用 App 专用密码（Apple ID 官网生成），不是登录密码。
5. 手机上：**设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书**。
6. 桌面出现 LectureBuddy，点开即可。

---

## 重要：免费账号的限制

- App 只能装 **7 天**，到期打不开，**重新用 Sideloadly 装一次**即可（代码不用重新编译，ipa 留着）。
- 最多同时 3 个自签 App。
- 这是苹果的规则，任何免 Mac 方案都一样。想长期用，只有两条路：
  - 花 688 元/年 买 Apple Developer Program → 签一次可用 1 年；
  - 或找一台 Mac，用 Xcode 免费账号装（同样 7 天）。

---

## iPhone 上和 iPad 上的区别

代码是同一套，iPhone 上会自动切成单列布局（竖屏字幕在上、控制栏在下）。
但课堂场景建议还是用 iPad 或者 iPhone 横向放在桌上，屏幕大字幕才看得清。

---

## 如果编译出错

常见原因只有两类：

1. **XcodeGen 找不到 `Sources`**：确认仓库里有 `LectureBuddy.swiftpm/Sources/*.swift`。
2. **Swift 并发报错**：`project.yml` 里已经设了 `SWIFT_STRICT_CONCURRENCY: minimal`，如果还报，
   说明本机代码有并发问题，把日志发我。