//! OCR 最小验证：加载 det+rec 模型，识别一张测试图，打印识别结果。
//! 运行：cargo run --example ocr_smoke
//!
//! 验证：paddle-ocr-rs + ort 在本项目里能真正跑通识别（不只是编译）。

use paddle_ocr_rs::ocr_lite::OcrLite;

fn main() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let models_dir = std::path::Path::new(manifest_dir).join("models");
    let det = models_dir.join("ch_PP-OCRv4_det_infer.onnx");
    let rec = models_dir.join("ch_PP-OCRv4_rec_infer.onnx");

    if !det.exists() {
        eprintln!("缺少 det 模型: {:?}", det);
        std::process::exit(1);
    }
    if !rec.exists() {
        eprintln!("缺少 rec 模型: {:?}", rec);
        std::process::exit(1);
    }

    println!("加载模型...");
    let det_s = det.to_str().unwrap();
    let rec_s = rec.to_str().unwrap();

    let mut ocr = OcrLite::new();
    // cls 用 det 占位（doAngle=false 时不会调用 cls）
    ocr.init_models(det_s, det_s, rec_s, 2)
        .expect("加载模型失败");
    println!("模型加载完成");

    // 读测试图（在项目根，即 src-tauri 的上级）
    let test_img = std::path::Path::new(manifest_dir)
        .join("..")
        .join("test_ocr.png");
    println!("识别图片: {:?}", test_img);
    let img = image::open(&test_img).expect("打开测试图失败").to_rgb8();

    let start = std::time::Instant::now();
    let result = ocr
        .detect(&img, 50, 1024, 0.5, 0.3, 1.6, false, false)
        .expect("识别失败");
    let elapsed = start.elapsed();

    println!("识别耗时: {:.2}s", elapsed.as_secs_f64());
    println!("识别到 {} 个文本块:", result.text_blocks.len());
    for (i, tb) in result.text_blocks.iter().enumerate() {
        println!("  [{}] text={:?} score={:.3}", i, tb.text, tb.text_score);
    }

    if result.text_blocks.is_empty() {
        eprintln!("❌ 未识别到任何文字");
        std::process::exit(1);
    }
    println!("✅ OCR 识别成功");
}
