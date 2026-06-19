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

export function classifyTranslationError(input: TranslationErrorInput): ClassifiedError {
  switch (input.kind) {
    case "network":
      return { message: `网络错误：${input.message}。请检查网络连接或接口地址是否可达。`, retryable: true };

    case "timeout":
      return { message: "请求超时。请检查网络或换用更低延迟的模型/服务商。", retryable: true };

    case "emptyTranslation":
      return { message: "接口返回了空翻译。请检查模型名或换用其他模型。", retryable: false };

    case "invalidResponse":
      return {
        message: `接口返回格式不符合预期：${input.preview.slice(0, 100)}`,
        retryable: false,
      };

    case "http": {
      const { status, body } = input;

      // 200 但内容不是预期 JSON（HTML 登录页/网关页）
      if (status === 200 && looksLikeHtml(body)) {
        return {
          message: "接口返回了 HTML 而非 JSON，可能是接口地址错误或经过登录页/网关。",
          retryable: false,
        };
      }
      if (status === 200) {
        return { message: "接口返回格式不符合预期。", retryable: false };
      }

      if (status === 401) {
        return { message: "API Key 无效或未配置（HTTP 401）。请检查设置里的 API Key。", retryable: false };
      }
      if (status === 403) {
        return {
          message: "权限不足或 API Key 无权限（HTTP 403）。请检查账号权限或余额。",
          retryable: false,
        };
      }
      if (status === 404) {
        return {
          message: "接口地址错误（HTTP 404）。请检查接口地址是否包含 /chat/completions 路径。",
          retryable: false,
        };
      }
      if (status === 429) {
        return {
          message: "请求被限流（HTTP 429）。请稍后重试或检查额度/限流策略。",
          retryable: true,
        };
      }
      if (status >= 500) {
        return { message: `服务商出错（HTTP ${status}）。可稍后重试。`, retryable: true };
      }

      return { message: `翻译接口返回 HTTP ${status}。`, retryable: false };
    }
  }
}
