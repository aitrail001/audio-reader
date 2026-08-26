import type { Principal } from "@audio-reader/auth";
import { problemResponse } from "./http";

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
  for (;;) {
    const claim = await store.claim(storageKey, fingerprint);
    if (claim.status !== "in_progress") {
      return claim;
    }
    const waited = await claim.wait();
    if (waited !== undefined) {
      return { status: "replay", record: waited };
    }
  }
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
