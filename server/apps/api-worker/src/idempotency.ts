import { problemResponse } from "./http";

export type IdempotencyRecord = {
  fingerprint: string;
  status: number;
  headers: Array<[string, string]>;
  body: string;
};

export type IdempotencyStore = {
  get(key: string): Promise<IdempotencyRecord | undefined>;
  set(key: string, record: IdempotencyRecord): Promise<void>;
};

const KEY_MIN = 16;
const KEY_MAX = 128;

export function createMemoryIdempotencyStore(): IdempotencyStore {
  const records = new Map<string, IdempotencyRecord>();
  return {
    get: (key) => Promise.resolve(records.get(key)),
    set: (key, record) => {
      records.set(key, record);
      return Promise.resolve();
    },
  };
}

export async function withIdempotency(
  store: IdempotencyStore,
  request: Request,
  next: () => Promise<Response>,
  requestId: string,
): Promise<Response> {
  const key = request.headers.get("Idempotency-Key")?.trim() ?? "";
  if (key.length < KEY_MIN || key.length > KEY_MAX) {
    return problemResponse({
      status: 400,
      code: "invalid_idempotency_key",
      title: "Bad request",
      detail: "Idempotency-Key must be between 16 and 128 characters.",
      traceId: requestId,
    });
  }

  const fingerprint = await fingerprintRequest(request);
  const existing = await store.get(key);
  if (existing !== undefined) {
    if (existing.fingerprint !== fingerprint) {
      return problemResponse({
        status: 409,
        code: "idempotency_key_conflict",
        title: "Conflict",
        detail: "Idempotency-Key was reused with a different request.",
        traceId: requestId,
      });
    }
    return new Response(existing.body, {
      status: existing.status,
      headers: existing.headers,
    });
  }

  const response = await next();
  const body = await response.clone().text();
  await store.set(key, {
    fingerprint,
    status: response.status,
    headers: [...response.headers.entries()],
    body,
  });
  return response;
}

async function fingerprintRequest(request: Request): Promise<string> {
  const body = await request.clone().text();
  const canonical = `${request.method.toUpperCase()}:${new URL(request.url).pathname}:${body}`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}
