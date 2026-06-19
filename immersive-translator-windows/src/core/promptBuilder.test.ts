import { describe, it, expect } from "vitest";
import { buildSystemPrompt } from "./promptBuilder";
import { parseGlossary } from "./glossaryParser";

describe("buildSystemPrompt", () => {
  it("includes base translation instruction with target language", () => {
    const prompt = buildSystemPrompt({ targetLanguage: "简体中文", customStyle: "", glossaryText: "" });
    expect(prompt).toContain("简体中文");
    expect(prompt).toContain("<text>");
    expect(prompt).toContain("</text>");
  });

  it("falls back to 简体中文 when targetLanguage is empty", () => {
    const prompt = buildSystemPrompt({ targetLanguage: "", customStyle: "", glossaryText: "" });
    expect(prompt).toContain("简体中文");
  });

  it("includes custom style section when provided", () => {
    const prompt = buildSystemPrompt({
      targetLanguage: "English",
      customStyle: "Use natural spoken style",
      glossaryText: "",
    });
    expect(prompt).toContain("User translation style preference");
    expect(prompt).toContain("Use natural spoken style");
  });

  it("omits custom style section when empty", () => {
    const prompt = buildSystemPrompt({ targetLanguage: "English", customStyle: "   ", glossaryText: "" });
    expect(prompt).not.toContain("User translation style preference");
  });

  it("includes glossary section when provided with valid entries", () => {
    const prompt = buildSystemPrompt({
      targetLanguage: "简体中文",
      customStyle: "",
      glossaryText: "hello = 你好\nworld = 世界",
    });
    expect(prompt).toContain("Local glossary");
    expect(prompt).toContain("hello");
    expect(prompt).toContain("你好");
  });

  it("omits glossary section when glossary has no valid entries", () => {
    const prompt = buildSystemPrompt({
      targetLanguage: "简体中文",
      customStyle: "",
      glossaryText: "# just a comment\n\n",
    });
    expect(prompt).not.toContain("Local glossary");
  });

  it("glossary section is capped at MAX_SEND_ENTRIES", () => {
    const many = Array.from({ length: 100 }, (_, i) => `s${i} = t${i}`).join("\n");
    const prompt = buildSystemPrompt({ targetLanguage: "简体中文", customStyle: "", glossaryText: many });
    const parsed = parseGlossary(many);
    // s79 在前 80 条内会出现，s99 在第 100 条不会出现
    expect(prompt).toContain("s79");
    expect(prompt).not.toContain("s99");
    expect(parsed.toSend).toHaveLength(80);
  });
});
