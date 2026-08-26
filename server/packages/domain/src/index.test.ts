import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/domain", () => {
  it("identifies the domain package", () => {
    expect(packageId).toBe("@audio-reader/domain");
  });
});
