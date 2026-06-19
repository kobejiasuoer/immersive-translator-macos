import { describe, it, expect } from "vitest";
import { parseGlossary, MAX_SEND_ENTRIES } from "./glossaryParser";

describe("parseGlossary", () => {
  it("parses 'source = target' format", () => {
    const result = parseGlossary("hello = 你好\nworld = 世界");
    expect(result.entries).toEqual([
      { source: "hello", target: "你好" },
      { source: "world", target: "世界" },
    ]);
  });

  it("parses 'source -> target' format", () => {
    const result = parseGlossary("hello -> 你好");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("parses 'source：target' (Chinese colon) format", () => {
    const result = parseGlossary("hello：你好");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("parses CSV/TSV first two columns (tab)", () => {
    const result = parseGlossary("hello\t你好\t备注");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("ignores empty lines and whitespace-only lines", () => {
    const result = parseGlossary("hello = 你好\n\n   \nworld = 世界");
    expect(result.entries).toHaveLength(2);
  });

  it("ignores # and // comments", () => {
    const result = parseGlossary("# 这是注释\n// 另一个注释\nhello = 你好");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("ignores header row 'source,target'", () => {
    const result = parseGlossary("source,target\nhello,你好");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("trims whitespace around source and target", () => {
    const result = parseGlossary("  hello   =   你好  ");
    expect(result.entries).toEqual([{ source: "hello", target: "你好" }]);
  });

  it("caps entries at MAX_SEND_ENTRIES for sending, keeps rest locally", () => {
    const lines = Array.from({ length: MAX_SEND_ENTRIES + 5 }, (_, i) => `s${i} = t${i}`).join("\n");
    const result = parseGlossary(lines);
    expect(result.entries).toHaveLength(MAX_SEND_ENTRIES + 5);
    expect(result.toSend).toHaveLength(MAX_SEND_ENTRIES);
    expect(result.localOnlyCount).toBe(5);
  });

  it("returns empty for unrecognized single-token line", () => {
    const result = parseGlossary("justoneword");
    expect(result.entries).toEqual([]);
  });

  it("deduplicates by source (case-insensitive)", () => {
    const result = parseGlossary("Hello = 你好\nhello = 你好呀");
    expect(result.entries).toEqual([{ source: "Hello", target: "你好" }]);
  });
});

describe("MAX_SEND_ENTRIES", () => {
  it("equals 80 (aligned with Mac)", () => {
    expect(MAX_SEND_ENTRIES).toBe(80);
  });
});
