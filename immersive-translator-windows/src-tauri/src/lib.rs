mod clipboard;
mod history;
mod ocr;
mod screenshot;
mod secret_store;
mod translation;

use std::str::FromStr;
use std::sync::Mutex;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[derive(Clone, serde::Serialize)]
struct PanelPayload {
    text: String,
    source: String,
}

#[derive(Default)]
struct PendingPanelPayload(Mutex<Option<PanelPayload>>);

fn show_panel_with_payload(app: &AppHandle, payload: PanelPayload) {
    let pending = app.state::<PendingPanelPayload>();
    *pending.0.lock().unwrap() = Some(payload.clone());

    let Some(panel) = app.get_webview_window("panel") else {
        eprintln!("[panel] panel window not found");
        return;
    };

    let _ = panel.show();
    let _ = panel.set_focus();
    let _ = panel.emit("panel:shown", payload);
}

#[tauri::command]
fn take_pending_panel_payload(
    state: tauri::State<'_, PendingPanelPayload>,
) -> Option<PanelPayload> {
    state.0.lock().unwrap().take()
}

#[tauri::command]
fn clear_pending_panel_payload(state: tauri::State<'_, PendingPanelPayload>) {
    *state.0.lock().unwrap() = None;
}

/// 打开设置窗口（前端可调用）。对齐托盘「设置」菜单的行为。
#[tauri::command]
fn open_settings(app: tauri::AppHandle) {
    use tauri::Manager;
    if let Some(win) = app.get_webview_window("settings") {
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// 打开历史记录窗口（前端可调用）。
#[tauri::command]
async fn open_history(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(win) = app.get_webview_window("history") {
        let _ = win.show();
        let _ = win.set_focus();
        return Ok(());
    }

    tauri::WebviewWindowBuilder::new(&app, "history", tauri::WebviewUrl::App("index.html".into()))
        .title("翻译历史")
        .inner_size(720.0, 560.0)
        .resizable(true)
        .minimizable(true)
        .maximizable(false)
        .center()
        .build()
        .map_err(|e| format!("打开历史窗口失败: {e}"))?;
    Ok(())
}

/// 进入截图 OCR 模式：显示全屏框选覆盖层。对齐 Mac 的 begin()。
/// 进入截图 OCR 模式：
/// 1. 确保 overlay 窗口隐藏
/// 2. 截取全屏（此时 overlay 不可见，不会出现在截图里）
/// 3. 把截图 base64 发给 overlay 窗口
/// 4. 显示 overlay（用户在截图上拖框）
#[tauri::command]
fn open_ocr_overlay(app: AppHandle) {
    use tauri::Manager;
    // 先确保 overlay 隐藏（否则它会出现在截图里）
    if let Some(win) = app.get_webview_window("ocr-overlay") {
        let _ = win.hide();
    }
    // 截全屏，并缓存原始 BGRA。OCR 识别时直接裁剪这张冻结截图。
    let snapshot = match screenshot::capture_fullscreen() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[ocr_overlay] 截图失败: {e}");
            return;
        }
    };
    let png = match screenshot::encode_png_data_url(&snapshot) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[ocr_overlay] PNG 编码失败: {e}");
            return;
        }
    };
    let engine = app.state::<ocr::OcrEngine>();
    ocr::set_fullscreen_snapshot(engine, snapshot);
    // 发给 overlay 窗口
    let _ = app.emit("ocr:fullscreen", png);
    // 显示 overlay
    if let Some(win) = app.get_webview_window("ocr-overlay") {
        let _ = win.show();
        let _ = win.set_focus();
    }
}

#[tauri::command]
fn show_ocr_result(app: AppHandle, text: String) {
    if let Some(overlay) = app.get_webview_window("ocr-overlay") {
        let _ = overlay.hide();
    }
    show_panel_with_payload(
        &app,
        PanelPayload {
            text,
            source: "ocr".into(),
        },
    );
}

fn show_window(app: &tauri::AppHandle, label: &str) {
    if let Some(win) = app.get_webview_window(label) {
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// 热键按下后的统一处理：隐藏已显示的 panel，否则模拟 Ctrl+C 读选区再 show。
fn trigger_panel(app: &AppHandle) {
    let panel = match app.get_webview_window("panel") {
        Some(p) => p,
        None => return,
    };
    if panel.is_visible().unwrap_or(false) {
        let _ = panel.hide();
        return;
    }
    let app_handle = app.clone();
    std::thread::spawn(move || {
        // 等热键释放，避免修饰键残留污染 Ctrl+C
        std::thread::sleep(std::time::Duration::from_millis(180));
        let selected = clipboard::read_selection_impl().unwrap_or_default();
        show_panel_with_payload(
            &app_handle,
            PanelPayload {
                text: selected,
                source: "selection".into(),
            },
        );
    });
}

/// 运行时切换全局热键。先注销全部，再注册新的，并持久化到 hotkey.txt。
/// 返回 Ok(normalized) 或 Err(原因)。
#[tauri::command]
fn reregister_hotkey(app: AppHandle, hotkey: String) -> Result<String, String> {
    let gs = app.global_shortcut();
    // 先全注销
    let _ = gs.unregister_all();

    let trimmed = hotkey.trim();
    if trimmed.is_empty() {
        return Err("热键为空".into());
    }
    let shortcut =
        Shortcut::from_str(trimmed).map_err(|e| format!("无法解析热键「{trimmed}」: {e}"))?;

    // 用 on_shortcut 注册 handler（每次注册需要新的 handler）
    gs.on_shortcut(shortcut, move |app, _shortcut, event| {
        if event.state != ShortcutState::Pressed {
            return;
        }
        trigger_panel(app);
    })
    .map_err(|e| format!("注册热键失败「{trimmed}」（可能已被系统或其它程序占用）: {e}"))?;

    // 持久化到 app_data_dir/hotkey.txt，供下次启动恢复
    if let Ok(appdata) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&appdata);
        let path = appdata.join("hotkey.txt");
        let _ = std::fs::write(&path, trimmed);
    }

    Ok(trimmed.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(translation::CancelFlag::default())
        .manage(ocr::OcrEngine::default())
        .manage(PendingPanelPayload::default())
        .invoke_handler(tauri::generate_handler![
            greet,
            take_pending_panel_payload,
            clear_pending_panel_payload,
            clipboard::read_selection,
            translation::translate_stream,
            translation::cancel_translation,
            translation::test_connectivity,
            ocr::ocr_models_ready,
            ocr::ocr_recognize,
            ocr::ocr_recognize_from_fullscreen,
            ocr::ocr_download_models,
            screenshot::capture_screenshot,
            screenshot::capture_fullscreen_png,
            secret_store::secret_get,
            secret_store::secret_set,
            secret_store::secret_exists,
            history::history_add,
            history::history_list,
            history::history_toggle_favorite,
            history::history_delete,
            history::history_clear_non_favorites,
            history::history_export,
            open_settings,
            open_history,
            open_ocr_overlay,
            show_ocr_result,
            reregister_hotkey,
        ])
        .setup(|app| {
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
            let history = MenuItem::with_id(app, "history", "翻译历史", true, None::<&str>)?;
            let ocr = MenuItem::with_id(app, "ocr", "截图翻译 (OCR)", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&ocr, &history, &settings, &quit])?;

            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("ImmersiveTranslator")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "quit" => app.exit(0),
                    "settings" => show_window(app, "settings"),
                    "history" => show_window(app, "history"),
                    "ocr" => {
                        // 截图 OCR：截全屏 → 发给 overlay → 显示 overlay
                        open_ocr_overlay(app.clone());
                    }
                    _ => {}
                })
                .build(app)?;

            // 注册默认全局热键 Ctrl+Shift+Q（启动占位；用户改键后由 reregister_hotkey 覆盖）。
            // 热键按下后的实际逻辑见 trigger_panel。
            app.global_shortcut()
                .on_shortcut("Ctrl+Shift+Q", |app, _shortcut, event| {
                    if event.state != ShortcutState::Pressed {
                        return;
                    }
                    trigger_panel(app);
                })?;

            // 启动后用用户保存的热键覆盖默认（hotkey.txt 在 app_data_dir，前端 saveSettingsAsync 写入）。
            if let Ok(appdata) = app.path().app_data_dir() {
                let path = appdata.join("hotkey.txt");
                if let Ok(hk) = std::fs::read_to_string(&path) {
                    let hk = hk.trim();
                    if !hk.is_empty() && hk != "Ctrl+Shift+Q" {
                        let _ = reregister_hotkey(app.handle().clone(), hk.to_string());
                    }
                }
            }

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
