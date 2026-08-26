import { describe, expect, it } from "vitest";
import { createFakeDatabaseClient, packageId } from "./index";

describe("@audio-reader/database", () => {
  it("identifies the database package", () => {
    expect(packageId).toBe("@audio-reader/database");
  });

  it("creates a ready fake database client", async () => {
    await expect(createFakeDatabaseClient().ping()).resolves.toBe("ok");
  });

  it("can simulate database unavailability", async () => {
    await expect(createFakeDatabaseClient({ status: "unavailable" }).ping()).resolves.toBe(
      "unavailable",
    );
  });
});
