# ImmersiveTranslator

ImmersiveTranslator 是一个 macOS 原生菜单栏翻译工具。它想解决的不是“再做一个网页翻译入口”，而是让 Mac 上的选中文本翻译、截图 OCR 翻译和沉浸式阅读浮窗更顺手。

项目目前处在 MVP 阶段：核心链路已经可用，但交互、OCR 体验和正式分发还在持续打磨。

## 当前能力

- 菜单栏 App：启动后菜单栏显示 `译`。
- 选中文本翻译：默认快捷键 `Option + Space`。
- 截图 OCR 翻译：默认快捷键 `Control + Option + Space`，框选屏幕区域后使用 Apple Vision 本机 OCR，并在翻译前提供轻量文本确认。
- 沉浸式翻译浮窗：支持复制、重新翻译、固定、自动隐藏、收藏、查看历史、OCR 原文确认和耗时展示。
- 流式翻译：接口支持时可以边生成边显示译文。
- 中英互译：中文自动翻成英文，非中文自动翻成简体中文。
- 固定目标语言：也可以指定始终翻译成某一种语言。
- 历史与收藏：本地保存，支持搜索、复制、删除和清空非收藏记录。
- OCR 设置：支持准确/快速模式，以及混合、中英、英文、日文、韩文识别语言预设。
- 快捷键预设：可以在设置里切换常用快捷键组合，减少和系统/输入法冲突。
- API Key 安全存储：API Key 保存在 macOS Keychain。
- OpenAI 兼容接口：支持 OpenAI Chat Completions 兼容服务，并对 DeepSeek、智谱 GLM 做了关闭思考模式的兼容处理。

## 系统要求

- macOS 13.0 或更高版本
- Swift 5.9 或更高版本
- 一个 OpenAI Chat Completions 兼容接口的 API Key

## 快速开始

从源码运行：

```bash
git clone https://github.com/kobejiasuoer/immersive-translator-macos.git
cd immersive-translator-macos
swift run ImmersiveTranslator
```

打包成 macOS App：

```bash
./scripts/build_app.sh
open dist/ImmersiveTranslator.app
```

首次打包前建议先按下文“本地开发签名”创建固定的本地 Code Signing 证书，避免反复重新授权辅助功能和屏幕录制。

安装到应用程序目录：

```bash
ditto dist/ImmersiveTranslator.app /Applications/ImmersiveTranslator.app
open /Applications/ImmersiveTranslator.app
```

## 下载

可以从 GitHub Releases 下载预构建版本：

```text
https://github.com/kobejiasuoer/immersive-translator-macos/releases
```

当前 release 仍是开发构建，尚未使用 Apple Developer ID 正式签名和公证。macOS 可能会提示“无法验证开发者”，需要在“系统设置 -> 隐私与安全性”里手动允许打开。开发者更推荐从源码构建运行。

## 使用方式

启动 App 后，它会以菜单栏工具的形式运行，不会出现在 Dock 里。点击菜单栏的 `译` 可以打开设置、历史、权限检查或退出 App。

首次使用建议先完成三件事：

1. 打开 `译 -> 设置...`，填入 API Key、接口地址和模型。
2. 授权 `辅助功能`，用于在触发选中文本翻译时临时发送 `Command + C` 读取当前选区。
3. 授权 `屏幕录制`，用于截图 OCR 翻译时截取你框选的屏幕区域。

默认快捷键：

- `Option + Space`：翻译当前选中的文本。
- `Control + Option + Space`：框选屏幕区域，先确认或修正 OCR 原文，再发送翻译。

截图 OCR 的当前流程：

1. 按下 OCR 快捷键后框选屏幕区域。
2. App 先在本机完成 OCR，并弹出原文预览。
3. 你可以直接修正文案、复制原文，或重新框选。
4. 点击“确认翻译”后，才会把文本发送给翻译接口。

常用设置：

- `翻译方向`：选择 `中英互译` 或 `固定目标语言`。
- `流式显示译文`：开启后接口支持时会边生成边展示。
- `OCR 识别模式`：准确模式更稳，快速模式更快。
- `OCR 识别语言`：语言越少通常越快、误识别越少。
- `快捷键`：选择预设快捷键组合。

## 接口配置

默认接口：

```text
https://api.openai.com/v1/chat/completions
```

默认模型：

```text
gpt-4o-mini
```

设置窗口内置了常用配置按钮：

- `DeepSeek 快速`：`https://api.deepseek.com/chat/completions` + `deepseek-chat`
- `DeepSeek V4 Flash`：`https://api.deepseek.com/chat/completions` + `deepseek-v4-flash`
- `OpenAI Mini`：`https://api.openai.com/v1/chat/completions` + `gpt-4o-mini`

如果你使用的是其它 OpenAI Chat Completions 兼容服务，只要填入对应接口地址、模型名和 API Key 即可。

## 隐私说明

- API Key 只写入 macOS Keychain，不写入仓库、日志或历史文件。
- 选中文本翻译会临时触发 `Command + C`，读取后恢复原剪贴板。
- OCR 使用本机 Apple Vision；截图不会发送给翻译服务。
- 翻译请求只发送待翻译文本、目标语言和模型配置。
- 翻译历史保存在本机 Application Support 目录。
- 诊断日志不记录 API Key。

本地数据路径：

```text
~/Library/Application Support/ImmersiveTranslator/
```

诊断日志路径：

```text
~/Library/Application Support/ImmersiveTranslator/diagnostic.log
```

## 已知限制

- 选中文本翻译依赖模拟 `Command + C`，因此需要辅助功能权限；某些 App 的自定义文本区域可能无法稳定读取。
- 截图 OCR 依赖 Apple Vision，识别质量会受字号、清晰度、背景干扰和语言设置影响。
- OCR 已有轻量识别确认流程；段落合并、跨栏识别和更精细的框选辅助仍在打磨。
- 快捷键目前是预设组合，还不是完整的快捷键录制器。
- 当前 release 未正式签名和公证，分发体验还不够好。
- 暂无自动更新机制。

## 待开发路线

优先级最高的是把日常使用体验从“能用”推进到“顺手”：

- OCR 确认增强：继续优化识别文本预览、空结果处理、键盘操作和多屏幕细节。
- OCR 段落优化：更好地合并多行文本、保留段落、减少跨栏/跨区域误合并。
- OCR 交互优化：优化框选遮罩、放大镜、边缘吸附、选区尺寸提示和多屏幕体验。
- 流式翻译体验：更早显示首字、减少等待感，并在慢请求时给出明确状态。
- 错误提示增强：区分 API Key、模型名、接口地址、余额/限流、权限和网络问题。
- 快捷键自定义：支持真实录制快捷键，并提示冲突。
- Provider 预设：补充更多服务商预设、模型说明和延迟诊断。
- 术语表/自定义提示词：支持用户维护本地词库、固定翻译风格和专有名词。
- 历史导出：支持导出历史和收藏。
- 正式分发：Developer ID 签名、公证、发布包校验和自动更新。

## 项目结构

- `Sources/ImmersiveTranslator/App.swift`：应用入口、菜单栏、热键动作、设置/历史/引导串联。
- `Sources/ImmersiveTranslator/HotKeyManager.swift`：使用 Carbon 注册全局快捷键。
- `Sources/ImmersiveTranslator/ClipboardReader.swift`：读取当前选中文本并恢复剪贴板。
- `Sources/ImmersiveTranslator/ScreenSelection.swift`：跨屏幕截图 OCR 框选遮罩和 Retina 坐标截图。
- `Sources/ImmersiveTranslator/OCRReader.swift`：使用 Apple Vision 做本机 OCR，并合并多行/多段识别结果。
- `Sources/ImmersiveTranslator/TranslationClient.swift`：调用 OpenAI Chat Completions 兼容接口，并处理流式输出与部分 provider 兼容项。
- `Sources/ImmersiveTranslator/TranslationPanel.swift`：翻译浮窗、OCR 原文确认、复制、重试、收藏、历史入口。
- `Sources/ImmersiveTranslator/TranslationHistoryStore.swift`：本地历史和收藏 JSON 存储。
- `Sources/ImmersiveTranslator/Settings.swift`：设置窗口和本地偏好。
- `Sources/ImmersiveTranslator/KeychainStore.swift`：API Key 的 Keychain 读写。
- `Sources/ImmersiveTranslator/Onboarding.swift`：首次启动引导。
- `Sources/ImmersiveTranslator/Permissions.swift`：辅助功能、屏幕录制权限检查和系统设置跳转。
- `scripts/build_app.sh`：构建 `dist/ImmersiveTranslator.app`。
- `scripts/package_release.sh`：生成 release zip 和 sha256。

## 构建与发布

普通构建：

```bash
swift build
```

Release App 构建：

```bash
./scripts/build_app.sh
```

生成 release zip：

```bash
./scripts/package_release.sh 0.1.0
```

### 本地开发签名

开发阶段如果每次重新打包后都需要重新授权辅助功能或屏幕录制，通常是因为 App 使用了 ad-hoc 签名。macOS 会把每次重新打包后的二进制当成新的代码身份。

`./scripts/build_app.sh` 默认会自动查找名为 `ImmersiveTranslator Local Dev` 的固定本地 Code Signing identity。找到后会直接复用；找不到时脚本会停止并给出提示，不再默认退回到 ad-hoc 签名。

可以在“钥匙串访问 -> 证书助理 -> 创建证书...”里创建一个本地自签名证书：

- 名称：`ImmersiveTranslator Local Dev`
- 身份类型：`自签名根证书`
- 证书类型：`代码签名`

创建后验证并构建：

```bash
security find-identity -v -p codesigning
./scripts/build_app.sh
codesign -dv --verbose=4 dist/ImmersiveTranslator.app 2>&1 | grep -E 'Authority|Signature'
```

如果你想使用其它稳定证书，可以显式指定：

```bash
CODESIGN_IDENTITY="Your Code Signing Identity" ./scripts/build_app.sh
```

只有在一次性构建或 release 打包确实可以接受权限重新授权风险时，才显式允许 ad-hoc：

```bash
ALLOW_ADHOC_CODESIGN=1 ./scripts/build_app.sh
```

`./scripts/package_release.sh` 在没有传入 `CODESIGN_IDENTITY` 时会显式使用 ad-hoc 签名，保持当前开发 release 的打包路径可用。正式分发需要 Apple Developer ID 证书和 notarytool 公证；如果要用正式证书打包，可以传入 `CODESIGN_IDENTITY`。

## 贡献

欢迎提交 issue 和 pull request。这个项目会优先保持简单、原生、可读，不会为了功能堆叠引入复杂依赖。

比较适合优先贡献的方向：

- OCR 体验和识别后处理
- 浮窗交互
- 错误提示和诊断
- 快捷键自定义
- Provider 预设
- 文档、截图和演示视频

## License

MIT
