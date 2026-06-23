use arboard::Clipboard;
use std::thread;
use std::time::{Duration, Instant};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_CONTROL,
};

const VK_C: u16 = 0x43;

/// 发送一个键盘事件（按下或抬起）。
unsafe fn send_key(vk: u16, up: bool) {
    let mut flags = 0u32;
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let ptr = [input].as_ptr();
    // SendInput 返回成功注入的事件数；忽略返回值，失败也无能为力
    SendInput(1, ptr, std::mem::size_of::<INPUT>() as i32);
}

/// 模拟 Ctrl+C（直接调 Win32 SendInput，绕开 enigo）。
fn send_ctrl_c() {
    unsafe {
        // Ctrl 按下
        send_key(VK_CONTROL as u16, false);
        thread::sleep(Duration::from_millis(40));
        // C 按下
        send_key(VK_C, false);
        thread::sleep(Duration::from_millis(30));
        // C 抬起
        send_key(VK_C, true);
        thread::sleep(Duration::from_millis(30));
        // Ctrl 抬起
        send_key(VK_CONTROL as u16, true);
    }
}

/// 读取当前选中文本的内部实现（非命令，可被热键 handler 直接调用）。
/// 流程：保存原剪贴板 -> 模拟 Ctrl+C -> 等待新剪贴板 -> 恢复原剪贴板。
pub fn read_selection_impl() -> Result<String, String> {
    eprintln!("[read_selection] start");

    // 1. 保存原剪贴板文本（如果有的话）
    let mut clipboard = Clipboard::new().map_err(|e| {
        eprintln!("[read_selection] Clipboard::new failed: {e}");
        format!("无法访问剪贴板: {e}")
    })?;
    let original = clipboard.get_text().ok();
    eprintln!(
        "[read_selection] saved original clipboard, has_old={}",
        original.is_some()
    );

    // 2. 模拟 Ctrl+C（直接 SendInput，不经过 enigo）
    eprintln!("[read_selection] sending Ctrl+C via SendInput");
    send_ctrl_c();
    eprintln!("[read_selection] Ctrl+C sent");

    // 3. 轮询等待剪贴板变化（最多 800ms）
    let poll_start = Instant::now();
    let mut selected = String::new();
    let poll_interval = Duration::from_millis(40);
    let max_wait = Duration::from_millis(800);
    let orig_text = original.clone().unwrap_or_default();

    loop {
        thread::sleep(poll_interval);
        let mut cb = match Clipboard::new() {
            Ok(c) => c,
            Err(_) => continue,
        };
        if let Ok(text) = cb.get_text() {
            if text != orig_text && !text.trim().is_empty() {
                selected = text;
                break;
            }
        }
        if poll_start.elapsed() >= max_wait {
            break;
        }
    }
    eprintln!(
        "[read_selection] polled {}ms, selected len={}",
        poll_start.elapsed().as_millis(),
        selected.chars().count()
    );

    // 4. 恢复原剪贴板
    if let Some(orig) = original {
        let mut cb = Clipboard::new().map_err(|e| format!("无法访问剪贴板: {e}"))?;
        let _ = cb.set_text(orig);
        eprintln!("[read_selection] restored original clipboard");
    }

    let result = selected.trim().to_string();
    eprintln!(
        "[read_selection] done, returning len={}",
        result.chars().count()
    );
    Ok(result)
}

/// Tauri 命令版本（前端可通过 invoke 调用，保留兼容）。
#[tauri::command]
pub fn read_selection() -> Result<String, String> {
    read_selection_impl()
}
