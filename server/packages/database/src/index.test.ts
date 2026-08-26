import { describe, expect, it } from "vitest";
import { packageId } from "./index";

describe("@audio-reader/database", () => {
  it("identifies the database package", () => {
    expect(packageId).toBe("@audio-reader/database");
  });
});
