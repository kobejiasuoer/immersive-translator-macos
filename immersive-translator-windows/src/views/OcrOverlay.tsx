import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { ocrModelsReady, showOcrResult } from "../lib/tauriBridge";

/**
 * OCR 截图框选覆盖层。对齐 Mac ScreenSelection。
 *
 * 实现方式（Windows WebView2 透明窗口不可靠，改用截图背景）：
 * 1. Rust open_ocr_overlay 在窗口隐藏时截全屏 → emit("ocr:fullscreen", png)
 * 2. 本组件接收截图作为背景图
 * 3. 在截图上拖框选区（选区内透明，外部半透明）
 * 4. 松手 → capture_screenshot 抠该区域 → ocr_recognize → 翻译
 * 5. Esc / 右键取消
 */
export function OcrOverlay() {
  const overlayWindow = getCurrentWindow();
  const [dragging, setDragging] = useState(false);
  const [rect, setRect] = useState<Rect | null>(null);
  const startRef = useRef<{ x: number; y: number } | null>(null);
  const [processing, setProcessing] = useState(false);
  const [modelMissing, setModelMissing] = useState(false);
  const [bgUrl, setBgUrl] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  // 接收全屏截图（Rust 在窗口显示前发来）
  useEffect(() => {
    const unlistenP = listen<string>("ocr:fullscreen", (event) => {
      setBgUrl(event.payload);
    });
    return () => {
      void unlistenP.then((u) => u());
    };
  }, []);

  // 挂载时检查模型是否就绪
  useEffect(() => {
    ocrModelsReady().then((ready) => {
      if (!ready) setModelMissing(true);
    });
  }, []);

  // Esc 取消
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        e.preventDefault();
        void hideOverlay();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  async function hideOverlay() {
    await overlayWindow.hide();
    setDragging(false);
    setRect(null);
    setProcessing(false);
    setBgUrl(null);
    startRef.current = null;
  }

  function onMouseDown(e: React.MouseEvent) {
    if (e.button !== 0 || modelMissing || processing) return;
    setErrorMsg(null);
    startRef.current = { x: e.clientX, y: e.clientY };
    setDragging(true);
    setRect({ x: e.clientX, y: e.clientY, w: 0, h: 0 });
  }

  function onMouseMove(e: React.MouseEvent) {
    if (!dragging || !startRef.current) return;
    const start = startRef.current;
    setRect({
      x: Math.min(start.x, e.clientX),
      y: Math.min(start.y, e.clientY),
      w: Math.abs(e.clientX - start.x),
      h: Math.abs(e.clientY - start.y),
    });
  }

  async function onMouseUp(e: React.MouseEvent) {
    if (e.button !== 0 || !dragging || !startRef.current) return;
    const start = startRef.current;
    const finalRect: Rect = {
      x: Math.min(start.x, e.clientX),
      y: Math.min(start.y, e.clientY),
      w: Math.abs(e.clientX - start.x),
      h: Math.abs(e.clientY - start.y),
    };
    setDragging(false);
    startRef.current = null;

    if (finalRect.w < 5 || finalRect.h < 5) {
      setRect(null);
      return;
    }

    setProcessing(true);
    setRect(finalRect);

    try {
      // 关键：不能再次调用 capture_screenshot，因为此时 overlay 窗口可见，
      // BitBlt 会把 overlay（半透明遮罩）一起截进去。
      // 改用从初始全屏截图（overlay 显示前截的）里按选区裁剪。
      const result = await invoke<{ text: string; blocks: unknown[] }>(
        "ocr_recognize_from_fullscreen",
        {
          // 选区坐标（逻辑 CSS 像素，Rust 端会做 DPI 缩放转物理像素）
          x: Math.round(finalRect.x),
          y: Math.round(finalRect.y),
          w: Math.round(finalRect.w),
          h: Math.round(finalRect.h),
        },
      );

      if (result.text.trim()) {
        await showOcrResult(result.text);
      } else {
        // 未识别到文字：显示提示，不关闭 overlay，让用户重新框选
        setProcessing(false);
        setRect(null);
        setErrorMsg("未识别到文字，请重新框选或放大选区");
        return;
      }
    } catch (err) {
      // OCR 失败：显示错误，不静默关闭
      console.error("[ocr] flow failed", err);
      setProcessing(false);
      setRect(null);
      setErrorMsg(String(err));
      return;
    }

    await hideOverlay();
  }

  async function onContextMenu(e: React.MouseEvent) {
    e.preventDefault();
    await hideOverlay();
  }

  const cursor = processing ? "wait" : "crosshair";

  // 模型未就绪
  if (modelMissing) {
    return (
      <div
        style={{
          ...rootStyle,
          backgroundImage: bgUrl ? `url(${bgUrl})` : undefined,
          backgroundSize: "cover",
        }}
        onClick={() => void hideOverlay()}
      >
        <div style={dimOverlayStyle} />
        <div style={modelMissingBoxStyle}>
          <div style={{ fontSize: 16, fontWeight: 600, marginBottom: 8 }}>OCR 模型未下载</div>
          <div style={{ fontSize: 13, color: "#666", marginBottom: 12 }}>
            截图翻译需要先下载 PaddleOCR 模型（约 16MB）。
            <br />
            请到「设置 → 截图翻译 (OCR)」里点「下载中文模型」。
          </div>
          <div style={{ fontSize: 12, color: "#999" }}>点击任意处关闭</div>
        </div>
      </div>
    );
  }

  return (
    <div
      style={{
        ...rootStyle,
        backgroundImage: bgUrl ? `url(${bgUrl})` : undefined,
        backgroundSize: "cover",
        cursor,
      }}
      onMouseDown={onMouseDown}
      onMouseMove={onMouseMove}
      onMouseUp={onMouseUp}
      onContextMenu={onContextMenu}
    >
      {/* 整体半透明遮罩（让用户知道进入截图模式）*/}
      <div style={dimOverlayStyle} />

      {/* 初始提示 */}
      {!dragging && !rect && !processing && (
        <div style={hintStyle}>拖拽选择要翻译的区域 · Esc 或右键取消</div>
      )}

      {/* 拖拽选区：四块遮罩（选区镂空）+ 边框 */}
      {dragging && rect && (
        <>
          {/* 用 box-shadow 做选区外遮罩，选区内透明 */}
          <div
            style={{
              position: "absolute",
              left: rect.x,
              top: rect.y,
              width: rect.w,
              height: rect.h,
              border: "2px solid #2563eb",
              boxShadow: "0 0 0 9999px rgba(0,0,0,0.45)",
              boxSizing: "border-box",
            }}
          >
            <div style={sizeLabelStyle}>
              {Math.round(rect.w)} × {Math.round(rect.h)}
            </div>
          </div>
        </>
      )}

      {/* 识别中 */}
      {processing && (
        <div style={processingOverlayStyle}>
          <div style={processingBoxStyle}>正在识别文字…</div>
        </div>
      )}

      {/* 错误提示 */}
      {errorMsg && (
        <div style={processingOverlayStyle} onClick={() => setErrorMsg(null)}>
          <div style={errorBoxStyle}>
            <div style={{ fontWeight: 600, marginBottom: 6 }}>OCR 失败</div>
            <div style={{ fontSize: 13, color: "#666" }}>{errorMsg}</div>
            <div style={{ fontSize: 11, color: "#999", marginTop: 8 }}>点击关闭，可重新框选</div>
          </div>
        </div>
      )}
    </div>
  );
}

interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

const rootStyle: React.CSSProperties = {
  position: "fixed",
  inset: 0,
  background: "#1a1a1a",
  overflow: "hidden",
};
const dimOverlayStyle: React.CSSProperties = {
  position: "absolute",
  inset: 0,
  background: "rgba(0,0,0,0.25)",
  pointerEvents: "none",
};
const sizeLabelStyle: React.CSSProperties = {
  position: "absolute",
  top: -22,
  left: 0,
  background: "#2563eb",
  color: "#fff",
  fontSize: 12,
  padding: "1px 6px",
  borderRadius: 3,
  whiteSpace: "nowrap",
};
const hintStyle: React.CSSProperties = {
  position: "absolute",
  top: "50%",
  left: "50%",
  transform: "translate(-50%, -50%)",
  color: "#fff",
  fontSize: 16,
  background: "rgba(0,0,0,0.6)",
  padding: "10px 20px",
  borderRadius: 8,
  pointerEvents: "none",
  zIndex: 10,
};
const processingOverlayStyle: React.CSSProperties = {
  position: "absolute",
  inset: 0,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  pointerEvents: "none",
  zIndex: 10,
};
const processingBoxStyle: React.CSSProperties = {
  color: "#fff",
  fontSize: 16,
  background: "rgba(0,0,0,0.7)",
  padding: "12px 24px",
  borderRadius: 8,
};
const errorBoxStyle: React.CSSProperties = {
  background: "#fff",
  borderRadius: 12,
  padding: "20px 24px",
  maxWidth: 400,
  cursor: "pointer",
  zIndex: 10,
};
const modelMissingBoxStyle: React.CSSProperties = {
  position: "relative",
  zIndex: 10,
  background: "#fff",
  borderRadius: 12,
  padding: "24px 28px",
  maxWidth: 420,
  textAlign: "center",
  cursor: "pointer",
  margin: "auto",
};
