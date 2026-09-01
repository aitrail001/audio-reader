import { describe, expect, it } from "vitest";
import { getOrCreateApiApp, resetApiAppCache } from "./index";

describe("worker isolate app cache", () => {
  it("reuses the app for the same env identity", () => {
    resetApiAppCache();
    const env = { ENVIRONMENT: "local" };
    const first = getOrCreateApiApp(env);
    expect(getOrCreateApiApp(env)).toBe(first);
    expect(getOrCreateApiApp({ ENVIRONMENT: "local" })).not.toBe(first);
    resetApiAppCache();
  });
});
