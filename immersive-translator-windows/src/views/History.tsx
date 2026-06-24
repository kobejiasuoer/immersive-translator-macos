import { useEffect, useMemo, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  historyList,
  historyToggleFavorite,
  historyDelete,
  historyClearNonFavorites,
  historyExport,
  type HistoryRecord,
  type ExportFormat,
} from "../lib/tauriBridge";

/**
 * 翻译历史窗口。对齐 Mac TranslationHistoryView：
 * - 搜索（原文/译文/语言/来源；支持「收藏」「未收藏」「ocr」关键词）
 * - 收藏 / 取消收藏
 * - 删除单条 / 清空非收藏
 * - 导出 CSV / JSON / Markdown / 纯文本
 */
export function History() {
  const [records, setRecords] = useState<HistoryRecord[]>([]);
  const [query, setQuery] = useState("");
  const [favoritesOnly, setFavoritesOnly] = useState(false);
  const [loading, setLoading] = useState(true);
  const [toast, setToast] = useState("");

  useEffect(() => {
    const win = getCurrentWindow();
    const unlistenP = win.onCloseRequested((event) => {
      event.preventDefault();
      void win.hide();
    });
    return () => {
      void unlistenP.then((u) => u());
    };
  }, []);

  async function refresh() {
    setLoading(true);
    try {
      const list = await historyList(query);
      setRecords(favoritesOnly ? list.filter((r) => r.isFavorite) : list);
    } finally {
      setLoading(false);
    }
  }

  // 首次加载 + 收藏筛选变化时刷新
  useEffect(() => {
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [favoritesOnly]);

  // 搜索输入防抖（避免每次按键都查）
  useEffect(() => {
    const t = setTimeout(() => void refresh(), 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);

  function showToast(msg: string) {
    setToast(msg);
    setTimeout(() => setToast(""), 2000);
  }

  async function handleToggleFav(id: string) {
    await historyToggleFavorite(id);
    await refresh();
  }

  async function handleDelete(id: string) {
    if (!confirm("删除这条历史？")) return;
    await historyDelete(id);
    await refresh();
    showToast("已删除");
  }

  async function handleClearNonFavorites() {
    if (!confirm("清空所有未收藏的历史？此操作不可撤销。")) return;
    const n = await historyClearNonFavorites();
    await refresh();
    showToast(`已清空 ${n} 条`);
  }

  async function handleExport(format: ExportFormat) {
    try {
      const text = await historyExport(query || null, favoritesOnly, format);
      await navigator.clipboard.writeText(text);
      showToast(`已复制到剪贴板（${format.toUpperCase()}）`);
    } catch (e) {
      showToast(`导出失败：${e}`);
    }
  }

  const hasRecords = records.length > 0;

  return (
    <div style={pageStyle}>
      <div style={toolbarStyle}>
        <input
          style={searchInputStyle}
          placeholder="搜索原文 / 译文 / 语言，或输入「收藏」「ocr」"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <label style={favCheckStyle}>
          <input
            type="checkbox"
            checked={favoritesOnly}
            onChange={(e) => setFavoritesOnly(e.target.checked)}
          />
          仅看收藏
        </label>
        <div style={{ flex: 1 }} />
        <button style={btnStyle} onClick={() => void refresh()}>
          刷新
        </button>
        <button
          style={{ ...btnStyle, color: "#b91c1c" }}
          onClick={() => void handleClearNonFavorites()}
          disabled={!hasRecords}
        >
          清空未收藏
        </button>
      </div>

      <div style={exportBarStyle}>
        <span style={{ fontSize: 12, color: "#666" }}>导出 / 复制：</span>
        <button style={exportBtnStyle} onClick={() => void handleExport("csv")}>
          CSV
        </button>
        <button style={exportBtnStyle} onClick={() => void handleExport("json")}>
          JSON
        </button>
        <button style={exportBtnStyle} onClick={() => void handleExport("markdown")}>
          Markdown
        </button>
        <button style={exportBtnStyle} onClick={() => void handleExport("text")}>
          纯文本
        </button>
        <span style={{ marginLeft: "auto", fontSize: 12, color: "#888" }}>
          {loading ? "加载中…" : `${records.length} 条`}
        </span>
      </div>

      <div style={listStyle}>
        {loading && <div style={emptyStyle}>加载中…</div>}
        {!loading && !hasRecords && (
          <div style={emptyStyle}>
            {query || favoritesOnly ? "没有匹配的记录" : "还没有翻译历史"}
          </div>
        )}
        {!loading &&
          records.map((r) => (
            <HistoryCard
              key={r.id}
              record={r}
              onToggleFav={() => handleToggleFav(r.id)}
              onDelete={() => handleDelete(r.id)}
            />
          ))}
      </div>

      {toast && <div style={toastStyle}>{toast}</div>}
    </div>
  );
}

function HistoryCard({
  record,
  onToggleFav,
  onDelete,
}: {
  record: HistoryRecord;
  onToggleFav: () => void;
  onDelete: () => void;
}) {
  const time = useMemo(() => formatTime(record.createdAt), [record.createdAt]);
  return (
    <div style={cardStyle}>
      <div style={cardMetaStyle}>
        <span style={srcTagStyle(record.source)}>
          {record.source === "selection" ? "选中" : "OCR"}
        </span>
        <span style={langStyle}>{record.targetLanguage || "—"}</span>
        <span style={timeStyle}>{time}</span>
        <span style={modelStyle}>{record.model}</span>
        <span style={elapsedStyle}>{(record.elapsedMs / 1000).toFixed(1)}s</span>
        <div style={{ marginLeft: "auto", display: "flex", gap: 6 }}>
          <button
            style={iconBtnStyle}
            title={record.isFavorite ? "取消收藏" : "收藏"}
            onClick={onToggleFav}
          >
            {record.isFavorite ? "★" : "☆"}
          </button>
          <button style={iconBtnStyle} title="删除" onClick={onDelete}>
            🗑
          </button>
        </div>
      </div>
      <div style={origStyle}>{record.original}</div>
      <div style={transStyle}>{record.translation}</div>
    </div>
  );
}

function formatTime(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(
    d.getHours(),
  )}:${pad(d.getMinutes())}`;
}

// ---- styles ----
const pageStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  height: "100vh",
  background: "#f7f7f8",
  fontFamily: "-apple-system, 'Segoe UI', sans-serif",
};
const toolbarStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  padding: "10px 14px",
  borderBottom: "1px solid #e5e5e5",
  background: "#fff",
};
const searchInputStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 200,
  padding: "6px 10px",
  border: "1px solid #d0d0d0",
  borderRadius: 6,
  fontSize: 13,
};
const favCheckStyle: React.CSSProperties = {
  fontSize: 13,
  color: "#444",
  display: "flex",
  alignItems: "center",
  gap: 4,
  cursor: "pointer",
};
const btnStyle: React.CSSProperties = {
  padding: "6px 12px",
  border: "1px solid #d0d0d0",
  borderRadius: 6,
  background: "#fff",
  cursor: "pointer",
  fontSize: 13,
};
const exportBarStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 6,
  padding: "8px 14px",
  borderBottom: "1px solid #e5e5e5",
  background: "#fafafa",
};
const exportBtnStyle: React.CSSProperties = {
  padding: "3px 9px",
  border: "1px solid #ccc",
  borderRadius: 4,
  background: "#fff",
  cursor: "pointer",
  fontSize: 12,
};
const listStyle: React.CSSProperties = {
  flex: 1,
  overflowY: "auto",
  padding: 14,
  display: "flex",
  flexDirection: "column",
  gap: 10,
};
const emptyStyle: React.CSSProperties = {
  textAlign: "center",
  color: "#999",
  padding: 40,
  fontSize: 13,
};
const cardStyle: React.CSSProperties = {
  background: "#fff",
  border: "1px solid #e5e5e5",
  borderRadius: 8,
  padding: "10px 12px",
};
const cardMetaStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  marginBottom: 6,
  fontSize: 11,
  color: "#888",
};
const srcTagStyle = (src: string): React.CSSProperties => ({
  padding: "1px 6px",
  borderRadius: 3,
  fontSize: 10,
  background: src === "ocr" ? "#fef3c7" : "#e0e7ff",
  color: src === "ocr" ? "#92400e" : "#3730a3",
});
const langStyle: React.CSSProperties = { fontWeight: 600, color: "#555" };
const timeStyle: React.CSSProperties = { color: "#999" };
const modelStyle: React.CSSProperties = { fontFamily: "monospace", color: "#666" };
const elapsedStyle: React.CSSProperties = { color: "#16a34a" };
const origStyle: React.CSSProperties = {
  fontSize: 13,
  color: "#666",
  whiteSpace: "pre-wrap",
  wordBreak: "break-word",
  marginBottom: 4,
};
const transStyle: React.CSSProperties = {
  fontSize: 14,
  color: "#1a1a1a",
  whiteSpace: "pre-wrap",
  wordBreak: "break-word",
  lineHeight: 1.5,
};
const iconBtnStyle: React.CSSProperties = {
  border: "none",
  background: "transparent",
  cursor: "pointer",
  fontSize: 16,
  padding: "2px 4px",
  lineHeight: 1,
};
const toastStyle: React.CSSProperties = {
  position: "fixed",
  bottom: 20,
  left: "50%",
  transform: "translateX(-50%)",
  background: "rgba(0,0,0,0.8)",
  color: "#fff",
  padding: "6px 14px",
  borderRadius: 6,
  fontSize: 13,
};
