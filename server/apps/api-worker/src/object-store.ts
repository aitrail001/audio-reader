import type { ReadinessStatus } from "@audio-reader/domain";
import { createGcsObjectStore } from "./gcs";

export type ObjectStore = {
  ping(): Promise<ReadinessStatus>;
  put(key: string, value: Uint8Array): Promise<void>;
  get(key: string): Promise<Uint8Array | undefined>;
  delete(key: string): Promise<void>;
  signedDownloadUrl?(key: string, expiresSeconds?: number): Promise<string | undefined>;
};

export function createFakeObjectStore(options: { status?: ReadinessStatus } = {}): ObjectStore {
  const objects = new Map<string, Uint8Array>();
  const status = options.status ?? "ok";
  return {
    ping: () => Promise.resolve(status),
    put: (key, value) => {
      objects.set(key, value);
      return Promise.resolve();
    },
    get: (key) => Promise.resolve(objects.get(key)),
    delete: (key) => {
      objects.delete(key);
      return Promise.resolve();
    },
  };
}

export function createUnavailableObjectStore(): ObjectStore {
  return {
    ping: () => Promise.resolve("unavailable"),
    put: () => Promise.reject(new Error("storage unavailable")),
    get: () => Promise.resolve(undefined),
    delete: () => Promise.resolve(),
  };
}

export function createR2ObjectStore(bucket: R2Bucket): ObjectStore {
  return {
    async ping() {
      try {
        await bucket.list({ limit: 1 });
        return "ok";
      } catch {
        return "unavailable";
      }
    },
    async put(key, value) {
      await bucket.put(key, value);
    },
    async get(key) {
      const object = await bucket.get(key);
      if (object === null) {
        return undefined;
      }
      return new Uint8Array(await object.arrayBuffer());
    },
    async delete(key) {
      await bucket.delete(key);
    },
  };
}

export function createResolvingObjectStore(resolve: () => Promise<ObjectStore>): ObjectStore {
  return {
    ping: async () => (await resolve()).ping(),
    put: async (key, value) => (await resolve()).put(key, value),
    get: async (key) => (await resolve()).get(key),
    delete: async (key) => (await resolve()).delete(key),
    signedDownloadUrl: async (key, expiresSeconds) => {
      const inner = await resolve();
      return inner.signedDownloadUrl?.(key, expiresSeconds);
    },
  };
}

export type SupabaseStorageOptions = {
  url: string;
  serviceRoleKey: string;
  bucket?: string;
  fetch?: typeof fetch;
};

export function createSupabaseObjectStore(options: SupabaseStorageOptions): ObjectStore {
  const origin = options.url.replace(/\/$/, "");
  const bucket = options.bucket?.trim() || "audio-reader-assets";
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const headers = {
    apikey: options.serviceRoleKey,
    authorization: `Bearer ${options.serviceRoleKey}`,
  };

  function objectUrl(key: string, prefix = "object"): string {
    const path = key
      .split("/")
      .map((segment) => encodeURIComponent(segment))
      .join("/");
    return `${origin}/storage/v1/${prefix}/${encodeURIComponent(bucket)}/${path}`;
  }

  return {
    async ping() {
      try {
        const listed = await fetchImpl(
          `${origin}/storage/v1/bucket/${encodeURIComponent(bucket)}`,
          {
            method: "GET",
            headers,
          },
        );
        if (listed.ok) {
          return "ok";
        }
        if (listed.status === 404) {
          const created = await fetchImpl(`${origin}/storage/v1/bucket`, {
            method: "POST",
            headers: { ...headers, "content-type": "application/json" },
            body: JSON.stringify({ name: bucket, public: false }),
          });
          return created.ok ? "ok" : "unavailable";
        }
        return "unavailable";
      } catch {
        return "unavailable";
      }
    },
    async put(key, value) {
      const response = await fetchImpl(objectUrl(key), {
        method: "POST",
        headers: {
          ...headers,
          "content-type": "application/octet-stream",
          "x-upsert": "true",
        },
        body: value,
      });
      if (!response.ok) {
        throw new Error("supabase storage upload failed");
      }
    },
    async get(key) {
      const response = await fetchImpl(objectUrl(key, "object/authenticated"), {
        method: "GET",
        headers,
      });
      if (response.status === 404) {
        return undefined;
      }
      if (!response.ok) {
        throw new Error("supabase storage download failed");
      }
      return new Uint8Array(await response.arrayBuffer());
    },
    async delete(key) {
      const response = await fetchImpl(objectUrl(key), { method: "DELETE", headers });
      if (response.status !== 404 && !response.ok) {
        throw new Error("supabase storage delete failed");
      }
    },
    async signedDownloadUrl(key, expiresSeconds = 900) {
      const response = await fetchImpl(objectUrl(key, "object/sign"), {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({
          expiresIn: Math.min(Math.max(Math.trunc(expiresSeconds), 1), 604_800),
        }),
      });
      if (!response.ok) {
        return undefined;
      }
      const payload: unknown = await response.json();
      if (typeof payload !== "object" || payload === null) {
        return undefined;
      }
      const signed =
        "signedURL" in payload && typeof payload.signedURL === "string"
          ? payload.signedURL
          : "signedUrl" in payload && typeof payload.signedUrl === "string"
            ? payload.signedUrl
            : "";
      if (signed === "") {
        return undefined;
      }
      return signed.startsWith("http")
        ? signed
        : `${origin}/storage/v1${signed.startsWith("/") ? signed : `/${signed}`}`;
    },
  };
}

export function tryCreateSupabaseObjectStore(input: {
  url?: string;
  serviceRoleKey?: string;
  bucket?: string;
  fetch?: typeof fetch;
}): ObjectStore | undefined {
  const url = input.url?.trim() ?? "";
  const serviceRoleKey = input.serviceRoleKey?.trim() ?? "";
  if (url === "" || serviceRoleKey === "") {
    return undefined;
  }
  return createSupabaseObjectStore({
    url,
    serviceRoleKey,
    ...(input.bucket === undefined ? {} : { bucket: input.bucket }),
    ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
  });
}

export function tryCreateGcsObjectStore(input: {
  bucket?: string;
  serviceAccountJson?: string;
  fetch?: typeof fetch;
}): ObjectStore | undefined {
  const bucket = input.bucket?.trim() ?? "";
  const serviceAccountJson = input.serviceAccountJson?.trim() ?? "";
  if (bucket === "" || serviceAccountJson === "") {
    return undefined;
  }
  try {
    return createGcsObjectStore({
      bucket,
      serviceAccountJson,
      ...(input.fetch === undefined ? {} : { fetch: input.fetch }),
    });
  } catch {
    return undefined;
  }
}
