import type { ReadinessStatus } from "@audio-reader/domain";
import type { ObjectStore } from "./object-store";

export type GcsServiceAccount = {
  clientEmail: string;
  privateKeyPem: string;
  privateKeyId?: string;
  tokenUri: string;
};

export type GcsStoreOptions = {
  bucket: string;
  serviceAccountJson: string;
  fetch?: typeof fetch;
  now?: () => number;
};

const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const STORAGE_SCOPE = "https://www.googleapis.com/auth/devstorage.read_write";

export function parseServiceAccountJson(raw: string): GcsServiceAccount {
  const parsed: unknown = JSON.parse(raw);
  if (!isRecord(parsed)) {
    throw new Error("GCS service account JSON must be an object.");
  }
  const clientEmail = typeof parsed.client_email === "string" ? parsed.client_email.trim() : "";
  const privateKeyPem = typeof parsed.private_key === "string" ? parsed.private_key : "";
  if (clientEmail === "" || privateKeyPem.trim() === "") {
    throw new Error("GCS service account JSON needs client_email and private_key.");
  }
  const tokenUri = typeof parsed.token_uri === "string" ? parsed.token_uri.trim() : "";
  const privateKeyId =
    typeof parsed.private_key_id === "string" ? parsed.private_key_id.trim() : "";
  return {
    clientEmail,
    privateKeyPem,
    tokenUri: tokenUri === "" ? DEFAULT_TOKEN_URI : tokenUri,
    ...(privateKeyId === "" ? {} : { privateKeyId }),
  };
}

export function createGcsObjectStore(options: GcsStoreOptions): ObjectStore {
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const now = options.now ?? (() => Date.now());
  const account = parseServiceAccountJson(options.serviceAccountJson);
  const bucket = options.bucket.trim();
  if (bucket === "") {
    throw new Error("GCS bucket is required.");
  }
  let cachedToken: { token: string; expiresAt: number } | undefined;
  let cachedKey: CryptoKey | undefined;

  async function accessToken(): Promise<string> {
    if (cachedToken !== undefined && cachedToken.expiresAt - 60_000 > now()) {
      return cachedToken.token;
    }
    const assertion = await signJwt(account, now, () => signingKey());
    const body = new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    });
    const response = await fetchImpl(account.tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!response.ok) {
      throw new Error("GCS token exchange failed.");
    }
    const payload: unknown = await response.json();
    if (!isRecord(payload) || typeof payload.access_token !== "string") {
      throw new Error("GCS token response was invalid.");
    }
    const expiresIn =
      typeof payload.expires_in === "number" && Number.isFinite(payload.expires_in)
        ? payload.expires_in
        : 3600;
    cachedToken = {
      token: payload.access_token,
      expiresAt: now() + expiresIn * 1000,
    };
    return cachedToken.token;
  }

  async function signingKey(): Promise<CryptoKey> {
    if (cachedKey !== undefined) {
      return cachedKey;
    }
    cachedKey = await importPkcs8(account.privateKeyPem);
    return cachedKey;
  }

  async function authorized(
    url: string,
    init: RequestInit & { rawBody?: Uint8Array } = {},
  ): Promise<Response> {
    const token = await accessToken();
    const { rawBody, headers: initHeaders, ...rest } = init;
    const headers = new Headers(initHeaders);
    headers.set("authorization", `Bearer ${token}`);
    return fetchImpl(url, {
      ...rest,
      headers,
      ...(rawBody === undefined ? {} : { body: rawBody }),
    });
  }

  return {
    async ping(): Promise<ReadinessStatus> {
      try {
        const response = await authorized(
          `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}`,
        );
        return response.ok ? "ok" : "unavailable";
      } catch {
        return "unavailable";
      }
    },
    async put(key, value) {
      const url = new URL(
        `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(bucket)}/o`,
      );
      url.searchParams.set("uploadType", "media");
      url.searchParams.set("name", key);
      const response = await authorized(url.toString(), {
        method: "POST",
        headers: { "content-type": "application/octet-stream" },
        rawBody: value,
      });
      if (!response.ok) {
        throw new Error("GCS upload failed.");
      }
    },
    async get(key) {
      const objectPath = encodeURIComponent(key);
      const response = await authorized(
        `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o/${objectPath}?alt=media`,
      );
      if (response.status === 404) {
        return undefined;
      }
      if (!response.ok) {
        throw new Error("GCS download failed.");
      }
      return new Uint8Array(await response.arrayBuffer());
    },
    async list(prefix) {
      const keys: string[] = [];
      let pageToken = "";
      do {
        const url = new URL(
          `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o`,
        );
        url.searchParams.set("prefix", prefix);
        url.searchParams.set("maxResults", "1000");
        if (pageToken !== "") url.searchParams.set("pageToken", pageToken);
        const response = await authorized(url.toString());
        if (!response.ok) throw new Error("GCS list failed.");
        const payload: unknown = await response.json();
        if (!isRecord(payload)) throw new Error("GCS list response was invalid.");
        if (Array.isArray(payload.items)) {
          keys.push(
            ...payload.items.flatMap((item) =>
              isRecord(item) && typeof item.name === "string" ? [item.name] : [],
            ),
          );
        }
        pageToken = typeof payload.nextPageToken === "string" ? payload.nextPageToken : "";
      } while (pageToken !== "");
      return [...new Set(keys)].sort();
    },
    async delete(key) {
      const objectPath = encodeURIComponent(key);
      const response = await authorized(
        `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o/${objectPath}`,
        { method: "DELETE" },
      );
      if (response.status !== 404 && !response.ok) {
        throw new Error("GCS delete failed.");
      }
    },
    async signedDownloadUrl(key, expiresSeconds = 900) {
      return signGcsGetUrl({
        bucket,
        objectName: key,
        account,
        expiresSeconds,
        now,
        key: await signingKey(),
      });
    },
  };
}

export async function signGcsGetUrl(input: {
  bucket: string;
  objectName: string;
  account: GcsServiceAccount;
  expiresSeconds: number;
  now: () => number;
  key: CryptoKey;
}): Promise<string> {
  const expires = Math.min(Math.max(Math.trunc(input.expiresSeconds), 1), 604_800);
  const issued = new Date(input.now());
  const dateStamp = yyyymmdd(issued);
  const timestamp = `${dateStamp}T${hhmmss(issued)}Z`;
  const credential = `${input.account.clientEmail}/${dateStamp}/auto/storage/goog4_request`;
  const params = new Map<string, string>([
    ["X-Goog-Algorithm", "GOOG4-RSA-SHA256"],
    ["X-Goog-Credential", credential],
    ["X-Goog-Date", timestamp],
    ["X-Goog-Expires", String(expires)],
    ["X-Goog-SignedHeaders", "host"],
  ]);
  const canonicalQuery = [...params.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([name, value]) => `${rfc3986(name)}=${rfc3986(value)}`)
    .join("&");
  const resourcePath = `/${input.bucket}/${input.objectName
    .split("/")
    .map((segment) => rfc3986(segment))
    .join("/")}`;
  const canonicalRequest = [
    "GET",
    resourcePath,
    canonicalQuery,
    "host:storage.googleapis.com",
    "",
    "host",
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const hashedRequest = await sha256Hex(canonicalRequest);
  const stringToSign = [
    "GOOG4-RSA-SHA256",
    timestamp,
    `${dateStamp}/auto/storage/goog4_request`,
    hashedRequest,
  ].join("\n");
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    input.key,
    new TextEncoder().encode(stringToSign),
  );
  const hex = bufferToHex(signature);
  return `https://storage.googleapis.com${resourcePath}?${canonicalQuery}&X-Goog-Signature=${hex}`;
}

async function signJwt(
  account: GcsServiceAccount,
  now: () => number,
  key: () => Promise<CryptoKey>,
): Promise<string> {
  const issuedAt = Math.floor(now() / 1000);
  const header = base64UrlJson({
    alg: "RS256",
    typ: "JWT",
    ...(account.privateKeyId === undefined ? {} : { kid: account.privateKeyId }),
  });
  const claims = base64UrlJson({
    iss: account.clientEmail,
    scope: STORAGE_SCOPE,
    aud: account.tokenUri,
    iat: issuedAt,
    exp: issuedAt + 3600,
  });
  const unsigned = `${header}.${claims}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    await key(),
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64Url(new Uint8Array(signature))}`;
}

async function importPkcs8(pem: string): Promise<CryptoKey> {
  const der = pemToArrayBuffer(pem);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const normalized = pem.replaceAll("\\n", "\n");
  const body = normalized
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bufferToHex(digest);
}

function bufferToHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64UrlJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function rfc3986(value: string): string {
  return encodeURIComponent(value).replaceAll(/[!'()*]/g, (char) => {
    return `%${char.charCodeAt(0).toString(16).toUpperCase()}`;
  });
}

function yyyymmdd(date: Date): string {
  return `${String(date.getUTCFullYear())}${pad2(date.getUTCMonth() + 1)}${pad2(date.getUTCDate())}`;
}

function hhmmss(date: Date): string {
  return `${pad2(date.getUTCHours())}${pad2(date.getUTCMinutes())}${pad2(date.getUTCSeconds())}`;
}

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
