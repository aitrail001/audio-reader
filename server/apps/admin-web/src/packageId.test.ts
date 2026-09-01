import { packageId as contractPackageId } from "@audio-reader/contract";
import { describe, expect, it } from "vitest";
import { packageId } from "./packageId";

describe("@audio-reader/admin-web", () => {
  it("identifies the admin-web app", () => {
    expect(packageId).toBe("@audio-reader/admin-web");
  });

  it("resolves the contract workspace package", () => {
    expect(contractPackageId).toBe("@audio-reader/contract");
  });
});
