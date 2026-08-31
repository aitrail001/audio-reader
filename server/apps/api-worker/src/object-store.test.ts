import { describe, expect, it } from "vitest";
import {
  createFakeObjectStore,
  createR2ObjectStore,
  createSupabaseObjectStore,
  createUnavailableObjectStore,
} from "./object-store";

describe("fake object store", () => {
  it("stores objects in memory and reports ready", async () => {
    const store = createFakeObjectStore();
    await expect(store.ping()).resolves.toBe("ok");
    await store.put("chapter/1.mp3", new Uint8Array([1, 2, 3]));
    await expect(store.get("chapter/1.mp3")).resolves.toEqual(new Uint8Array([1, 2, 3]));
    await expect(store.list("chapter/")).resolves.toEqual(["chapter/1.mp3"]);
    await store.delete("chapter/1.mp3");
    await expect(store.get("chapter/1.mp3")).resolves.toBeUndefined();
  });

  it("can simulate storage unavailability", async () => {
    await expect(createFakeObjectStore({ status: "unavailable" }).ping()).resolves.toBe(
      "unavailable",
    );
  });
});

describe("unavailable object store", () => {
  it("reports unavailable", async () => {
    await expect(createUnavailableObjectStore().ping()).resolves.toBe("unavailable");
  });
});

describe("supabase object store", () => {
  it("recursively returns nested objects while excluding folder placeholders", async () => {
    const prefixes: string[] = [];
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: (_input, init) => {
        const body = JSON.parse(typeof init?.body === "string" ? init.body : "") as {
          prefix: string;
        };
        prefixes.push(body.prefix);
        const payload =
          body.prefix === "private/account-sync-readiness/"
            ? [{ name: "1777000000000", id: null, metadata: null }]
            : body.prefix === "private/account-sync-readiness/1777000000000/"
              ? [{ name: "owner-a", id: null, metadata: null }]
              : body.prefix === "private/account-sync-readiness/1777000000000/owner-a/"
                ? [{ name: "probe.canary", id: "object-id", metadata: { size: 8 } }]
                : [];
        return Promise.resolve(new Response(JSON.stringify(payload), { status: 200 }));
      },
    });

    await expect(store.list("private/account-sync-readiness/", 21)).resolves.toEqual([
      "private/account-sync-readiness/1777000000000/owner-a/probe.canary",
    ]);
    expect(prefixes).toEqual([
      "private/account-sync-readiness/",
      "private/account-sync-readiness/1777000000000/",
      "private/account-sync-readiness/1777000000000/owner-a/",
    ]);
  });

  it("rejects folder traversal and bounds recursive listing depth", async () => {
    const traversal = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () =>
        Promise.resolve(
          new Response(JSON.stringify([{ name: "../outside", id: null, metadata: null }]), {
            status: 200,
          }),
        ),
    });
    await expect(traversal.list("private/account-sync-readiness/", 21)).rejects.toThrow(/invalid/i);

    const depth = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () =>
        Promise.resolve(
          new Response(JSON.stringify([{ name: "nested", id: null, metadata: null }]), {
            status: 200,
          }),
        ),
    });
    await expect(depth.list("private/account-sync-readiness/", 21)).rejects.toThrow(/depth/i);

    const count = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: (_input, init) => {
        const body = JSON.parse(typeof init?.body === "string" ? init.body : "") as {
          limit: number;
          offset: number;
        };
        return Promise.resolve(
          new Response(
            JSON.stringify(
              Array.from({ length: body.limit }, (_, index) => ({
                name: `folder-${String(body.offset + index)}`,
                id: null,
                metadata: null,
              })),
            ),
            { status: 200 },
          ),
        );
      },
    });
    await expect(count.list("private/account-sync-readiness/", 21)).rejects.toThrow(/bound/i);
  });

  it.each([
    [401, "denied"],
    [403, "denied"],
    [404, "not_found"],
    [429, "unknown"],
    [503, "unknown"],
  ] as const)("classifies anonymous HTTP %s as %s", async (status, expected) => {
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () => Promise.resolve(new Response("probe", { status })),
    });

    await expect(store.anonymousRead("private/canary")).resolves.toBe(expected);
  });

  it("does not create a missing bucket during a readiness ping", async () => {
    const calls: Array<{ url: string; method: string }> = [];
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "missing-private-bucket",
      fetch: (input, init) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        calls.push({ url, method: init?.method ?? "GET" });
        return Promise.resolve(new Response("missing", { status: 404 }));
      },
    });

    await expect(store.ping()).resolves.toBe("unavailable");
    await expect(store.inspectPrivacy()).resolves.toMatchObject({ bucketExists: false });
    expect(calls.every((call) => call.method === "GET")).toBe(true);
    expect(calls.every((call) => !call.url.endsWith("/storage/v1/bucket"))).toBe(true);
  });

  it("reports a public bucket as non-private", async () => {
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "public-assets",
      fetch: () => Promise.resolve(new Response(JSON.stringify({ public: true }), { status: 200 })),
    });

    await expect(store.inspectPrivacy()).resolves.toEqual({
      bucketExists: true,
      publicAccess: true,
    });
  });

  it("uploads, downloads, deletes, and signs URLs", async () => {
    const objects = new Map<string, Uint8Array>();
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "audio-reader-assets",
      fetch: (input, init) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        const method = init?.method ?? "GET";
        if (url.endsWith("/storage/v1/bucket/audio-reader-assets") && method === "GET") {
          return Promise.resolve(new Response("{}", { status: 200 }));
        }
        if (url.endsWith("/storage/v1/object/list/audio-reader-assets") && method === "POST") {
          return Promise.resolve(
            new Response(
              JSON.stringify(
                objects.size === 0 ? [] : [{ name: "1.mp3", id: "object-id", metadata: {} }],
              ),
              {
                status: 200,
              },
            ),
          );
        }
        if (url.includes("/storage/v1/object/audio-reader-assets/") && method === "POST") {
          objects.set(url, init?.body instanceof Uint8Array ? init.body : new Uint8Array([9]));
          return Promise.resolve(new Response("{}", { status: 200 }));
        }
        if (
          url.includes("/storage/v1/object/authenticated/audio-reader-assets/") &&
          method === "GET"
        ) {
          const stored = [...objects.values()][0];
          if (stored === undefined) {
            return Promise.resolve(new Response("missing", { status: 404 }));
          }
          return Promise.resolve(new Response(stored, { status: 200 }));
        }
        if (url.includes("/storage/v1/object/sign/audio-reader-assets/") && method === "POST") {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                signedURL: "/object/sign/audio-reader-assets/chapter%2F1.mp3?token=t",
              }),
              {
                status: 200,
              },
            ),
          );
        }
        if (method === "DELETE") {
          objects.clear();
          return Promise.resolve(new Response(null, { status: 200 }));
        }
        return Promise.resolve(new Response("no", { status: 500 }));
      },
    });
    await expect(store.ping()).resolves.toBe("ok");
    await store.put("chapter/1.mp3", new Uint8Array([1, 2, 3]));
    await expect(store.get("chapter/1.mp3")).resolves.toEqual(new Uint8Array([1, 2, 3]));
    await expect(store.list("chapter/")).resolves.toEqual(["chapter/1.mp3"]);
    const signed = await store.signedDownloadUrl?.("chapter/1.mp3");
    expect(signed).toContain("https://example.supabase.co/storage/v1/object/sign/");
    await store.delete("chapter/1.mp3");
  });
});

function r2Bucket(): R2Bucket {
  const objects = new Map<string, Uint8Array>();
  return {
    put: (key: string, value: Uint8Array) => {
      objects.set(key, value);
      return Promise.resolve({} as R2Object);
    },
    get: (key: string) => {
      const value = objects.get(key);
      return Promise.resolve(
        value === undefined
          ? null
          : ({ arrayBuffer: () => Promise.resolve(value.buffer) } as R2ObjectBody),
      );
    },
    list: () =>
      Promise.resolve({ objects: [], delimitedPrefixes: [], truncated: false } as R2Objects),
    delete: (key: string) => {
      objects.delete(key);
      return Promise.resolve();
    },
  } as unknown as R2Bucket;
}

describe("R2 object store privacy", () => {
  function managementFetch(input: RequestInfo | URL): Promise<Response> {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.endsWith("/domains/managed")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            success: true,
            result: { bucketId: "id", domain: "private.r2.dev", enabled: false },
          }),
          { status: 200 },
        ),
      );
    }
    if (url.endsWith("/domains/custom")) {
      return Promise.resolve(
        new Response(JSON.stringify({ success: true, result: { domains: [] } }), { status: 200 }),
      );
    }
    return Promise.resolve(new Response("denied", { status: 403 }));
  }

  it("fails closed when management proof is not configured", async () => {
    const store = createR2ObjectStore(r2Bucket());
    await expect(store.inspectPrivacy()).rejects.toThrow(/privacy proof/i);
  });

  it("proves a bucket private only after checking managed and custom exposure", async () => {
    const calls: Array<{ url: string; authorization: string | null }> = [];
    const store = createR2ObjectStore(r2Bucket(), {
      accountId: "account-id",
      bucketName: "private-bucket",
      apiToken: "scoped-token",
      fetch: (input, init) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        calls.push({ url, authorization: new Headers(init?.headers).get("authorization") });
        return managementFetch(input);
      },
    });

    await expect(store.inspectPrivacy()).resolves.toEqual({
      bucketExists: true,
      publicAccess: false,
    });
    expect(calls.map((call) => new URL(call.url).pathname)).toEqual([
      "/client/v4/accounts/account-id/r2/buckets/private-bucket/domains/managed",
      "/client/v4/accounts/account-id/r2/buckets/private-bucket/domains/custom",
    ]);
    expect(calls.every((call) => call.authorization === "Bearer scoped-token")).toBe(true);
  });

  it("reports enabled r2.dev access and probes the anonymous canary URL", async () => {
    const anonymousUrls: string[] = [];
    const store = createR2ObjectStore(r2Bucket(), {
      accountId: "account-id",
      bucketName: "public-bucket",
      apiToken: "scoped-token",
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (url.endsWith("/domains/managed")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                success: true,
                result: { bucketId: "id", domain: "public.r2.dev", enabled: true },
              }),
              { status: 200 },
            ),
          );
        }
        if (url.endsWith("/domains/custom")) {
          return Promise.resolve(
            new Response(JSON.stringify({ success: true, result: { domains: [] } }), {
              status: 200,
            }),
          );
        }
        anonymousUrls.push(url);
        return Promise.resolve(new Response("canary", { status: 200 }));
      },
    });

    await expect(store.inspectPrivacy()).resolves.toMatchObject({ publicAccess: true });
    await expect(store.anonymousRead("private/readiness key")).resolves.toBe("readable");
    expect(anonymousUrls).toEqual(["https://public.r2.dev/private/readiness%20key"]);
  });

  it("reports an enabled custom domain and treats transient anonymous responses as unknown", async () => {
    const store = createR2ObjectStore(r2Bucket(), {
      accountId: "account-id",
      bucketName: "custom-public-bucket",
      apiToken: "scoped-token",
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (url.endsWith("/domains/managed")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                success: true,
                result: { bucketId: "id", domain: "disabled.r2.dev", enabled: false },
              }),
              { status: 200 },
            ),
          );
        }
        if (url.endsWith("/domains/custom")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                success: true,
                result: {
                  domains: [
                    {
                      domain: "assets.example.com",
                      enabled: true,
                      status: { ownership: "active", ssl: "active" },
                    },
                  ],
                },
              }),
              { status: 200 },
            ),
          );
        }
        return Promise.resolve(new Response("busy", { status: 429 }));
      },
    });

    await expect(store.inspectPrivacy()).resolves.toMatchObject({ publicAccess: true });
    await expect(store.anonymousRead("private/canary")).resolves.toBe("unknown");
  });
});
