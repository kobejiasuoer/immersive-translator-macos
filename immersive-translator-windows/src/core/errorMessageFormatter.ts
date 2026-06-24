import { isLocalhostEndpoint } from "./providerPresets";

export type TranslationErrorInput =
  | { kind: "http"; status: number; body: string }
  | { kind: "network"; message: string }
  | { kind: "timeout" }
  | { kind: "emptyTranslation" }
  | { kind: "invalidResponse"; preview: string };

export interface ClassifiedError {
  message: string;
  retryable: boolean;
}

function looksLikeHtml(body: string): boolean {
  const lower = body.trim().toLowerCase();
  return lower.startsWith("<!doctype html") || lower.startsWith("<html") || lower.includes("<body");
}

/** 检测 body 里的服务商，用于给针对性建议。 */
type Vendor =
  | "openai"
  | "deepseek"
  | "zhipu"
  | "gemini"
  | "openrouter"
  | "dashscope"
  | "groq"
  | "xai"
  | "moonshot"
  | "ollama"
  | "lmstudio"
  | "vllm"
  | "unknown";

/** 注意：endpoint 可能为空（错误可能不带上下文），这里尽力推断。 */
function detectVendor(body: string, code?: string): Vendor {
  const b = body.toLowerCase();
  // 先用特征 code（部分服务商用专属错误码）
  if (code === "API_KEY_INVALID" || code === "API_KEY_SERVICE_BLOCKED") return "gemini";
  if (b.includes("openrouter") || b.includes("credits")) return "openrouter";
  if (b.includes("deepseek")) return "deepseek";
  if (b.includes("zhipu") || b.includes("bigmodel") || b.includes("glm")) return "zhipu";
  if (b.includes("gemini") || b.includes("generativelanguage")) return "gemini";
  if (b.includes("dashscope") || b.includes("阿里") || b.includes("qwen") || b.includes("tongyi"))
    return "dashscope";
  if (b.includes("groq")) return "groq";
  if (b.includes("x.ai") || b.includes("grok")) return "xai";
  if (b.includes("moonshot") || b.includes("kimi")) return "moonshot";
  if (b.includes("ollama")) return "ollama";
  if (b.includes("lm studio")) return "lmstudio";
  if (b.includes("vllm")) return "vllm";
  if (b.includes("openai")) return "openai";
  return "unknown";
}

/** 从错误 body 提取 message/code 字段（多数 OpenAI 兼容服务用 {error:{message,code}}）。 */
function parseErrorBody(body: string): { message?: string; code?: string; type?: string } {
  const trimmed = body.trim();
  if (!trimmed || !trimmed.startsWith("{")) return {};
  try {
    const v = JSON.parse(trimmed);
    const err = v?.error ?? v;
    return {
      message: typeof err?.message === "string" ? err.message : undefined,
      code: typeof err?.code === "string" ? err.code : undefined,
      type: typeof err?.type === "string" ? err.type : undefined,
    };
  } catch {
    return {};
  }
}

/** 截断 body 预览，避免把整页 HTML 塞进 UI。 */
function preview(body: string, max = 120): string {
  const t = body.trim();
  if (t.length <= max) return t;
  return t.slice(0, max) + "…";
}

/** 按服务商给出针对性建议。 */
function vendorHint(vendor: Vendor, status: number, code?: string, message?: string): string {
  switch (vendor) {
    case "openai":
      if (status === 429) return "OpenAI 限流或额度耗尽，稍后重试或检查账单。";
      if (code === "invalid_api_key") return "OpenAI 报 API Key 无效，请检查是否以 sk- 开头且完整。";
      return "OpenAI 接口报错。";
    case "deepseek":
      if (status === 402 || status === 429) return "DeepSeek 余额不足或限流，请到控制台充值。";
      return "DeepSeek 接口报错。";
    case "zhipu":
      if (status === 401) return "智谱 API Key 无效或 JWT 签名错误，请到开放平台重新生成。";
      return "智谱接口报错。";
    case "gemini":
      if (code === "API_KEY_INVALID" || /api key/i.test(message ?? ""))
        return "Gemini API Key 无效，请在 Google AI Studio 重新生成。";
      if (status === 429) return "Gemini 免费额度限流，稍后重试。";
      return "Gemini 接口报错（国内需代理）。";
    case "openrouter":
      if (/credit/i.test(message ?? "") || status === 402)
        return "OpenRouter 信用额度不足，请到 openrouter.ai 充值。";
      return "OpenRouter 接口报错。";
    case "dashscope":
      if (status === 401) return "百炼 API Key 无效，请在阿里云控制台重新获取。";
      return "百炼接口报错。";
    case "groq":
      if (/capacity|rate/i.test(message ?? "")) return "Groq 容量限流，稍后重试。";
      return "Groq 接口报错。";
    case "xai":
      return "xAI Grok 接口报错。";
    case "moonshot":
      return "Kimi / Moonshot 接口报错。";
    case "ollama":
      return "Ollama 报错：确认已运行 `ollama serve` 且已 pull 对应模型。";
    case "lmstudio":
      return "LM Studio 报错：确认本地 Server 已启动且端口正确。";
    case "vllm":
      return "vLLM 报错：确认已 `vllm serve` 且模型名与 served-model-name 一致。";
    default:
      return "";
  }
}

export function classifyTranslationError(
  input: TranslationErrorInput,
  endpoint?: string,
): ClassifiedError {
  switch (input.kind) {
    case "network": {
      const isLocal = endpoint ? isLocalhostEndpoint(endpoint) : false;
      if (isLocal) {
        return {
          message: `无法连接到本地接口：${input.message}。请确认本地服务（Ollama/LM Studio/vLLM）已启动。`,
          retryable: true,
        };
      }
      return {
        message: `网络错误：${input.message}。请检查网络连接或接口地址是否可达（国内访问 OpenAI/Gemini 需代理）。`,
        retryable: true,
      };
    }

    case "timeout":
      return { message: "请求超时。请检查网络或换用更低延迟的模型/服务商。", retryable: true };

    case "emptyTranslation":
      return {
        message: "接口返回了空翻译。可能原因：模型名错误、被安全策略拦截、或返回了纯思考内容。请换模型或检查术语表/风格设置。",
        retryable: false,
      };

    case "invalidResponse":
      return {
        message: `接口返回格式不符合预期（非 JSON 或缺少 choices[0]）：${preview(input.preview)}`,
        retryable: false,
      };

    case "http": {
      const { status, body } = input;
      const parsed = parseErrorBody(body);
      const vendor = detectVendor(body, parsed.code);
      const hint = vendorHint(vendor, status, parsed.code, parsed.message);
      // 把服务端错误消息拼进去（截断）
      const srvMsg = parsed.message ? ` 服务端消息：${preview(parsed.message, 80)}` : "";

      // 200 但内容不是预期 JSON
      if (status === 200 && looksLikeHtml(body)) {
        return {
          message: "接口返回了 HTML 而非 JSON，可能是接口地址错误或经过登录页/网关。",
          retryable: false,
        };
      }
      if (status === 200) {
        // 200 但带 error JSON（对齐 Mac：部分网关用 200 包错误）
        if (parsed.message) {
          return {
            message: `接口返回 200 但携带错误：${preview(parsed.message, 120)}${hint ? " " + hint : ""}`,
            retryable: false,
          };
        }
        return { message: "接口返回格式不符合预期。", retryable: false };
      }

      if (status === 401) {
        return {
          message: `API Key 无效或未配置（HTTP 401）。请检查设置里的 API Key。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: false,
        };
      }
      if (status === 403) {
        return {
          message: `权限不足或 API Key 无权限（HTTP 403）。请检查账号权限或余额。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: false,
        };
      }
      if (status === 404) {
        return {
          message: `接口地址错误（HTTP 404）。请确认地址包含 /chat/completions 且域名正确。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: false,
        };
      }
      if (status === 429) {
        return {
          message: `请求被限流（HTTP 429）。请稍后重试或检查额度/限流策略。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: true,
        };
      }
      if (status === 402) {
        return {
          message: `余额不足（HTTP 402）。请到服务商控制台充值。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: false,
        };
      }
      if (status >= 500) {
        return {
          message: `服务商出错（HTTP ${status}）。可稍后重试。${srvMsg}${hint ? " " + hint : ""}`,
          retryable: true,
        };
      }

      return {
        message: `翻译接口返回 HTTP ${status}。${srvMsg}${hint ? " " + hint : ""}`,
        retryable: false,
      };
    }
  }
}

/**
 * 构造脱敏的 curl 命令，用于排查 / 反馈。
 * API Key 被替换为 sk-***REDACTED***。
 */
export function buildSanitizedCurl(
  endpoint: string,
  apiKey: string,
  model: string,
  sampleText: string,
): string {
  const safeText = (sampleText || "hello").replace(/"/g, '\\"').slice(0, 60);
  const key = apiKey.trim() ? "sk-***REDACTED***" : "(空)";
  return (
    `curl -X POST '${endpoint || "https://api.example.com/v1/chat/completions"}' \\\n` +
    `  -H 'Content-Type: application/json' \\\n` +
    `  -H 'Authorization: Bearer ${key}' \\\n` +
    `  -d '{"model":"${model}","messages":[{"role":"user","content":"${safeText}"}]}'`
  );
}

/** 诊断报告入参。所有敏感字段会被脱敏。 */
export interface DiagnosticInput {
  endpoint: string;
  apiKey: string;
  model: string;
  stream: boolean;
  translationMode: string;
  fixedTarget: string;
  /** 最近一次错误（可选）。 */
  lastError?: string;
  /** 应用版本号。 */
  appVersion?: string;
}

/**
 * 生成一份可复制的诊断报告（脱敏），用于反馈问题。
 * 包含：环境信息、配置摘要（Key 脱敏）、最近错误、复现用的脱敏 curl。
 */
export function buildDiagnosticReport(input: DiagnosticInput): string {
  const now = new Date().toISOString();
  const keyState = input.apiKey.trim()
    ? `已配置（长度 ${input.apiKey.trim().length}，前 3 位 ${input.apiKey.trim().slice(0, 3)}***）`
    : "未配置";
  const lines = [
    "===== ImmersiveTranslator 诊断报告 =====",
    `生成时间：${now}`,
    `版本：${input.appVersion ?? "未知"}`,
    `平台：Windows (Tauri)`,
    "",
    "--- 配置摘要（已脱敏）---",
    `接口地址：${input.endpoint || "(空)"}`,
    `模型：${input.model || "(空)"}`,
    `API Key：${keyState}`,
    `流式输出：${input.stream ? "开" : "关"}`,
    `翻译模式：${input.translationMode}` +
      (input.fixedTarget ? `（目标：${input.fixedTarget}）` : ""),
    "",
    "--- 最近错误 ---",
    input.lastError?.trim() || "（无）",
    "",
    "--- 复现命令（脱敏 curl）---",
    buildSanitizedCurl(input.endpoint, input.apiKey, input.model, "hello"),
    "",
    "===== 报告结束 =====",
  ];
  return lines.join("\n");
}
