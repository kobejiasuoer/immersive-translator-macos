# ImmersiveTranslator (Windows)

基于 Tauri 2.x + React + TypeScript 的 Windows 沉浸式翻译工具。

选中任意文本，按 `Ctrl+Shift+Q`，即可在浮窗中实时查看 AI 翻译结果。

## 功能

- **全局热键翻译** — 在任意应用中选中文字，按 `Ctrl+Shift+Q` 触发翻译
- **流式输出** — 支持 SSE 流式渲染，翻译过程逐字显示
- **浮窗面板** — 可拖拽、按 Escape 关闭、不影响当前工作流
- **智能语言检测** — 中文自动译英，其他语言自动译中文；也可固定目标语言
- **术语表** — 支持自定义术语表（多种分隔符格式），确保专有名词一致性
- **自定义翻译风格** — 可追加翻译风格指令（如"保留原文语气"、"使用口语化表达"等）
- **多 LLM 后端** — 兼容 OpenAI、DeepSeek、智谱、通义等所有 OpenAI 格式接口
- **系统托盘** — 最小化到托盘，右键菜单可打开设置或退出
- **剪贴板保护** — 翻译完成后自动恢复原始剪贴板内容

## 技术栈

| 层级 | 技术 |
|------|------|
| 桌面框架 | Tauri 2.x (Rust 内核 + WebView2) |
| 前端 | React 19 + TypeScript |
| 构建 | Vite 6 |
| 测试 | Vitest |
| HTTP / SSE | reqwest (Rust) |
| 剪贴板 & 键盘 | arboard + windows-sys SendInput |

## 项目结构

```
immersive-translator-windows/
├── src/                       # 前端 (React + TypeScript)
│   ├── views/
│   │   ├── TranslationPanel   # 翻译浮窗面板
│   │   └── Settings           # 设置窗口
│   ├── core/                  # 平台无关的核心逻辑
│   │   ├── languageDetect     # 语言检测 & 目标语言选择
│   │   ├── glossaryParser     # 术语表解析
│   │   ├── promptBuilder      # 系统提示词构造
│   │   └── errorMessageFormatter  # 错误分类 & 格式化
│   ├── lib/
│   │   └── settingsStore      # 设置持久化 (localStorage)
│   └── App.tsx                # 窗口路由
├── src-tauri/                 # Rust 后端
│   ├── src/
│   │   ├── lib.rs             # 应用入口、托盘、热键注册
│   │   ├── clipboard.rs       # 选中文本读取 (Ctrl+C 模拟)
│   │   └── translation.rs     # LLM API 调用 & SSE 流式解析
│   └── tauri.conf.json        # Tauri 配置
├── WINDOWS-SETUP.md           # 开发环境搭建指南
├── run-dev.bat                # 一键启动开发服务器
├── run-build.bat              # 一键构建
└── run-test.bat               # 一键运行测试
```

## 快速开始

### 安装依赖

```bash
cd immersive-translator-windows
npm install
```

### 开发环境准备

首次开发请参阅 [`WINDOWS-SETUP.md`](./WINDOWS-SETUP.md)，需要安装：
- Rust 工具链
- C++ Build Tools
- Node.js
- WebView2 Runtime

### 开发模式

```bash
npm run tauri dev
```

或直接双击 `run-dev.bat`。

### 构建

```bash
npm run tauri build
```

或双击 `run-build.bat`，产物在 `src-tauri/target/release/bundle/` 下。

### 测试

```bash
npx vitest run
```

## 使用方式

1. 启动应用后，程序最小化到系统托盘
2. 在任意应用中选中文字
3. 按 **Ctrl+Shift+Q**，浮窗出现并自动翻译
4. 可复制翻译结果、拖拽浮窗位置、按 **Esc** 关闭面板
5. 右键托盘图标可打开设置或退出

## 设置说明

| 设置项 | 说明 | 默认值 |
|--------|------|--------|
| 接口地址 | OpenAI 兼容 API 的 Chat Completions 端点 | OpenAI 官方 |
| API Key | 服务商提供的密钥 | — |
| 模型 | 使用的模型名称 | gpt-4o-mini |
| 翻译模式 | 自动 / 固定目标语言 | 自动 |
| 翻译风格 | 追加到系统提示词的自定义指令 | — |
| 术语表 | 自定义翻译对照表（最多 80 条） | — |
| 流式输出 | 是否启用逐字流式渲染 | 开启 |
