import { describe, expect, it } from "vitest";
import { packageId, REQUEST_ID_HEADER, resolveRequestId } from "./index";

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
});
