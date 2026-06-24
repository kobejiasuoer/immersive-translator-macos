import { getCurrentWindow } from "@tauri-apps/api/window";
import { TranslationPanel } from "./views/TranslationPanel";
import { Settings } from "./views/Settings";
import { History } from "./views/History";
import { OcrOverlay } from "./views/OcrOverlay";

// 多窗口分发：根据当前窗口 label 渲染不同 UI。
// panel → 翻译浮窗；settings → 设置；history → 历史；ocr-overlay → 截图框选。
function App() {
  const label = getCurrentWindow().label;
  if (label === "settings") {
    return <Settings />;
  }
  if (label === "history") {
    return <History />;
  }
  if (label === "ocr-overlay") {
    return <OcrOverlay />;
  }
  return <TranslationPanel />;
}

export default App;
