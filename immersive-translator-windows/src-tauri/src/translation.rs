use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tauri::{AppHandle, Emitter, State};

/// 全局取消标志。translate_stream 启动时置 false，
/// cancel_translation 命令置 true，流式循环据此提前退出。
#[derive(Default)]
pub struct CancelFlag(Arc<AtomicBool>);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranslateRequest {
    pub text: String,
    pub endpoint: String, // OpenAI 兼容接口地址
    pub api_key: String,
    pub model: String,
    pub system_prompt: String,
    pub stream: bool,
    pub window_label: String, // 发送事件的目标窗口 label，默认 "panel"
}

/// 流式阶段，对齐 Mac 版的状态机：
/// - connecting：已发出请求，等待服务商响应（TCP/TLS + 排队）
/// - waitingFirstToken：已收到响应头（HTTP 200），等待第一个可见文字
/// - streaming：正在输出文字
/// - done：完成
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct StatusEvent {
    phase: String,
    /// 已耗时（毫秒）
    elapsed_ms: u128,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DeltaEvent {
    text: String,
    /// 从请求发出到当前的累计毫秒。
    elapsed_ms: u128,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DoneEvent {
    text: String,
    /// 总耗时（请求发出到完成）。
    elapsed_ms: u128,
    /// 连接耗时（请求发出到收到响应头）。
    connect_ms: u128,
    /// 首字耗时（收到响应头到第一个可见文字）。
    first_token_ms: u128,
    model: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ErrorEvent {
    kind: String, // "http" | "network" | "timeout" | "empty" | "invalid"
    status: Option<u16>,
    body: String,
    /// 失败时已耗时（毫秒），用于面板展示。
    elapsed_ms: u128,
}

/// 规范化接口地址：确保以 /chat/completions 结尾。对齐 Mac 版逻辑。
fn normalize_endpoint(endpoint: &str) -> String {
    let trimmed = endpoint.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed.ends_with("/chat/completions") {
        trimmed.to_string()
    } else if trimmed.ends_with("/v1") {
        format!("{trimmed}/chat/completions")
    } else {
        format!("{trimmed}/v1/chat/completions")
    }
}

fn build_body(req: &TranslateRequest, stream: bool) -> serde_json::Value {
    let mut body = serde_json::json!({
        "model": req.model,
        "stream": stream,
        "messages": [
            { "role": "system", "content": req.system_prompt },
            { "role": "user", "content": format!("<text>{}</text>", req.text) }
        ]
    });

    // 思考模式兼容：DeepSeek / 智谱 的推理模型会输出 <think> 噪声，
    // 在翻译场景下我们不需要思考过程，主动关闭。
    apply_thinking_mode_compat(&mut body, &req.endpoint, &req.model);

    body
}

/// 按服务商/模型关闭思考模式，避免译文里混入 <think>…</think> 噪声。
/// 对齐 Mac 版 ProviderProfile 的处理。
fn apply_thinking_mode_compat(body: &mut serde_json::Value, endpoint: &str, model: &str) {
    let ep = endpoint.to_lowercase();
    let m = model.to_lowercase();

    // 智谱 GLM：glm-4.5 / glm-z1 / glm-4.6 等支持思考的模型。
    // 官方 OpenAI 兼容路径用 thinking.type=disabled。
    if ep.contains("bigmodel") || ep.contains("zhipu") {
        if m.contains("glm-4.5")
            || m.contains("glm-4.6")
            || m.contains("glm-z1")
            || m.contains("glm-4-plus")
        {
            body["thinking"] = serde_json::json!({ "type": "disabled" });
            return;
        }
    }

    // DeepSeek：deepseek-reasoner 默认会思考。OpenAI 兼容路径下
    // 无法用标准字段关闭（reasoning 字段非标准），但 deepseek-chat 不思考，
    // 所以仅在 reasoner 模型上加提示性字段（部分网关识别）。
    if ep.contains("deepseek") && m.contains("reasoner") {
        body["enable_thinking"] = serde_json::Value::Bool(false);
        return;
    }

    // 通义千问 Qwen：qwen3 / qwq 系列在兼容模式下用 enable_thinking=false。
    if ep.contains("dashscope") || ep.contains("tongyi") || ep.contains("qwen") {
        if m.contains("qwen3") || m.contains("qwq") {
            body["enable_thinking"] = serde_json::Value::Bool(false);
            return;
        }
    }
}

#[tauri::command]
pub async fn translate_stream(
    app: AppHandle,
    cancel: State<'_, CancelFlag>,
    req: TranslateRequest,
) -> Result<(), String> {
    // 重置取消标志（新请求开始）
    cancel.0.store(false, Ordering::SeqCst);
    let target = normalize_endpoint(&req.endpoint);
    let window_label = req.window_label.clone();
    if target.is_empty() {
        let _ = app.emit_to(
            window_label.as_str(),
            "translation:error",
            ErrorEvent {
                kind: "invalid".into(),
                status: None,
                body: "接口地址为空".into(),
                elapsed_ms: 0,
            },
        );
        return Err("接口地址为空".into());
    }

    let request_start = Instant::now();

    // 阶段 1：connecting
    let _ = app.emit_to(
        window_label.as_str(),
        "translation:status",
        StatusEvent {
            phase: "connecting".into(),
            elapsed_ms: 0,
        },
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;

    let mut request_builder = client
        .post(&target)
        .header("Content-Type", "application/json");

    if !req.api_key.trim().is_empty() {
        request_builder =
            request_builder.header("Authorization", format!("Bearer {}", req.api_key));
    }

    let body = build_body(&req, req.stream);
    let response = request_builder.json(&body).send().await;

    let response = match response {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:error",
                ErrorEvent {
                    kind: "timeout".into(),
                    status: None,
                    body: e.to_string(),
                    elapsed_ms: request_start.elapsed().as_millis(),
                },
            );
            return Ok(());
        }
        Err(e) => {
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:error",
                ErrorEvent {
                    kind: "network".into(),
                    status: None,
                    body: e.to_string(),
                    elapsed_ms: request_start.elapsed().as_millis(),
                },
            );
            return Ok(());
        }
    };

    // 收到响应头：连接耗时确定
    let connect_ms = request_start.elapsed().as_millis();
    let status = response.status().as_u16();
    if !response.status().is_success() {
        let body_text = response.text().await.unwrap_or_default();
        let _ = app.emit_to(
            window_label.as_str(),
            "translation:error",
            ErrorEvent {
                kind: "http".into(),
                status: Some(status),
                body: body_text,
                elapsed_ms: request_start.elapsed().as_millis(),
            },
        );
        return Ok(());
    }

    // 阶段 2：waitingFirstToken
    let _ = app.emit_to(
        window_label.as_str(),
        "translation:status",
        StatusEvent {
            phase: "waitingFirstToken".into(),
            elapsed_ms: connect_ms,
        },
    );

    // firstToken 计时基点：收到响应头之后。首字耗时 = response_header 时间到第一个可见 delta。
    let first_token_start = Instant::now();

    if req.stream {
        // 流式：按行读取 SSE data: 行
        use futures_util::StreamExt;
        let mut stream = response.bytes_stream();
        let mut buffer = String::new();
        let mut full_text = String::new();
        let mut first_token_ms: Option<u128> = None;

        while let Some(chunk_result) = stream.next().await {
            // 用户点了取消：提前结束，发 cancelled 事件
            if cancel.0.load(Ordering::SeqCst) {
                let _ = app.emit_to(
                    window_label.as_str(),
                    "translation:cancelled",
                    serde_json::json!({
                        "partial": strip_think_tags(&full_text),
                        "elapsedMs": request_start.elapsed().as_millis(),
                    }),
                );
                return Ok(());
            }
            let chunk = match chunk_result {
                Ok(c) => c,
                Err(e) => {
                    let _ = app.emit_to(
                        window_label.as_str(),
                        "translation:error",
                        ErrorEvent {
                            kind: "network".into(),
                            status: None,
                            body: e.to_string(),
                            elapsed_ms: request_start.elapsed().as_millis(),
                        },
                    );
                    return Ok(());
                }
            };
            buffer.push_str(std::str::from_utf8(&chunk).unwrap_or(""));
            // 按行处理
            while let Some(newline_idx) = buffer.find('\n') {
                let line: String = buffer.drain(..=newline_idx).collect();
                let trimmed = line.trim();
                if !trimmed.starts_with("data:") {
                    continue;
                }
                let data = trimmed.trim_start_matches("data:").trim();
                if data == "[DONE]" {
                    continue;
                }
                // 解析 JSON: choices[0].delta.content
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(data) {
                    // 思考模型可能把推理过程放在 reasoning_content / reasoning 字段，跳过
                    let content = v["choices"][0]["delta"]["content"].as_str();
                    let content = match content {
                        Some(c) => c,
                        None => continue,
                    };
                    // 忽略空 delta（对齐 Mac：部分服务先发空 content 占位）
                    if content.is_empty() {
                        continue;
                    }
                    if first_token_ms.is_none() {
                        first_token_ms = Some(first_token_start.elapsed().as_millis());
                        // 阶段 3：streaming
                        let _ = app.emit_to(
                            window_label.as_str(),
                            "translation:status",
                            StatusEvent {
                                phase: "streaming".into(),
                                elapsed_ms: request_start.elapsed().as_millis(),
                            },
                        );
                    }
                    full_text.push_str(content);
                    // 剥离 <think>…</think> 思考噪声（兼容未关思考的模型）
                    let display = strip_think_tags(&full_text);
                    if display.trim().is_empty() {
                        // 全是思考内容，不更新展示，等真正正文
                        continue;
                    }
                    let _ = app.emit_to(
                        window_label.as_str(),
                        "translation:delta",
                        DeltaEvent {
                            text: display,
                            elapsed_ms: request_start.elapsed().as_millis(),
                        },
                    );
                }
            }
        }

        if full_text.trim().is_empty() {
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:error",
                ErrorEvent {
                    kind: "empty".into(),
                    status: None,
                    body: String::new(),
                    elapsed_ms: request_start.elapsed().as_millis(),
                },
            );
        } else {
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:done",
                DoneEvent {
                    text: strip_think_tags(&full_text),
                    elapsed_ms: request_start.elapsed().as_millis(),
                    connect_ms,
                    first_token_ms: first_token_ms.unwrap_or(0),
                    model: req.model.clone(),
                },
            );
        }
    } else {
        // 非流式：直接解析完整 JSON
        let body_text = response.text().await.unwrap_or_default();
        let parsed: serde_json::Value = match serde_json::from_str(&body_text) {
            Ok(v) => v,
            Err(_) => {
                let _ = app.emit_to(
                    window_label.as_str(),
                    "translation:error",
                    ErrorEvent {
                        kind: "invalid".into(),
                        status: Some(200),
                        body: body_text,
                        elapsed_ms: request_start.elapsed().as_millis(),
                    },
                );
                return Ok(());
            }
        };
        let content = strip_think_tags(
            parsed["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or(""),
        )
        .trim()
        .to_string();

        if content.is_empty() {
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:error",
                ErrorEvent {
                    kind: "empty".into(),
                    status: None,
                    body: String::new(),
                    elapsed_ms: request_start.elapsed().as_millis(),
                },
            );
        } else {
            // 非流式：首字耗时 ≈ 整个响应体的接收耗时
            let first_token_ms = first_token_start.elapsed().as_millis();
            let _ = app.emit_to(
                window_label.as_str(),
                "translation:done",
                DoneEvent {
                    text: content,
                    elapsed_ms: request_start.elapsed().as_millis(),
                    connect_ms,
                    first_token_ms,
                    model: req.model.clone(),
                },
            );
        }
    }

    Ok(())
}

/// 连通性测试结果，用于设置页「测试当前接口」按钮。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectivityResult {
    pub ok: bool,
    pub status: Option<u16>,
    pub message: String,
    /// 耗时（毫秒）
    pub elapsed_ms: u128,
}

/// 用一个极小的请求探测接口可用性（1 token 上限），返回状态 + 耗时 + 简要信息。
/// 不会翻译真实文本，避免消耗额度。
#[tauri::command]
pub async fn test_connectivity(
    endpoint: String,
    api_key: String,
    model: String,
) -> Result<ConnectivityResult, String> {
    let start = Instant::now();
    let target = normalize_endpoint(&endpoint);
    if target.is_empty() {
        return Ok(ConnectivityResult {
            ok: false,
            status: None,
            message: "接口地址为空".into(),
            elapsed_ms: start.elapsed().as_millis(),
        });
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;

    let body = serde_json::json!({
        "model": model,
        "stream": false,
        "max_tokens": 1,
        "messages": [{ "role": "user", "content": "hi" }]
    });

    let mut req = client
        .post(&target)
        .header("Content-Type", "application/json")
        .json(&body);
    if !api_key.trim().is_empty() {
        req = req.header("Authorization", format!("Bearer {}", api_key));
    }

    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            return Ok(ConnectivityResult {
                ok: false,
                status: None,
                message: format!(
                    "连接超时（{:.1}s）",
                    start.elapsed().as_millis() as f64 / 1000.0
                ),
                elapsed_ms: start.elapsed().as_millis(),
            });
        }
        Err(e) => {
            return Ok(ConnectivityResult {
                ok: false,
                status: None,
                message: format!("无法连接：{e}"),
                elapsed_ms: start.elapsed().as_millis(),
            });
        }
    };

    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();
    let elapsed = start.elapsed().as_millis();

    if status >= 200 && status < 300 {
        // 200 但要确认返回里有 choices（避免网关 200 假成功）
        let has_choices = serde_json::from_str::<serde_json::Value>(&text)
            .map(|v| v["choices"].is_array())
            .unwrap_or(false);
        if has_choices {
            return Ok(ConnectivityResult {
                ok: true,
                status: Some(status),
                message: format!("连接正常，模型可用（{:.1}s）", elapsed as f64 / 1000.0),
                elapsed_ms: elapsed,
            });
        }
        return Ok(ConnectivityResult {
            ok: false,
            status: Some(status),
            message: format!(
                "HTTP 200 但响应缺少 choices 字段，可能是网关：{}",
                truncate(&text, 120)
            ),
            elapsed_ms: elapsed,
        });
    }

    Ok(ConnectivityResult {
        ok: false,
        status: Some(status),
        message: format!("HTTP {status}：{}", truncate(&text, 150)),
        elapsed_ms: elapsed,
    })
}

fn truncate(s: &str, max: usize) -> String {
    let t = s.trim();
    if t.chars().count() <= max {
        return t.to_string();
    }
    let mut out: String = t.chars().take(max).collect();
    out.push('…');
    out
}

/// 剥离 <think>…</think>（含未闭合的情况）思考噪声。
/// 对齐 Mac：部分模型即使声明关闭思考，仍可能输出 think 标签。
fn strip_think_tags(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let bytes = input.as_bytes();
    let lower = input.to_lowercase();
    let lb = lower.as_bytes();
    while i < bytes.len() {
        // 检测 <think> 开始
        if input[i..].starts_with('<') && lb[i..].starts_with(b"<think") {
            // 找到对应的 </think>
            if let Some(end_rel) = lower[i..].find("</think>") {
                i += end_rel + "</think>".len();
                continue;
            } else {
                // 未闭合：丢弃后续全部思考内容
                break;
            }
        }
        // 安全追加一个 UTF-8 字符
        let ch_start = i;
        // 找到下一个字符边界
        i += 1;
        while i < bytes.len() && (bytes[i] & 0xC0) == 0x80 {
            i += 1;
        }
        out.push_str(&input[ch_start..i]);
    }
    out
}

/// 取消当前正在进行的翻译（流式）。触发后流式循环在下一次 chunk 检查时退出。
#[tauri::command]
pub fn cancel_translation(cancel: State<'_, CancelFlag>) {
    cancel.0.store(true, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_think_removes_closed_block() {
        assert_eq!(strip_think_tags("<think>hello</think>world"), "world");
    }

    #[test]
    fn strip_think_removes_unclosed_block() {
        // 未闭合 think：丢弃后续
        assert_eq!(strip_think_tags("a<think>thinking"), "a");
    }

    #[test]
    fn strip_think_preserves_surrounding_text() {
        assert_eq!(
            strip_think_tags("before<think>x</think>after"),
            "beforeafter"
        );
    }

    #[test]
    fn strip_think_case_insensitive() {
        assert_eq!(strip_think_tags("<THINK>x</THINK>y"), "y");
    }

    #[test]
    fn strip_think_no_tags_unchanged() {
        assert_eq!(strip_think_tags("普通文本 中文"), "普通文本 中文");
    }

    #[test]
    fn normalize_endpoint_appends_v1() {
        assert_eq!(
            normalize_endpoint("https://api.example.com"),
            "https://api.example.com/v1/chat/completions"
        );
    }

    #[test]
    fn normalize_endpoint_appends_chat_completions() {
        assert_eq!(
            normalize_endpoint("https://api.example.com/v1"),
            "https://api.example.com/v1/chat/completions"
        );
    }

    #[test]
    fn normalize_endpoint_already_complete() {
        assert_eq!(
            normalize_endpoint("https://api.example.com/v1/chat/completions/"),
            "https://api.example.com/v1/chat/completions"
        );
    }
}
