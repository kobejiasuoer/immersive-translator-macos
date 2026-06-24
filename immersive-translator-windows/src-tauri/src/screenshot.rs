//! 屏幕截图。对齐 Mac 版 ScreenSelection 的截图部分。
//!
//! 用 Win32 GDI 的 BitBlt 从屏幕 DC 抠取指定矩形区域，返回 BGRA 字节。
//! 框选交互由前端的透明覆盖窗口完成，确定选区后调用 capture_region。

use base64::Engine as _;
use windows_sys::Win32::Foundation::{POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    GetDeviceCaps, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT,
    DIB_RGB_COLORS, HORZRES, SRCCOPY, VERTRES,
};

/// 截图结果：BGRA 字节 + 宽高。
#[derive(Clone)]
pub struct CapturedImage {
    pub bgra: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// 抠取屏幕上 [x, y, x+w, y+h] 区域为 BGRA 字节。
///
/// 坐标基于主显示器左上角（物理像素）。
/// 返回 32bpp BGRA（每像素 4 字节，B 在前），供 ocr_recognize 使用。
pub fn capture_region(x: i32, y: i32, w: i32, h: i32) -> Result<CapturedImage, String> {
    if w <= 0 || h <= 0 {
        return Err(format!("截图区域尺寸无效: {w}x{h}"));
    }

    unsafe {
        // 1. 获取屏幕 DC
        let hwnd: windows_sys::Win32::Foundation::HWND = std::ptr::null_mut(); // null = 整个屏幕
        let screen_dc = GetDC(hwnd);
        if screen_dc.is_null() {
            return Err("GetDC 失败".into());
        }

        // 2. 创建兼容 DC + 位图
        let mem_dc = CreateCompatibleDC(screen_dc);
        if mem_dc.is_null() {
            ReleaseDC(hwnd, screen_dc);
            return Err("CreateCompatibleDC 失败".into());
        }

        let bitmap = CreateCompatibleBitmap(screen_dc, w, h);
        if bitmap.is_null() {
            DeleteDC(mem_dc);
            ReleaseDC(hwnd, screen_dc);
            return Err("CreateCompatibleBitmap 失败".into());
        }

        let old_obj = SelectObject(mem_dc, bitmap);

        // 3. BitBlt 从屏幕拷贝到内存位图
        //    CAPTUREBLT 让分层窗口也被捕获
        let ok = BitBlt(mem_dc, 0, 0, w, h, screen_dc, x, y, SRCCOPY | CAPTUREBLT);
        if ok == 0 {
            SelectObject(mem_dc, old_obj);
            DeleteObject(bitmap);
            DeleteDC(mem_dc);
            ReleaseDC(hwnd, screen_dc);
            return Err("BitBlt 失败".into());
        }

        // 4. 准备 BITMAPINFO，请求 32bpp BGRA
        let mut bmi: BITMAPINFO = std::mem::zeroed();
        bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h; // 负值 = 自上而下（正常阅读顺序）
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        let buf_size = (w as usize) * (h as usize) * 4;
        let mut buf = vec![0u8; buf_size];

        let got = GetDIBits(
            mem_dc,
            bitmap,
            0,
            h as u32,
            buf.as_mut_ptr() as *mut _,
            &mut bmi as *mut BITMAPINFO,
            DIB_RGB_COLORS,
        );

        // 清理 GDI 资源
        SelectObject(mem_dc, old_obj);
        DeleteObject(bitmap);
        DeleteDC(mem_dc);
        ReleaseDC(hwnd, screen_dc);

        if got == 0 {
            return Err("GetDIBits 失败".into());
        }

        Ok(CapturedImage {
            bgra: buf,
            width: w as u32,
            height: h as u32,
        })
    }
}

/// 获取主显示器的物理尺寸（像素），用于覆盖层窗口铺满。
pub fn screen_size() -> (i32, i32) {
    unsafe {
        let hwnd: windows_sys::Win32::Foundation::HWND = std::ptr::null_mut();
        let dc = GetDC(hwnd);
        if dc.is_null() {
            return (1920, 1080);
        }
        let w = GetDeviceCaps(dc, HORZRES as i32);
        let h = GetDeviceCaps(dc, VERTRES as i32);
        ReleaseDC(hwnd, dc);
        (w, h)
    }
}

/// 截图 Tauri 命令：抠取区域，返回 base64 编码的 BGRA（供前端预览）+ 元数据。
/// OCR 识别走 ocr_recognize 直接传字节，不经此命令。
#[tauri::command]
pub fn capture_screenshot(x: i32, y: i32, w: i32, h: i32) -> Result<CaptureResult, String> {
    let img = capture_region(x, y, w, h)?;
    Ok(CaptureResult {
        width: img.width,
        height: img.height,
        bgra: img.bgra,
    })
}

/// 截图命令返回：BGRA 字节 + 宽高。前端可直接传给 ocr_recognize。
#[derive(serde::Serialize)]
pub struct CaptureResult {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

/// 截取主显示器全屏为 BGRA 字节。
pub fn capture_fullscreen() -> Result<CapturedImage, String> {
    let (w, h) = screen_size();
    capture_region(0, 0, w, h)
}

/// 把 BGRA 截图编码为 base64 PNG data URL，供覆盖层当冻结背景使用。
pub fn encode_png_data_url(img: &CapturedImage) -> Result<String, String> {
    // BGRA → RGB → DynamicImage → PNG
    let rgb = bgra_to_rgb(&img.bgra);
    let rgb_img = image::RgbImage::from_raw(img.width, img.height, rgb)
        .ok_or_else(|| "构造 RgbImage 失败".to_string())?;
    let dyn_img = image::DynamicImage::ImageRgb8(rgb_img);

    // 编码为 PNG
    let mut png_buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut png_buf);
    dyn_img
        .write_to(&mut cursor, image::ImageFormat::Png)
        .map_err(|e| format!("PNG 编码失败: {e}"))?;

    let b64 = base64::engine::general_purpose::STANDARD.encode(&png_buf);
    Ok(format!("data:image/png;base64,{}", b64))
}

/// 截取全屏并返回 base64 编码的 PNG（data URL）。
/// 用于 OCR 框选覆盖层：WebView2 透明窗口不可靠，
/// 改用截图作为背景，让用户看到"冻结的屏幕"再在上面拖框。
#[tauri::command]
pub fn capture_fullscreen_png() -> Result<String, String> {
    let img = capture_fullscreen()?;
    encode_png_data_url(&img)
}

/// BGRA → RGB（丢弃 alpha，交换 B/R）。
fn bgra_to_rgb(bgra: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(bgra.len() / 4 * 3);
    for chunk in bgra.chunks_exact(4) {
        rgb.push(chunk[2]); // R
        rgb.push(chunk[1]); // G
        rgb.push(chunk[0]); // B
    }
    rgb
}

// 抑制未使用导入（RECT/POINT 在多屏扩展时用得到）
#[allow(dead_code)]
const _: fn() = || {
    let _ = std::ptr::null::<RECT>();
    let _ = std::ptr::null::<POINT>();
};
