# 跨平台共享契约

本目录存放 Mac 版和 Windows 版共享的数据契约。两端引用这些文件作为单一事实来源，保证跨平台数据一致。

## 文件

- `provider-presets.json`：Provider 预设表（OpenAI / DeepSeek / 智谱 / Gemini 等）。两端引用同一份，避免模型名 / 接口地址漂移。**填充时间：阶段 4**。
- `history.schema.json`：历史记录 JSON schema。保证 Mac 导出的历史能在 Windows 导入，反之亦然。**填充时间：阶段 2**。

## 版本约定

每个契约文件带 `schemaVersion` 字段。两端在读取或导入数据时校验版本兼容性：

- 主版本号一致：兼容，正常读取。
- 主版本号不同：不兼容，向用户友好提示（例如「历史记录格式来自更新版本，请升级 App」），不静默失败。

## 为什么不共享所有数据

只共享「用户能跨平台感知」的数据（Provider 预设、历史记录格式）。各平台的设置项、内部实现格式各自管理——因为两端本就有平台差异（Mac 用 Keychain 存 API Key，Windows 用 Credential Manager），强行统一反而僵硬。
