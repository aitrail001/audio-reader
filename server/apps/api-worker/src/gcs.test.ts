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
    const signed = await store.signedDownloadUrl?.("chapter/1.mp3", 900);
    expect(signed).toContain("https://storage.googleapis.com/audio-reader-assets/chapter/1.mp3");
    expect(signed).toContain("X-Goog-Algorithm=GOOG4-RSA-SHA256");
    expect(signed).toContain("X-Goog-Signature=");
    await store.delete("chapter/1.mp3");
    await expect(store.get("chapter/1.mp3")).resolves.toBeUndefined();
    expect(calls.some((call) => call.url.includes("oauth2.googleapis.com/token"))).toBe(true);
  });
});
