# ImmersiveTranslator

ImmersiveTranslator 是一个跨平台的沉浸式翻译工具，提供选中文本翻译和截图 OCR 翻译，让日常阅读和翻译更顺手。

## 平台

- **macOS**：原生 Swift 实现，菜单栏 App，详见 [`immersive-translator-mac/`](./immersive-translator-mac/README.md)
- **Windows**：Tauri + TypeScript 实现（开发中），详见 [`immersive-translator-windows/`](./immersive-translator-windows/README.md)

## 下载

前往 [Releases](https://github.com/kobejiasuoer/immersive-translator-macos/releases) 下载对应平台的安装包。每次发布会同时提供 macOS 和 Windows 安装包，按你的平台选择下载即可。

## 共享契约

跨平台共享的数据契约（Provider 预设表、历史记录 schema）位于 [`contracts/`](./contracts/README.md)。两端的 Mac 和 Windows 实现引用这些文件作为单一事实来源，保证跨平台数据一致。

## 架构

本项目采用「双端独立、契约共享」的架构：

- 两个平台各自有独立的实现（Mac 用 Swift 原生，Windows 用 Tauri + TypeScript）。
- 用户能跨平台感知的数据（Provider 预设、历史记录）通过 `contracts/` 共享，保证一致性。
- 各平台的内部实现各自演化，互不影响。

详细架构设计见 [`docs/superpowers/specs/`](./docs/superpowers/specs/)。

## License

MIT
