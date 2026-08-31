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
    [400, "unknown"],
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

  it("recognizes Supabase's structured HTTP 400 object-not-found response", async () => {
    const notFound = JSON.stringify({
      statusCode: "404",
      error: "not_found",
      message: "Object not found",
    });
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      bucket: "private-assets",
      fetch: () => Promise.resolve(new Response(notFound, { status: 400 })),
    });

    await expect(store.anonymousRead("private/canary")).resolves.toBe("not_found");
    await expect(store.get("private/canary")).resolves.toBeUndefined();
    await expect(store.open("private/canary")).resolves.toBeUndefined();
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

  it.each([
    [
      "/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=relative",
      "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=relative",
    ],
    [
      "/storage/v1/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=storage-relative",
      "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=storage-relative",
    ],
    [
      "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=absolute",
      "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private%2Fpending%2Flarge.m4b?token=absolute",
    ],
  ])("creates a non-overwriting bound PUT for signed URL %s", async (signed, expectedUrl) => {
    const issuedAt = Date.UTC(2026, 8, 1, 0, 0, 0);
    const calls: Array<{ url: string; method: string; headers: Headers; body: unknown }> = [];
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co/",
      serviceRoleKey: "service-role",
      bucket: "audio-reader-assets",
      now: () => issuedAt,
      fetch: (input, init) => {
        calls.push({
          url: typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
          method: init?.method ?? "GET",
          headers: new Headers(init?.headers),
          body: init?.body,
        });
        return Promise.resolve(new Response(JSON.stringify({ url: signed }), { status: 200 }));
      },
    });

    await expect(store.supportsBoundUpload()).resolves.toBe(true);
    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "a".repeat(64),
      }),
    ).resolves.toEqual({
      url: expectedUrl,
      expiresAt: "2026-09-01T02:00:00.000Z",
      headers: {
        "content-length": "8388609",
        "content-type": "audio/mp4",
        "x-upsert": "false",
      },
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe(
      "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private/pending/large.m4b",
    );
    expect(calls[0]?.method).toBe("POST");
    expect(calls[0]?.headers.get("x-upsert")).toBeNull();
    expect(JSON.parse(String(calls[0]?.body))).toEqual({});
  });

  it("captures the hosted Supabase upload deadline before signing latency", async () => {
    const issuedAt = Date.UTC(2026, 8, 1, 0, 0, 0);
    let now = issuedAt;
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      now: () => now,
      fetch: () => {
        now += 30_000;
        return Promise.resolve(
          new Response(
            JSON.stringify({
              signedURL:
                "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=latency",
            }),
            { status: 200 },
          ),
        );
      },
    });

    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "e".repeat(64),
      }),
    ).resolves.toMatchObject({ expiresAt: "2026-09-01T02:00:00.000Z" });
  });

  it.each([
    [300, 900, "2026-09-01T00:05:00.000Z"],
    [1800, 900, "2026-09-01T00:15:00.000Z"],
    [10_000, 10_000, "2026-09-01T02:00:00.000Z"],
  ])(
    "clamps a custom HTTPS deadline to provider TTL %s, caller window %s, and two hours",
    async (signedUploadTtlSeconds, expiresSeconds, expectedExpiresAt) => {
      const issuedAt = Date.UTC(2026, 8, 1, 0, 0, 0);
      const store = createSupabaseObjectStore({
        url: "https://storage.example.com",
        serviceRoleKey: "service-role",
        signedUploadTtlSeconds,
        now: () => issuedAt,
        fetch: () =>
          Promise.resolve(
            new Response(
              JSON.stringify({
                signedURL:
                  "https://storage.example.com/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=self-hosted",
              }),
              { status: 200 },
            ),
          ),
      });

      await expect(store.supportsBoundUpload()).resolves.toBe(true);
      await expect(
        store.createBoundUpload?.("private/pending/large.m4b", {
          expiresSeconds,
          contentType: "audio/mp4",
          contentLength: 8 * 1024 * 1024 + 1,
          sha256: "f".repeat(64),
        }),
      ).resolves.toMatchObject({ expiresAt: expectedExpiresAt });
    },
  );

  it.each([undefined, 0, -1, 1.5, Number.NaN])(
    "fails custom HTTPS direct uploads closed without a valid provider TTL: %s",
    async (signedUploadTtlSeconds) => {
      let fetches = 0;
      const store = createSupabaseObjectStore({
        url: "https://storage.example.com",
        serviceRoleKey: "service-role",
        ...(signedUploadTtlSeconds === undefined ? {} : { signedUploadTtlSeconds }),
        fetch: () => {
          fetches += 1;
          return Promise.resolve(new Response("{}", { status: 200 }));
        },
      });

      await expect(store.supportsBoundUpload()).resolves.toBe(false);
      await expect(
        store.createBoundUpload?.("private/pending/large.m4b", {
          expiresSeconds: 900,
          contentType: "audio/mp4",
          contentLength: 8 * 1024 * 1024 + 1,
          sha256: "0".repeat(64),
        }),
      ).resolves.toBeUndefined();
      expect(fetches).toBe(0);
    },
  );

  it("keeps hosted Supabase direct uploads available without an explicit provider TTL", async () => {
    const issuedAt = Date.UTC(2026, 8, 1, 0, 0, 0);
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      now: () => issuedAt,
      fetch: () =>
        Promise.resolve(
          new Response(
            JSON.stringify({
              signedURL:
                "https://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=hosted",
            }),
            { status: 200 },
          ),
        ),
    });

    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "f".repeat(64),
      }),
    ).resolves.toMatchObject({ expiresAt: "2026-09-01T02:00:00.000Z" });
  });

  it.each([
    "https://uploads.example.com/private/large.m4b?token=cross-origin",
    "http://example.supabase.co/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=downgrade",
    "https://example.supabase.co:444/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=wrong-port",
  ])("rejects a signed upload URL outside the configured Supabase origin: %s", async (signed) => {
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      fetch: () =>
        Promise.resolve(new Response(JSON.stringify({ signedURL: signed }), { status: 200 })),
    });

    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "c".repeat(64),
      }),
    ).resolves.toBeUndefined();
  });

  it("does not advertise or create direct uploads for an HTTP Supabase origin", async () => {
    let fetches = 0;
    const store = createSupabaseObjectStore({
      url: "http://127.0.0.1:54321",
      serviceRoleKey: "service-role",
      fetch: () => {
        fetches += 1;
        return Promise.resolve(
          new Response(
            JSON.stringify({
              url: "http://127.0.0.1:54321/storage/v1/object/upload/sign/audio-reader-assets/private/large.m4b?token=local",
            }),
            { status: 200 },
          ),
        );
      },
    });

    await expect(store.supportsBoundUpload()).resolves.toBe(false);
    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "d".repeat(64),
      }),
    ).resolves.toBeUndefined();
    expect(fetches).toBe(0);
  });

  it.each([
    new Response("not-json", { status: 200 }),
    new Response(JSON.stringify({}), { status: 200 }),
    new Response(JSON.stringify({ url: "" }), { status: 200 }),
    new Response("unavailable", { status: 503 }),
  ])("fails closed when signed upload response is malformed or unavailable", async (response) => {
    const store = createSupabaseObjectStore({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role",
      fetch: () => Promise.resolve(response.clone()),
    });

    await expect(
      store.createBoundUpload?.("private/pending/large.m4b", {
        expiresSeconds: 900,
        contentType: "audio/mp4",
        contentLength: 8 * 1024 * 1024 + 1,
        sha256: "b".repeat(64),
      }),
    ).resolves.toBeUndefined();
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
