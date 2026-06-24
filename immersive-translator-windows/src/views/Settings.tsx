import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  loadSettingsAsync,
  saveSettingsAsync,
  DEFAULT_SETTINGS,
  hasValidSettings,
  isOnboardingDismissed,
  setOnboardingDismissed,
  type AppSettings,
} from "../lib/settingsStore";
import type { TranslationMode } from "../core/languageDetect";
import {
  PROVIDER_PRESETS,
  findMatchingPreset,
  isLocalhostEndpoint,
  type ProviderPreset,
} from "../core/providerPresets";
import {
  parseHotkey,
  validateHotkey,
  normalizeHotkey,
  RECOMMENDED_HOTKEYS,
} from "../core/hotkeyValidator";
import { reregisterHotkey, testConnectivity } from "../lib/tauriBridge";
import {
  ocrModelsReady,
  ocrDownloadModels,
  onDownloadProgress,
} from "../lib/tauriBridge";
import {
  checkForUpdate,
  downloadAndInstall,
  type UpdateProgress,
  type UpdateStage,
} from "../lib/updater";
import { buildSanitizedCurl, buildDiagnosticReport } from "../core/errorMessageFormatter";
import {
  glossaryStats,
  dedupAndNormalize,
  mergeGlossary,
} from "../core/glossaryParser";

/** 规范化 endpoint，对齐后端 translation.rs::normalize_endpoint。 */
function normalizeEndpointPreview(endpoint: string): string {
  const trimmed = endpoint.trim().replace(/\/+$/, "");
  if (trimmed === "") return "";
  if (trimmed.toLowerCase().endsWith("/chat/completions")) return trimmed;
  if (trimmed.toLowerCase().endsWith("/v1")) return `${trimmed}/chat/completions`;
  return `${trimmed}/v1/chat/completions`;
}

/**
 * 设置窗口。点托盘「设置」菜单打开。
 * 对齐 Mac 版设置字段。apiKey 经 DPAPI 加密存储，其余字段存 localStorage。
 */
export function Settings() {
  const [settings, setSettings] = useState<AppSettings>(() => ({
    ...DEFAULT_SETTINGS,
  }));
  const [saved, setSaved] = useState(false);
  const [showWelcome, setShowWelcome] = useState(false);

  // 首次加载后：加载设置；若未关闭引导且接口未配好，显示欢迎横幅
  useEffect(() => {
    let active = true;
    loadSettingsAsync().then((s) => {
      if (!active) return;
      setSettings(s);
      if (!isOnboardingDismissed() && !hasValidSettings(s)) {
        setShowWelcome(true);
      }
    });
    return () => {
      active = false;
    };
  }, []);

  function update<K extends keyof AppSettings>(key: K, value: AppSettings[K]) {
    setSettings((prev) => ({ ...prev, [key]: value }));
    setSaved(false);
  }

  // ---- 热键录制 ----
  const [recording, setRecording] = useState(false);
  const [hotkeyMsg, setHotkeyMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const recordingRef = useRef(false);

  // ---- 连通性测试 ----
  const [testing, setTesting] = useState(false);
  const [testMsg, setTestMsg] = useState<{ text: string; ok: boolean } | null>(null);

  // ---- 术语表 ----
  const glossaryFileRef = useRef<HTMLInputElement>(null);
  const [glossaryMsg, setGlossaryMsg] = useState<string | null>(null);
  const glossStats = glossaryStats(settings.glossaryText);

  // ---- OCR 模型 ----
  const [ocrReady, setOcrReady] = useState<boolean | null>(null);
  const [ocrDownloading, setOcrDownloading] = useState(false);
  const [ocrMsg, setOcrMsg] = useState<string | null>(null);

  // 首次加载检查模型状态
  useEffect(() => {
    let active = true;
    ocrModelsReady().then((ready) => {
      if (active) setOcrReady(ready);
    });
    const unlistenP = onDownloadProgress((p) => {
      if (p.status === "downloading") {
        setOcrMsg(`正在下载 ${p.file}…`);
      } else if (p.status === "done") {
        setOcrMsg(`✓ ${p.file} 下载完成`);
      } else if (p.status === "complete") {
        setOcrMsg("✓ 模型下载完成，可以使用截图翻译了");
        setOcrDownloading(false);
        setOcrReady(true);
      }
    });
    return () => {
      active = false;
      void unlistenP.then((u) => u());
    };
  }, []);

  async function handleDownloadModels() {
    setOcrDownloading(true);
    setOcrMsg("开始下载…");
    try {
      await ocrDownloadModels();
    } catch (e) {
      setOcrMsg(`下载失败：${e}`);
      setOcrDownloading(false);
    }
  }

  // ---- 自动更新 ----
  const [updateStage, setUpdateStage] = useState<UpdateStage>("idle");
  const [updateMsg, setUpdateMsg] = useState<string | null>(null);
  const [updateProgress, setUpdateProgress] = useState<number | undefined>(undefined);
  const [updateAvailable, setUpdateAvailable] = useState<{ version: string } | null>(null);

  async function handleCheckUpdate() {
    setUpdateStage("checking");
    setUpdateMsg("正在检查更新…");
    setUpdateAvailable(null);
    try {
      const info = await checkForUpdate();
      if (info.hasUpdate) {
        setUpdateAvailable({ version: info.newVersion! });
        setUpdateMsg(
          `发现新版本 v${info.newVersion}（当前 v${info.currentVersion}）`,
        );
        setUpdateStage("idle");
      } else {
        setUpdateMsg(`已是最新版本 v${info.currentVersion}`);
        setUpdateStage("done");
      }
    } catch (e) {
      setUpdateMsg(String(e));
      setUpdateStage("error");
    }
  }

  async function handleDownloadUpdate() {
    const onProgress = (p: UpdateProgress) => {
      setUpdateStage(p.stage);
      setUpdateMsg(p.message);
      setUpdateProgress(p.progress);
    };
    try {
      await downloadAndInstall(onProgress);
    } catch (e) {
      setUpdateMsg(`更新失败：${e}`);
      setUpdateStage("error");
    }
  }

  async function handleTest() {
    setTesting(true);
    setTestMsg(null);
    try {
      const r = await testConnectivity(settings.endpoint, settings.apiKey, settings.model);
      setTestMsg({ text: r.message, ok: r.ok });
    } catch (e) {
      setTestMsg({ text: `测试失败：${e}`, ok: false });
    } finally {
      setTesting(false);
    }
  }

  const validation = validateHotkey(settings.hotkey);

  // 录制：监听下一次按键组合
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (!recordingRef.current) return;
      e.preventDefault();
      e.stopPropagation();
      // 忽略单按修饰键
      const modKeys = ["Control", "Alt", "Shift", "Meta"];
      if (modKeys.includes(e.key)) return;

      const mods: string[] = [];
      if (e.ctrlKey) mods.push("Ctrl");
      if (e.altKey) mods.push("Alt");
      if (e.shiftKey) mods.push("Shift");
      if (e.metaKey) mods.push("Super");
      // 主键名
      let key = e.key;
      if (key === " ") key = "Space";
      key = key.length === 1 ? key.toUpperCase() : key;
      const combo = [...mods, key].join("+");
      const parsed = parseHotkey(combo);
      if (!parsed) {
        setHotkeyMsg({ text: "需要至少一个修饰键 + 一个主键", ok: false });
        return;
      }
      const norm = normalizeHotkey(combo);
      const v = validateHotkey(norm);
      if (v.blocking) {
        setHotkeyMsg({ text: v.warning ?? "该组合不可用", ok: false });
        return;
      }
      setSettings((prev) => ({ ...prev, hotkey: norm }));
      setSaved(false);
      setHotkeyMsg(
        v.warning ? { text: `已设置为 ${norm}（${v.warning}）`, ok: true } : { text: `已设置为 ${norm}`, ok: true },
      );
      stopRecording();
    }
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, []);

  function startRecording() {
    recordingRef.current = true;
    setRecording(true);
    setHotkeyMsg({ text: "请按下新的组合键…（Esc 取消）", ok: true });
    // Esc 取消
    const onCancel = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        stopRecording();
      }
    };
    window.addEventListener("keydown", onCancel, true);
  }

  function stopRecording() {
    recordingRef.current = false;
    setRecording(false);
  }

  /** 应用并注册热键（保存设置时自动调用，也可单独点「应用」）。 */
  async function applyHotkey() {
    if (validation.blocking) {
      setHotkeyMsg({ text: validation.warning ?? "热键无效", ok: false });
      return false;
    }
    try {
      await reregisterHotkey(settings.hotkey);
      setHotkeyMsg({ text: `热键已注册：${settings.hotkey}`, ok: true });
      return true;
    } catch (e) {
      setHotkeyMsg({ text: String(e), ok: false });
      return false;
    }
  }

  async function handleSave() {
    // 保存设置；如果热键改过则重新注册
    const hotkeyChanged = settings.hotkey !== DEFAULT_SETTINGS.hotkey;
    await saveSettingsAsync(settings);
    if (hotkeyChanged || validation.ok) {
      await applyHotkey();
    }
    // 配置已有效时，自动关闭欢迎横幅
    if (hasValidSettings(settings)) {
      setOnboardingDismissed(true);
      setShowWelcome(false);
    }
    setSaved(true);
  }

  async function handleClose() {
    await getCurrentWindow().hide();
  }

  function handleResetDefaults() {
    if (confirm("确定恢复默认设置？已保存的接口配置会被清空。")) {
      const reset = { ...DEFAULT_SETTINGS };
      void saveSettingsAsync(reset);
      setSettings(reset);
      setSaved(false);
    }
  }

  return (
    <div style={pageStyle}>
      <h1 style={titleStyle}>ImmersiveTranslator 设置</h1>

      {showWelcome && (
        <div style={welcomeStyle}>
          <div style={welcomeTitleStyle}>👋 欢迎使用 ImmersiveTranslator</div>
          <div style={welcomeStepStyle}>三步开始：</div>
          <div style={welcomeStepStyle}>
            1. 在下方「Provider 预设」里点一个厂商（推荐 DeepSeek 或 智谱，国内直连快）。
          </div>
          <div style={welcomeStepStyle}>
            2. 填入对应厂商的 <strong>API Key</strong>（本地 Ollama/LM Studio 可留空）。
          </div>
          <div style={welcomeStepStyle}>
            3. 点「测试当前接口」确认能连通，然后回到任意应用选中文本，按热键翻译。
          </div>
          <div style={{ marginTop: 8 }}>
            <button
              style={dismissBtnStyle}
              onClick={() => {
                setOnboardingDismissed(true);
                setShowWelcome(false);
              }}
            >
              我知道了
            </button>
          </div>
        </div>
      )}

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>翻译接口</h2>

        <div style={{ marginBottom: 10 }}>
          <div style={labelStyle}>Provider 预设（点击套用接口 + 模型）</div>
          <div style={presetGridStyle}>
            {PROVIDER_PRESETS.map((p) => (
              <PresetCard
                key={p.id}
                preset={p}
                active={findMatchingPreset(settings.endpoint)?.id === p.id}
                apiKeyMissing={settings.apiKey.trim() === "" && !(p.allowEmptyApiKey ?? false)}
                onApply={() =>
                  setSettings((prev) => ({
                    ...prev,
                    endpoint: p.endpoint,
                    model: p.model,
                  }))
                }
              />
            ))}
          </div>
        </div>

        <label style={labelStyle}>
          接口地址（OpenAI 兼容）
          <input
            style={inputStyle}
            value={settings.endpoint}
            onChange={(e) => update("endpoint", e.target.value)}
            placeholder="https://api.openai.com/v1/chat/completions"
          />
        </label>
        <div style={hintStyle}>
          实际请求地址：<code>{normalizeEndpointPreview(settings.endpoint) || "（未填写）"}</code>
          <br />
          支持 OpenAI / DeepSeek / 智谱 / 通义等兼容接口。地址会自动补全 /v1/chat/completions。
        </div>

        <label style={labelStyle}>
          API Key
          <input
            style={inputStyle}
            type="password"
            value={settings.apiKey}
            onChange={(e) => update("apiKey", e.target.value)}
            placeholder="sk-..."
          />
        </label>
        {settings.apiKey.trim() === "" && !isLocalhostEndpoint(settings.endpoint) && (
          <div style={warnHintStyle}>该接口需要 API Key，当前为空。本地接口（localhost）可留空。</div>
        )}

        <label style={labelStyle}>
          模型
          <input
            style={inputStyle}
            value={settings.model}
            onChange={(e) => update("model", e.target.value)}
            placeholder="gpt-4o-mini"
          />
        </label>

        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 4 }}>
          <button
            style={secondaryBtnStyle}
            disabled={testing}
            onClick={() => void handleTest()}
          >
            {testing ? "测试中…" : "测试当前接口"}
          </button>
          <button
            style={secondaryBtnStyle}
            onClick={() => {
              const curl = buildSanitizedCurl(
                settings.endpoint,
                settings.apiKey,
                settings.model,
                "hello",
              );
              void navigator.clipboard.writeText(curl);
              setTestMsg({ text: "脱敏 curl 已复制到剪贴板", ok: true });
            }}
          >
            复制脱敏 curl
          </button>
          <button
            style={secondaryBtnStyle}
            onClick={() => {
              const report = buildDiagnosticReport({
                endpoint: settings.endpoint,
                apiKey: settings.apiKey,
                model: settings.model,
                stream: settings.stream,
                translationMode: settings.translationMode,
                fixedTarget: settings.fixedTarget,
                appVersion: "0.1.0",
              });
              void navigator.clipboard.writeText(report);
              setTestMsg({ text: "诊断报告已复制到剪贴板（已脱敏，可安全分享）", ok: true });
            }}
          >
            生成诊断报告
          </button>
        </div>
        {testMsg && (
          <div style={testMsg.ok ? savedHintStyle : warnHintStyle}>{testMsg.text}</div>
        )}
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>翻译语言</h2>

        <div style={labelStyle}>
          翻译模式
          <div style={{ marginTop: 6 }}>
            <label style={radioLabelStyle}>
              <input
                type="radio"
                name="mode"
                checked={settings.translationMode === "auto"}
                onChange={() => update("translationMode", "auto" as TranslationMode)}
              />
              自动（中文 → English，其他 → 简体中文）
            </label>
            <label style={radioLabelStyle}>
              <input
                type="radio"
                name="mode"
                checked={settings.translationMode === "fixed"}
                onChange={() => update("translationMode", "fixed" as TranslationMode)}
              />
              固定目标语言
            </label>
          </div>
        </div>

        <label style={labelStyle}>
          固定目标语言（仅"固定目标语言"模式生效）
          <input
            style={inputStyle}
            value={settings.fixedTarget}
            onChange={(e) => update("fixedTarget", e.target.value)}
            placeholder="例如：日本語、English、简体中文"
            disabled={settings.translationMode !== "fixed"}
          />
        </label>
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>高级</h2>

        <label style={labelStyle}>
          自定义翻译风格（可选）
          <textarea
            style={{ ...inputStyle, minHeight: 60, resize: "vertical" }}
            value={settings.customStyle}
            onChange={(e) => update("customStyle", e.target.value)}
            placeholder="例如：使用自然口语化的风格；保留专有名词不翻译"
          />
        </label>

        <label style={labelStyle}>
          术语表（可选，每行一条，格式：原词 = 译法）
          <textarea
            style={{ ...inputStyle, minHeight: 90, resize: "vertical", fontFamily: "monospace" }}
            value={settings.glossaryText}
            onChange={(e) => update("glossaryText", e.target.value)}
            placeholder={"hello = 你好\nworld -> 世界\n# 这是注释，会被忽略"}
          />
        </label>
        <div style={hintStyle}>
          支持的格式：<code>=</code>、<code>-&gt;</code>、<code>：</code>、CSV/TSV 前两列。最多发送前 80 条。
        </div>
        {/* 格式预检 */}
        <div style={hintStyle}>
          有效 {glossStats.valid} 条
          {glossStats.invalid > 0 && (
            <span style={{ color: "#b45309" }}> · 无法解析 {glossStats.invalid} 行</span>
          )}
          {glossStats.overLimit > 0 && (
            <span style={{ color: "#b45309" }}> · 超出 80 条上限 {glossStats.overLimit} 条（不会发送）</span>
          )}
        </div>
        {/* 导入 / 导出 / 去重 */}
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 4 }}>
          <input
            ref={glossaryFileRef}
            type="file"
            accept=".txt,.csv,.tsv"
            style={{ display: "none" }}
            onChange={async (e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              const text = await file.text();
              update("glossaryText", mergeGlossary(settings.glossaryText, text));
              setGlossaryMsg(`已导入并合并 ${file.name}`);
              if (glossaryFileRef.current) glossaryFileRef.current.value = "";
            }}
          />
          <button style={secondaryBtnStyle} onClick={() => glossaryFileRef.current?.click()}>
            导入文件
          </button>
          <button
            style={secondaryBtnStyle}
            onClick={async () => {
              const clip = await navigator.clipboard.readText().catch(() => "");
              const merged = mergeGlossary(settings.glossaryText, clip);
              update("glossaryText", merged);
              setGlossaryMsg("已从剪贴板导入并合并");
            }}
          >
            从剪贴板导入
          </button>
          <button
            style={secondaryBtnStyle}
            onClick={() => {
              update("glossaryText", dedupAndNormalize(settings.glossaryText));
              setGlossaryMsg("已去重并规范化");
            }}
          >
            去重 / 规范化
          </button>
          <button
            style={secondaryBtnStyle}
            onClick={() => {
              const out = dedupAndNormalize(settings.glossaryText);
              void navigator.clipboard.writeText(out);
              setGlossaryMsg(`已复制 ${out ? out.split("\n").length : 0} 条到剪贴板`);
            }}
          >
            导出到剪贴板
          </button>
        </div>
        {glossaryMsg && <div style={savedHintStyle}>{glossaryMsg}</div>}
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>截图翻译 (OCR)</h2>
        <div style={hintStyle}>
          通过托盘菜单「截图翻译」或框选屏幕区域，识别文字后自动翻译。
          基于 PaddleOCR，离线运行，支持中英日韩等多语言。
        </div>
        <div style={{ marginTop: 8 }}>
          {ocrReady === null ? (
            <span style={hintStyle}>检查模型状态…</span>
          ) : ocrReady ? (
            <span style={{ ...savedHintStyle, fontSize: 13 }}>
              ✓ OCR 模型已就绪
            </span>
          ) : (
            <span style={{ ...warnHintStyle, fontSize: 13 }}>
              ⚠ OCR 模型未下载（约 16MB），首次使用需下载
            </span>
          )}
        </div>
        <div style={{ marginTop: 8 }}>
          <button
            style={secondaryBtnStyle}
            disabled={ocrDownloading || ocrReady === true}
            onClick={() => void handleDownloadModels()}
          >
            {ocrDownloading
              ? "下载中…"
              : ocrReady
                ? "模型已就绪"
                : "下载中文模型 (det + rec)"}
          </button>
        </div>
        {ocrMsg && <div style={savedHintStyle}>{ocrMsg}</div>}
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>高级</h2>
        <label style={checkboxRowStyle}>
          <input
            type="checkbox"
            checked={settings.stream}
            onChange={(e) => update("stream", e.target.checked)}
          />
          流式输出（边翻译边显示，关掉则等全部完成）
        </label>
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>快捷键</h2>
        <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
          <input
            style={{ ...inputStyle, fontFamily: "monospace", width: 180 }}
            value={settings.hotkey}
            onChange={(e) => {
              update("hotkey", e.target.value);
              setHotkeyMsg(null);
            }}
            placeholder="Ctrl+Shift+Q"
          />
          <button
            style={recording ? { ...secondaryBtnStyle, background: "#2563eb", color: "#fff" } : secondaryBtnStyle}
            onClick={recording ? stopRecording : startRecording}
          >
            {recording ? "录制中…（点击取消）" : "录制组合键"}
          </button>
          <button style={secondaryBtnStyle} onClick={() => void applyHotkey()} disabled={!validation.ok}>
            立即注册
          </button>
        </div>
        <div style={hintStyle}>
          按下热键会读取当前选中文字并弹出翻译浮窗。当前已注册：
          <code>{settings.hotkey}</code>
        </div>
        {hotkeyMsg && (
          <div style={hotkeyMsg.ok ? savedHintStyle : warnHintStyle}>{hotkeyMsg.text}</div>
        )}
        {!hotkeyMsg && validation.blocking && (
          <div style={warnHintStyle}>{validation.warning}</div>
        )}
        {!hotkeyMsg && validation.warning && !validation.blocking && (
          <div style={warnHintStyle}>{validation.warning}</div>
        )}
        <div style={hintStyle}>
          推荐组合：
          {RECOMMENDED_HOTKEYS.map((h) => (
            <button
              key={h}
              style={tagBtnStyle}
              onClick={() => {
                update("hotkey", h);
                setHotkeyMsg(null);
              }}
            >
              {h}
            </button>
          ))}
        </div>
      </section>

      <section style={sectionStyle}>
        <h2 style={sectionTitleStyle}>关于 / 更新</h2>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          {updateAvailable && updateStage !== "downloading" && updateStage !== "installing" && (
            <button
              style={primaryBtnStyle}
              onClick={() => void handleDownloadUpdate()}
            >
              下载并安装 v{updateAvailable.version}
            </button>
          )}
          <button
            style={secondaryBtnStyle}
            disabled={updateStage === "checking" || updateStage === "downloading" || updateStage === "installing"}
            onClick={() => void handleCheckUpdate()}
          >
            {updateStage === "checking" ? "检查中…" : "检查更新"}
          </button>
        </div>
        {updateMsg && (
          <div style={updateStage === "error" ? warnHintStyle : savedHintStyle}>
            {updateMsg}
          </div>
        )}
        {updateStage === "downloading" && updateProgress !== undefined && (
          <div style={progressBarContainerStyle}>
            <div style={{ ...progressBarFillStyle, width: `${Math.round(updateProgress * 100)}%` }} />
          </div>
        )}
        <div style={hintStyle}>
          每次检查更新会从 GitHub Releases 拉取版本信息，下载后自动校验签名（防止篡改）。
        </div>
      </section>

      <div style={actionsStyle}>
        <button style={secondaryBtnStyle} onClick={handleResetDefaults}>
          恢复默认
        </button>
        <span style={{ flex: 1 }} />
        {saved && <span style={savedHintStyle}>✓ 已保存</span>}
        <button style={secondaryBtnStyle} onClick={handleClose}>
          关闭
        </button>
        <button style={primaryBtnStyle} onClick={handleSave}>
          保存
        </button>
      </div>
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  padding: 24,
  fontFamily: "system-ui, -apple-system, sans-serif",
  fontSize: 14,
  color: "#222",
  height: "100vh",
  boxSizing: "border-box",
  overflowY: "auto",
  background: "#fff",
};
const titleStyle: React.CSSProperties = {
  fontSize: 18,
  fontWeight: 600,
  margin: "0 0 16px",
};
const sectionStyle: React.CSSProperties = {
  marginBottom: 20,
  paddingBottom: 16,
  borderBottom: "1px solid #eee",
};
const sectionTitleStyle: React.CSSProperties = {
  fontSize: 14,
  fontWeight: 600,
  margin: "0 0 10px",
  color: "#333",
};
const labelStyle: React.CSSProperties = {
  display: "block",
  marginBottom: 12,
  fontSize: 13,
  color: "#555",
};
const inputStyle: React.CSSProperties = {
  display: "block",
  width: "100%",
  marginTop: 4,
  padding: "6px 8px",
  border: "1px solid #ccc",
  borderRadius: 4,
  fontSize: 13,
  boxSizing: "border-box",
  fontFamily: "inherit",
};
const radioLabelStyle: React.CSSProperties = {
  display: "block",
  fontSize: 13,
  color: "#444",
  marginBottom: 4,
};
const checkboxRowStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 6,
  fontSize: 13,
  color: "#444",
  marginBottom: 8,
};
const hintStyle: React.CSSProperties = {
  fontSize: 11,
  color: "#999",
  margin: "-4px 0 12px",
  lineHeight: 1.4,
};
const actionsStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  paddingTop: 8,
};
const primaryBtnStyle: React.CSSProperties = {
  padding: "6px 18px",
  border: "none",
  background: "#2563eb",
  color: "#fff",
  borderRadius: 4,
  fontSize: 13,
  cursor: "pointer",
};
const secondaryBtnStyle: React.CSSProperties = {
  padding: "6px 14px",
  border: "1px solid #ccc",
  background: "#fff",
  color: "#333",
  borderRadius: 4,
  fontSize: 13,
  cursor: "pointer",
};
const savedHintStyle: React.CSSProperties = {
  fontSize: 12,
  color: "#16a34a",
};

function PresetCard({
  preset,
  active,
  apiKeyMissing,
  onApply,
}: {
  preset: ProviderPreset;
  active: boolean;
  apiKeyMissing: boolean;
  onApply: () => void;
}) {
  const cardStyle: React.CSSProperties = {
    border: active ? "1.5px solid #2563eb" : "1px solid #ddd",
    background: active ? "#eff6ff" : "#fafafa",
    borderRadius: 6,
    padding: "8px 10px",
    cursor: "pointer",
    fontSize: 12,
    lineHeight: 1.4,
    transition: "border-color 0.15s, background 0.15s",
  };
  const nameStyle: React.CSSProperties = {
    fontWeight: 600,
    color: active ? "#2563eb" : "#333",
    marginBottom: 2,
  };
  const modelStyle: React.CSSProperties = {
    color: "#666",
    fontFamily: "monospace",
    fontSize: 11,
  };
  const tagStyle: React.CSSProperties = {
    display: "inline-block",
    fontSize: 10,
    padding: "1px 5px",
    borderRadius: 3,
    marginTop: 4,
    marginRight: 4,
  };

  return (
    <div
      style={cardStyle}
      onClick={onApply}
      onMouseEnter={(e) => {
        if (!active) e.currentTarget.style.borderColor = "#2563eb";
      }}
      onMouseLeave={(e) => {
        if (!active) e.currentTarget.style.borderColor = "#ddd";
      }}
    >
      <div style={nameStyle}>{preset.displayName}</div>
      <div style={modelStyle}>{preset.model}</div>
      <div>
        {preset.allowEmptyApiKey && (
          <span style={{ ...tagStyle, background: "#dcfce7", color: "#166534" }}>免 Key</span>
        )}
        {apiKeyMissing && !preset.allowEmptyApiKey && (
          <span style={{ ...tagStyle, background: "#fef3c7", color: "#92400e" }}>需填 Key</span>
        )}
        {active && (
          <span style={{ ...tagStyle, background: "#dbeafe", color: "#1e40af" }}>当前</span>
        )}
      </div>
      {preset.hint && <div style={hintStyle}>{preset.hint}</div>}
    </div>
  );
}

const presetGridStyle: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: "repeat(auto-fill, minmax(180px, 1fr))",
  gap: 8,
  marginTop: 6,
};
const warnHintStyle: React.CSSProperties = {
  fontSize: 11,
  color: "#b45309",
  margin: "-4px 0 12px",
  lineHeight: 1.4,
};
const tagBtnStyle: React.CSSProperties = {
  padding: "2px 8px",
  margin: "0 4px 4px 0",
  border: "1px solid #ccc",
  borderRadius: 4,
  background: "#fff",
  cursor: "pointer",
  fontSize: 11,
  fontFamily: "monospace",
};
const welcomeStyle: React.CSSProperties = {
  background: "#eff6ff",
  border: "1px solid #bfdbfe",
  borderRadius: 8,
  padding: "14px 16px",
  marginBottom: 14,
  lineHeight: 1.6,
};
const welcomeTitleStyle: React.CSSProperties = {
  fontWeight: 600,
  fontSize: 15,
  marginBottom: 6,
  color: "#1e40af",
};
const welcomeStepStyle: React.CSSProperties = {
  fontSize: 13,
  color: "#3730a3",
};
const dismissBtnStyle: React.CSSProperties = {
  padding: "5px 14px",
  border: "none",
  background: "#2563eb",
  color: "#fff",
  borderRadius: 6,
  cursor: "pointer",
  fontSize: 13,
};
const progressBarContainerStyle: React.CSSProperties = {
  width: "100%",
  height: 6,
  background: "#e5e7eb",
  borderRadius: 3,
  marginTop: 6,
  overflow: "hidden",
};
const progressBarFillStyle: React.CSSProperties = {
  height: "100%",
  background: "#2563eb",
  borderRadius: 3,
  transition: "width 0.3s",
};
