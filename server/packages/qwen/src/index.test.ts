import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/qwen", () => {
  it("identifies the qwen package", () => {
    expect(packageId).toBe("@audio-reader/qwen");
  });
});
