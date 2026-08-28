import { describe, expect, it } from "vitest";
import { CORE_TABLES, TRANSACTION_FUNCTIONS, createFakeDatabaseClient, packageId } from "./index";

describe("@audio-reader/database", () => {
  it("identifies the database package", () => {
    expect(packageId).toBe("@audio-reader/database");
  });

  it("exports the core multi-user table contract", () => {
    expect(CORE_TABLES).toHaveLength(28);
    expect(CORE_TABLES).toContain("profiles");
    expect(CORE_TABLES).toContain("assistant_cache_entries");
    expect(CORE_TABLES).toContain("operator_settings");
    expect(CORE_TABLES).toContain("quota_limits");
  });

  it("exports privileged transaction function names", () => {
    expect(TRANSACTION_FUNCTIONS).toContain("claim_idempotency_record");
    expect(TRANSACTION_FUNCTIONS).toContain("claim_assistant_generation");
    expect(TRANSACTION_FUNCTIONS).toContain("append_audit_event");
  });

  it("creates a ready fake database client with identity and sync stores", async () => {
    const client = createFakeDatabaseClient();
    await expect(client.ping()).resolves.toBe("ok");
    const profile = await client.identity.ensureProfile({
      userId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      email: "reader@example.com",
    });
    expect(profile.email).toBe("reader@example.com");
    expect(profile.status).toBe("active");
    expect(await client.sync.latestCursor(profile.accountId)).toBe("0");
    const book = await client.catalog.createBook(profile.accountId, {
      clientId: "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d",
      title: "Moby-Dick",
      editionFingerprint: "ed-1",
      fingerprintVersion: 1,
      source: "local_folder",
      chapters: [
        {
          clientId: "3c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d",
          index: 0,
          title: "Loomings",
          chapterFingerprint: "ch-1",
          durationSeconds: 120,
        },
      ],
    });
    expect(book.chapterCount).toBe(1);
    expect((await client.catalog.listBooks(profile.accountId)).map((item) => item.id)).toEqual([
      book.id,
    ]);
  });

  it("can simulate database unavailability", async () => {
    await expect(createFakeDatabaseClient({ status: "unavailable" }).ping()).resolves.toBe(
      "unavailable",
    );
  });

  it("seeds feature flags and starter quotas for bootstrap", async () => {
    const client = createFakeDatabaseClient();
    const profile = await client.identity.ensureProfile({
      userId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      email: "reader@example.com",
    });
    const flags = await client.ops.listFlags();
    expect(flags.map((flag) => flag.key)).toEqual([
      "account_sync",
      "cloud_media",
      "maintenance_mode",
      "managed_qwen",
    ]);
    expect(flags.find((flag) => flag.key === "managed_qwen")?.enabled).toBe(true);
    expect(flags.find((flag) => flag.key === "maintenance_mode")?.enabled).toBe(false);
    const quotas = await client.ops.quotasFor(profile.accountId);
    expect(quotas.find((item) => item.key === "qwen_tasks_day")?.limit).toBe(50);
    expect(quotas.find((item) => item.key === "devices")?.limit).toBe(2);
    const allowed = await client.ops.consumeQuota(profile.accountId, "translations", 50);
    expect(allowed).toBe(true);
    await client.ops.patchFlag("managed_qwen", { enabled: false });
    expect(
      (await client.ops.listFlags()).find((flag) => flag.key === "managed_qwen")?.enabled,
    ).toBe(false);
    const policies = await client.ops.listPolicies();
    expect(policies.map((policy) => policy.task).sort()).toEqual([
      "chapter_summary",
      "chat",
      "translation",
    ]);
    expect(policies.every((policy) => policy.systemPrompt.length > 20)).toBe(true);
    expect(new Set(policies.map((policy) => policy.systemPrompt)).size).toBe(3);
  });
});
