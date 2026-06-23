import { describe, it, expect } from "vitest";
import { classifyTranslationError } from "./errorMessageFormatter";

describe("classifyTranslationError", () => {
  it("classifies 401 as API Key problem, not retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 401, body: "Unauthorized" });
    expect(result.message).toContain("API Key");
    expect(result.retryable).toBe(false);
  });

  it("classifies 403 as permission/auth problem, not retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 403, body: "" });
    expect(result.message).toContain("权限");
    expect(result.retryable).toBe(false);
  });

  it("classifies 404 as endpoint path problem, not retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 404, body: "Cannot POST" });
    expect(result.message).toContain("接口地址");
    expect(result.retryable).toBe(false);
  });

  it("classifies 429 as rate limit, retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 429, body: "" });
    expect(result.message).toContain("限流");
    expect(result.retryable).toBe(true);
  });

  it("classifies 500 as server error, retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 500, body: "" });
    expect(result.retryable).toBe(true);
    expect(result.message).toContain("服务");
  });

  it("classifies network error as retryable", () => {
    const result = classifyTranslationError({ kind: "network", message: "connection refused" });
    expect(result.retryable).toBe(true);
    expect(result.message).toContain("网络");
  });

  it("classifies timeout as retryable", () => {
    const result = classifyTranslationError({ kind: "timeout" });
    expect(result.retryable).toBe(true);
    expect(result.message).toContain("超时");
  });

  it("classifies empty translation body, not retryable", () => {
    const result = classifyTranslationError({ kind: "emptyTranslation" });
    expect(result.retryable).toBe(false);
  });

  it("classifies 200 HTML response as format problem, not retryable", () => {
    const result = classifyTranslationError({ kind: "http", status: 200, body: "<html>login page</html>" });
    expect(result.retryable).toBe(false);
    expect(result.message).toContain("HTML");
  });

  it("falls back to generic message for unknown status", () => {
    const result = classifyTranslationError({ kind: "http", status: 418, body: "" });
    expect(result.message).toContain("418");
  });

  it("includes preview for invalidResponse", () => {
    const result = classifyTranslationError({ kind: "invalidResponse", preview: "some garbage response" });
    expect(result.message).toContain("some garbage response");
    expect(result.retryable).toBe(false);
  });
});
