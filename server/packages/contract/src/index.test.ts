import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/contract", () => {
  it("identifies the contract package", () => {
    expect(packageId).toBe("@audio-reader/contract");
  });
});
