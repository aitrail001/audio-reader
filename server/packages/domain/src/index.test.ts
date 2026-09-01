import { describe, expect, it } from "vitest";
import { packageId, type ReadinessStatus } from "./index";

describe("@audio-reader/domain", () => {
  it("identifies the domain package", () => {
    expect(packageId).toBe("@audio-reader/domain");
  });

  it("types readiness as ok or unavailable", () => {
    const ok: ReadinessStatus = "ok";
    const unavailable: ReadinessStatus = "unavailable";
    expect(ok).toBe("ok");
    expect(unavailable).toBe("unavailable");
  });
});
