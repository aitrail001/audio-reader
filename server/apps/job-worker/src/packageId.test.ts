import { packageId as qwenPackageId } from "@audio-reader/qwen";
import { describe, expect, it } from "vitest";
import { packageId } from "./packageId";

describe("@audio-reader/job-worker", () => {
  it("identifies the job-worker app", () => {
    expect(packageId).toBe("@audio-reader/job-worker");
  });

  it("resolves the qwen workspace package", () => {
    expect(qwenPackageId).toBe("@audio-reader/qwen");
  });
});
