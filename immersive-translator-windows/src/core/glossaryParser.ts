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

  // 分隔符按优先级尝试：
  //   键值分隔符（target 取分隔符后整行剩余）：-> 、 = 、 中文冒号、英文冒号
  //   列分隔符（TSV/CSV/竖线，target 只取第二列）：制表符、竖线、中文逗号、英文逗号
  const kvSeparators = ["->", "=", "：", ":"];
  const colSeparators = ["\t", "|", "，", ","];

  // 优先匹配键值分隔符
  for (const sep of kvSeparators) {
    const idx = trimmed.indexOf(sep);
    if (idx > 0) {
      const source = trimmed.slice(0, idx).trim();
      const target = trimmed.slice(idx + sep.length).trim();
      if (source !== "" && target !== "") {
        return { source, target };
      }
    }
  }

  // 再匹配列分隔符：取第二列（首个分隔符到下一个列分隔符或行尾）
  for (const sep of colSeparators) {
    const firstIdx = trimmed.indexOf(sep);
    if (firstIdx > 0) {
      const source = trimmed.slice(0, firstIdx).trim();
      const rest = trimmed.slice(firstIdx + sep.length);
      // 第二列：在 rest 中找下一个列分隔符截断
      let endIdx = rest.length;
      for (const s2 of colSeparators) {
        const i = rest.indexOf(s2);
        if (i >= 0 && i < endIdx) endIdx = i;
      }
      const target = rest.slice(0, endIdx).trim();
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

export interface GlossaryStats {
  valid: number;
  invalid: number;
  overLimit: number;
}

/** 统计词库：有效条数、无法解析的行数、超出上限的条数。用于格式预检。 */
export function glossaryStats(text: string): GlossaryStats {
  const parsed = parseGlossary(text);
  const lines = text.split(/\r?\n/);
  let invalid = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    if (trimmed.startsWith("#") || trimmed.startsWith("//")) continue;
    if (isHeader(trimmed)) continue;
    // 能解析到这里说明有效
    if (parseLine(trimmed) === null) invalid++;
  }
  return {
    valid: parsed.entries.length,
    invalid,
    overLimit: parsed.localOnlyCount,
  };
}

/**
 * 把词库文本去重并规范化为 `source = target` 格式输出。
 * 用于"去重"和"导出"按钮。
 */
export function dedupAndNormalize(text: string): string {
  const { entries } = parseGlossary(text);
  return entries.map((e) => `${e.source} = ${e.target}`).join("\n");
}

/**
 * 把新文本合并进已有词库文本，去重后返回。
 * 用于"导入"按钮（追加，不覆盖）。
 */
export function mergeGlossary(existing: string, incoming: string): string {
  const combined = `${existing}\n${incoming}`;
  return dedupAndNormalize(combined);
}
