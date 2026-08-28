import type { Principal } from "@audio-reader/auth";
import type { RestClient } from "@audio-reader/database";
import { problemResponse } from "./http";

const ANONYMOUS_IDEMPOTENCY_USER = "00000000-0000-4000-8000-0000000000a0";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type IdempotencyRecord = {
  fingerprint: string;
  status: number;
  headers: Array<[string, string]>;
  body: string;
};

export type IdempotencyClaim =
  | { status: "claimed" }
  | { status: "replay"; record: IdempotencyRecord }
  | { status: "conflict" }
  | { status: "unavailable" }
  | { status: "in_progress"; wait: () => Promise<IdempotencyRecord | undefined> };

export type IdempotencyStore = {
  claim(storageKey: string, fingerprint: string): Promise<IdempotencyClaim>;
  complete(storageKey: string, record: IdempotencyRecord): Promise<void>;
  abort(storageKey: string): Promise<void>;
};

const KEY_MIN = 16;
const KEY_MAX = 128;

type InProgressSlot = {
  state: "in_progress";
  fingerprint: string;
  waiters: Array<(record: IdempotencyRecord | undefined) => void>;
};

type CompletedSlot = {
  state: "completed";
  record: IdempotencyRecord;
};

type Slot = InProgressSlot | CompletedSlot;

function slotFingerprint(slot: Slot): string {
  return slot.state === "completed" ? slot.record.fingerprint : slot.fingerprint;
}

export function idempotencyStorageKey(parts: {
  principalId: string;
  method: string;
  pathname: string;
  key: string;
}): string {
  return `${parts.principalId}:${parts.method}:${parts.pathname}:${parts.key}`;
}

/** Postgres RPCs so every Worker isolate shares claims. Memory is local/test only. */
export function createPostgresIdempotencyStore(rest: RestClient): IdempotencyStore {
  const fingerprints = new Map<string, string>();
  return {
    async claim(storageKey, fingerprint) {
      const parts = parseIdempotencyStorageKey(storageKey);
      if (parts === undefined) {
        return { status: "unavailable" };
      }
      fingerprints.set(storageKey, fingerprint);
      const body = await rpc(rest, "claim_idempotency_record", {
        p_user_id: parts.userId,
        p_key: parts.key,
        p_method: parts.method,
        p_pathname: parts.pathname,
        p_fingerprint: fingerprint,
      });
      if (body === undefined) {
        return { status: "unavailable" };
      }
      const status = typeof body.status === "string" ? body.status : "";
      if (status === "claimed") {
        return { status: "claimed" };
      }
      if (status === "conflict") {
        return { status: "conflict" };
      }
      if (status === "replay") {
        const record = recordFromRpc(body, fingerprint);
        return record === undefined ? { status: "unavailable" } : { status: "replay", record };
      }
      if (status === "in_progress") {
        return {
          status: "in_progress",
          wait: () => waitForReplay(rest, parts, fingerprint),
        };
      }
      return { status: "unavailable" };
    },
    async complete(storageKey, record) {
      const parts = parseIdempotencyStorageKey(storageKey);
      fingerprints.delete(storageKey);
      if (parts === undefined) {
        return;
      }
      await rpc(rest, "record_idempotency_response", {
        p_user_id: parts.userId,
        p_key: parts.key,
        p_method: parts.method,
        p_pathname: parts.pathname,
        p_fingerprint: record.fingerprint,
        p_response_status: record.status,
        p_response_headers: Object.fromEntries(record.headers),
        p_response_body: record.body,
      });
    },
    async abort(storageKey) {
      const parts = parseIdempotencyStorageKey(storageKey);
      const fingerprint = fingerprints.get(storageKey);
      fingerprints.delete(storageKey);
      if (parts === undefined || fingerprint === undefined) {
        return;
      }
      await rpc(rest, "abort_idempotency_record", {
        p_user_id: parts.userId,
        p_key: parts.key,
        p_method: parts.method,
        p_pathname: parts.pathname,
        p_fingerprint: fingerprint,
      });
    },
  };
}

function parseIdempotencyStorageKey(
  storageKey: string,
): { userId: string; method: string; pathname: string; key: string } | undefined {
  const first = storageKey.indexOf(":");
  const second = storageKey.indexOf(":", first + 1);
  const last = storageKey.lastIndexOf(":");
  if (first <= 0 || second <= first || last <= second) {
    return undefined;
  }
  const principalId = storageKey.slice(0, first);
  const method = storageKey.slice(first + 1, second);
  const pathname = storageKey.slice(second + 1, last);
  const key = storageKey.slice(last + 1);
  if (method === "" || pathname === "" || key.length < 16) {
    return undefined;
  }
  return {
    userId: UUID_PATTERN.test(principalId) ? principalId : ANONYMOUS_IDEMPOTENCY_USER,
    method,
    pathname,
    key,
  };
}

async function waitForReplay(
  rest: RestClient,
  parts: { userId: string; method: string; pathname: string; key: string },
  fingerprint: string,
): Promise<IdempotencyRecord | undefined> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await new Promise((resolve) => {
      setTimeout(resolve, 50);
    });
    const body = await rpc(rest, "claim_idempotency_record", {
      p_user_id: parts.userId,
      p_key: parts.key,
      p_method: parts.method,
      p_pathname: parts.pathname,
      p_fingerprint: fingerprint,
    });
    if (body === undefined) {
      return undefined;
    }
    if (body.status === "replay") {
      return recordFromRpc(body, fingerprint);
    }
    if (body.status !== "in_progress") {
      return undefined;
    }
  }
  return undefined;
}

async function rpc(
  rest: RestClient,
  name: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown> | undefined> {
  const response = await rest.request({
    method: "POST",
    path: `/rpc/${name}`,
    body,
  });
  if (response.status < 200 || response.status >= 300 || response.body === null) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "idempotency_rpc_failed",
        component: "idempotency",
        outcome: "unavailable",
        rpc: name,
        status: response.status,
      }),
    );
    return undefined;
  }
  if (
    typeof response.body === "object" &&
    response.body !== null &&
    !Array.isArray(response.body)
  ) {
    return response.body as Record<string, unknown>;
  }
  return undefined;
}

function recordFromRpc(
  body: Record<string, unknown>,
  fingerprint: string,
): IdempotencyRecord | undefined {
  if (typeof body.response_status !== "number" || typeof body.response_body !== "string") {
    return undefined;
  }
  const headers = headersFromRpc(body.response_headers);
  return {
    fingerprint: typeof body.fingerprint === "string" ? body.fingerprint : fingerprint,
    status: body.response_status,
    headers,
    body: body.response_body,
  };
}

function headersFromRpc(value: unknown): Array<[string, string]> {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return Object.entries(value).flatMap(([name, headerValue]) =>
      typeof headerValue === "string" ? [[name, headerValue] as [string, string]] : [],
    );
  }
  return [];
}

export function createMemoryIdempotencyStore(): IdempotencyStore {
  const slots = new Map<string, Slot>();
  return {
    claim(storageKey, fingerprint) {
      const existing = slots.get(storageKey);
      if (existing === undefined) {
        slots.set(storageKey, { state: "in_progress", fingerprint, waiters: [] });
        return Promise.resolve({ status: "claimed" as const });
      }
      if (slotFingerprint(existing) !== fingerprint) {
        return Promise.resolve({ status: "conflict" as const });
      }
      if (existing.state === "completed") {
        return Promise.resolve({ status: "replay" as const, record: existing.record });
      }
      return Promise.resolve({
        status: "in_progress" as const,
        wait: () =>
          new Promise<IdempotencyRecord | undefined>((resolve) => {
            existing.waiters.push(resolve);
          }),
      });
    },
    complete(storageKey, record) {
      const existing = slots.get(storageKey);
      slots.set(storageKey, { state: "completed", record });
      if (existing?.state === "in_progress") {
        for (const waiter of existing.waiters) {
          waiter(record);
        }
      }
      return Promise.resolve();
    },
    abort(storageKey) {
      const existing = slots.get(storageKey);
      slots.delete(storageKey);
      if (existing?.state === "in_progress") {
        for (const waiter of existing.waiters) {
          waiter(undefined);
        }
      }
      return Promise.resolve();
    },
  };
}

export async function withIdempotency(
  store: IdempotencyStore,
  request: Request,
  next: () => Promise<Response>,
  requestId: string,
  principal?: Principal | null,
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

  const principalId = principal?.subject ?? "anonymous";
  const url = new URL(request.url);
  const storageKey = idempotencyStorageKey({
    principalId,
    method: request.method.toUpperCase(),
    pathname: url.pathname,
    key,
  });
  const fingerprint = await fingerprintRequest(request, principalId);

  const claim = await settleClaim(store, storageKey, fingerprint);
  if (claim.status === "unavailable") {
    return problemResponse({
      status: 503,
      code: "not_ready",
      title: "Service unavailable",
      detail: "Idempotency store is unavailable.",
      traceId: requestId,
    });
  }
  if (claim.status === "conflict") {
    return problemResponse({
      status: 409,
      code: "idempotency_key_conflict",
      title: "Conflict",
      detail: "Idempotency-Key was reused with a different request.",
      traceId: requestId,
    });
  }
  if (claim.status === "replay") {
    return replay(claim.record);
  }

  try {
    const response = await next();
    if (response.status >= 500) {
      await store.abort(storageKey);
      return response;
    }
    const body = await response.clone().text();
    await store.complete(storageKey, {
      fingerprint,
      status: response.status,
      headers: [...response.headers.entries()],
      body,
    });
    return response;
  } catch (error: unknown) {
    await store.abort(storageKey);
    throw error;
  }
}

async function settleClaim(
  store: IdempotencyStore,
  storageKey: string,
  fingerprint: string,
): Promise<Exclude<IdempotencyClaim, { status: "in_progress" }>> {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const claim = await store.claim(storageKey, fingerprint);
    if (claim.status !== "in_progress") {
      return claim;
    }
    const waited = await claim.wait();
    if (waited !== undefined) {
      return { status: "replay", record: waited };
    }
  }
  return { status: "unavailable" };
}

function replay(record: IdempotencyRecord): Response {
  return new Response(record.body, {
    status: record.status,
    headers: record.headers,
  });
}

async function fingerprintRequest(request: Request, principalId: string): Promise<string> {
  const body = await request.clone().text();
  const url = new URL(request.url);
  const deviceId = request.headers.get("X-Device-Id")?.trim() ?? "";
  const canonical = [
    principalId,
    request.method.toUpperCase(),
    url.pathname,
    url.search,
    deviceId,
    body,
  ].join("\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical));
  const bytes = new Uint8Array(digest);
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}
