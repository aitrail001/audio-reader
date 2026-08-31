import type { ReadinessStatus } from "@audio-reader/domain";
import { createGcsObjectStore } from "./gcs";

export type ObjectStore = {
  ping(): Promise<ReadinessStatus>;
  inspectPrivacy(): Promise<{ bucketExists: boolean; publicAccess: boolean }>;
  anonymousRead(key: string): Promise<"denied" | "readable" | "not_found" | "unknown">;
  put(key: string, value: Uint8Array): Promise<void>;
  copy(sourceKey: string, destinationKey: string): Promise<void>;
  get(key: string): Promise<Uint8Array | undefined>;
  open(key: string): Promise<ObjectStream | undefined>;
  list(prefix: string, limit?: number): Promise<string[]>;
  delete(key: string): Promise<void>;
  supportsBoundUpload(): Promise<boolean>;
  signedUploadUrl?(key: string, expiresSeconds?: number): Promise<string | undefined>;
  createBoundUpload?(key: string, input: BoundUploadInput): Promise<BoundUploadTarget | undefined>;
  signedDownloadUrl?(key: string, expiresSeconds?: number): Promise<string | undefined>;
};

export type ObjectStream = {
  size: number;
  body: ReadableStream<Uint8Array>;
  sha256?: string;
};

export type BoundUploadInput = {
  expiresSeconds: number;
  contentType: string;
  contentLength: number;
  sha256: string;
};

export type BoundUploadTarget = {
  url: string;
  headers: Record<string, string>;
  /** Conservative do-not-use-after deadline; not proof of a configurable provider's token TTL. */
  expiresAt: string;
};

export function createFakeObjectStore(
  options: { status?: ReadinessStatus; publicAccess?: boolean; bucketExists?: boolean } = {},
): ObjectStore {
  const objects = new Map<string, Uint8Array>();
  const status = options.status ?? "ok";
  return {
    ping: () => Promise.resolve(status),
    inspectPrivacy: () =>
      Promise.resolve({
        bucketExists: options.bucketExists ?? true,
        publicAccess: options.publicAccess ?? false,
      }),
    anonymousRead: () => Promise.resolve(options.publicAccess === true ? "readable" : "denied"),
    put: (key, value) => {
      objects.set(key, value);
      return Promise.resolve();
    },
    copy: (sourceKey, destinationKey) => {
      const value = objects.get(sourceKey);
      if (value === undefined) return Promise.reject(new Error("source object missing"));
      objects.set(destinationKey, value);
      return Promise.resolve();
    },
    get: (key) => Promise.resolve(objects.get(key)),
    open: (key) => {
      const value = objects.get(key);
      return Promise.resolve(
        value === undefined
          ? undefined
          : {
              size: value.byteLength,
              body: streamBytes(value),
            },
      );
    },
    list: (prefix, limit) =>
      Promise.resolve(
        [...objects.keys()]
          .filter((key) => key.startsWith(prefix))
          .sort()
          .slice(0, limit),
      ),
    delete: (key) => {
      objects.delete(key);
      return Promise.resolve();
    },
    supportsBoundUpload: () => Promise.resolve(false),
  };
}

export function createUnavailableObjectStore(): ObjectStore {
  return {
    ping: () => Promise.resolve("unavailable"),
    inspectPrivacy: () => Promise.reject(new Error("storage unavailable")),
    anonymousRead: () => Promise.resolve("unknown"),
    put: () => Promise.reject(new Error("storage unavailable")),
    copy: () => Promise.reject(new Error("storage unavailable")),
    get: () => Promise.resolve(undefined),
    open: () => Promise.resolve(undefined),
    list: () => Promise.reject(new Error("storage unavailable")),
    delete: () => Promise.resolve(),
    supportsBoundUpload: () => Promise.resolve(false),
  };
}

export type R2PrivacyProofOptions = {
  accountId: string;
  bucketName: string;
  apiToken: string;
  fetch?: typeof fetch;
};

/** R2 bindings do not expose public-domain policy, so readiness also requires management proof. */
export function createR2ObjectStore(
  bucket: R2Bucket,
  privacyProof?: R2PrivacyProofOptions,
): ObjectStore {
  const accountId = privacyProof?.accountId.trim() ?? "";
  const bucketName = privacyProof?.bucketName.trim() ?? "";
  const apiToken = privacyProof?.apiToken.trim() ?? "";
  const fetchImpl = privacyProof?.fetch ?? ((input, init) => globalThis.fetch(input, init));
  let anonymousDomains: string[] | undefined;

  async function managementGet(suffix: "managed" | "custom"): Promise<Response> {
    const url = `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/r2/buckets/${encodeURIComponent(bucketName)}/domains/${suffix}`;
    return fetchImpl(url, {
      method: "GET",
      headers: { authorization: `Bearer ${apiToken}` },
    });
  }

  return {
    async ping() {
      try {
        await bucket.list({ limit: 1 });
        return "ok";
      } catch {
        return "unavailable";
      }
    },
    async inspectPrivacy() {
      if (accountId === "" || bucketName === "" || apiToken === "") {
        throw new Error("R2 privacy proof is not configured.");
      }
      const managedResponse = await managementGet("managed");
      if (managedResponse.status === 404) {
        anonymousDomains = undefined;
        return { bucketExists: false, publicAccess: false };
      }
      if (!managedResponse.ok) throw new Error("R2 privacy proof failed.");
      const managed = cloudflareResult(await managedResponse.json());
      if (
        !isRecord(managed) ||
        typeof managed.enabled !== "boolean" ||
        typeof managed.domain !== "string"
      ) {
        throw new Error("R2 privacy proof response was invalid.");
      }

      const customResponse = await managementGet("custom");
      if (customResponse.status === 404) {
        anonymousDomains = undefined;
        return { bucketExists: false, publicAccess: false };
      }
      if (!customResponse.ok) throw new Error("R2 privacy proof failed.");
      const custom = cloudflareResult(await customResponse.json());
      if (!isRecord(custom) || !Array.isArray(custom.domains)) {
        throw new Error("R2 privacy proof response was invalid.");
      }
      const enabledDomains: string[] = [];
      if (managed.enabled) enabledDomains.push(validPublicHostname(managed.domain));
      for (const entry of custom.domains) {
        if (
          !isRecord(entry) ||
          typeof entry.enabled !== "boolean" ||
          typeof entry.domain !== "string"
        ) {
          throw new Error("R2 privacy proof response was invalid.");
        }
        if (entry.enabled) enabledDomains.push(validPublicHostname(entry.domain));
      }
      anonymousDomains = [...new Set(enabledDomains)];
      return { bucketExists: true, publicAccess: anonymousDomains.length > 0 };
    },
    async anonymousRead(key) {
      if (anonymousDomains === undefined) return "unknown";
      // With both public exposure mechanisms disabled, management proof establishes no URL exists.
      if (anonymousDomains.length === 0) return "denied";
      const statuses = await Promise.all(
        anonymousDomains.map(async (domain) => {
          try {
            const response = await fetchImpl(`https://${domain}/${encodeObjectPath(key)}`, {
              method: "GET",
            });
            return classifyAnonymousResponse(response);
          } catch {
            return "unknown" as const;
          }
        }),
      );
      if (statuses.includes("readable")) return "readable";
      if (statuses.includes("unknown")) return "unknown";
      if (statuses.every((status) => status === "denied")) return "denied";
      if (statuses.every((status) => status === "not_found")) return "not_found";
      return "unknown";
    },
    async put(key, value) {
      await bucket.put(key, value);
    },
    async copy(sourceKey, destinationKey) {
      const source = await bucket.get(sourceKey);
      if (source === null) throw new Error("R2 source object missing");
      await bucket.put(destinationKey, source.body);
    },
    async get(key) {
      const object = await bucket.get(key);
      if (object === null) {
        return undefined;
      }
      return new Uint8Array(await object.arrayBuffer());
    },
    async open(key) {
      const object = await bucket.get(key);
      if (object === null) return undefined;
      return { size: object.size, body: object.body as ReadableStream<Uint8Array> };
    },
    async list(prefix, limit) {
      const keys: string[] = [];
      let cursor: string | undefined;
      do {
        const remaining = limit === undefined ? 1000 : Math.max(1, limit - keys.length);
        const page = await bucket.list({
          prefix,
          limit: Math.min(1000, remaining),
          ...(cursor ? { cursor } : {}),
        });
        keys.push(...page.objects.map((object) => object.key));
        if (limit !== undefined && keys.length >= limit) break;
        cursor = page.truncated ? page.cursor : undefined;
      } while (cursor !== undefined);
      return keys.sort();
    },
    async delete(key) {
      await bucket.delete(key);
    },
    supportsBoundUpload: () => Promise.resolve(false),
  };
}

export function createResolvingObjectStore(resolve: () => Promise<ObjectStore>): ObjectStore {
  return {
    ping: async () => (await resolve()).ping(),
    inspectPrivacy: async () => (await resolve()).inspectPrivacy(),
    anonymousRead: async (key) => (await resolve()).anonymousRead(key),
    put: async (key, value) => (await resolve()).put(key, value),
    copy: async (sourceKey, destinationKey) => (await resolve()).copy(sourceKey, destinationKey),
    get: async (key) => (await resolve()).get(key),
    open: async (key) => (await resolve()).open(key),
    list: async (prefix, limit) => (await resolve()).list(prefix, limit),
    delete: async (key) => (await resolve()).delete(key),
    supportsBoundUpload: async () => (await resolve()).supportsBoundUpload(),
    signedUploadUrl: async (key, expiresSeconds) => {
      const inner = await resolve();
      return inner.signedUploadUrl?.(key, expiresSeconds);
    },
    createBoundUpload: async (key, input) => {
      const inner = await resolve();
      return inner.createBoundUpload?.(key, input);
    },
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
  now?: () => number;
  signedUploadTtlSeconds?: number;
};

const SUPABASE_LIST_MAX_DEPTH = 8;
const SUPABASE_LIST_MAX_TRAVERSAL_ENTRIES = 4_096;
const SUPABASE_SIGNED_UPLOAD_SECONDS = 2 * 60 * 60;

export function createSupabaseObjectStore(options: SupabaseStorageOptions): ObjectStore {
  const origin = options.url.replace(/\/+$/, "");
  const bucket = options.bucket?.trim() || "audio-reader-assets";
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const now = options.now ?? (() => Date.now());
  let configuredUrl: URL | undefined;
  try {
    configuredUrl = new URL(origin);
  } catch {
    configuredUrl = undefined;
  }
  const usesHostedSupabaseLifetime =
    configuredUrl?.hostname === "supabase.co" ||
    configuredUrl?.hostname.endsWith(".supabase.co") === true;
  const customSignedUploadSeconds =
    Number.isSafeInteger(options.signedUploadTtlSeconds) &&
    (options.signedUploadTtlSeconds ?? 0) > 0
      ? Math.min(options.signedUploadTtlSeconds ?? 0, SUPABASE_SIGNED_UPLOAD_SECONDS)
      : undefined;
  const supportsNativeDirectUpload =
    configuredUrl?.protocol === "https:" &&
    (usesHostedSupabaseLifetime || customSignedUploadSeconds !== undefined);
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

  async function createSignedUploadUrl(key: string): Promise<string | undefined> {
    if (!supportsNativeDirectUpload) return undefined;
    try {
      const response = await fetchImpl(objectUrl(key, "object/upload/sign"), {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: "{}",
      });
      if (!response.ok) return undefined;
      const payload: unknown = await response.json();
      if (!isRecord(payload)) return undefined;
      const signed = [payload.signedURL, payload.signedUrl, payload.url].find(
        (value): value is string => typeof value === "string" && value.trim() !== "",
      );
      return signed === undefined ? undefined : normalizeSupabaseSignedUrl(origin, signed);
    } catch {
      return undefined;
    }
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
        return "unavailable";
      } catch {
        return "unavailable";
      }
    },
    async inspectPrivacy() {
      const response = await fetchImpl(
        `${origin}/storage/v1/bucket/${encodeURIComponent(bucket)}`,
        {
          method: "GET",
          headers,
        },
      );
      if (response.status === 404) return { bucketExists: false, publicAccess: false };
      if (!response.ok) throw new Error("supabase storage privacy inspection failed");
      const payload: unknown = await response.json();
      if (
        typeof payload !== "object" ||
        payload === null ||
        !("public" in payload) ||
        typeof payload.public !== "boolean"
      ) {
        throw new Error("supabase storage privacy response was invalid");
      }
      return {
        bucketExists: true,
        publicAccess: payload.public,
      };
    },
    async anonymousRead(key) {
      try {
        return classifyAnonymousResponse(
          await fetchImpl(objectUrl(key, "object/public"), { method: "GET" }),
        );
      } catch {
        return "unknown";
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
    async copy(sourceKey, destinationKey) {
      const response = await fetchImpl(`${origin}/storage/v1/object/copy`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({
          bucketId: bucket,
          sourceKey,
          destinationKey,
        }),
      });
      if (!response.ok) throw new Error("supabase storage copy failed");
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
    async open(key) {
      const response = await fetchImpl(objectUrl(key, "object/authenticated"), {
        method: "GET",
        headers,
      });
      if (response.status === 404) return undefined;
      if (!response.ok || response.body === null)
        throw new Error("supabase storage download failed");
      const size = Number(response.headers.get("content-length"));
      if (!Number.isSafeInteger(size) || size < 0) {
        await response.body.cancel();
        throw new Error("supabase storage object size is unavailable");
      }
      return { size, body: response.body as ReadableStream<Uint8Array> };
    },
    async list(prefix, limit) {
      const objectLimit = Math.min(1000, Math.max(1, limit ?? 1000));
      const traversalLimit = Math.min(
        SUPABASE_LIST_MAX_TRAVERSAL_ENTRIES,
        Math.max(64, objectLimit * 4),
      );
      const keys = new Set<string>();
      const pending: Array<{ prefix: string; depth: number }> = [{ prefix, depth: 0 }];
      const visited = new Set<string>([prefix]);
      let traversed = 0;

      while (pending.length > 0 && keys.size < objectLimit) {
        const current = pending.shift();
        if (current === undefined) break;
        for (let offset = 0; ;) {
          const remainingTraversal = traversalLimit - traversed;
          if (remainingTraversal <= 0) {
            throw new Error("supabase storage list traversal bound exceeded");
          }
          const pageSize = Math.min(1000, remainingTraversal);
          const response = await fetchImpl(
            `${origin}/storage/v1/object/list/${encodeURIComponent(bucket)}`,
            {
              method: "POST",
              headers: { ...headers, "content-type": "application/json" },
              body: JSON.stringify({
                prefix: current.prefix,
                limit: pageSize,
                offset,
                sortBy: { column: "name", order: "asc" },
              }),
            },
          );
          if (!response.ok) throw new Error("supabase storage list failed");
          const payload: unknown = await response.json();
          if (!Array.isArray(payload)) {
            throw new Error("supabase storage list response was invalid");
          }
          for (const item of payload as unknown[]) {
            traversed += 1;
            if (traversed > traversalLimit || !isRecord(item) || typeof item.name !== "string") {
              throw new Error("supabase storage list response was invalid");
            }
            const key = supabaseChildKey(current.prefix, item.name);
            if (item.id === null && item.metadata === null) {
              if (current.depth >= SUPABASE_LIST_MAX_DEPTH) {
                throw new Error("supabase storage list depth bound exceeded");
              }
              const childPrefix = `${key}/`;
              if (!visited.has(childPrefix)) {
                visited.add(childPrefix);
                pending.push({ prefix: childPrefix, depth: current.depth + 1 });
              }
            } else if (typeof item.id === "string" && item.id !== "") {
              keys.add(key);
              if (keys.size >= objectLimit) break;
            } else {
              throw new Error("supabase storage list response was invalid");
            }
          }
          if (keys.size >= objectLimit || payload.length < pageSize) break;
          offset += pageSize;
        }
      }
      return [...keys].sort().slice(0, objectLimit);
    },
    async delete(key) {
      const response = await fetchImpl(objectUrl(key), { method: "DELETE", headers });
      if (response.status !== 404 && !response.ok) {
        throw new Error("supabase storage delete failed");
      }
    },
    supportsBoundUpload: () => Promise.resolve(supportsNativeDirectUpload),
    signedUploadUrl: createSignedUploadUrl,
    async createBoundUpload(key, input) {
      const issuedBeforeRequest = now();
      const url = await createSignedUploadUrl(key);
      if (url === undefined) return undefined;
      // Hosted Supabase fixes upload tokens at two hours. Custom HTTPS deployments use the
      // shorter of the caller window and their explicit provider TTL.
      const adapterSeconds = usesHostedSupabaseLifetime
        ? SUPABASE_SIGNED_UPLOAD_SECONDS
        : Math.min(
            Math.max(Math.trunc(input.expiresSeconds), 1),
            customSignedUploadSeconds ?? SUPABASE_SIGNED_UPLOAD_SECONDS,
          );
      // Supabase's token selects the temporary key but does not bind size or checksum. Refuse
      // overwrite here; completion streams and verifies both values before promoting the object.
      return {
        url,
        expiresAt: new Date(issuedBeforeRequest + adapterSeconds * 1000).toISOString(),
        headers: {
          "content-length": String(input.contentLength),
          "content-type": input.contentType,
          "x-upsert": "false",
        },
      };
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

function normalizeSupabaseSignedUrl(origin: string, signed: string): string | undefined {
  const value = signed.trim();
  try {
    const configuredOrigin = new URL(origin).origin;
    if (/^https?:\/\//i.test(value)) {
      const url = new URL(value);
      return url.origin === configuredOrigin ? url.toString() : undefined;
    }
    const path = value.replace(/^\/+/, "");
    const storagePath = path.startsWith("storage/v1/") ? path : `storage/v1/${path}`;
    return new URL(`/${storagePath}`, `${origin}/`).toString();
  } catch {
    return undefined;
  }
}

function streamBytes(value: Uint8Array): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      controller.enqueue(value);
      controller.close();
    },
  });
}

function classifyAnonymousResponse(
  response: Response,
): "denied" | "readable" | "not_found" | "unknown" {
  if (response.ok) return "readable";
  if (response.status === 401 || response.status === 403) return "denied";
  if (response.status === 404) return "not_found";
  return "unknown";
}

function cloudflareResult(payload: unknown): unknown {
  if (!isRecord(payload) || payload.success !== true || !("result" in payload)) {
    throw new Error("R2 privacy proof response was invalid.");
  }
  return payload.result;
}

function validPublicHostname(value: string): string {
  const domain = value.trim().toLowerCase();
  if (domain === "" || domain.includes("/") || domain.includes("@") || domain.includes(":")) {
    throw new Error("R2 privacy proof response was invalid.");
  }
  const parsed = new URL(`https://${domain}`);
  if (parsed.hostname !== domain || parsed.port !== "") {
    throw new Error("R2 privacy proof response was invalid.");
  }
  return domain;
}

function encodeObjectPath(key: string): string {
  return key
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

function supabaseChildKey(prefix: string, name: string): string {
  const relative = name.startsWith(prefix) ? name.slice(prefix.length) : name;
  if (
    relative === "" ||
    relative === "." ||
    relative === ".." ||
    relative.includes("/") ||
    relative.includes("\\")
  ) {
    throw new Error("supabase storage list response was invalid");
  }
  return `${prefix}${relative}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function tryCreateSupabaseObjectStore(input: {
  url?: string;
  serviceRoleKey?: string;
  bucket?: string;
  fetch?: typeof fetch;
  signedUploadTtlSeconds?: number;
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
    ...(input.signedUploadTtlSeconds === undefined
      ? {}
      : { signedUploadTtlSeconds: input.signedUploadTtlSeconds }),
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
