import type { IdentitySettings, IdentityStore } from "./identity";
import { restRows, type RestClient } from "./rest";

export const SYNC_ENTITY_TYPES = [
  "settings",
  "book",
  "chapter",
  "progress",
  "vocabulary",
  "lexeme_state",
  "review_event",
  "transcript",
  "asset",
  "transcript_overlay",
  "assistant_result",
  "chat_message",
  "study_activity",
] as const;

export type SyncEntityType = (typeof SYNC_ENTITY_TYPES)[number];

export type SyncMutation = {
  mutationId: string;
  entityType: SyncEntityType;
  entityId: string;
  operation: "upsert" | "delete" | "append";
  baseRevision: number;
  occurredAt: string;
  payload: Record<string, unknown>;
};

export type SyncMutationProblem = {
  title: string;
  detail: string;
};

export type SyncMutationResult = {
  mutationId: string;
  status: "applied" | "duplicate" | "conflict" | "rejected";
  entityRevision: number | null;
  problem: SyncMutationProblem | null;
};

export type SyncChange = {
  sequence: number;
  entityType: string;
  entityId: string;
  operation: "upsert" | "delete" | "append";
  revision: number;
  changedAt: string;
  payload: Record<string, unknown>;
};

export type SyncPushInput = {
  userId: string;
  deviceId: string;
  batchId: string;
  mutations: readonly SyncMutation[];
};

export type SyncPushResult = {
  batchId: string;
  results: SyncMutationResult[];
  cursor: string;
};

export type SyncPullInput = {
  userId: string;
  cursor: string;
  limit: number;
};

export type SyncPullResult = {
  changes: SyncChange[];
  cursor: string;
  hasMore: boolean;
};

export type SyncBootstrapEntity = SyncChange & { payloadHash: string };

export type SyncBootstrapInput = {
  userId: string;
  cursor: string | null;
  offset: number;
  limit: number;
};

export type SyncBootstrapResult = {
  entities: SyncBootstrapEntity[];
  cursor: string;
  nextOffset: number;
  hasMore: boolean;
};

export type SyncStore = {
  push(input: SyncPushInput): Promise<SyncPushResult>;
  bootstrap(input: SyncBootstrapInput): Promise<SyncBootstrapResult>;
  pull(input: SyncPullInput): Promise<SyncPullResult>;
  latestCursor(userId: string): Promise<string>;
};

const ENTITY_TYPE_SET = new Set<string>(SYNC_ENTITY_TYPES);

export function isSyncEntityType(value: string): value is SyncEntityType {
  return ENTITY_TYPE_SET.has(value);
}

export function createMemorySyncStore(options: { identity?: IdentityStore } = {}): SyncStore {
  const identity = options.identity;
  const changes = new Map<string, SyncChange[]>();
  const seenResults = new Map<string, SyncMutationResult>();
  const revisions = new Map<string, number>();

  function userChanges(userId: string): SyncChange[] {
    const existing = changes.get(userId);
    if (existing !== undefined) {
      return existing;
    }
    const created: SyncChange[] = [];
    changes.set(userId, created);
    return created;
  }

  function mutationKey(userId: string, mutationId: string): string {
    return `${userId}:${mutationId}`;
  }

  function entityKey(userId: string, entityType: string, entityId: string): string {
    return `${userId}:${entityType}:${entityId}`;
  }

  return {
    async push(input) {
      const log = userChanges(input.userId);
      const results: SyncMutationResult[] = [];
      for (const mutation of input.mutations) {
        const key = mutationKey(input.userId, mutation.mutationId);
        const replayed = seenResults.get(key);
        if (replayed !== undefined) {
          results.push({
            mutationId: mutation.mutationId,
            status: "duplicate",
            entityRevision: replayed.entityRevision,
            problem: null,
          });
          continue;
        }
        const result = await applyMutation({
          mutation,
          currentRevision:
            revisions.get(entityKey(input.userId, mutation.entityType, mutation.entityId)) ?? 0,
          userId: input.userId,
          ...(identity === undefined ? {} : { identity }),
        });
        if (result.status === "applied") {
          const revision = result.entityRevision ?? 1;
          revisions.set(entityKey(input.userId, mutation.entityType, mutation.entityId), revision);
          log.push({
            sequence: log.length + 1,
            entityType: mutation.entityType,
            entityId: mutation.entityId,
            operation: mutation.operation,
            revision,
            changedAt: mutation.occurredAt,
            payload: mutation.payload,
          });
        }
        seenResults.set(mutationKey(input.userId, mutation.mutationId), result);
        results.push(result);
      }
      return {
        batchId: input.batchId,
        results,
        cursor: String(log.length),
      };
    },

    pull(input) {
      const log = userChanges(input.userId);
      const after = parseCursor(input.cursor);
      const sliced = log.filter((change) => change.sequence > after).slice(0, input.limit);
      const last = sliced.at(-1)?.sequence ?? after;
      return Promise.resolve({
        changes: sliced.map((change) => ({ ...change, payload: { ...change.payload } })),
        cursor: String(last),
        hasMore: log.some((change) => change.sequence > last),
      });
    },

    async bootstrap(input) {
      const log = userChanges(input.userId);
      const snapshotCursor = input.cursor === null ? log.length : parseCursor(input.cursor);
      const latest = new Map<string, SyncChange>();
      for (const change of log) {
        if (change.sequence > snapshotCursor) continue;
        latest.set(`${change.entityType}|${change.entityId}`, change);
      }
      const ordered = [...latest.values()].sort(
        (left, right) =>
          left.entityType.localeCompare(right.entityType) ||
          left.entityId.localeCompare(right.entityId),
      );
      const page = ordered.slice(input.offset, input.offset + input.limit);
      const entities = await Promise.all(
        page.map(async (change) => ({
          ...change,
          payload: { ...change.payload },
          payloadHash: await hashSyncPayload(change.payload),
        })),
      );
      const nextOffset = input.offset + entities.length;
      return {
        entities,
        cursor: String(snapshotCursor),
        nextOffset,
        hasMore: nextOffset < ordered.length,
      };
    },

    latestCursor(userId) {
      const log = userChanges(userId);
      return Promise.resolve(String(log.length));
    },
  };
}

export function createSupabaseSyncStore(rest: RestClient, namespace: "v1" | "v2" = "v1"): SyncStore {
  const pushRpc = namespace === "v2" ? "/rpc/push_sync_v2_batch" : "/rpc/push_sync_batch";
  const pullRpc = namespace === "v2" ? "/rpc/pull_sync_v2_page" : "/rpc/pull_sync_page";
  const bootstrapRpc = namespace === "v2" ? "/rpc/bootstrap_sync_v2_page" : "/rpc/bootstrap_sync_page";
  const changesTable = namespace === "v2" ? "/sync_v2_changes" : "/sync_changes";
  const batchesTable = namespace === "v2" ? "/sync_v2_batches" : "/sync_batches";
  return {
    async push(input) {
      const response = await rest.request({
        method: "POST",
        path: pushRpc,
        body: {
          p_user_id: input.userId,
          p_device_id: input.deviceId,
          p_batch_id: input.batchId,
          p_mutations: input.mutations,
        },
      });
      const pushed = syncPushResultFromRpc(response.body, input);
      if (response.status < 200 || response.status >= 300 || pushed === undefined) {
        throw new Error("sync batch write failed");
      }
      const timestamp = new Date().toISOString();
      const [batchAttribution, deviceTouch] = await Promise.all([
        rest.request({
          method: "PATCH",
          path: batchesTable,
          query: {
            user_id: `eq.${input.userId}`,
            batch_id: `eq.${input.batchId}`,
          },
          body: { device_id: input.deviceId },
        }),
        rest.request({
          method: "PATCH",
          path: "/devices",
          query: { user_id: `eq.${input.userId}`, id: `eq.${input.deviceId}` },
          body: { last_sync_at: timestamp, last_seen_at: timestamp, updated_at: timestamp },
        }),
      ]);
      if (batchAttribution.status >= 400 || deviceTouch.status >= 400) {
        console.warn(
          JSON.stringify({
            level: "warn",
            message: "sync_device_attribution_failed",
            component: "database",
            batchStatus: batchAttribution.status,
            deviceStatus: deviceTouch.status,
          }),
        );
      }
      return pushed;
    },

    async pull(input) {
      const pageLimit = Math.min(500, Math.max(1, Math.floor(input.limit)));
      const response = await rest.request({
        method: "POST",
        path: pullRpc,
        body: {
          p_user_id: input.userId,
          p_cursor: parseCursor(input.cursor),
          p_limit: pageLimit,
          p_max_payload_bytes: 1_048_576,
        },
      });
      const pulled = syncPullResultFromRpc(response.body, input, pageLimit);
      if (response.status < 200 || response.status >= 300 || pulled === undefined) {
        throw new Error("sync pull failed");
      }
      return pulled;
    },

    async bootstrap(input) {
      const pageLimit = Math.min(500, Math.max(1, Math.floor(input.limit)));
      const response = await rest.request({
        method: "POST",
        path: bootstrapRpc,
        body: {
          p_user_id: input.userId,
          p_cursor: input.cursor === null ? null : parseCursor(input.cursor),
          p_offset: Math.max(0, Math.floor(input.offset)),
          p_limit: pageLimit,
          p_max_payload_bytes: 1_048_576,
        },
      });
      const parsed = bootstrapResultFromRpc(response.body, input, pageLimit);
      if (response.status < 200 || response.status >= 300 || parsed === undefined) {
        throw new Error("sync bootstrap failed");
      }
      const entities = await Promise.all(
        parsed.entities.map(async (change) => ({
          ...change,
          payloadHash: await hashSyncPayload(change.payload),
        })),
      );
      return { ...parsed, entities };
    },

    async latestCursor(userId) {
      const response = await rest.request({
        method: "GET",
        path: changesTable,
        query: {
          user_id: `eq.${userId}`,
          select: "sequence",
          order: "sequence.desc",
          limit: "1",
        },
      });
      if (response.status >= 400 || response.status === 0) {
        throw new Error("sync cursor lookup failed");
      }
      const row = restRows(response.body)[0];
      if (row === undefined) {
        return "0";
      }
      return String(numericValue(row.sequence, 0));
    },
  };
}

function syncPullResultFromRpc(
  value: unknown,
  input: SyncPullInput,
  pageLimit: number,
): SyncPullResult | undefined {
  if (!isRecord(value) || !Array.isArray(value.changes) || typeof value.hasMore !== "boolean") {
    return undefined;
  }
  const cursorNumber = numericValue(value.cursor, -1);
  const inputCursor = parseCursor(input.cursor);
  if (
    !Number.isSafeInteger(cursorNumber) ||
    cursorNumber < inputCursor ||
    value.changes.length > pageLimit ||
    !value.changes.every(isRecord)
  ) {
    return undefined;
  }
  const changes = value.changes.map(changeFromRow);
  if (changes.some((change) => change.sequence <= inputCursor || change.sequence > cursorNumber)) {
    return undefined;
  }
  return { changes, cursor: String(cursorNumber), hasMore: value.hasMore };
}

function syncPushResultFromRpc(value: unknown, input: SyncPushInput): SyncPushResult | undefined {
  if (!isRecord(value) || value.batchId !== input.batchId) {
    return undefined;
  }
  const cursor = value.cursor;
  if ((typeof cursor !== "string" && typeof cursor !== "number") || !Array.isArray(value.results)) {
    return undefined;
  }
  const cursorNumber = Number(cursor);
  if (
    !Number.isSafeInteger(cursorNumber) ||
    cursorNumber < 0 ||
    value.results.length !== input.mutations.length
  ) {
    return undefined;
  }
  const expectedMutationIDs = new Set(input.mutations.map((mutation) => mutation.mutationId));
  const returnedMutationIDs = new Set<string>();
  const results: SyncMutationResult[] = [];
  for (const item of value.results) {
    if (
      !isRecord(item) ||
      typeof item.mutationId !== "string" ||
      !expectedMutationIDs.has(item.mutationId) ||
      returnedMutationIDs.has(item.mutationId)
    ) {
      return undefined;
    }
    returnedMutationIDs.add(item.mutationId);
    const status = item.status;
    if (
      status !== "applied" &&
      status !== "duplicate" &&
      status !== "conflict" &&
      status !== "rejected"
    ) {
      return undefined;
    }
    const entityRevision = typeof item.entityRevision === "number" ? item.entityRevision : null;
    if (entityRevision !== null && (!Number.isSafeInteger(entityRevision) || entityRevision < 0)) {
      return undefined;
    }
    const problem = isRecord(item.problem)
      ? {
          title:
            typeof item.problem.title === "string" ? item.problem.title : "Sync mutation failed",
          detail:
            typeof item.problem.detail === "string"
              ? item.problem.detail
              : "The change was not applied.",
        }
      : null;
    results.push({ mutationId: item.mutationId, status, entityRevision, problem });
  }
  return { batchId: input.batchId, cursor: String(cursorNumber), results };
}

export function createUnavailableSyncStore(): SyncStore {
  return {
    push() {
      return Promise.reject(new Error("database unavailable"));
    },
    pull() {
      return Promise.reject(new Error("database unavailable"));
    },
    bootstrap() {
      return Promise.reject(new Error("database unavailable"));
    },
    latestCursor() {
      return Promise.resolve("0");
    },
  };
}

function bootstrapResultFromRpc(
  value: unknown,
  input: SyncBootstrapInput,
  pageLimit: number,
): (Omit<SyncBootstrapResult, "entities"> & { entities: SyncChange[] }) | undefined {
  if (!isRecord(value) || !Array.isArray(value.entities) || typeof value.hasMore !== "boolean") {
    return undefined;
  }
  const cursor = numericValue(value.cursor, -1);
  const nextOffset = numericValue(value.nextOffset, -1);
  if (
    !Number.isSafeInteger(cursor) ||
    cursor < 0 ||
    !Number.isSafeInteger(nextOffset) ||
    nextOffset !== input.offset + value.entities.length ||
    value.entities.length > pageLimit ||
    !value.entities.every(isRecord)
  ) {
    return undefined;
  }
  if (input.cursor !== null && cursor !== parseCursor(input.cursor)) return undefined;
  return {
    entities: value.entities.map(changeFromRow),
    cursor: String(cursor),
    nextOffset,
    hasMore: value.hasMore,
  };
}

async function hashSyncPayload(payload: Record<string, unknown>): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalJSON(payload));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (isRecord(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`)
      .join(",")}}`;
  }
  if (value === undefined) return "null";
  return JSON.stringify(value);
}

async function applyMutation(input: {
  mutation: SyncMutation;
  currentRevision: number;
  identity?: IdentityStore;
  userId: string;
}): Promise<SyncMutationResult> {
  const mutation = input.mutation;
  if (!isSyncEntityType(mutation.entityType)) {
    return rejected(mutation.mutationId, "Unknown entity type.");
  }
  if (mutation.baseRevision < 0 || mutation.baseRevision > input.currentRevision) {
    return rejected(mutation.mutationId, "baseRevision is invalid.");
  }
  if (input.currentRevision > 0 && mutation.baseRevision < input.currentRevision) {
    return {
      mutationId: mutation.mutationId,
      status: "conflict",
      entityRevision: input.currentRevision,
      problem: {
        title: "Conflict",
        detail: "The entity was updated on another device.",
      },
    };
  }
  if (
    mutation.entityType === "settings" &&
    input.identity !== undefined &&
    mutation.operation === "upsert"
  ) {
    const current = await input.identity.getSettings(input.userId);
    const incoming = settingsFromPayload(mutation.payload, mutation.baseRevision, current);
    const put = await input.identity.putSettings(input.userId, incoming);
    if (!put.ok) {
      return {
        mutationId: mutation.mutationId,
        status: "conflict",
        entityRevision: put.current.revision,
        problem: {
          title: "Conflict",
          detail: "Settings were updated on another device.",
        },
      };
    }
    return {
      mutationId: mutation.mutationId,
      status: "applied",
      entityRevision: put.value.revision,
      problem: null,
    };
  }
  return {
    mutationId: mutation.mutationId,
    status: "applied",
    entityRevision: input.currentRevision + 1,
    problem: null,
  };
}

function settingsFromPayload(
  payload: Record<string, unknown>,
  revision: number,
  fallback: IdentitySettings,
): IdentitySettings {
  const level = payload.readerLevel;
  const appearance = payload.appearance;
  return {
    revision,
    sourceLanguage:
      typeof payload.sourceLanguage === "string" ? payload.sourceLanguage : fallback.sourceLanguage,
    targetLanguage:
      typeof payload.targetLanguage === "string" ? payload.targetLanguage : fallback.targetLanguage,
    readerLevel:
      level === "beginner" ||
      level === "elementary" ||
      level === "intermediate" ||
      level === "upper_intermediate" ||
      level === "advanced"
        ? level
        : fallback.readerLevel,
    playbackRate:
      typeof payload.playbackRate === "number" ? payload.playbackRate : fallback.playbackRate,
    skipSeconds:
      typeof payload.skipSeconds === "number" ? payload.skipSeconds : fallback.skipSeconds,
    appearance:
      appearance === "system" || appearance === "light" || appearance === "dark"
        ? appearance
        : fallback.appearance,
    updatedAt: fallback.updatedAt,
  };
}

function changeFromRow(row: Record<string, unknown>): SyncChange {
  const operation = row.operation;
  return {
    sequence: numericValue(row.sequence, 0),
    entityType: typeof row.entity_type === "string" ? row.entity_type : "",
    entityId: typeof row.entity_id === "string" ? row.entity_id : "",
    operation: operation === "delete" || operation === "append" ? operation : "upsert",
    revision: numericValue(row.revision, 0),
    changedAt: typeof row.changed_at === "string" ? row.changed_at : new Date().toISOString(),
    payload: isRecord(row.payload) ? row.payload : {},
  };
}

function parseCursor(cursor: string): number {
  const trimmed = cursor.trim();
  if (trimmed === "" || trimmed === "0") {
    return 0;
  }
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return 0;
  }
  return Math.floor(parsed);
}

function rejected(mutationId: string, detail: string): SyncMutationResult {
  return {
    mutationId,
    status: "rejected",
    entityRevision: null,
    problem: { title: "Rejected", detail },
  };
}

function numericValue(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallback;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
