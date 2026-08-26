import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/auth", () => {
  it("identifies the auth package", () => {
    expect(packageId).toBe("@audio-reader/auth");
  });
});
