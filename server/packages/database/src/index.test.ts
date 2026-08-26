import { describe, expect, it } from "vitest";
import { CORE_TABLES, createFakeDatabaseClient, packageId } from "./index";

describe("@audio-reader/database", () => {
  it("identifies the database package", () => {
    expect(packageId).toBe("@audio-reader/database");
  });

  it("exports the core multi-user table contract", () => {
    expect(CORE_TABLES).toHaveLength(26);
    expect(CORE_TABLES).toContain("profiles");
    expect(CORE_TABLES).toContain("assistant_cache_entries");
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
