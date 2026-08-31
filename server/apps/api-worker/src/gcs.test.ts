import { describe, expect, it } from "vitest";
import { createGcsObjectStore, parseServiceAccountJson } from "./gcs";

async function serviceAccountJson(): Promise<string> {
  const pair = (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const exported = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  if (!(exported instanceof ArrayBuffer)) {
    throw new Error("expected PKCS8 ArrayBuffer");
  }
  const pkcs8 = new Uint8Array(exported);
  let binary = "";
  for (const byte of pkcs8) {
    binary += String.fromCharCode(byte);
  }
  const body = btoa(binary).replace(/(.{64})/g, "$1\n");
  return JSON.stringify({
    type: "service_account",
    client_email: "audio-reader@example.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    token_uri: "https://oauth2.googleapis.com/token",
  });
}

describe("GCS object store", () => {
  it("requires a service account JSON with client_email and private_key", () => {
    expect(() => parseServiceAccountJson("{}")).toThrow(/client_email/);
    expect(
      parseServiceAccountJson(
        JSON.stringify({
          client_email: "sa@example.com",
          private_key: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n",
        }),
      ),
    ).toMatchObject({ clientEmail: "sa@example.com" });
  });

  it("ignores an untrusted token_uri and exchanges only with Google's fixed HTTPS endpoint", async () => {
    const parsed = JSON.parse(await serviceAccountJson()) as Record<string, unknown>;
    parsed.token_uri = "https://attacker.example/token";
    const calls: string[] = [];
    const store = createGcsObjectStore({
      bucket: "audio-reader-assets",
      serviceAccountJson: JSON.stringify(parsed),
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        calls.push(url);
        if (url === "https://oauth2.googleapis.com/token") {
          return Promise.resolve(
            new Response(JSON.stringify({ access_token: "token", expires_in: 3600 }), {
              status: 200,
            }),
          );
        }
        return Promise.resolve(new Response("{}", { status: 200 }));
      },
    });

    await expect(store.ping()).resolves.toBe("ok");
    expect(calls).toContain("https://oauth2.googleapis.com/token");
    expect(calls.some((url) => url.includes("attacker.example"))).toBe(false);
  });

  it("detects public IAM access even when the bucket metadata itself is readable", async () => {
    const store = createGcsObjectStore({
      bucket: "public-assets",
      serviceAccountJson: await serviceAccountJson(),
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (url === "https://oauth2.googleapis.com/token") {
          return Promise.resolve(
            new Response(JSON.stringify({ access_token: "token", expires_in: 3600 }), {
              status: 200,
            }),
          );
        }
        if (url.endsWith("/iam")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                bindings: [{ role: "roles/storage.objectViewer", members: ["allUsers"] }],
              }),
              { status: 200 },
            ),
          );
        }
        if (url.endsWith("/defaultObjectAcl")) {
          return Promise.resolve(new Response(JSON.stringify({ items: [] }), { status: 200 }));
        }
        return Promise.resolve(
          new Response(
            JSON.stringify({ iamConfiguration: { publicAccessPrevention: "inherited" } }),
            { status: 200 },
          ),
        );
      },
    });

    await expect(store.inspectPrivacy()).resolves.toEqual({
      bucketExists: true,
      publicAccess: true,
    });
  });

  it("accepts a private UBLA bucket without requesting the disabled default object ACL API", async () => {
    const calls: string[] = [];
    const store = createGcsObjectStore({
      bucket: "ubla-private-assets",
      serviceAccountJson: await serviceAccountJson(),
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        calls.push(url);
        if (url === "https://oauth2.googleapis.com/token") {
          return Promise.resolve(
            new Response(JSON.stringify({ access_token: "token", expires_in: 3600 }), {
              status: 200,
            }),
          );
        }
        if (url.endsWith("/iam")) {
          return Promise.resolve(new Response(JSON.stringify({ bindings: [] }), { status: 200 }));
        }
        if (url.endsWith("/defaultObjectAcl")) {
          return Promise.resolve(new Response("UBLA forbids ACL reads", { status: 400 }));
        }
        return Promise.resolve(
          new Response(
            JSON.stringify({
              iamConfiguration: {
                uniformBucketLevelAccess: { enabled: true },
                publicAccessPrevention: "enforced",
              },
            }),
            { status: 200 },
          ),
        );
      },
    });

    await expect(store.inspectPrivacy()).resolves.toEqual({
      bucketExists: true,
      publicAccess: false,
    });
    expect(calls.some((url) => url.endsWith("/defaultObjectAcl"))).toBe(false);
    expect(calls.some((url) => url.endsWith("/iam"))).toBe(true);
  });

  it("rejects a non-UBLA bucket with a public default object ACL", async () => {
    const store = createGcsObjectStore({
      bucket: "acl-public-assets",
      serviceAccountJson: await serviceAccountJson(),
      fetch: (input) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (url === "https://oauth2.googleapis.com/token") {
          return Promise.resolve(
            new Response(JSON.stringify({ access_token: "token", expires_in: 3600 }), {
              status: 200,
            }),
          );
        }
        if (url.endsWith("/iam"))
          return Promise.resolve(new Response(JSON.stringify({ bindings: [] }), { status: 200 }));
        if (url.endsWith("/defaultObjectAcl")) {
          return Promise.resolve(
            new Response(JSON.stringify({ items: [{ entity: "allUsers", role: "READER" }] }), {
              status: 200,
            }),
          );
        }
        return Promise.resolve(
          new Response(
            JSON.stringify({
              iamConfiguration: {
                uniformBucketLevelAccess: { enabled: false },
                publicAccessPrevention: "inherited",
              },
            }),
            { status: 200 },
          ),
        );
      },
    });

    await expect(store.inspectPrivacy()).resolves.toEqual({
      bucketExists: true,
      publicAccess: true,
    });
  });

  it.each([
    [401, "denied"],
    [403, "denied"],
    [404, "not_found"],
    [429, "unknown"],
    [500, "unknown"],
  ] as const)("classifies anonymous HTTP %s as %s", async (status, expected) => {
    const store = createGcsObjectStore({
      bucket: "private-assets",
      serviceAccountJson: await serviceAccountJson(),
      fetch: () => Promise.resolve(new Response("probe", { status })),
    });

    await expect(store.anonymousRead("private/canary")).resolves.toBe(expected);
  });

  it("uploads, downloads, deletes, and signs GET URLs through the JSON API", async () => {
    const json = await serviceAccountJson();
    const calls: { url: string; method: string }[] = [];
    const objects = new Map<string, Uint8Array>();
    const store = createGcsObjectStore({
      bucket: "audio-reader-assets",
      serviceAccountJson: json,
      now: () => Date.UTC(2026, 7, 28, 12, 0, 0),
      fetch: (input, init) => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        const method = init?.method ?? "GET";
        calls.push({ url, method });
        if (url.includes("oauth2.googleapis.com/token")) {
          return Promise.resolve(
            new Response(JSON.stringify({ access_token: "ya29.test", expires_in: 3600 }), {
              status: 200,
            }),
          );
        }
        if (
          url.startsWith("https://storage.googleapis.com/storage/v1/b/audio-reader-assets") &&
          method === "GET" &&
          !url.includes("/o/")
        ) {
          const parsed = new URL(url);
          if (parsed.pathname.endsWith("/o")) {
            const prefix = parsed.searchParams.get("prefix") ?? "";
            return Promise.resolve(
              new Response(
                JSON.stringify({
                  items: [...objects.keys()]
                    .filter((key) => key.startsWith(prefix))
                    .map((name) => ({ name })),
                }),
                { status: 200 },
              ),
            );
          }
          return Promise.resolve(new Response("{}", { status: 200 }));
        }
        if (url.includes("/upload/storage/v1/b/audio-reader-assets/o")) {
          const name = new URL(url).searchParams.get("name") ?? "";
          const body = init?.body;
          objects.set(
            name,
            body instanceof Uint8Array
              ? body
              : new Uint8Array(body instanceof ArrayBuffer ? body : []),
          );
          return Promise.resolve(new Response("{}", { status: 200 }));
        }
        const objectMatch = /\/o\/([^?]+)/.exec(url);
        const key = objectMatch?.[1] === undefined ? "" : decodeURIComponent(objectMatch[1]);
        if (method === "GET") {
          const stored = objects.get(key);
          if (stored === undefined) {
            return Promise.resolve(new Response("missing", { status: 404 }));
          }
          return Promise.resolve(new Response(stored, { status: 200 }));
        }
        if (method === "DELETE") {
          objects.delete(key);
          return Promise.resolve(new Response(null, { status: 204 }));
        }
        return Promise.resolve(new Response("no", { status: 500 }));
      },
    });

    await expect(store.ping()).resolves.toBe("ok");
    await store.put("chapter/1.mp3", new Uint8Array([1, 2, 3]));
    await expect(store.get("chapter/1.mp3")).resolves.toEqual(new Uint8Array([1, 2, 3]));
    await expect(store.list("chapter/")).resolves.toEqual(["chapter/1.mp3"]);
    const signed = await store.signedDownloadUrl?.("chapter/1.mp3", 900);
    expect(signed).toContain("https://storage.googleapis.com/audio-reader-assets/chapter/1.mp3");
    expect(signed).toContain("X-Goog-Algorithm=GOOG4-RSA-SHA256");
    expect(signed).toContain("X-Goog-Signature=");
    const bound = await store.createBoundUpload?.("chapter/large.m4b", {
      expiresSeconds: 900,
      contentType: "audio/mp4",
      contentLength: 2_147_483_648,
      sha256: "a".repeat(64),
    });
    expect(bound?.headers).toEqual({
      "content-length": "2147483648",
      "content-type": "audio/mp4",
      "x-goog-content-sha256": "a".repeat(64),
      "x-goog-meta-sha256": "a".repeat(64),
    });
    expect(bound?.expiresAt).toBe("2026-08-28T12:15:00.000Z");
    expect(bound?.url).toContain(
      "X-Goog-SignedHeaders=content-length%3Bcontent-type%3Bhost%3Bx-goog-content-sha256%3Bx-goog-meta-sha256",
    );
    await store.delete("chapter/1.mp3");
    await expect(store.get("chapter/1.mp3")).resolves.toBeUndefined();
    expect(calls.some((call) => call.url.includes("oauth2.googleapis.com/token"))).toBe(true);
  });
});
