import { describe, expect, it } from "vitest";
import {
  createFakeObjectStore,
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
            new Response(JSON.stringify(objects.size === 0 ? [] : [{ name: "1.mp3" }]), {
              status: 200,
            }),
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
