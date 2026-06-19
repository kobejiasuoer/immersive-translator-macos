import { describe, it, expect } from "vitest";
import { looksMostlyChinese, resolveTargetLanguage } from "./languageDetect";

describe("looksMostlyChinese", () => {
  it("returns true for text with 4+ Chinese chars", () => {
    expect(looksMostlyChinese("你好世界你好")).toBe(true);
  });

  it("returns false for pure English", () => {
    expect(looksMostlyChinese("hello world")).toBe(false);
  });

  it("returns false for empty/whitespace", () => {
    expect(looksMostlyChinese("   ")).toBe(false);
    expect(looksMostlyChinese("")).toBe(false);
  });

  it("returns true when Chinese count >= letter count", () => {
    // 3 Chinese, 2 letters -> chinese >= letters
    expect(looksMostlyChinese("你好啊ab")).toBe(true);
  });

  it("returns false when letters dominate", () => {
    // 1 Chinese, many letters
    expect(looksMostlyChinese("你 helloworld")).toBe(false);
  });

  it("ignores punctuation and whitespace in counting", () => {
    expect(looksMostlyChinese("你好，世界！")).toBe(true);
  });
});

describe("resolveTargetLanguage", () => {
  it("auto mode: Chinese text -> English", () => {
    expect(resolveTargetLanguage("你好世界你好", { mode: "auto", fixed: "" })).toBe("English");
  });

  it("auto mode: non-Chinese text -> 简体中文", () => {
    expect(resolveTargetLanguage("hello world", { mode: "auto", fixed: "" })).toBe("简体中文");
  });

  it("fixed mode: uses fixed language", () => {
    expect(resolveTargetLanguage("hello", { mode: "fixed", fixed: "日本語" })).toBe("日本語");
  });

  it("fixed mode: empty fixed falls back to 简体中文", () => {
    expect(resolveTargetLanguage("hello", { mode: "fixed", fixed: "" })).toBe("简体中文");
    expect(resolveTargetLanguage("hello", { mode: "fixed", fixed: "   " })).toBe("简体中文");
  });
});
