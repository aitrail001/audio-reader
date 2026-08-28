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
  "transcript_overlay",
  "translation_decision",
  "summary_decision",
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

export type SyncStore = {
  push(input: SyncPushInput): Promise<SyncPushResult>;
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

    latestCursor(userId) {
      const log = userChanges(userId);
      return Promise.resolve(String(log.length));
    },
  };
}

export function createSupabaseSyncStore(
  rest: RestClient,
  options: { identity?: IdentityStore } = {},
): SyncStore {
  const identity = options.identity;

  async function loadChanges(userId: string): Promise<SyncChange[]> {
    const response = await rest.request({
      method: "GET",
      path: "/sync_changes",
      query: {
        user_id: `eq.${userId}`,
        select: "*",
        order: "sequence.asc",
      },
    });
    if (response.status >= 400 || response.status === 0) {
      return [];
    }
    return restRows(response.body).map(changeFromRow);
  }

  async function findMutation(userId: string, mutationId: string): Promise<SyncChange | undefined> {
    const response = await rest.request({
      method: "GET",
      path: "/sync_changes",
      query: {
        user_id: `eq.${userId}`,
        mutation_id: `eq.${mutationId}`,
        select: "*",
        limit: "1",
      },
    });
    const row = restRows(response.body)[0];
    return row === undefined ? undefined : changeFromRow(row);
  }

  async function currentRevision(
    userId: string,
    entityType: string,
    entityId: string,
  ): Promise<number> {
    const response = await rest.request({
      method: "GET",
      path: "/sync_changes",
      query: {
        user_id: `eq.${userId}`,
        entity_type: `eq.${entityType}`,
        entity_id: `eq.${entityId}`,
        select: "revision",
        order: "sequence.desc",
        limit: "1",
      },
    });
    const row = restRows(response.body)[0];
    if (row === undefined) {
      return 0;
    }
    return numericValue(row.revision, 0);
  }

  return {
    async push(input) {
      const results: SyncMutationResult[] = [];
      let cursor = await this.latestCursor(input.userId);
      for (const mutation of input.mutations) {
        const existing = await findMutation(input.userId, mutation.mutationId);
        if (existing !== undefined) {
          results.push({
            mutationId: mutation.mutationId,
            status: "duplicate",
            entityRevision: existing.revision,
            problem: null,
          });
          continue;
        }
        const result = await applyMutation({
          mutation,
          currentRevision: await currentRevision(
            input.userId,
            mutation.entityType,
            mutation.entityId,
          ),
          userId: input.userId,
          ...(identity === undefined ? {} : { identity }),
        });
        if (result.status === "applied") {
          const revision = result.entityRevision ?? 1;
          const nextSequence = Number(cursor) + 1;
          const insert = await rest.request({
            method: "POST",
            path: "/sync_changes",
            prefer: "return=representation",
            body: {
              user_id: input.userId,
              sequence: nextSequence,
              entity_type: mutation.entityType,
              entity_id: mutation.entityId,
              operation: mutation.operation,
              revision,
              mutation_id: mutation.mutationId,
              payload: mutation.payload,
              changed_at: mutation.occurredAt,
            },
          });
          if (insert.status >= 400 || insert.status === 0) {
            const rejected: SyncMutationResult = {
              mutationId: mutation.mutationId,
              status: "rejected",
              entityRevision: null,
              problem: {
                title: "Sync write failed",
                detail: "The change could not be recorded.",
              },
            };
            results.push(rejected);
            continue;
          }
          cursor = String(nextSequence);
        }
        results.push(result);
      }
      return { batchId: input.batchId, results, cursor };
    },

    async pull(input) {
      const log = await loadChanges(input.userId);
      const after = parseCursor(input.cursor);
      const sliced = log.filter((change) => change.sequence > after).slice(0, input.limit);
      const last = sliced.at(-1)?.sequence ?? after;
      return {
        changes: sliced,
        cursor: String(last),
        hasMore: log.some((change) => change.sequence > last),
      };
    },

    async latestCursor(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/sync_changes",
        query: {
          user_id: `eq.${userId}`,
          select: "sequence",
          order: "sequence.desc",
          limit: "1",
        },
      });
      const row = restRows(response.body)[0];
      if (row === undefined) {
        return "0";
      }
      return String(numericValue(row.sequence, 0));
    },
  };
}

export function createUnavailableSyncStore(): SyncStore {
  return {
    push() {
      return Promise.reject(new Error("database unavailable"));
    },
    pull() {
      return Promise.reject(new Error("database unavailable"));
    },
    latestCursor() {
      return Promise.resolve("0");
    },
  };
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
    appearance: appearance === "light" || appearance === "dark" ? appearance : fallback.appearance,
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
