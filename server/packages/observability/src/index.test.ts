import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/observability", () => {
  it("identifies the observability package", () => {
    expect(packageId).toBe("@audio-reader/observability");
  });
});
