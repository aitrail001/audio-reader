import { LOCAL_PASSWORDLESS_HMAC_SECRET, type Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import {
  composeAssistantSystemPrompt,
  type IdentityStore,
  type OpsStore,
} from "@audio-reader/database";
import {
  hmacCacheKey,
  sha256Hex,
  sharedCacheMaterial,
  type QwenClient,
  type QwenCompletionRequest,
  type QwenCompletionResult,
  type QwenMessage,
} from "@audio-reader/qwen";
import { readJsonObject } from "./body";
import { resolveTaskModel, type TaskModelResolution } from "./diagnostics";
import { jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import { requireBoundDevice } from "./route-helpers";
import { recordOperatorEvent, SYSTEM_ACTOR_ID } from "./operator-events";
import { hostOf, type RuntimeConfigService } from "./runtime-config";

type TranslationResult = components["schemas"]["TranslationResult"];
type ChapterSummary = components["schemas"]["ChapterSummary"];
type ChatAccepted = components["schemas"]["ChatAccepted"];
type ChatMessage = components["schemas"]["ChatMessage"];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHAT_MESSAGE_PATH =
  /^\/v1\/ai\/chat\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/messages\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const ASSISTANT_METHODS: Record<string, readonly string[]> = {
  "/v1/ai/translations": ["POST"],
  "/v1/ai/chapter-summaries": ["POST"],
  "/v1/ai/chat": ["POST"],
};

export type AssistantRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  qwen: QwenClient;
  ops?: OpsStore;
  identity?: IdentityStore;
  cacheHmacSecret?: string;
  runtime?: RuntimeConfigService;
};

const DEFAULT_DAILY_QUOTA = 50;
const inflight = new Map<string, Promise<unknown>>();

export function isAssistantPath(path: string): boolean {
  return path in ASSISTANT_METHODS || CHAT_MESSAGE_PATH.test(path);
}

export function assistantMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  if (CHAT_MESSAGE_PATH.test(path)) {
    if (method.toUpperCase() === "GET") {
      return undefined;
    }
    return problemResponse({
      status: 405,
      code: "method_not_allowed",
      title: "Method not allowed",
      detail: "This endpoint accepts GET.",
      traceId: requestId,
      headers: { Allow: "GET" },
    });
  }
  const allowed = ASSISTANT_METHODS[path];
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

export async function handleAssistantRoute(
  context: AssistantRouteContext,
): Promise<Response | undefined> {
  const path = new URL(context.request.url).pathname;
  const method = context.request.method.toUpperCase();
  const chatMessage = CHAT_MESSAGE_PATH.exec(path);
  if (chatMessage !== null) {
    if (method !== "GET") {
      return assistantMethodError(path, method, context.requestId);
    }
    return getChatMessage(context, chatMessage[1] ?? "", chatMessage[2] ?? "");
  }
  const allowed = ASSISTANT_METHODS[path];
  if (allowed === undefined) {
    return undefined;
  }
  if (!allowed.includes(method)) {
    return assistantMethodError(path, method, context.requestId);
  }
  if (path === "/v1/ai/translations") {
    return createTranslation(context);
  }
  if (path === "/v1/ai/chapter-summaries") {
    return createSummary(context);
  }
  return createChat(context);
}

async function createTranslation(context: AssistantRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const gated = await requireAssistantEnabled(context);
  if (gated !== undefined) {
    return gated;
  }
  const bound = await requireBoundProductDevice(context, principal);
  if (bound instanceof Response) {
    return bound;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const source = requiredString(body.value.source, "source", context.requestId);
      if (source instanceof Response) {
        return source;
      }
      const sourceLanguage = requiredString(
        body.value.sourceLanguage,
        "sourceLanguage",
        context.requestId,
      );
      if (sourceLanguage instanceof Response) {
        return sourceLanguage;
      }
      const targetLanguage = requiredString(
        body.value.targetLanguage,
        "targetLanguage",
        context.requestId,
      );
      if (targetLanguage instanceof Response) {
        return targetLanguage;
      }
      const allowed = await consumeQuota(context, principal.accountId, "translations");
      if (!allowed) {
        return quotaExceeded(context.requestId);
      }
      const policy = await resolveAssistantPolicy(context, "translation", principal.accountId);
      const cacheKey = await cacheKeyFor(context, {
        taskType: "translation",
        sourceLanguage,
        targetLanguage,
        source,
        context: typeof body.value.contextBefore === "string" ? body.value.contextBefore : "",
        editionFingerprint:
          typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
        learnerProfileBucket:
          typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate",
        promptVersion: policy.promptVersion,
        modelPolicyHash: await sha256Hex(`${policy.model}|${policy.systemPrompt}`),
      });
      const hit = await cacheHitTranslation(context, cacheKey);
      if (hit !== undefined) {
        await recordUse(context, principal.accountId, "translation", hit.id, hit.translation);
        return jsonResponse(hit);
      }
      const generated = await singleFlight(cacheKey, async () => {
        const replay = await cacheHitTranslation(context, cacheKey);
        if (replay !== undefined) {
          return replay;
        }
        const completed = await completeWithPolicy(context, "translation", principal.accountId, {
          jsonObject: true,
          messages: [
            {
              role: "system",
              content: policy.systemPrompt,
            },
            {
              role: "user",
              content: JSON.stringify({
                task: body.value.task ?? "sentence",
                sourceLanguage,
                targetLanguage,
                learnerLevel: body.value.learnerLevel ?? "intermediate",
                source,
              }),
            },
          ],
        });
        if (completed === "disabled" || !completed.ok) {
          return qwenFailure(context, "translation", completed);
        }
        const parsed = parseObject(completed.text);
        const translation = stringField(parsed, "translation") ?? completed.text;
        const notes = learningNotes(parsed.notes);
        const id = crypto.randomUUID();
        await context.ops?.putCache({
          id,
          cacheKey,
          task: "translation",
          state: "active",
          sourceLanguage,
          targetLanguage,
          editionFingerprint:
            typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
          policyVersion: policy.promptVersion,
          payload: { translation, notes },
        });
        const payload: TranslationResult = {
          id,
          translation,
          notes,
          provenance: "generated",
          policyVersion: policy.promptVersion,
          createdAt: new Date().toISOString(),
        };
        return payload;
      });
      if (generated instanceof Response) {
        return generated;
      }
      await recordUse(
        context,
        principal.accountId,
        "translation",
        generated.id,
        generated.translation,
      );
      return jsonResponse(generated);
    },
    context.requestId,
    principal,
  );
}

async function createSummary(context: AssistantRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const gated = await requireAssistantEnabled(context);
  if (gated !== undefined) {
    return gated;
  }
  const bound = await requireBoundProductDevice(context, principal);
  if (bound instanceof Response) {
    return bound;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const chapterId = requiredString(body.value.chapterId, "chapterId", context.requestId);
      if (chapterId instanceof Response) {
        return chapterId;
      }
      const allowed = await consumeQuota(context, principal.accountId, "summaries");
      if (!allowed) {
        return quotaExceeded(context.requestId);
      }
      const policy = await resolveAssistantPolicy(context, "chapter_summary", principal.accountId);
      const segments = Array.isArray(body.value.segments)
        ? body.value.segments.filter((item): item is string => typeof item === "string")
        : [];
      const sourceLanguage =
        typeof body.value.sourceLanguage === "string" ? body.value.sourceLanguage : "en";
      const targetLanguage =
        typeof body.value.targetLanguage === "string" ? body.value.targetLanguage : "en";
      const cacheKey = await cacheKeyFor(context, {
        taskType: "chapter_summary",
        sourceLanguage,
        targetLanguage,
        source: segments.join("\n"),
        editionFingerprint:
          typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
        learnerProfileBucket:
          typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate",
        promptVersion: policy.promptVersion,
        modelPolicyHash: await sha256Hex(`${policy.model}|${policy.systemPrompt}`),
      });
      const hit = await cacheHitSummary(context, cacheKey);
      if (hit !== undefined) {
        await recordUse(context, principal.accountId, "chapter_summary", hit.id, hit.overview);
        return jsonResponse(hit);
      }
      const generated = await singleFlight(cacheKey, async () => {
        const replay = await cacheHitSummary(context, cacheKey);
        if (replay !== undefined) {
          return replay;
        }
        const completed = await completeWithPolicy(
          context,
          "chapter_summary",
          principal.accountId,
          {
            jsonObject: true,
            messages: [
              {
                role: "system",
                content: policy.systemPrompt,
              },
              {
                role: "user",
                content: JSON.stringify({
                  chapterId,
                  sourceLanguage: body.value.sourceLanguage,
                  targetLanguage: body.value.targetLanguage,
                  segments,
                }),
              },
            ],
          },
        );
        if (completed === "disabled" || !completed.ok) {
          return qwenFailure(context, "chapter_summary", completed);
        }
        const parsed = parseObject(completed.text);
        const id = crypto.randomUUID();
        const payload: ChapterSummary = {
          id,
          overview: stringField(parsed, "overview") ?? completed.text,
          keyPoints: stringArray(parsed, "keyPoints"),
          charactersOrIdeas: stringArray(parsed, "charactersOrIdeas"),
          keyConcepts: conceptArray(parsed.keyConcepts),
          themes: stringArray(parsed, "themes"),
          provenance: "generated",
          createdAt: new Date().toISOString(),
        };
        await context.ops?.putCache({
          id,
          cacheKey,
          task: "chapter_summary",
          state: "active",
          sourceLanguage,
          targetLanguage,
          editionFingerprint:
            typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
          policyVersion: policy.promptVersion,
          payload: { ...payload },
        });
        return payload;
      });
      if (generated instanceof Response) {
        return generated;
      }
      await recordUse(
        context,
        principal.accountId,
        "chapter_summary",
        generated.id,
        generated.overview,
      );
      return jsonResponse(generated);
    },
    context.requestId,
    principal,
  );
}

async function createChat(context: AssistantRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const gated = await requireAssistantEnabled(context);
  if (gated !== undefined) {
    return gated;
  }
  const bound = await requireBoundProductDevice(context, principal);
  if (bound instanceof Response) {
    return bound;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const message = requiredString(
        body.value.message ?? body.value.question ?? body.value.content,
        "question",
        context.requestId,
      );
      if (message instanceof Response) {
        return message;
      }
      const chapterId = requiredString(body.value.chapterId, "chapterId", context.requestId);
      if (chapterId instanceof Response) {
        return chapterId;
      }
      void chapterId;
      const allowed = await consumeQuota(context, principal.accountId, "chat");
      if (!allowed) {
        return quotaExceeded(context.requestId);
      }
      const contextSegments = Array.isArray(body.value.contextSegments)
        ? body.value.contextSegments.filter((item): item is string => typeof item === "string")
        : [];
      const completed = await completeWithPolicy(context, "chat", principal.accountId, {
        messages: [
          {
            role: "system",
            content: contextSegments[0] ?? "",
          },
          {
            role: "user",
            content:
              contextSegments.length > 1
                ? JSON.stringify({ question: message, contextSegments: contextSegments.slice(1) })
                : message,
          },
        ],
      });
      if (completed === "disabled" || !completed.ok) {
        return qwenFailure(context, "chat", completed);
      }
      const threadId =
        typeof body.value.threadId === "string" && UUID_PATTERN.test(body.value.threadId)
          ? body.value.threadId
          : crypto.randomUUID();
      const messageId = crypto.randomUUID();
      const createdAt = new Date().toISOString();
      await context.ops?.putChatMessage({
        accountId: principal.accountId,
        threadId,
        messageId,
        role: "assistant",
        text: completed.text,
        createdAt,
      });
      await recordUse(context, principal.accountId, "chat", null, completed.text);
      const payload: ChatAccepted = {
        threadId,
        messageId,
        streamUrl: `/v1/ai/chat/${threadId}/messages/${messageId}`,
      };
      return jsonResponse(payload, 202);
    },
    context.requestId,
    principal,
  );
}

async function getChatMessage(
  context: AssistantRouteContext,
  threadId: string,
  messageId: string,
): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const bound = await requireBoundProductDevice(context, principal);
  if (bound instanceof Response) {
    return bound;
  }
  const stored = await context.ops?.getChatMessage(threadId, messageId);
  if (stored === undefined || stored.accountId !== principal.accountId) {
    return problemResponse({
      status: 404,
      code: "not_found",
      title: "Not found",
      detail: "Chat message was not found.",
      traceId: context.requestId,
    });
  }
  const payload: ChatMessage = {
    id: stored.messageId,
    role: stored.role,
    text: stored.text,
    createdAt: stored.createdAt,
  };
  return jsonResponse(payload);
}

async function requirePrincipal(context: AssistantRouteContext): Promise<Principal | Response> {
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

async function requireBoundProductDevice(
  context: AssistantRouteContext,
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

function requiredString(value: unknown, field: string, requestId: string): string | Response {
  if (typeof value === "string" && value.trim() !== "") {
    return value.trim();
  }
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: `${field} is required.`,
    traceId: requestId,
    fieldErrors: [{ field, message: `${field} is required.` }],
  });
}

async function resolveAssistantPolicy(
  context: AssistantRouteContext,
  task: string,
  accountId?: string,
): Promise<TaskModelResolution> {
  const policies = (await context.ops?.listPolicies()) ?? [];
  const view = await context.runtime?.view();
  return resolveTaskModel(
    policies.map((policy) => ({
      task: policy.task,
      enabled: policy.enabled,
      model: policy.model,
      promptVersion: policy.promptVersion,
      systemPrompt: policy.systemPrompt,
      canaryPercent: policy.canaryPercent,
    })),
    task,
    view?.qwen.model ?? "",
    accountId === undefined ? {} : { accountId },
  );
}

function withPolicySystemPrompt(
  task: string,
  policyPrompt: string,
  messages: readonly QwenMessage[],
): QwenMessage[] {
  const next = [...messages];
  const first = next[0];
  if (task === "chat") {
    const composed = composeAssistantSystemPrompt(
      policyPrompt,
      first?.role === "system" ? first.content : undefined,
    );
    if (first?.role === "system") {
      next[0] = { role: "system", content: composed };
      return next;
    }
    return [{ role: "system", content: composed }, ...next];
  }
  if (first?.role === "system") {
    next[0] = { role: "system", content: policyPrompt };
    return next;
  }
  return [{ role: "system", content: policyPrompt }, ...next];
}

async function completeWithPolicy(
  context: AssistantRouteContext,
  task: string,
  accountId: string,
  request: QwenCompletionRequest,
): Promise<QwenCompletionResult | "disabled"> {
  const resolved = await resolveAssistantPolicy(context, task, accountId);
  const view = await context.runtime?.view();
  console.warn(
    JSON.stringify({
      level: "warn",
      message: "managed_qwen_request",
      requestId: context.requestId,
      task,
      configured: view?.qwen.apiKeyConfigured === true,
      source: view?.qwen.source ?? "none",
      deskModel: view?.qwen.model ?? "",
      policyModel: resolved.source === "policy" ? resolved.model : "",
      usedModel: resolved.model,
      modelSource: resolved.source,
      promptVersion: resolved.promptVersion,
      systemPromptChars: resolved.systemPrompt.length,
      disabled: resolved.disabled,
      wrappingSource: view?.qwen.wrappingSecretSource,
      secretsDecryptable: view?.qwen.secretsDecryptable,
      qwenBaseUrlHost: hostOf(view?.qwen.baseUrl ?? ""),
    }),
  );
  recordOperatorEvent({
    kind: "managed_qwen_request",
    requestId: context.requestId,
    task,
    status: resolved.disabled ? "disabled" : "started",
    summary: resolved.disabled
      ? `Managed Qwen ${task} blocked by policy.`
      : `Managed Qwen ${task} using ${resolved.model || "default"} (${resolved.source}).`,
    metadata: {
      model: resolved.model,
      modelSource: resolved.source,
      promptVersion: resolved.promptVersion,
      systemPromptChars: resolved.systemPrompt.length,
    },
  });
  if (resolved.disabled) {
    return "disabled";
  }
  const completed = await context.qwen.complete({
    ...request,
    messages: withPolicySystemPrompt(task, resolved.systemPrompt, request.messages),
    ...(resolved.model === "" ? {} : { model: resolved.model }),
  });
  if (completed.ok) {
    recordOperatorEvent({
      kind: "managed_qwen_ok",
      requestId: context.requestId,
      task,
      status: "ok",
      summary: `Managed Qwen ${task} succeeded with ${completed.model}.`,
      metadata: { model: completed.model, promptVersion: resolved.promptVersion },
    });
  }
  return completed;
}

async function qwenFailure(
  context: AssistantRouteContext,
  task: string,
  completed: "disabled" | QwenCompletionResult,
): Promise<Response> {
  const view = await context.runtime?.view();
  const configured = view?.qwen.apiKeyConfigured === true;
  const source = view?.qwen.source ?? "none";
  const failure = completed === "disabled" || completed.ok ? undefined : completed;
  const model =
    completed === "disabled"
      ? (view?.qwen.model ?? "")
      : completed.ok
        ? completed.model
        : completed.usedModel;
  const providerDetail =
    failure?.detail === undefined || failure.detail === "" ? "" : ` ${failure.detail}`;
  let detail: string;
  if (completed === "disabled") {
    detail = `Managed Qwen policy for ${task} is disabled.`;
  } else if (!configured) {
    detail =
      "Managed Qwen has no API key. Save a Qwen key on operator Desk, or set Worker secret QWEN_API_KEY.";
  } else if (failure?.code === "rejected") {
    detail = `Managed Qwen rejected ${task} (HTTP ${String(failure.httpStatus ?? 400)}) using ${model || "default model"}.${providerDetail}`;
  } else {
    detail = `Managed Qwen endpoint is unreachable for ${task} (HTTP ${String(failure?.httpStatus ?? 0)}) using ${model || "default model"}.${providerDetail}`;
  }
  recordOperatorEvent({
    kind: "managed_qwen_failed",
    requestId: context.requestId,
    task,
    status: completed === "disabled" ? "policy_disabled" : completed.ok ? "ok" : completed.code,
    summary: detail,
    ...(completed === "disabled" || completed.ok ? {} : { detail: completed.detail }),
    metadata: {
      configured,
      source,
      model,
      httpStatus: completed === "disabled" || completed.ok ? undefined : completed.httpStatus,
    },
  });
  if (context.ops !== undefined) {
    await context.ops.appendAudit({
      actorId: SYSTEM_ACTOR_ID,
      action: "managed_qwen_failed",
      resourceType: "qwen",
      resourceId: task,
      reason: detail,
      traceId: context.requestId,
      metadata: {
        task,
        status: completed === "disabled" ? "policy_disabled" : completed.ok ? "ok" : completed.code,
        model,
        configured,
      },
    });
  }
  console.warn(
    JSON.stringify({
      level: "warn",
      message: "managed_qwen_failed",
      requestId: context.requestId,
      task,
      configured,
      source,
      model,
      wrappingSource: view?.qwen.wrappingSecretSource,
      secretsDecryptable: view?.qwen.secretsDecryptable,
      ciphertextPresent: view?.qwen.ciphertextPresent,
      qwenBaseUrlHost: hostOf(view?.qwen.baseUrl ?? ""),
      code: completed === "disabled" ? "policy_disabled" : failure?.code,
      httpStatus: failure?.httpStatus,
      detail: failure?.detail,
    }),
  );
  return problemResponse({
    status: 503,
    code: "not_ready",
    title: "Service unavailable",
    detail,
    traceId: context.requestId,
  });
}

function quotaExceeded(requestId: string): Response {
  return problemResponse({
    status: 429,
    code: "rate_limited",
    title: "Too many requests",
    detail: "Daily managed Qwen quota exceeded.",
    traceId: requestId,
    retryAfterSeconds: 3600,
  });
}

async function requireAssistantEnabled(
  context: AssistantRouteContext,
): Promise<Response | undefined> {
  if (context.ops === undefined) {
    return undefined;
  }
  const flags = await context.ops.listFlags();
  if (flags.some((flag) => flag.key === "maintenance_mode" && flag.enabled)) {
    return problemResponse({
      status: 503,
      code: "not_ready",
      title: "Service unavailable",
      detail: "AudioReader is in maintenance mode.",
      traceId: context.requestId,
    });
  }
  const managed = flags.find((flag) => flag.key === "managed_qwen");
  if (managed !== undefined && !managed.enabled) {
    return problemResponse({
      status: 403,
      code: "forbidden",
      title: "Forbidden",
      detail: "Managed Qwen is disabled.",
      traceId: context.requestId,
    });
  }
  return undefined;
}

async function consumeQuota(
  context: AssistantRouteContext,
  userId: string,
  kind: "translations" | "summaries" | "chat",
): Promise<boolean> {
  if (context.ops === undefined) {
    return true;
  }
  const quotas = await context.ops.quotasFor(userId);
  const daily = quotas.find((item) => item.key === "qwen_tasks_day");
  const limit = daily?.limit ?? DEFAULT_DAILY_QUOTA;
  return context.ops.consumeQuota(userId, kind, limit);
}

async function cacheKeyFor(
  context: AssistantRouteContext,
  parts: Parameters<typeof sharedCacheMaterial>[0],
): Promise<string> {
  const material = await sharedCacheMaterial(parts);
  return hmacCacheKey(context.cacheHmacSecret ?? LOCAL_PASSWORDLESS_HMAC_SECRET, material);
}

async function cacheHitTranslation(
  context: AssistantRouteContext,
  cacheKey: string,
): Promise<TranslationResult | undefined> {
  const cached = await context.ops?.lookupCache(cacheKey);
  if (cached === undefined) {
    return undefined;
  }
  await context.ops?.touchCache(cached.id);
  return {
    id: cached.id,
    translation: stringField(cached.payload, "translation") ?? "",
    notes: learningNotes(cached.payload.notes),
    provenance: "cache_shared_exact",
    policyVersion: cached.policyVersion,
    createdAt: cached.createdAt,
  };
}

async function cacheHitSummary(
  context: AssistantRouteContext,
  cacheKey: string,
): Promise<ChapterSummary | undefined> {
  const cached = await context.ops?.lookupCache(cacheKey);
  if (cached === undefined) {
    return undefined;
  }
  await context.ops?.touchCache(cached.id);
  return {
    id: cached.id,
    overview: stringField(cached.payload, "overview") ?? "",
    keyPoints: stringArray(cached.payload, "keyPoints"),
    charactersOrIdeas: stringArray(cached.payload, "charactersOrIdeas"),
    keyConcepts: conceptArray(cached.payload.keyConcepts),
    themes: stringArray(cached.payload, "themes"),
    provenance: "cache_shared_exact",
    createdAt: cached.createdAt,
  };
}

async function recordUse(
  context: AssistantRouteContext,
  userId: string,
  task: string,
  cacheEntryId: string | null,
  outputText: string,
): Promise<void> {
  await context.ops?.recordAssistantUse(userId, { task, cacheEntryId, outputText });
}

async function singleFlight<T>(key: string, work: () => Promise<T>): Promise<T> {
  const existing = inflight.get(key);
  if (existing !== undefined) {
    return (await existing) as T;
  }
  const pending = work();
  inflight.set(key, pending);
  try {
    return await pending;
  } finally {
    inflight.delete(key);
  }
}

function parseObject(text: string): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(text);
    if (typeof value === "object" && value !== null && !Array.isArray(value)) {
      return value as Record<string, unknown>;
    }
  } catch {
    return {};
  }
  return {};
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

function stringArray(record: Record<string, unknown>, key: string): string[] {
  const value = record[key];
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string");
}

function learningNotes(value: unknown): TranslationResult["notes"] {
  if (!Array.isArray(value)) {
    return [];
  }
  const notes: TranslationResult["notes"] = [];
  for (const item of value) {
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const record = item as Record<string, unknown>;
    const source = typeof record.source === "string" ? record.source : "";
    const explanation = typeof record.explanation === "string" ? record.explanation : "";
    const category = record.category;
    if (source === "" || explanation === "") {
      continue;
    }
    const allowed = [
      "phrasal_verb",
      "phrase",
      "idiom",
      "challenging_word",
      "challenging_combination",
      "concept",
      "grammar",
    ] as const;
    notes.push({
      source,
      category: allowed.find((entry) => entry === category) ?? "phrase",
      explanation,
    });
  }
  return notes;
}

function conceptArray(value: unknown): ChapterSummary["keyConcepts"] {
  if (!Array.isArray(value)) {
    return [];
  }
  const concepts: ChapterSummary["keyConcepts"] = [];
  for (const item of value) {
    if (typeof item === "string" && item.trim() !== "") {
      concepts.push({ name: item, explanation: item });
      continue;
    }
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const record = item as Record<string, unknown>;
    const name = typeof record.name === "string" ? record.name : "";
    const explanation = typeof record.explanation === "string" ? record.explanation : "";
    if (name !== "") {
      concepts.push({ name, explanation });
    }
  }
  return concepts;
}
