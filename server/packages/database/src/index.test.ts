import { describe, expect, it } from "vitest";
import {
  ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION,
  CORE_TABLES,
  TRANSACTION_FUNCTIONS,
  createFakeDatabaseClient,
  createSupabaseDatabaseClient,
  packageId,
} from "./index";

describe("@audio-reader/database", () => {
  it("identifies the database package", () => {
    expect(packageId).toBe("@audio-reader/database");
  });

  it("exports the core multi-user table contract", () => {
    expect(CORE_TABLES).toHaveLength(43);
    expect(CORE_TABLES).toContain("service_schema_versions");
    expect(CORE_TABLES).toContain("chat_messages");
    expect(CORE_TABLES).toContain("passwordless_hits");
    expect(CORE_TABLES).toContain("profiles");
    expect(CORE_TABLES).toContain("assistant_cache_entries");
    expect(CORE_TABLES).toContain("operator_settings");
    expect(CORE_TABLES).toContain("quota_limits");
    expect(CORE_TABLES).toContain("product_events");
    expect(CORE_TABLES).toContain("sync_batches");
    expect(CORE_TABLES).toContain("sync_mutation_outcomes");
    expect(CORE_TABLES).toContain("user_analytics_preferences");
    expect(CORE_TABLES).toContain("user_progress_summaries");
    expect(CORE_TABLES).toContain("object_write_leases");
    expect(CORE_TABLES).toContain("asset_manifests_v2");
    expect(CORE_TABLES).toContain("sync_v2_changes");
    expect(CORE_TABLES).toContain("sync_v2_batches");
    expect(CORE_TABLES).toContain("sync_v2_mutation_outcomes");
  });

  it("exports privileged transaction function names", () => {
    expect(TRANSACTION_FUNCTIONS).toContain("claim_idempotency_record");
    expect(TRANSACTION_FUNCTIONS).toContain("claim_assistant_generation");
    expect(TRANSACTION_FUNCTIONS).toContain("append_audit_event");
    expect(TRANSACTION_FUNCTIONS).toContain("admin_user_progress_summary");
    expect(TRANSACTION_FUNCTIONS).toContain("complete_v2_asset_and_publish");
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

  it.each([
    [JSON.stringify(ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION), ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION],
    [JSON.stringify("wrong-version"), "wrong-version"],
    ["null", undefined],
  ] as const)("reads the exact account sync migration identity from its dedicated RPC", async (body, expected) => {
    const requests: string[] = [];
    const client = createSupabaseDatabaseClient({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      fetch: (input) => {
        requests.push(
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
        );
        return Promise.resolve(new Response(body, { status: 200 }));
      },
    });

    await expect(client.accountSyncSchemaVersion()).resolves.toBe(expected);
    expect(requests).toEqual([
      "https://example.supabase.co/rest/v1/rpc/account_sync_schema_version",
    ]);
  });

  it("treats the product-event window end as exclusive", async () => {
    const client = createFakeDatabaseClient();
    const base = {
      accountId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      deviceId: null,
      name: "reading.session.completed",
      outcome: "ok" as const,
      requestId: null,
      properties: {},
    };
    await client.ops.recordProductEvent({
      ...base,
      createdAt: "2026-08-30T23:59:59.999Z",
    });
    await client.ops.recordProductEvent({
      ...base,
      createdAt: "2026-08-31T00:00:00.000Z",
    });

    const events = await client.ops.listProductEvents({
      from: "2026-08-30T00:00:00.000Z",
      to: "2026-08-31T00:00:00.000Z",
    });
    expect(events.map((event) => event.createdAt)).toEqual(["2026-08-30T23:59:59.999Z"]);
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
    expect(flags.find((flag) => flag.key === "account_sync")?.enabled).toBe(false);
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
    expect(policies.every((policy) => policy.userPrompt.includes("{{"))).toBe(true);
    expect(new Set(policies.map((policy) => policy.systemPrompt)).size).toBe(3);
  });
});
