import { packageId as domainPackageId } from "@audio-reader/domain";
import { describe, expect, it } from "vitest";
import { packageId } from "./packageId";

describe("@audio-reader/api-worker", () => {
  it("identifies the api-worker app", () => {
    expect(packageId).toBe("@audio-reader/api-worker");
  });

  it("resolves the domain workspace package", () => {
    expect(domainPackageId).toBe("@audio-reader/domain");
  });
});
