export type TranslationMode = "auto" | "fixed";

export interface TargetLanguageConfig {
  mode: TranslationMode;
  fixed: string;
}

/**
 * 判断文本是否主要是中文。对齐 Mac 版 TranslationClient.looksMostlyChinese。
 * 规则：忽略空白和标点；统计汉字与字母；汉字数 >= 4 或 汉字数 >= 字母数 即视为中文。
 */
export function looksMostlyChinese(text: string): boolean {
  let chineseCount = 0;
  let letterCount = 0;

  for (const ch of text) {
    const code = ch.codePointAt(0)!;
    // 跳过空白
    if (/\s/.test(ch)) continue;
    // 跳过标点（通用 Unicode 标点）
    if (/\p{P}/u.test(ch)) continue;

    if (
      (code >= 0x4e00 && code <= 0x9fff) ||
      (code >= 0x3400 && code <= 0x4dbf) ||
      (code >= 0xf900 && code <= 0xfaff)
    ) {
      chineseCount += 1;
    } else if ((code >= 0x0041 && code <= 0x005a) || (code >= 0x0061 && code <= 0x007a)) {
      letterCount += 1;
    }
  }

  if (chineseCount <= 0) return false;
  return chineseCount >= 4 || chineseCount >= letterCount;
}

/**
 * 决定目标语言。对齐 Mac 版 TranslationClient.targetLanguage。
 * - auto 模式：中文 -> English，非中文 -> 简体中文。
 * - fixed 模式：用 fixed 值，为空则回退简体中文。
 */
export function resolveTargetLanguage(text: string, config: TargetLanguageConfig): string {
  if (config.mode === "fixed") {
    const trimmed = config.fixed.trim();
    return trimmed === "" ? "简体中文" : trimmed;
  }
  return looksMostlyChinese(text) ? "English" : "简体中文";
}
