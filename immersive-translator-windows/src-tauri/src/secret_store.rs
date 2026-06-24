//! Windows DPAPI 安全存储。
//!
//! 用 `CryptProtectData` 把 API Key 加密后写入应用数据目录下的 JSON 文件，
//! 只能由当前 Windows 用户解密。对齐 Mac 版 Keychain 的"不落盘明文"目标。
//!
//! 设计：
//! - 明文 key 永远不写入 settings JSON；settings JSON 里只保留一个布尔 `hasApiKey` 占位。
//! - 加密 blob 以 base64 存入 `app_data_dir/secrets.json`。
//! - DPAPI 绑定当前用户；换机 / 换用户会解密失败，此时返回空并让用户重新填。

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};
use windows_sys::Win32::Foundation::{LocalFree, BOOL};
use windows_sys::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB,
};
use windows_sys::Win32::System::Memory::{LocalAlloc, LPTR};

const SECRET_KEY: &str = "openai_api_key";

#[derive(Serialize, Deserialize, Default)]
struct SecretsFile {
    /// name -> base64(encrypted bytes)
    entries: HashMap<String, String>,
}

fn secrets_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("无法获取应用数据目录: {e}"))?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("无法创建数据目录: {e}"))?;
    Ok(dir.join("secrets.json"))
}

fn load_secrets(app: &AppHandle) -> SecretsFile {
    match secrets_path(app) {
        Ok(path) => {
            if let Ok(text) = std::fs::read_to_string(&path) {
                serde_json::from_str(&text).unwrap_or_default()
            } else {
                SecretsFile::default()
            }
        }
        Err(_) => SecretsFile::default(),
    }
}

fn save_secrets(app: &AppHandle, secrets: &SecretsFile) -> Result<(), String> {
    let path = secrets_path(app)?;
    let text = serde_json::to_string_pretty(secrets).map_err(|e| e.to_string())?;
    std::fs::write(&path, text).map_err(|e| format!("写入 secrets.json 失败: {e}"))
}

fn encrypt(plain: &str) -> Result<String, String> {
    let bytes = plain.as_bytes();
    let len = bytes.len();

    unsafe {
        // 分配一块可写内存并拷贝明文（DPAPI 读这块内存）。
        // LPTR = LMEM_ZEROINIT|LMEM_FIXED，返回固定指针可直接当 *mut u8 用。
        let ptr = LocalAlloc(LPTR, len);
        if ptr.is_null() {
            return Err("LocalAlloc 失败".into());
        }
        if len > 0 {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        }

        let input = CRYPT_INTEGER_BLOB {
            cbData: len as u32,
            pbData: ptr as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };

        // dwFlags=0: 绑定当前用户 + 当前机器的 Master Key
        let ok: BOOL = CryptProtectData(
            &input,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut output,
        );
        LocalFree(ptr);

        if ok == 0 {
            return Err("CryptProtectData 失败".into());
        }

        let cipher = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(output.pbData as _);

        Ok(B64.encode(cipher))
    }
}

fn decrypt(b64: &str) -> Result<String, String> {
    let cipher = B64
        .decode(b64.trim())
        .map_err(|e| format!("base64 解码失败: {e}"))?;
    let len = cipher.len();
    if len == 0 {
        return Err("空密文".into());
    }

    unsafe {
        let ptr = LocalAlloc(LPTR, len);
        if ptr.is_null() {
            return Err("LocalAlloc 失败".into());
        }
        std::ptr::copy_nonoverlapping(cipher.as_ptr(), ptr as *mut u8, len);

        let input = CRYPT_INTEGER_BLOB {
            cbData: len as u32,
            pbData: ptr as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };

        let ok: BOOL = CryptUnprotectData(
            &input,
            std::ptr::null_mut(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            0,
            &mut output,
        );
        LocalFree(ptr);

        if ok == 0 {
            return Err("CryptUnprotectData 失败（可能已换用户/换机）".into());
        }

        let plain_bytes =
            std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(output.pbData as _);

        String::from_utf8(plain_bytes).map_err(|e| format!("解密后非 UTF-8: {e}"))
    }
}

/// 读取 API Key 明文。不存在或解密失败都返回空串（让前端走重新填写流程）。
#[tauri::command]
pub fn secret_get(app: AppHandle) -> String {
    let secrets = load_secrets(&app);
    match secrets.entries.get(SECRET_KEY) {
        Some(b64) => match decrypt(b64) {
            Ok(plain) => plain,
            Err(e) => {
                eprintln!("[secret_store] decrypt failed: {e}");
                String::new()
            }
        },
        None => String::new(),
    }
}

/// 保存 API Key 明文（加密落盘）。空串会删除条目。
#[tauri::command]
pub fn secret_set(app: AppHandle, value: String) -> Result<(), String> {
    let mut secrets = load_secrets(&app);
    let trimmed = value.trim();
    if trimmed.is_empty() {
        secrets.entries.remove(SECRET_KEY);
    } else {
        let b64 = encrypt(trimmed)?;
        secrets.entries.insert(SECRET_KEY.into(), b64);
    }
    save_secrets(&app, &secrets)
}

/// 用于让前端判断 settings 里的 hasApiKey 占位是否还有效密钥。
#[tauri::command]
pub fn secret_exists(app: AppHandle) -> bool {
    load_secrets(&app).entries.contains_key(SECRET_KEY)
}
