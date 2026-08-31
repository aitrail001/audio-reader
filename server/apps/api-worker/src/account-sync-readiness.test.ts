import { afterEach, describe, expect, it, vi } from "vitest";
import { ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION } from "@audio-reader/database";
import {
  createAccountSyncReadinessService,
  type AccountSyncStorageProvider,
} from "./account-sync-readiness";
import type { ObjectStore } from "./object-store";
import { createSupabaseObjectStore } from "./object-store";

afterEach(() => {
  vi.restoreAllMocks();
});

function recordingStore(options: { corruptRead?: boolean; ping?: "ok" | "unavailable" } = {}): {
  store: ObjectStore;
  actions: string[];
  objects: Map<string, Uint8Array>;
} {
  const objects = new Map<string, Uint8Array>();
  const actions: string[] = [];
  return {
    actions,
    objects,
    store: {
      ping: () => {
        actions.push("ping");
        return Promise.resolve(options.ping ?? "ok");
      },
      put: (key, value) => {
        actions.push(`put:${key}`);
        objects.set(key, value);
        return Promise.resolve();
      },
      copy: (sourceKey, destinationKey) => {
        const value = objects.get(sourceKey);
        if (value === undefined) throw new Error("source missing");
        objects.set(destinationKey, value);
        return Promise.resolve();
      },
      get: (key) => {
        actions.push(`get:${key}`);
        const value = objects.get(key);
        return Promise.resolve(
          value === undefined || !options.corruptRead ? value : new TextEncoder().encode("corrupt"),
        );
      },
      open: (key) => {
        const value = objects.get(key);
        return Promise.resolve(
          value === undefined
            ? undefined
            : { size: value.byteLength, body: new Blob([value]).stream() },
        );
      },
      supportsBoundUpload: () => Promise.resolve(true),
      inspectPrivacy: () =>
        Promise.resolve({
          bucketExists: true,
          publicAccess: false,
        }),
      anonymousRead: (key) => {
        actions.push(`anonymous:${key}`);
        return Promise.resolve("denied");
      },
      list: (prefix, limit) => {
        actions.push(`list:${prefix}:${String(limit ?? "all")}`);
        return Promise.resolve(
          [...objects.keys()].filter((key) => key.startsWith(prefix)).slice(0, limit),
        );
      },
      delete: (key) => {
        actions.push(`delete:${key}`);
        objects.delete(key);
        return Promise.resolve();
      },
    },
  };
}

function service(
  provider: AccountSyncStorageProvider,
  storage: ObjectStore,
  options: {
    now?: () => number;
    successTtlMs?: number;
    failureTtlMs?: number;
    randomUUID?: () => string;
  } = {},
) {
  return createAccountSyncReadinessService({
    database: {
      accountSyncSchemaVersion: () => Promise.resolve(ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION),
    },
    resolveStorage: () =>
      Promise.resolve({
        store: storage,
        descriptor: {
          provider,
          bucket: `${provider}-private-assets`,
          configured: true,
          credentialsConfigured: true,
        },
      }),
    randomUUID: options.randomUUID ?? (() => "00000000-0000-4000-8000-000000000123"),
    ...options,
  });
}

describe("account sync object-storage readiness", () => {
  it("fails closed on a missing required schema before touching object storage", async () => {
    const { store, actions } = recordingStore();
    const readiness = createAccountSyncReadinessService({
      database: { accountSyncSchemaVersion: () => Promise.resolve(undefined) },
      resolveStorage: () =>
        Promise.resolve({
          store,
          descriptor: {
            provider: "gcs",
            bucket: "private-assets",
            configured: true,
            credentialsConfigured: true,
          },
        }),
    });

    await expect(readiness.read(true)).resolves.toMatchObject({
      schemaReady: false,
      ready: false,
      effective: false,
      reason: "required_schema_unavailable",
    });
    expect(actions).toEqual([]);
  });

  for (const provider of ["gcs", "supabase", "r2"] as const) {
    it(`probes ${provider} through the shared private canary contract`, async () => {
      const { store, actions } = recordingStore();
      const readiness = await service(provider, store).read(true);

      expect(readiness).toMatchObject({
        provider,
        schemaReady: true,
        credentialStatus: "ok",
        uploadStatus: "ok",
        downloadStatus: "ok",
        checksumStatus: "ok",
        deleteStatus: "ok",
        notFoundStatus: "ok",
        ready: true,
        requested: true,
        effective: true,
      });
      const put = actions.find((action) => action.startsWith("put:"));
      const deleted = actions.find((action) => action.startsWith("delete:"));
      expect(put).toMatch(/^put:private\/account-sync-readiness\//);
      expect(deleted?.replace(/^delete:/, "")).toBe(put?.replace(/^put:/, ""));
    });
  }

  it.each(["r2", "supabase"] as const)(
    "fails %s readiness closed without checksum-bound direct uploads",
    async (provider) => {
      const { store } = recordingStore();
      store.supportsBoundUpload = () => Promise.resolve(false);
      await expect(service(provider, store).read(true)).resolves.toMatchObject({
        ready: false,
        effective: false,
        reason: "storage_direct_upload_unavailable",
      });
    },
  );

  it("fails checksum readiness but still deletes and verifies the canary is gone", async () => {
    const { store } = recordingStore({ corruptRead: true });
    const readiness = await service("gcs", store).read(true);

    expect(readiness).toMatchObject({
      ready: false,
      effective: false,
      reason: "storage_checksum_mismatch",
      checksumStatus: "failed",
      deleteStatus: "ok",
      notFoundStatus: "ok",
    });
  });

  it("caches failures for a bounded TTL and retains last failure after recovery", async () => {
    let time = 1_777_000_000_000;
    const recording = recordingStore({ ping: "unavailable" });
    const readiness = service("r2", recording.store, {
      now: () => time,
      successTtlMs: 2_000,
      failureTtlMs: 1_000,
    });

    const first = await readiness.read(true);
    const cached = await readiness.read(true);
    expect(first.reason).toBe("storage_credentials_invalid");
    expect(cached.checkedAt).toBe(first.checkedAt);
    expect(recording.actions.filter((action) => action === "ping")).toHaveLength(1);

    time += 1_001;
    const healthy = recordingStore();
    Object.assign(recording.store, healthy.store);
    const recovered = await readiness.read(true);
    expect(recovered.ready).toBe(true);
    expect(recovered.lastSuccessAt).toBe(recovered.checkedAt);
    expect(recovered.lastFailureCode).toBe("storage_credentials_invalid");
  });

  it("coalesces concurrent forced probes while bypassing a cached result", async () => {
    const recording = recordingStore();
    const readiness = service("gcs", recording.store);
    await readiness.read(true);
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let calls = 0;
    recording.store.ping = async () => {
      calls += 1;
      await gate;
      return "ok";
    };

    const first = readiness.read(true, { force: true });
    const second = readiness.read(true, { force: true });
    await vi.waitFor(() => {
      expect(calls).toBe(1);
    });
    release?.();
    await expect(Promise.all([first, second])).resolves.toHaveLength(2);
  });

  it("generation-fences an old config probe and makes its caller observe the new selection", async () => {
    const old = recordingStore();
    const current = recordingStore({ ping: "unavailable" });
    let release:
      | ((value: {
          store: ObjectStore;
          descriptor: {
            provider: "gcs";
            bucket: string;
            configured: true;
            credentialsConfigured: true;
          };
        }) => void)
      | undefined;
    const oldSelection = new Promise<{
      store: ObjectStore;
      descriptor: {
        provider: "gcs";
        bucket: string;
        configured: true;
        credentialsConfigured: true;
      };
    }>((resolve) => {
      release = resolve;
    });
    let selection = 0;
    const readiness = createAccountSyncReadinessService({
      database: {
        accountSyncSchemaVersion: () => Promise.resolve(ACCOUNT_SYNC_REQUIRED_SCHEMA_VERSION),
      },
      resolveStorage: () => {
        selection += 1;
        return selection === 1
          ? oldSelection
          : Promise.resolve({
              store: current.store,
              descriptor: {
                provider: "gcs" as const,
                bucket: "new-private",
                configured: true as const,
                credentialsConfigured: true as const,
              },
            });
      },
    });

    const staleCaller = readiness.read(true, { force: true });
    await Promise.resolve();
    readiness.invalidate();
    const fresh = readiness.read(true, { force: true });
    release?.({
      store: old.store,
      descriptor: {
        provider: "gcs",
        bucket: "old-private",
        configured: true,
        credentialsConfigured: true,
      },
    });

    await expect(fresh).resolves.toMatchObject({ ready: false, bucket: "new-private" });
    await expect(staleCaller).resolves.toMatchObject({ ready: false, bucket: "new-private" });
    expect(selection).toBe(2);
  });

  for (const provider of ["gcs", "supabase", "r2"] as const) {
    it(`fails ${provider} readiness when provider privacy inspection reports public access`, async () => {
      const recording = recordingStore();
      recording.store.inspectPrivacy = () =>
        Promise.resolve({ bucketExists: true, publicAccess: true });
      await expect(service(provider, recording.store).read(true)).resolves.toMatchObject({
        ready: false,
        effective: false,
        privacyStatus: "failed",
        reason: "storage_public_access_allowed",
      });
      if (provider === "r2") {
        expect(recording.actions.some((action) => action.startsWith("put:"))).toBe(true);
        expect(recording.actions.some((action) => action.startsWith("anonymous:"))).toBe(true);
      } else {
        expect(recording.actions.some((action) => action.startsWith("put:"))).toBe(false);
      }
    });
  }

  it("cleans up a canary even when upload reports an ambiguous error after committing", async () => {
    const recording = recordingStore();
    recording.store.put = (key, value) => {
      recording.objects.set(key, value);
      return Promise.reject(new Error("ambiguous provider timeout"));
    };
    const result = await service("supabase", recording.store).read(true);
    expect(result).toMatchObject({
      ready: false,
      reason: "storage_upload_failed",
      deleteStatus: "ok",
      notFoundStatus: "ok",
    });
    expect(recording.objects.size).toBe(0);
  });

  it("recovers a stale canary through the bounded cleanup sweep after delete failures", async () => {
    let time = 1_777_000_000_000;
    const recording = recordingStore();
    let deletesFail = true;
    const normalDelete = recording.store.delete.bind(recording.store);
    recording.store.delete = (key) =>
      deletesFail ? Promise.reject(new Error("delete failed")) : normalDelete(key);
    const readiness = service("r2", recording.store, { now: () => time });
    await expect(readiness.read(true, { force: true })).resolves.toMatchObject({
      ready: false,
      reason: "storage_delete_failed",
    });
    expect(recording.objects.size).toBe(1);

    deletesFail = false;
    time += 15 * 60 * 1_000 + 1;
    await expect(readiness.read(true, { force: true })).resolves.toMatchObject({ ready: true });
    expect(recording.objects.size).toBe(0);
    expect(recording.actions).toContain("list:private/account-sync-readiness/:21");
  });

  it("recursively deletes and verifies a nested Supabase canary without deleting folders", async () => {
    const time = 1_777_000_000_000;
    const staleKey = `private/account-sync-readiness/${String(time - 15 * 60 * 1_000 - 1)}/stale-owner/ambiguous.canary`;
    const objects = new Map<string, Uint8Array>([[staleKey, new Uint8Array([1])]]);
    const deleted: string[] = [];
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: (input, init) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        const method = init?.method ?? "GET";
        if (url.endsWith("/storage/v1/bucket/private-assets")) {
          return Promise.resolve(new Response(JSON.stringify({ public: false }), { status: 200 }));
        }
        if (url.endsWith("/storage/v1/object/list/private-assets")) {
          const { prefix } = JSON.parse(typeof init?.body === "string" ? init.body : "") as {
            prefix: string;
          };
          const children = new Map<
            string,
            { name: string; id: string | null; metadata: object | null }
          >();
          for (const key of objects.keys()) {
            if (!key.startsWith(prefix)) continue;
            const relative = key.slice(prefix.length);
            const slash = relative.indexOf("/");
            const name = slash === -1 ? relative : relative.slice(0, slash);
            children.set(
              name,
              slash === -1
                ? { name, id: `id-${name}`, metadata: {} }
                : { name, id: null, metadata: null },
            );
          }
          return Promise.resolve(
            new Response(JSON.stringify([...children.values()]), { status: 200 }),
          );
        }
        const encodedPrefix = "/storage/v1/object/private-assets/";
        if (url.includes(encodedPrefix) && method === "POST") {
          const key = decodeURIComponent(
            url.slice(url.indexOf(encodedPrefix) + encodedPrefix.length),
          );
          objects.set(key, init?.body as Uint8Array);
          return Promise.resolve(new Response("{}", { status: 200 }));
        }
        if (url.includes("/storage/v1/object/public/private-assets/") && method === "GET") {
          return Promise.resolve(new Response("denied", { status: 403 }));
        }
        const authenticatedPrefix = "/storage/v1/object/authenticated/private-assets/";
        if (url.includes(authenticatedPrefix) && method === "GET") {
          const key = decodeURIComponent(
            url.slice(url.indexOf(authenticatedPrefix) + authenticatedPrefix.length),
          );
          const value = objects.get(key);
          return Promise.resolve(
            value === undefined
              ? new Response("missing", { status: 404 })
              : new Response(value, { status: 200 }),
          );
        }
        if (url.includes(encodedPrefix) && method === "DELETE") {
          const key = decodeURIComponent(
            url.slice(url.indexOf(encodedPrefix) + encodedPrefix.length),
          );
          deleted.push(key);
          objects.delete(key);
          return Promise.resolve(new Response(null, { status: 200 }));
        }
        return Promise.resolve(new Response("unexpected", { status: 500 }));
      },
    });
    await expect(service("supabase", store, { now: () => time }).read(true)).resolves.toMatchObject(
      {
        ready: true,
        deleteStatus: "ok",
        notFoundStatus: "ok",
      },
    );
    expect(deleted).toContain(staleKey);
    expect(deleted.some((key) => !key.endsWith(".canary"))).toBe(false);
    expect(objects.size).toBe(0);
  });

  it("rejects account-sync readiness when Supabase direct uploads use HTTP", async () => {
    const time = 1_777_000_000_000;
    const store = createSupabaseObjectStore({
      url: "http://127.0.0.1:54321",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () =>
        Promise.resolve(new Response(JSON.stringify({ public: false }), { status: 200 })),
    });

    await expect(service("supabase", store, { now: () => time }).read(true)).resolves.toMatchObject(
      {
        ready: false,
        reason: "storage_direct_upload_unavailable",
      },
    );
  });

  it("rejects custom HTTPS Supabase readiness without an explicit provider TTL", async () => {
    const time = 1_777_000_000_000;
    const store = createSupabaseObjectStore({
      url: "https://storage.example.com",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () =>
        Promise.resolve(new Response(JSON.stringify({ public: false }), { status: 200 })),
    });

    await expect(service("supabase", store, { now: () => time }).read(true)).resolves.toMatchObject(
      {
        ready: false,
        reason: "storage_direct_upload_unavailable",
      },
    );
  });

  it("does not sweep a canary exactly fifteen minutes old", async () => {
    const time = 1_777_000_000_000;
    const boundaryKey = `private/account-sync-readiness/${String(time - 15 * 60 * 1_000)}/boundary-owner/boundary.canary`;
    const recording = recordingStore();
    recording.objects.set(boundaryKey, new Uint8Array([1]));

    await expect(
      service("r2", recording.store, { now: () => time }).read(true),
    ).resolves.toMatchObject({
      ready: true,
    });
    expect(recording.objects.has(boundaryKey)).toBe(true);
    expect(recording.actions).not.toContain(`delete:${boundaryKey}`);
  });

  it("drains an oversized stale prefix in bounded chunks across probes", async () => {
    const time = 1_777_000_000_000;
    const recording = recordingStore();
    for (let index = 0; index < 21; index += 1) {
      recording.objects.set(
        `private/account-sync-readiness/${String(time - 15 * 60 * 1_000 - 1)}/stale-owner/stale-${String(index)}.canary`,
        new Uint8Array([index]),
      );
    }
    const readiness = service("r2", recording.store, { now: () => time });

    await expect(readiness.read(true, { force: true })).resolves.toMatchObject({
      ready: false,
      reason: "storage_delete_failed",
    });
    expect(recording.objects.size).toBe(1);
    await expect(readiness.read(true, { force: true })).resolves.toMatchObject({ ready: true });
    expect(recording.objects.size).toBe(0);
  });

  it("does not sweep another service instance's active canary during an interleaved probe", async () => {
    const time = 1_777_000_000_000;
    const recording = recordingStore();
    const originalPut = recording.store.put.bind(recording.store);
    let releaseFirst: (() => void) | undefined;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let putCount = 0;
    recording.store.put = async (key, value) => {
      putCount += 1;
      await originalPut(key, value);
      if (putCount === 1) await firstGate;
    };
    const uuids = (owner: string) => {
      let count = 0;
      return () => `${owner}-${String((count += 1))}`;
    };
    const firstService = service("r2", recording.store, {
      now: () => time,
      randomUUID: uuids("first"),
    });
    const secondService = service("r2", recording.store, {
      now: () => time,
      randomUUID: uuids("second"),
    });

    const first = firstService.read(true, { force: true });
    await vi.waitFor(() => {
      expect(putCount).toBe(1);
    });
    const activeKey = [...recording.objects.keys()][0];
    expect(activeKey).toContain(`/first-1/`);

    await expect(secondService.read(true, { force: true })).resolves.toMatchObject({ ready: true });
    expect(recording.objects.has(activeKey ?? "")).toBe(true);
    expect(recording.actions).not.toContain(`delete:${String(activeKey)}`);

    releaseFirst?.();
    await expect(first).resolves.toMatchObject({ ready: true });
    expect(recording.objects.size).toBe(0);
  });

  it.each(["not_found", "unknown"] as const)(
    "fails closed when the post-upload anonymous check is %s",
    async (status) => {
      const recording = recordingStore();
      recording.store.anonymousRead = () => Promise.resolve(status);

      await expect(service("gcs", recording.store).read(true)).resolves.toMatchObject({
        ready: false,
        effective: false,
        privacyStatus: "failed",
        reason: "storage_privacy_verification_failed",
        deleteStatus: "ok",
        notFoundStatus: "ok",
      });
    },
  );

  it("classifies an anonymous probe transport failure as privacy verification, not upload failure", async () => {
    const recording = recordingStore();
    recording.store.anonymousRead = () => Promise.reject(new Error("transient anonymous fetch"));

    await expect(service("supabase", recording.store).read(true)).resolves.toMatchObject({
      ready: false,
      reason: "storage_privacy_verification_failed",
      uploadStatus: "ok",
      privacyStatus: "failed",
      deleteStatus: "ok",
    });
  });

  it("never logs the private key, canary content, or raw provider error", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const rawSecret = "credential-secret-that-must-not-leak";
    const { store } = recordingStore();
    store.put = () => Promise.reject(new Error(rawSecret));
    const readiness = await service("supabase", store).read(true);

    expect(readiness.reason).toBe("storage_upload_failed");
    const logged = warning.mock.calls.flat().join(" ");
    expect(logged).not.toContain(rawSecret);
    expect(logged).not.toContain("00000000-0000-4000-8000-000000000123");
    expect(logged).not.toContain("audio-reader-account-sync");
  });
});
