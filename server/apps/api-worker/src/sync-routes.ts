import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import {
  isSyncEntityType,
  type IdentityStore,
  type SyncMutation,
  type SyncStore,
} from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import { requireBoundDevice } from "./route-helpers";

type SyncPushResponse = components["schemas"]["SyncPushResponse"];
type SyncPullResponse = components["schemas"]["SyncPullResponse"];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const SYNC_METHODS: Record<string, readonly string[]> = {
  "/v1/sync/push": ["POST"],
  "/v1/sync/pull": ["GET", "HEAD"],
};

export type SyncRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  sync?: SyncStore;
  identity?: IdentityStore;
};

export function isSyncPath(path: string): boolean {
  return path in SYNC_METHODS;
}

export function syncMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const allowed = SYNC_METHODS[path];
  if (allowed === undefined || allowed.includes(method.toUpperCase())) {
    return undefined;
  }
  return problemResponse({
    status: 405,
    code: "method_not_allowed",
    title: "Method not allowed",
    detail: `This endpoint accepts ${allowed.join(", ")}.`,
    traceId: requestId,
    headers: { Allow: allowed.join(", ") },
  });
}

export async function handleSyncRoute(context: SyncRouteContext): Promise<Response | undefined> {
  const url = new URL(context.request.url);
  const path = url.pathname;
  const allowed = SYNC_METHODS[path];
  if (allowed === undefined) {
    return undefined;
  }
  const method = context.request.method.toUpperCase();
  if (!allowed.includes(method)) {
    return syncMethodError(path, method, context.requestId);
  }
  if (path === "/v1/sync/push") {
    return pushSync(context);
  }
  return pullSync(context, url);
}

async function pushSync(context: SyncRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const sync = requireSync(context);
  if (sync instanceof Response) {
    return sync;
  }
  const deviceId = await requireBoundSyncDevice(context, principal);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  const contentDigest = optionalContentDigest(context.request, context.requestId);
  if (contentDigest instanceof Response) {
    return contentDigest;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const batchId = requiredUuid(body.value.batchId, "batchId", context.requestId);
      if (batchId instanceof Response) {
        return batchId;
      }
      const bodyDeviceId = requiredUuid(body.value.deviceId, "deviceId", context.requestId);
      if (bodyDeviceId instanceof Response) {
        return bodyDeviceId;
      }
      if (bodyDeviceId !== deviceId) {
        return fieldError(context.requestId, "deviceId", "deviceId must match X-Device-Id.");
      }
      const mutations = parseMutations(body.value.mutations, context.requestId);
      if (mutations instanceof Response) {
        return mutations;
      }
      logSync("sync_push_start", context.requestId, {
        mutations: mutations.length,
        contentLength: context.request.headers.get("content-length") ?? "unknown",
      });
      const pushed = await sync.push({
        userId: principal.accountId,
        deviceId,
        batchId,
        mutations,
      });
      logSync("sync_push_finish", context.requestId, {
        mutations: mutations.length,
        cursor: pushed.cursor,
      });
      const payload: SyncPushResponse = {
        batchId: pushed.batchId,
        cursor: pushed.cursor,
        results: pushed.results.map((result) => ({
          mutationId: result.mutationId,
          status: result.status,
          entityRevision: result.entityRevision,
          problem:
            result.problem === null
              ? null
              : {
                  type: "https://api.example.com/problems/sync_mutation",
                  title: result.problem.title,
                  status: result.status === "conflict" ? 409 : 422,
                  detail: result.problem.detail,
                  code: result.status,
                  traceId: context.requestId,
                  retryAfterSeconds: null,
                  fieldErrors: [],
                },
        })),
      };
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
    contentDigest,
  );
}

function optionalContentDigest(request: Request, requestId: string): string | undefined | Response {
  const digest = request.headers.get("X-Content-SHA256")?.trim();
  if (digest === undefined || digest === "") {
    return undefined;
  }
  if (!SHA256_PATTERN.test(digest)) {
    return fieldError(
      requestId,
      "X-Content-SHA256",
      "X-Content-SHA256 must be a SHA-256 hex digest.",
    );
  }
  return digest.toLowerCase();
}

async function pullSync(context: SyncRouteContext, url: URL): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const sync = requireSync(context);
  if (sync instanceof Response) {
    return sync;
  }
  const deviceId = await requireBoundSyncDevice(context, principal);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  void deviceId;
  const cursor = url.searchParams.get("cursor") ?? "0";
  const limitRaw = url.searchParams.get("limit");
  const limit = limitRaw === null || limitRaw.trim() === "" ? 100 : Number(limitRaw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
    return fieldError(context.requestId, "limit", "limit must be an integer between 1 and 500.");
  }
  logSync("sync_pull_start", context.requestId, { cursor, limit });
  const pulled = await sync.pull({
    userId: principal.accountId,
    cursor,
    limit,
  });
  logSync("sync_pull_finish", context.requestId, {
    cursor: pulled.cursor,
    changes: pulled.changes.length,
    hasMore: pulled.hasMore,
  });
  const payload: SyncPullResponse = {
    changes: pulled.changes,
    cursor: pulled.cursor,
    hasMore: pulled.hasMore,
  };
  return asHead(context.request, jsonResponse(payload));
}

/** Logs sync boundaries and counts without exposing learning payloads. */
function logSync(
  message: string,
  requestId: string,
  details: Record<string, string | number | boolean>,
): void {
  console.warn(
    JSON.stringify({ level: "warn", message, component: "sync", requestId, ...details }),
  );
}

async function requirePrincipal(context: SyncRouteContext): Promise<Principal | Response> {
  const principal = await context.authenticate(context.request);
  if (principal === null) {
    return problemResponse({
      status: 401,
      code: "unauthorized",
      title: "Unauthorized",
      detail: "Authentication required.",
      traceId: context.requestId,
    });
  }
  return principal;
}

function requireSync(context: SyncRouteContext): SyncStore | Response {
  if (context.sync === undefined) {
    return problemResponse({
      status: 503,
      code: "not_ready",
      title: "Service unavailable",
      detail: "Sync is not configured.",
      traceId: context.requestId,
    });
  }
  return context.sync;
}

async function requireBoundSyncDevice(
  context: SyncRouteContext,
  principal: Principal,
): Promise<string | Response> {
  return requireBoundDevice({
    request: context.request,
    requestId: context.requestId,
    accountId: principal.accountId,
    hasActiveDevice: (accountId, deviceId) =>
      context.identity === undefined
        ? Promise.resolve(false)
        : context.identity.hasActiveDevice(accountId, deviceId),
  });
}

function parseMutations(value: unknown, requestId: string): SyncMutation[] | Response {
  if (!Array.isArray(value)) {
    return fieldError(requestId, "mutations", "mutations must be an array.");
  }
  if (value.length > 500) {
    return fieldError(requestId, "mutations", "mutations cannot exceed 500 items.");
  }
  const mutations: SyncMutation[] = [];
  const mutationIds = new Set<string>();
  for (const [index, item] of value.entries()) {
    if (!isRecord(item)) {
      return fieldError(requestId, `mutations.${String(index)}`, "mutation must be an object.");
    }
    const mutationId = requiredUuid(
      item.mutationId,
      `mutations.${String(index)}.mutationId`,
      requestId,
    );
    if (mutationId instanceof Response) {
      return mutationId;
    }
    if (mutationIds.has(mutationId)) {
      return fieldError(
        requestId,
        `mutations.${String(index)}.mutationId`,
        "mutationId must be unique within the batch.",
      );
    }
    mutationIds.add(mutationId);
    const entityId = requiredUuid(item.entityId, `mutations.${String(index)}.entityId`, requestId);
    if (entityId instanceof Response) {
      return entityId;
    }
    if (typeof item.entityType !== "string" || !isSyncEntityType(item.entityType)) {
      return fieldError(
        requestId,
        `mutations.${String(index)}.entityType`,
        "entityType is not a supported sync entity.",
      );
    }
    const operation = item.operation;
    if (operation !== "upsert" && operation !== "delete" && operation !== "append") {
      return fieldError(
        requestId,
        `mutations.${String(index)}.operation`,
        "operation must be upsert, delete, or append.",
      );
    }
    if (
      typeof item.baseRevision !== "number" ||
      !Number.isInteger(item.baseRevision) ||
      item.baseRevision < 0
    ) {
      return fieldError(
        requestId,
        `mutations.${String(index)}.baseRevision`,
        "baseRevision must be a non-negative integer.",
      );
    }
    if (typeof item.occurredAt !== "string" || Number.isNaN(Date.parse(item.occurredAt))) {
      return fieldError(
        requestId,
        `mutations.${String(index)}.occurredAt`,
        "occurredAt must be an ISO-8601 timestamp.",
      );
    }
    if (!isRecord(item.payload)) {
      return fieldError(
        requestId,
        `mutations.${String(index)}.payload`,
        "payload must be an object.",
      );
    }
    mutations.push({
      mutationId,
      entityType: item.entityType,
      entityId,
      operation,
      baseRevision: item.baseRevision,
      occurredAt: item.occurredAt,
      payload: item.payload,
    });
  }
  return mutations;
}

function requiredUuid(value: unknown, field: string, requestId: string): string | Response {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    return fieldError(requestId, field, `${field} must be a UUID.`);
  }
  return value;
}

function fieldError(requestId: string, field: string, message: string): Response {
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: message,
    traceId: requestId,
    fieldErrors: [{ field, message }],
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
