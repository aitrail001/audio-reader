import { describe, expect, it } from "vitest";
import { createFakeQwenClient, packageId } from "./index";

describe("@audio-reader/qwen", () => {
  it("identifies the qwen package", () => {
    expect(packageId).toBe("@audio-reader/qwen");
  });

  it("creates a ready fake Qwen adapter", async () => {
    await expect(createFakeQwenClient().ping()).resolves.toBe("ok");
  });

  it("can simulate Qwen unavailability", async () => {
    await expect(createFakeQwenClient({ status: "unavailable" }).ping()).resolves.toBe(
      "unavailable",
    );
  });
});
