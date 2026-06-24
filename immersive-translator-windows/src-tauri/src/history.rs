//! 翻译历史本地存储。对齐 Mac 版 TranslationHistoryStore。
//!
//! - 存储路径：app_data_dir/history.json
//! - 上限 500 条，超出按时间最旧淘汰。
//! - 支持按原文/译文/目标语言/来源/收藏状态搜索。
//! - 支持导出为 CSV / JSON / Markdown / 纯文本。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

const MAX_RECORDS: usize = 500;

/// 来源类型，对齐 Mac TranslationSource。
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HistorySource {
    /// 选中文本翻译（Ctrl+C 模拟）
    Selection,
    /// 截图 OCR 翻译（Windows 暂未实现，预留）
    Ocr,
}

impl HistorySource {
    pub fn display_name(&self) -> &'static str {
        match self {
            HistorySource::Selection => "选中",
            HistorySource::Ocr => "OCR",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRecord {
    pub id: String,
    /// Unix 毫秒时间戳
    #[serde(alias = "created_at")]
    pub created_at: i64,
    pub original: String,
    pub translation: String,
    #[serde(alias = "target_language")]
    pub target_language: String,
    pub source: HistorySource,
    #[serde(alias = "is_favorite")]
    pub is_favorite: bool,
    /// 使用的模型（用于诊断/复盘）
    pub model: String,
    /// 翻译耗时（毫秒）
    #[serde(alias = "elapsed_ms")]
    pub elapsed_ms: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
struct HistoryFile {
    records: Vec<HistoryRecord>,
}

fn history_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("无法获取应用数据目录: {e}"))?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("无法创建数据目录: {e}"))?;
    Ok(dir.join("history.json"))
}

fn load(app: &AppHandle) -> HistoryFile {
    match history_path(app) {
        Ok(path) => {
            if let Ok(text) = std::fs::read_to_string(&path) {
                serde_json::from_str(&text).unwrap_or_default()
            } else {
                HistoryFile::default()
            }
        }
        Err(_) => HistoryFile::default(),
    }
}

fn save(app: &AppHandle, file: &HistoryFile) -> Result<(), String> {
    let path = history_path(app)?;
    let text = serde_json::to_string_pretty(file).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("写入 history.json 失败: {e}"))
}

fn new_id() -> String {
    // 简单的时间戳 + 计数，避免引入 uuid 依赖。
    // 用纳秒时间戳 + 进程 id 的低位拼接，碰撞概率极低。
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("h-{nanos}-{}", std::process::id() & 0xffff)
}

/// 追加一条历史记录（自动维持上限）。
#[tauri::command]
pub fn history_add(
    app: AppHandle,
    original: String,
    translation: String,
    target_language: String,
    source: HistorySource,
    model: String,
    elapsed_ms: u64,
) -> Result<HistoryRecord, String> {
    let mut file = load(&app);
    let rec = HistoryRecord {
        id: new_id(),
        created_at: now_ms(),
        original: original.trim().to_string(),
        translation,
        target_language,
        source,
        is_favorite: false,
        model,
        elapsed_ms,
    };
    file.records.insert(0, rec.clone());
    // 超出上限：优先淘汰非收藏的最旧记录
    while file.records.len() > MAX_RECORDS {
        if let Some(idx) = file.records.iter().rposition(|r| !r.is_favorite) {
            file.records.remove(idx);
        } else {
            // 全是收藏，直接弹最旧
            file.records.pop();
        }
    }
    save(&app, &file)?;
    Ok(rec)
}

/// 读取全部历史（按时间倒序）。可选按 query 过滤。
#[tauri::command]
pub fn history_list(app: AppHandle, query: Option<String>) -> Vec<HistoryRecord> {
    let file = load(&app);
    let q = query.as_deref().map(|s| s.trim()).unwrap_or("");
    if q.is_empty() {
        return file.records;
    }
    let lower = q.to_lowercase();
    // 对齐 Mac：支持 OCR / 收藏 / 未收藏 关键词
    let (want_fav, _fav_filter) = match lower.as_str() {
        "收藏" => (Some(true), true),
        "未收藏" => (Some(false), true),
        "ocr" => (None, false),
        _ => (None, false),
    };
    let is_ocr_query = lower == "ocr";

    file.records
        .into_iter()
        .filter(|r| {
            if let Some(fav) = want_fav {
                if r.is_favorite != fav {
                    return false;
                }
            }
            if is_ocr_query {
                return r.source == HistorySource::Ocr;
            }
            r.original.to_lowercase().contains(&lower)
                || r.translation.to_lowercase().contains(&lower)
                || r.target_language.to_lowercase().contains(&lower)
                || r.source.display_name().to_lowercase().contains(&lower)
        })
        .collect()
}

/// 切换某条记录的收藏状态。
#[tauri::command]
pub fn history_toggle_favorite(app: AppHandle, id: String) -> Result<(), String> {
    let mut file = load(&app);
    for r in file.records.iter_mut() {
        if r.id == id {
            r.is_favorite = !r.is_favorite;
            save(&app, &file)?;
            return Ok(());
        }
    }
    Err("记录不存在".into())
}

/// 删除一条记录。
#[tauri::command]
pub fn history_delete(app: AppHandle, id: String) -> Result<(), String> {
    let mut file = load(&app);
    let before = file.records.len();
    file.records.retain(|r| r.id != id);
    if file.records.len() == before {
        return Err("记录不存在".into());
    }
    save(&app, &file)
}

/// 清空非收藏的历史（对齐 Mac：收藏不会被清空，需二次确认）。
#[tauri::command]
pub fn history_clear_non_favorites(app: AppHandle) -> Result<usize, String> {
    let mut file = load(&app);
    let before = file.records.len();
    file.records.retain(|r| r.is_favorite);
    let removed = before - file.records.len();
    save(&app, &file)?;
    Ok(removed)
}

/// 导出格式。
#[derive(Serialize, Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum ExportFormat {
    Csv,
    Json,
    Markdown,
    Text,
}

/// 把记录列表导出为指定格式的字符串（前端可直接保存或复制）。
#[tauri::command]
pub fn history_export(
    app: AppHandle,
    query: Option<String>,
    favorites_only: bool,
    format: ExportFormat,
) -> Result<String, String> {
    let records = history_list_inner(&app, query.as_deref(), favorites_only);
    Ok(match format {
        ExportFormat::Json => serde_json::to_string_pretty(&records).map_err(|e| e.to_string())?,
        ExportFormat::Csv => to_csv(&records),
        ExportFormat::Markdown => to_markdown(&records),
        ExportFormat::Text => to_text(&records),
    })
}

fn history_list_inner(
    app: &AppHandle,
    query: Option<&str>,
    favorites_only: bool,
) -> Vec<HistoryRecord> {
    let file = load(app);
    let q = query.unwrap_or("").trim();
    let lower = q.to_lowercase();
    let (want_fav, _fav_filter) = match lower.as_str() {
        "收藏" => (Some(true), true),
        "未收藏" => (Some(false), true),
        _ => (None, false),
    };
    let is_ocr_query = lower == "ocr";

    file.records
        .into_iter()
        .filter(|r| {
            if favorites_only && !r.is_favorite {
                return false;
            }
            if let Some(fav) = want_fav {
                if r.is_favorite != fav {
                    return false;
                }
            }
            if is_ocr_query {
                return r.source == HistorySource::Ocr;
            }
            if q.is_empty() {
                return true;
            }
            r.original.to_lowercase().contains(&lower)
                || r.translation.to_lowercase().contains(&lower)
                || r.target_language.to_lowercase().contains(&lower)
        })
        .collect()
}

fn fmt_time(ms: i64) -> String {
    // 简单格式化为 ISO-ish，避免引入 chrono。
    use std::time::{SystemTime, UNIX_EPOCH};
    let _ = SystemTime::now().duration_since(UNIX_EPOCH);
    // 直接用秒级 UTC + 本地偏移太复杂，这里输出 unix 毫秒，前端做友好展示。
    ms.to_string()
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn to_csv(records: &[HistoryRecord]) -> String {
    let mut out = String::from(
        "created_at,source,target_language,model,elapsed_ms,is_favorite,original,translation\n",
    );
    for r in records {
        out.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            csv_escape(&fmt_time(r.created_at)),
            csv_escape(r.source.display_name()),
            csv_escape(&r.target_language),
            csv_escape(&r.model),
            r.elapsed_ms,
            r.is_favorite,
            csv_escape(&r.original),
            csv_escape(&r.translation),
        ));
    }
    out
}

fn to_markdown(records: &[HistoryRecord]) -> String {
    let mut out = String::from("# 翻译历史\n\n");
    for r in records {
        out.push_str(&format!(
            "## {}（{} → {}，耗时 {:.1}s）\n\n**原文：**\n\n{}\n\n**译文：**\n\n{}\n\n---\n\n",
            fmt_time(r.created_at),
            r.source.display_name(),
            if r.target_language.is_empty() {
                "未指定"
            } else {
                &r.target_language
            },
            r.elapsed_ms as f64 / 1000.0,
            r.original,
            r.translation,
        ));
    }
    out
}

fn to_text(records: &[HistoryRecord]) -> String {
    let mut out = String::new();
    for r in records {
        out.push_str(&format!(
            "[{}] 原文：\n{}\n译文：\n{}\n\n",
            fmt_time(r.created_at),
            r.original,
            r.translation
        ));
    }
    out
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
