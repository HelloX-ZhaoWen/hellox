<p align="center">
  <img src="Packaging/AppIconSource.png" width="128" height="128" alt="HelloX 图标">
</p>

<h1 align="center">HelloX</h1>

<p align="center">
  原生、轻量的 macOS 截图与屏幕工具
</p>

HelloX 是一款原生 macOS 菜单栏应用，覆盖截图、滚动长截图、标注、文字识别、翻译和录屏等常用场景。应用基于 Swift 与系统框架构建，不包含账号、广告、分析或遥测 SDK。

## 主要功能

- 区域、窗口和全屏截图
- 手动滚动长截图与自动内容拼接
- 矩形、椭圆、箭头、画笔、文字、马赛克、裁剪和水印
- Vision OCR 与 macOS 系统离线翻译
- 可选的云端翻译服务
- 图片置顶与屏幕录制
- 自定义全局快捷键和常用文本工具

## 系统要求

- macOS 15 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

从 [GitHub Releases](https://github.com/HelloX/HelloX/releases) 下载最新 DMG，打开后运行其中的安装包。

首次使用相关功能时，macOS 可能请求以下权限：

- **屏幕录制**：读取用户选择的屏幕或窗口，用于截图和录屏。
- **辅助功能**：用于滚动长截图，以及在用户主动触发划词翻译时读取所选文字。
- **网络访问**：下载系统翻译语言资源，或访问用户主动配置的云端翻译服务。

## 隐私与数据

- 截图、标注、OCR 和系统离线翻译默认在本机完成。
- HelloX 不建立截图历史库；用户明确保存的文件由用户自行管理。
- 只有在用户配置并主动执行云端翻译时，待翻译文字才会发送给相应服务；截图像素不会发送。
- 划词翻译只在用户按下快捷键后运行，不会持续监听选区；密码框和安全输入不会读取。
- 云端服务配置保存在当前 macOS 用户的应用配置域中，不写入日志，但不具备钥匙串的独立加密保护。
- 应用不包含账号、广告、分析、云同步或遥测 SDK。

请勿向云端翻译服务提交密码、密钥、个人信息或其他敏感内容。第三方服务如何处理文本，以相应服务商的条款为准。

## 从源码构建

开发环境需要 macOS 15 SDK、Swift 6 和完整 Xcode 工具链。

```sh
git clone https://github.com/HelloX/HelloX.git
cd HelloX
swift build
Scripts/build-app.sh
open build/HelloX.app
```

`Scripts/build-app.sh` 会生成同时支持 Apple Silicon 和 Intel 的 `build/HelloX.app`。未配置开发者证书时使用 ad-hoc 签名，只适合本机开发和测试。

创建本地安装包：

```sh
Scripts/create-pkg.sh
Scripts/create-dmg.sh
```

正式发布需要 Developer ID Application 和 Developer ID Installer 证书，并通过 `Scripts/notarize.sh` 完成 Apple 公证。

## 目录结构

```text
HelloX/
├── Sources/
│   ├── HelloXApp/       # macOS 应用、界面与资源
│   └── HelloXCore/      # 截图、拼接、OCR、翻译等核心能力
├── Packaging/           # 图标、Info.plist、权限与安装包配置
├── Scripts/             # 构建、打包和公证脚本
├── Package.swift        # Swift Package 配置
└── LICENSE              # MIT License
```

## 参与项目

欢迎提交 Issue 和 Pull Request。提交前请确认：

- 不包含 API Key、证书、用户截图、日志或个人信息。
- 不包含 `.build/`、`build/`、DMG、PKG 或公证凭据。
- 涉及屏幕录制、辅助功能或全局快捷键的改动，已使用构建后的 `HelloX.app` 做真实权限与交互验证。

发现安全问题时，请使用 GitHub 的私密安全报告功能，不要在公开 Issue 中披露漏洞、密钥或用户数据。

## 开源许可

HelloX 源码采用 [MIT License](LICENSE)。`Sources/HelloXApp/Resources/Icons` 中的图标来自 [Lucide](https://lucide.dev/)，依据目录内的 [ISC License](Sources/HelloXApp/Resources/Icons/LICENSE) 使用。
