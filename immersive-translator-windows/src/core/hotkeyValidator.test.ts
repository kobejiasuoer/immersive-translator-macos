import { describe, it, expect } from "vitest";
import {
  parseHotkey,
  validateHotkey,
  normalizeHotkey,
} from "./hotkeyValidator";

describe("parseHotkey", () => {
  it("parses standard combo", () => {
    const p = parseHotkey("Ctrl+Shift+Q");
    expect(p).not.toBeNull();
    expect(p!.mods.has("Ctrl")).toBe(true);
    expect(p!.mods.has("Shift")).toBe(true);
    expect(p!.key).toBe("Q");
  });

  it("is case-insensitive", () => {
    const p = parseHotkey("ctrl+shift+q");
    expect(p!.mods.has("Ctrl")).toBe(true);
    expect(p!.key).toBe("Q");
  });

  it("rejects missing modifier", () => {
    expect(parseHotkey("Q")).toBeNull();
  });

  it("rejects missing main key", () => {
    expect(parseHotkey("Ctrl+Shift")).toBeNull();
  });

  it("rejects empty", () => {
    expect(parseHotkey("")).toBeNull();
    expect(parseHotkey("   ")).toBeNull();
  });

  it("accepts Super (Win) modifier", () => {
    const p = parseHotkey("Super+Shift+T");
    expect(p!.mods.has("Super")).toBe(true);
    expect(p!.mods.has("Shift")).toBe(true);
  });
});

describe("validateHotkey", () => {
  it("accepts Ctrl+Shift+Q", () => {
    const v = validateHotkey("Ctrl+Shift+Q");
    expect(v.ok).toBe(true);
    expect(v.warning).toBeUndefined();
  });

  it("blocks Ctrl+Alt+Del", () => {
    const v = validateHotkey("Ctrl+Alt+Del");
    expect(v.ok).toBe(false);
    expect(v.blocking).toBe(true);
    expect(v.warning).toContain("安全序列");
  });

  it("blocks Win+L (lock)", () => {
    const v = validateHotkey("Super+L");
    expect(v.ok).toBe(false);
    expect(v.blocking).toBe(true);
  });

  it("warns (non-blocking) for Ctrl+C clash", () => {
    const v = validateHotkey("Ctrl+C");
    expect(v.ok).toBe(true);
    expect(v.blocking).toBe(false);
    expect(v.warning).toContain("复制");
  });

  it("warns for Alt-only combo", () => {
    const v = validateHotkey("Alt+T");
    expect(v.ok).toBe(true);
    expect(v.warning).toBeTruthy();
  });

  it("rejects invalid format", () => {
    const v = validateHotkey("Q");
    expect(v.ok).toBe(false);
    expect(v.blocking).toBe(true);
  });

  it("blocks Ctrl+Shift+Esc (task manager)", () => {
    const v = validateHotkey("Ctrl+Shift+Esc");
    expect(v.ok).toBe(false);
    expect(v.blocking).toBe(true);
  });
});

describe("normalizeHotkey", () => {
  it("orders modifiers and uppercases key", () => {
    expect(normalizeHotkey("shift+ctrl+q")).toBe("Ctrl+Shift+Q");
  });

  it("returns input as-is for invalid", () => {
    expect(normalizeHotkey("qqq")).toBe("qqq");
  });
});
