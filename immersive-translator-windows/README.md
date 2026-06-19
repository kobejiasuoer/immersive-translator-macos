# ImmersiveTranslator (Windows)

Tauri + TypeScript 实现的 Windows 版 ImmersiveTranslator。**开发中**。

## 当前状态

- `src/core/` 下已预写好 4 个平台无关的核心逻辑模块及单元测试（语言检测、术语表解析、提示词构造、错误分类），行为对齐 Mac 版。
- Tauri 工程骨架、Rust 端（系统集成）、前端 UI 尚未创建——这些需要在 Windows 环境（含 Rust 工具链）下完成。

## 开发前准备

如果是第一次在本机开发，请先按 [`WINDOWS-SETUP.md`](./WINDOWS-SETUP.md) 准备 Windows 开发环境（Rust、C++ Build Tools、Node、WebView2）。

## 实施计划

Windows 版的分阶段实施计划见仓库根目录：[`../docs/superpowers/plans/2026-06-19-windows-phase-0-1.md`](../docs/superpowers/plans/2026-06-19-windows-phase-0-1.md)。

整体架构设计见：[`../docs/superpowers/specs/2026-06-19-windows-version-design.md`](../docs/superpowers/specs/2026-06-19-windows-version-design.md)。

## 技术栈

- Tauri 2.x（Rust 内核 + WebView 前端）
- React + TypeScript
- Vitest（纯逻辑单测）
- reqwest（Rust 端 HTTP / SSE 流式）
- enigo + arboard（Rust 端键盘模拟 + 剪贴板）
