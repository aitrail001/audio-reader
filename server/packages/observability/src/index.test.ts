import { describe, expect, it, vi } from "vitest";
import {
  formatError,
  logUnhandledError,
  packageId,
  REQUEST_ID_HEADER,
  resolveRequestId,
} from "./index";

describe("@audio-reader/observability", () => {
  it("identifies the observability package", () => {
    expect(packageId).toBe("@audio-reader/observability");
  });

  it("names the correlation header X-Request-Id", () => {
    expect(REQUEST_ID_HEADER).toBe("X-Request-Id");
  });

  it("reuses a valid incoming request id", () => {
    expect(resolveRequestId("req-12345678")).toBe("req-12345678");
    expect(resolveRequestId("4bf92f3577b34da6a3ce929d0e0e4736")).toBe(
      "4bf92f3577b34da6a3ce929d0e0e4736",
    );
  });

  it("generates a UUID when the header is missing or invalid", () => {
    expect(resolveRequestId(null)).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
    expect(resolveRequestId("bad")).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });

  it("formats errors for structured logs", () => {
    expect(formatError(new Error("boom"))).toContain("boom");
    expect(formatError("plain")).toBe("plain");
  });

  it("logs unhandled errors with the request id", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      logUnhandledError("client-request-1", new Error("boom"));
      expect(spy).toHaveBeenCalledTimes(1);
      const line = String(spy.mock.calls[0]?.[0]);
      expect(line).toContain("client-request-1");
      expect(line).toContain("unhandled_request_error");
      expect(line).toContain("boom");
    } finally {
      spy.mockRestore();
    }
  });
});
