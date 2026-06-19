export const MAX_SEND_ENTRIES = 80;

export interface GlossaryEntry {
  source: string;
  target: string;
}

export interface ParsedGlossary {
  entries: GlossaryEntry[];
  toSend: GlossaryEntry[]; // 前 MAX_SEND_ENTRIES 条
  localOnlyCount: number; // 超出上限的条数
}

const HEADER_PATTERNS = ["source", "原词", "original", "term", "key", "source,target", "原词,译法"];

function isHeader(line: string): boolean {
  const lower = line.toLowerCase().trim();
  return (
    HEADER_PATTERNS.some(
      (h) => lower === h || lower.startsWith(h + ",") || lower.startsWith(h + "\t"),
    )
  );
}

function parseLine(line: string): GlossaryEntry | null {
  const trimmed = line.trim();
  if (trimmed === "") return null;

  // 注释
  if (trimmed.startsWith("#") || trimmed.startsWith("//")) return null;

  // 表头
  if (isHeader(trimmed)) return null;

  // 尝试分隔符，按优先级：
  // -> 、 = 、 中文冒号、英文冒号、制表符、竖线、中文逗号、逗号
  const separators = ["->", "=", "：", ":", "\t", "|", "，", ","];

  for (const sep of separators) {
    const idx = trimmed.indexOf(sep);
    if (idx > 0) {
      const source = trimmed.slice(0, idx).trim();
      const target = trimmed.slice(idx + sep.length).trim();
      if (source !== "" && target !== "") {
        return { source, target };
      }
    }
  }

  return null;
}

export function parseGlossary(text: string): ParsedGlossary {
  const lines = text.split(/\r?\n/);
  const entries: GlossaryEntry[] = [];
  const seen = new Set<string>();

  for (const line of lines) {
    const entry = parseLine(line);
    if (!entry) continue;
    // 去重（按 source，大小写不敏感）
    const key = entry.source.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    entries.push(entry);
  }

  const toSend = entries.slice(0, MAX_SEND_ENTRIES);
  const localOnlyCount = Math.max(0, entries.length - MAX_SEND_ENTRIES);

  return { entries, toSend, localOnlyCount };
}
