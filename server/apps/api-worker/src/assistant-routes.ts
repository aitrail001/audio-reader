import { LOCAL_PASSWORDLESS_HMAC_SECRET, type Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import {
  CHAPTER_SUMMARY_INSTRUCTIONS,
  assembleManagedPrompt,
  composeAssistantSystemPrompt,
  isWordTranslationTask,
  SENTENCE_TRANSLATION_INSTRUCTIONS,
  WORD_IN_SENTENCE_INSTRUCTIONS,
  formatManagedChapterBatchContext,
  formatManagedSentenceContext,
  stringList,
  validateManagedPromptOutput,
  type IdentityStore,
  type ManagedPromptAssembly,
  type ManagedPromptSubtask,
  type OpsAssistantResult,
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
import { captureProductEvent } from "./product-events";
import { hostOf, type RuntimeConfigService } from "./runtime-config";

type TranslationResult = components["schemas"]["TranslationResult"];
type TranslationBatchResult = components["schemas"]["TranslationBatchResult"];
type ChapterSummary = components["schemas"]["ChapterSummary"];
type ChatAccepted = components["schemas"]["ChatAccepted"];
type ChatMessage = components["schemas"]["ChatMessage"];
type HeardQuizResponse = components["schemas"]["HeardQuizResponse"];
type TranslationSentence = { id: string; text: string; assistantResultId?: string };

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHAT_MESSAGE_PATH =
  /^\/v1\/ai\/chat\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/messages\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const ASSISTANT_METHODS: Record<string, readonly string[]> = {
  "/v1/ai/translations": ["POST"],
  "/v1/ai/translation-batches": ["POST"],
  "/v1/ai/chapter-summaries": ["POST"],
  "/v1/ai/chat": ["POST"],
  "/v1/ai/heard-quizzes": ["POST"],
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
  if (path === "/v1/ai/translation-batches") {
    return createTranslationBatch(context);
  }
  if (path === "/v1/ai/chapter-summaries") {
    return createSummary(context);
  }
  if (path === "/v1/ai/heard-quizzes") {
    return createHeardQuiz(context);
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
      const policy = await resolveAssistantPolicy(context, "translation", principal.accountId);
      const taskKind = typeof body.value.task === "string" ? body.value.task : "sentence";
      const wordTask = isWordTranslationTask(taskKind);
      const lookupOnly = body.value.lookupOnly === true;
      const refresh = body.value.refresh === true;
      const contextBefore =
        typeof body.value.contextBefore === "string" ? body.value.contextBefore : "";
      const contextPrevious = stringList(body.value.contextPrevious);
      const contextNext = stringList(body.value.contextNext);
      const learnerLevel =
        typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate";
      const bookTitle = typeof body.value.bookTitle === "string" ? body.value.bookTitle : "";
      const author = typeof body.value.author === "string" ? body.value.author : "";
      const chapterTitle =
        typeof body.value.chapterTitle === "string" ? body.value.chapterTitle : "";
      const sentenceContextCount =
        (await context.runtime?.view())?.assistant.sentenceContextCount ?? 1;
      const managedContext = formatManagedSentenceContext({
        source,
        previous: contextPrevious,
        next: contextNext,
        radius: sentenceContextCount,
        fallback: contextBefore,
      });
      const targetId = typeof body.value.targetId === "string" ? body.value.targetId : "";
      const editionFingerprint =
        typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "";
      const modelPolicyHash = await sha256Hex(
        `${policy.model}|${policy.systemPrompt}|${policy.userPrompt}|${wordTask ? WORD_IN_SENTENCE_INSTRUCTIONS : SENTENCE_TRANSLATION_INSTRUCTIONS}`,
      );
      const requestedResultId =
        typeof body.value.assistantResultId === "string" && UUID_PATTERN.test(body.value.assistantResultId)
          ? body.value.assistantResultId
          : undefined;
      const cacheKey = await cacheKeyFor(context, {
        taskType: "translation",
        sourceLanguage,
        targetLanguage,
        source,
        // Words keep the containing sentence. Sentence identity is the source
        // text plus languages/policy so a later block lookup can reuse it.
        context: wordTask ? managedContext : "",
        editionFingerprint,
        learnerProfileBucket: learnerLevel,
        promptVersion: policy.promptVersion,
        // Layout extras are not stored on the policy row; include them so
        // older English-note or gloss-only cache entries miss after a change.
        modelPolicyHash,
      });
      if (!refresh) {
        const hit = await cacheHitTranslation(context, cacheKey);
        if (hit !== undefined) {
          const resultId = requestedResultId ?? crypto.randomUUID();
          const exactModel = hit.model || policy.model;
          const exactPromptVersion = hit.promptVersion || policy.promptVersion;
          const exactModelPolicyHash = hit.modelPolicyHash || modelPolicyHash;
          const payload = withTranslationIdentity({
            ...hit,
            id: resultId,
            sharedCacheEntryID: hit.id,
            model: exactModel,
            promptVersion: exactPromptVersion,
            modelPolicyHash: exactModelPolicyHash,
          }, { targetId, source });
          const recorded = await recordUse(
            context, principal.accountId, resultId, "translation",
            requestedResultId === undefined ? "pending" : "replaced", hit.id,
            translationPrivateText(payload),
            exactModel, exactPromptVersion, exactModelPolicyHash,
            {
              resultKind: wordTask ? "wordGloss" : "sentenceGloss",
              language: targetLanguage,
              sourceText: source,
              contextText: managedContext,
              bookTitle,
              chapterTitle,
              targetId,
              privateContent: translationPrivateContent(payload),
            },
          );
          await captureProductEvent(context.ops, {
            accountId: principal.accountId,
            name: "ai.translation.cache_hit",
            requestId: context.requestId,
            properties: { cacheId: hit.id, lookupOnly },
          });
          console.warn(
            JSON.stringify({
              level: "info",
              message: "assistant_translation_cache_hit",
              requestId: context.requestId,
              task: taskKind,
              lookupOnly,
            }),
          );
          return jsonResponse({
            ...payload,
            sharedCacheEntryID: recorded?.cacheEntryId ?? null,
          });
        }
      }
      if (lookupOnly) {
        console.warn(
          JSON.stringify({
            level: "info",
            message: "assistant_translation_lookup_miss",
            requestId: context.requestId,
            task: taskKind,
          }),
        );
        return cacheLookupMiss(context.requestId, "translation");
      }
      const generated = await singleFlight(cacheKey, async () => {
        // Refresh asked for a new payload; a concurrent fill must not replay cache.
        if (!refresh) {
          const replay = await cacheHitTranslation(context, cacheKey);
          if (replay !== undefined) {
            return replay;
          }
        }
        // qwen_tasks_day counts an actual Qwen call, not a cache replay.
        const allowed = await consumeQuota(context, principal.accountId, "translations");
        if (!allowed) {
          return quotaExceeded(context.requestId);
        }
        const promptFields = {
          task: taskKind,
          sourceLanguage,
          targetLanguage,
          learnerLevel,
          source,
          context: managedContext,
          bookTitle,
          author,
          chapterTitle,
          chapterId: typeof body.value.chapterId === "string" ? body.value.chapterId : "",
        };
        const assembled = assembleManagedPrompt({
          subtask: wordTask ? "word" : "sentence",
          policySystemPrompt: policy.systemPrompt,
          policyUserPrompt: policy.userPrompt,
          schemaVersion: policy.schemaVersion,
          fields: promptFields,
        });
        console.warn(
          JSON.stringify({
            level: "info",
            message: "assistant_translation_prompt",
            requestId: context.requestId,
            task: taskKind,
            wordTask,
            hasContext: managedContext !== "",
            bookTitleChars: bookTitle.length,
            sentenceContextCount,
            managedContextChars: managedContext.length,
          }),
        );
        const completed = await completeWithPolicy(
          context,
          "translation",
          principal.accountId,
          {
            jsonObject: true,
            messages: [
              { role: "system", content: assembled.effective.system },
              { role: "user", content: assembled.effective.user },
            ],
          },
          assembled,
          "translation",
          false,
        );
        if (completed === "disabled" || !completed.ok) {
          return qwenFailure(context, "translation", completed);
        }
        const parsed = await validateManagedRouteOutput(context, {
          accountId: principal.accountId,
          eventTask: "translation",
          outputSubtask: wordTask ? "word" : "sentence",
          text: completed.text,
          model: completed.model,
          promptVersion: policy.promptVersion,
        });
        if (parsed instanceof Response) return parsed;
        const translationCore = stringField(parsed, "translation") ?? completed.text;
        const connection = stringField(parsed, "connection") ?? "";
        const translation =
          wordTask && connection !== "" ? `${translationCore}\n${connection}` : translationCore;
        const notes = [...learningNotes(parsed.notes), ...exampleNotes(parsed.examples)];
        const id = crypto.randomUUID();
        const cacheEntryId = await persistAssistantCache(context, principal.accountId, {
          id,
          cacheKey,
          task: "translation",
          state: "active",
          sourceLanguage,
          targetLanguage,
          editionFingerprint,
          policyVersion: policy.promptVersion,
          payload: {
            translation,
            connection,
            notes,
            model: completed.model,
            promptVersion: policy.promptVersion,
            modelPolicyHash,
          },
        });
        const payload: TranslationResult = withTranslationIdentity(
          {
            id,
            sharedCacheEntryID: cacheEntryId,
            translation,
            notes,
            provenance: "generated",
            policyVersion: policy.promptVersion,
            model: completed.model,
            promptVersion: policy.promptVersion,
            modelPolicyHash,
            createdAt: new Date().toISOString(),
          },
          { targetId, source },
        );
        return payload;
      });
      if (generated instanceof Response) {
        return generated;
      }
      const cacheEntryId = generated.sharedCacheEntryID ?? null;
      const resultId = requestedResultId ?? crypto.randomUUID();
      const recorded = await recordUse(
        context,
        principal.accountId,
        resultId,
        "translation",
        requestedResultId === undefined ? "pending" : "replaced",
        cacheEntryId,
        translationPrivateText(generated),
        generated.model,
        policy.promptVersion,
        modelPolicyHash,
        {
          resultKind: wordTask ? "wordGloss" : "sentenceGloss",
          language: targetLanguage,
          sourceText: source,
          contextText: managedContext,
          bookTitle,
          chapterTitle,
          targetId,
          privateContent: translationPrivateContent(generated),
        },
      );
      return jsonResponse({
        ...generated,
        id: resultId,
        sharedCacheEntryID: recorded?.cacheEntryId ?? null,
        model: generated.model,
        promptVersion: policy.promptVersion,
        modelPolicyHash,
      });
    },
    context.requestId,
    principal,
  );
}

async function createTranslationBatch(context: AssistantRouteContext): Promise<Response> {
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
      const sentences = translationSentences(body.value.sentences, context.requestId);
      if (sentences instanceof Response) {
        return sentences;
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
      const lookupOnly = body.value.lookupOnly === true;
      const refreshIds = new Set(stringList(body.value.refreshIds, 40));
      const learnerLevel =
        typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate";
      const editionFingerprint =
        typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "";
      const bookTitle = typeof body.value.bookTitle === "string" ? body.value.bookTitle : "";
      const author = typeof body.value.author === "string" ? body.value.author : "";
      const chapterTitle =
        typeof body.value.chapterTitle === "string" ? body.value.chapterTitle : "";
      const contextBefore =
        typeof body.value.contextBefore === "string" ? body.value.contextBefore : "";
      const contextPrevious = stringList(body.value.contextPrevious);
      const contextNext = stringList(body.value.contextNext);
      const policy = await resolveAssistantPolicy(context, "translation", principal.accountId);
      const modelPolicyHash = await sha256Hex(
        `${policy.model}|${policy.systemPrompt}|${policy.userPrompt}|${SENTENCE_TRANSLATION_INSTRUCTIONS}`,
      );
      const requestedResultIDs = new Map(
        sentences.flatMap((sentence) =>
          sentence.assistantResultId === undefined ? [] : [[sentence.id, sentence.assistantResultId] as const],
        ),
      );
      const sentenceContextCount =
        (await context.runtime?.view())?.assistant.sentenceContextCount ?? 1;
      const keyed = await Promise.all(
        sentences.map(async (sentence) => ({
          sentence,
          cacheKey: await cacheKeyFor(context, {
            taskType: "translation",
            sourceLanguage,
            targetLanguage,
            source: sentence.text,
            context: "",
            editionFingerprint,
            learnerProfileBucket: learnerLevel,
            promptVersion: policy.promptVersion,
            modelPolicyHash,
          }),
        })),
      );
      const results: TranslationResult[] = [];
      const pending: typeof keyed = [];
      for (const item of keyed) {
        if (!refreshIds.has(item.sentence.id)) {
          const hit = await cacheHitTranslation(context, item.cacheKey);
          if (hit !== undefined) {
            results.push(
              withTranslationIdentity(hit, {
                targetId: item.sentence.id,
                source: item.sentence.text,
              }),
            );
            continue;
          }
        }
        pending.push(item);
      }
      console.warn(
        JSON.stringify({
          level: "info",
          message: "assistant_translation_batch_lookup",
          requestId: context.requestId,
          sentenceCount: sentences.length,
          cacheHits: results.length,
          pending: pending.length,
          lookupOnly,
        }),
      );
      if (pending.length === 0) {
        const privateResults = await materializePrivateTranslationResults(
          context, principal.accountId, results, policy.model, policy.promptVersion, modelPolicyHash,
          requestedResultIDs,
          { language: targetLanguage, contextText: contextBefore, bookTitle, chapterTitle },
        );
        await captureProductEvent(context.ops, {
          accountId: principal.accountId,
          name: "ai.translation.cache_hit",
          requestId: context.requestId,
          properties: { cacheHitCount: results.length, batch: true },
        });
        return jsonResponse(batchResult(privateResults, [], results.length, 0));
      }
      if (lookupOnly) {
        return jsonResponse(
          batchResult(
            results,
            pending.map((item) => item.sentence.id),
            results.length,
            0,
          ),
        );
      }
      const flightKey = pending
        .map((item) => item.cacheKey)
        .sort()
        .join("|");
      const generated = await singleFlight(flightKey, async () => {
        const replayed: TranslationResult[] = [];
        const stillMissing: typeof pending = [];
        for (const item of pending) {
          if (!refreshIds.has(item.sentence.id)) {
            const replay = await cacheHitTranslation(context, item.cacheKey);
            if (replay !== undefined) {
              replayed.push(
                withTranslationIdentity(replay, {
                  targetId: item.sentence.id,
                  source: item.sentence.text,
                }),
              );
              continue;
            }
          }
          stillMissing.push(item);
        }
        if (stillMissing.length === 0) {
          return { generated: replayed, missingIds: [] as string[] };
        }
        // Charge quota only on the path that is about to call Qwen.
        const allowed = await consumeQuota(context, principal.accountId, "translations");
        if (!allowed) {
          return quotaExceeded(context.requestId);
        }
        const targetIDs = stillMissing.map((item) => item.sentence.id);
        const managedContext = formatManagedChapterBatchContext({
          // Empty contextBefore: keep in-block cached sentences as PREVIOUS/NEXT.
          sentences:
            contextBefore.trim() === "" ? sentences : stillMissing.map((item) => item.sentence),
          previous: contextPrevious,
          next: contextNext,
          radius: sentenceContextCount,
          targetIds: targetIDs,
        });
        const promptFields = {
          task: "chapter_batch",
          sourceLanguage,
          targetLanguage,
          learnerLevel,
          source: stillMissing.map((item) => item.sentence.text).join("\n"),
          context: [contextBefore, managedContext].filter((part) => part.trim() !== "").join("\n"),
          segments: contextBefore,
          bookTitle,
          author,
          chapterTitle,
          chapterId: typeof body.value.chapterId === "string" ? body.value.chapterId : "",
          targetIds: targetIDs.join(", "),
        };
        const assembled = assembleManagedPrompt({
          subtask: "chapter_batch",
          policySystemPrompt: policy.systemPrompt,
          policyUserPrompt: policy.userPrompt,
          schemaVersion: policy.schemaVersion,
          fields: promptFields,
        });
        console.warn(
          JSON.stringify({
            level: "info",
            message: "assistant_translation_batch_prompt",
            requestId: context.requestId,
            task: "chapter_batch",
            pending: stillMissing.length,
            sentenceContextCount,
            managedContextChars: managedContext.length,
          }),
        );
        const completed = await completeWithPolicy(
          context,
          "translation",
          principal.accountId,
          {
            jsonObject: true,
            messages: [
              { role: "system", content: assembled.effective.system },
              { role: "user", content: assembled.effective.user },
            ],
          },
          assembled,
          "translation",
          false,
        );
        if (completed === "disabled" || !completed.ok) {
          return qwenFailure(context, "translation", completed);
        }
        const output = await validateManagedRouteOutput(context, {
          accountId: principal.accountId,
          eventTask: "translation",
          outputSubtask: "chapter_batch",
          text: completed.text,
          model: completed.model,
          promptVersion: policy.promptVersion,
          expectedTargetIDs: new Set(targetIDs),
        });
        if (output instanceof Response) return output;
        const parsedUnits = parseBatchTranslations(completed.text, targetIDs);
        const createdAt = new Date().toISOString();
        const generatedResults: TranslationResult[] = [...replayed];
        const missingIds: string[] = [];
        for (const item of stillMissing) {
          const unit = parsedUnits.get(item.sentence.id);
          if (unit === undefined) {
            missingIds.push(item.sentence.id);
            continue;
          }
          const id = crypto.randomUUID();
          const cacheEntryId = await persistAssistantCache(context, principal.accountId, {
            id,
            cacheKey: item.cacheKey,
            task: "translation",
            state: "active",
            sourceLanguage,
            targetLanguage,
            editionFingerprint,
            policyVersion: policy.promptVersion,
            payload: {
              translation: unit.translation,
              notes: unit.notes,
              model: completed.model,
              promptVersion: policy.promptVersion,
              modelPolicyHash,
            },
          });
          generatedResults.push(
            withTranslationIdentity(
              {
                id,
                sharedCacheEntryID: cacheEntryId,
                translation: unit.translation,
                notes: unit.notes,
                provenance: "generated",
                policyVersion: policy.promptVersion,
                model: completed.model,
                promptVersion: policy.promptVersion,
                modelPolicyHash,
                createdAt,
              },
              { targetId: item.sentence.id, source: item.sentence.text },
            ),
          );
        }
        return { generated: generatedResults, missingIds };
      });
      if (generated instanceof Response) {
        return generated;
      }
      const combined = [...results, ...generated.generated];
      const privateResults = await materializePrivateTranslationResults(
        context, principal.accountId, combined, policy.model, policy.promptVersion, modelPolicyHash,
        requestedResultIDs,
        { language: targetLanguage, contextText: contextBefore, bookTitle, chapterTitle },
      );
      return jsonResponse(
        batchResult(
          privateResults,
          generated.missingIds,
          results.length,
          generated.generated.filter((item) => item.provenance === "generated").length,
        ),
      );
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
      const lookupOnly = body.value.lookupOnly === true;
      const refresh = body.value.refresh === true;
      const policy = await resolveAssistantPolicy(context, "chapter_summary", principal.accountId);
      const segments = Array.isArray(body.value.segments)
        ? body.value.segments.filter((item): item is string => typeof item === "string")
        : [];
      const sourceLanguage =
        typeof body.value.sourceLanguage === "string" ? body.value.sourceLanguage : "en";
      const targetLanguage =
        typeof body.value.targetLanguage === "string" ? body.value.targetLanguage : "en";
      const learnerLevel =
        typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate";
      const bookTitle = typeof body.value.bookTitle === "string" ? body.value.bookTitle : "";
      const author = typeof body.value.author === "string" ? body.value.author : "";
      const chapterTitle =
        typeof body.value.chapterTitle === "string" ? body.value.chapterTitle : "";
      const modelPolicyHash = await sha256Hex(
        `${policy.model}|${policy.systemPrompt}|${policy.userPrompt}|${CHAPTER_SUMMARY_INSTRUCTIONS}`,
      );
      const requestedResultId =
        typeof body.value.assistantResultId === "string" && UUID_PATTERN.test(body.value.assistantResultId)
          ? body.value.assistantResultId
          : undefined;
      const cacheKey = await cacheKeyFor(context, {
        taskType: "chapter_summary",
        sourceLanguage,
        targetLanguage,
        source: segments.join("\n"),
        editionFingerprint:
          typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
        learnerProfileBucket: learnerLevel,
        promptVersion: policy.promptVersion,
        modelPolicyHash,
      });
      if (!refresh) {
        const hit = await cacheHitSummary(context, cacheKey);
        if (hit !== undefined) {
          const resultId = requestedResultId ?? crypto.randomUUID();
          const exactModel = hit.model || policy.model;
          const exactPromptVersion = hit.promptVersion || policy.promptVersion;
          const exactModelPolicyHash = hit.modelPolicyHash || modelPolicyHash;
          const recorded = await recordUse(
            context, principal.accountId, resultId, "chapter_summary",
            requestedResultId === undefined ? "pending" : "replaced", hit.id,
            JSON.stringify(summaryPrivateContent(hit)),
            exactModel, exactPromptVersion, exactModelPolicyHash,
            {
              resultKind: "chapterSummary",
              language: targetLanguage,
              sourceText: segments.join("\n").slice(0, 20_000),
              bookTitle,
              chapterTitle,
              targetId: chapterId,
              privateContent: summaryPrivateContent(hit),
            },
          );
          await captureProductEvent(context.ops, {
            accountId: principal.accountId,
            name: "ai.summary.cache_hit",
            requestId: context.requestId,
            properties: { cacheId: hit.id, lookupOnly },
          });
          console.warn(
            JSON.stringify({
              level: "info",
              message: "assistant_summary_cache_hit",
              requestId: context.requestId,
              lookupOnly,
            }),
          );
          return jsonResponse({
            ...hit,
            id: resultId,
            sharedCacheEntryID: recorded?.cacheEntryId ?? null,
            model: exactModel,
            promptVersion: exactPromptVersion,
            modelPolicyHash: exactModelPolicyHash,
            policyVersion: exactPromptVersion,
          });
        }
      }
      if (lookupOnly) {
        console.warn(
          JSON.stringify({
            level: "info",
            message: "assistant_summary_lookup_miss",
            requestId: context.requestId,
          }),
        );
        return cacheLookupMiss(context.requestId, "chapter summary");
      }
      const generated = await singleFlight(cacheKey, async () => {
        if (!refresh) {
          const replay = await cacheHitSummary(context, cacheKey);
          if (replay !== undefined) {
            return replay;
          }
        }
        const allowed = await consumeQuota(context, principal.accountId, "summaries");
        if (!allowed) {
          return quotaExceeded(context.requestId);
        }
        const assembled = assembleManagedPrompt({
          subtask: "chapter_summary",
          policySystemPrompt: policy.systemPrompt,
          policyUserPrompt: policy.userPrompt,
          schemaVersion: policy.schemaVersion,
          fields: {
            task: "chapter_summary",
            chapterId,
            sourceLanguage,
            targetLanguage,
            learnerLevel,
            segments: segments.join("\n"),
            source: segments.join("\n"),
            context: segments.join("\n"),
            bookTitle,
            author,
            chapterTitle,
          },
        });
        const completed = await completeWithPolicy(
          context,
          "chapter_summary",
          principal.accountId,
          {
            jsonObject: true,
            messages: [
              { role: "system", content: assembled.effective.system },
              { role: "user", content: assembled.effective.user },
            ],
          },
          assembled,
          "chapter_summary",
          false,
        );
        if (completed === "disabled" || !completed.ok) {
          return qwenFailure(context, "chapter_summary", completed);
        }
        const parsed = await validateManagedRouteOutput(context, {
          accountId: principal.accountId,
          eventTask: "chapter_summary",
          outputSubtask: "chapter_summary",
          text: completed.text,
          model: completed.model,
          promptVersion: policy.promptVersion,
        });
        if (parsed instanceof Response) return parsed;
        const id = crypto.randomUUID();
        const payload: ChapterSummary = {
          id,
          sharedCacheEntryID: id,
          overview: stringField(parsed, "overview") ?? completed.text,
          keyPoints: stringArray(parsed, "keyPoints"),
          charactersOrIdeas: stringArray(parsed, "charactersOrIdeas"),
          keyConcepts: conceptArray(parsed.keyConcepts),
          themes: stringArray(parsed, "themes"),
          provenance: "generated",
          model: completed.model,
          promptVersion: policy.promptVersion,
          modelPolicyHash,
          policyVersion: policy.promptVersion,
          createdAt: new Date().toISOString(),
        };
        const cacheEntryId = await persistAssistantCache(context, principal.accountId, {
          id,
          cacheKey,
          task: "chapter_summary",
          state: "active",
          sourceLanguage,
          targetLanguage,
          editionFingerprint:
            typeof body.value.editionFingerprint === "string" ? body.value.editionFingerprint : "",
          policyVersion: policy.promptVersion,
          payload: {
            ...payload,
          },
        });
        return { ...payload, sharedCacheEntryID: cacheEntryId };
      });
      if (generated instanceof Response) {
        return generated;
      }
      const cacheEntryId = generated.sharedCacheEntryID ?? null;
      const resultId = requestedResultId ?? crypto.randomUUID();
      const recorded = await recordUse(
        context,
        principal.accountId,
        resultId,
        "chapter_summary",
        requestedResultId === undefined ? "pending" : "replaced",
        cacheEntryId,
        JSON.stringify(summaryPrivateContent(generated)),
        generated.model,
        policy.promptVersion,
        modelPolicyHash,
        {
          resultKind: "chapterSummary",
          language: targetLanguage,
          sourceText: segments.join("\n").slice(0, 20_000),
          bookTitle,
          chapterTitle,
          targetId: chapterId,
          privateContent: summaryPrivateContent(generated),
        },
      );
      return jsonResponse({
        ...generated,
        id: resultId,
        sharedCacheEntryID: recorded?.cacheEntryId ?? null,
        model: generated.model,
        promptVersion: policy.promptVersion,
        modelPolicyHash,
        policyVersion: policy.promptVersion,
      });
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
      const policy = await resolveAssistantPolicy(context, "chat", principal.accountId);
      const sourceLanguage =
        typeof body.value.sourceLanguage === "string" ? body.value.sourceLanguage : "en";
      const targetLanguage =
        typeof body.value.targetLanguage === "string" ? body.value.targetLanguage : "en";
      const learnerLevel =
        typeof body.value.learnerLevel === "string" ? body.value.learnerLevel : "intermediate";
      const assembled = assembleManagedPrompt({
        subtask: "chat",
        policySystemPrompt: policy.systemPrompt,
        policyUserPrompt: policy.userPrompt,
        schemaVersion: policy.schemaVersion,
        fields: {
          task: "chat",
          question: message,
          context: contextSegments.join("\n"),
          source: contextSegments.join("\n"),
          chapterId,
          bookTitle: typeof body.value.bookTitle === "string" ? body.value.bookTitle : "",
          author: typeof body.value.author === "string" ? body.value.author : "",
          chapterTitle: typeof body.value.chapterTitle === "string" ? body.value.chapterTitle : "",
          sourceLanguage,
          targetLanguage,
          learnerLevel,
        },
      });
      const completed = await completeWithPolicy(
        context,
        "chat",
        principal.accountId,
        {
          jsonObject: true,
          messages: [
            { role: "system", content: assembled.effective.system },
            { role: "user", content: assembled.effective.user },
          ],
        },
        assembled,
        "chat",
        false,
      );
      if (completed === "disabled" || !completed.ok) {
        return qwenFailure(context, "chat", completed);
      }
      const parsed = await validateManagedRouteOutput(context, {
        accountId: principal.accountId,
        eventTask: "chat",
        outputSubtask: "chat",
        text: completed.text,
        model: completed.model,
        promptVersion: policy.promptVersion,
      });
      if (parsed instanceof Response) return parsed;
      const answer = stringField(parsed, "answer") ?? "";
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
        text: answer,
        createdAt,
      });
      await recordUse(
        context, principal.accountId, messageId, "chat", "pending", null, answer,
        completed.model, policy.promptVersion,
        await sha256Hex(`${completed.model}|${policy.systemPrompt}|${policy.userPrompt}`),
      );
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

/** Generates a quiz from an explicit, bounded list; the Worker never reads chapter-wide context here. */
async function createHeardQuiz(context: AssistantRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) return principal;
  const gated = await requireAssistantEnabled(context);
  if (gated !== undefined) return gated;
  const bound = await requireBoundProductDevice(context, principal);
  if (bound instanceof Response) return bound;
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) return body.response;
      if (body.value.task !== "heard_quiz") {
        return badRequestField(context.requestId, "task", "task must be heard_quiz.");
      }
      const chapterId = requiredString(body.value.chapterId, "chapterId", context.requestId);
      if (chapterId instanceof Response) return chapterId;
      const sourceLanguage = requiredString(
        body.value.sourceLanguage,
        "sourceLanguage",
        context.requestId,
      );
      if (sourceLanguage instanceof Response) return sourceLanguage;
      const targetLanguage = requiredString(
        body.value.targetLanguage,
        "targetLanguage",
        context.requestId,
      );
      if (targetLanguage instanceof Response) return targetLanguage;
      const learnerLevel = requiredString(
        body.value.learnerLevel,
        "learnerLevel",
        context.requestId,
      );
      if (learnerLevel instanceof Response) return learnerLevel;
      if (!Array.isArray(body.value.segments) || body.value.segments.length === 0) {
        return badRequestField(context.requestId, "segments", "segments must not be empty.");
      }
      if (body.value.segments.length > 12) {
        return badRequestField(
          context.requestId,
          "segments",
          "segments must contain at most 12 heard sentences.",
        );
      }
      const segments: Array<{ id: string; text: string }> = [];
      for (const value of body.value.segments) {
        if (typeof value !== "object" || value === null || Array.isArray(value)) {
          return badRequestField(context.requestId, "segments", "Every segment needs id and text.");
        }
        const record = value as Record<string, unknown>;
        const id = typeof record.id === "string" ? record.id.trim() : "";
        const text = typeof record.text === "string" ? record.text.trim() : "";
        if (id === "" || text === "") {
          return badRequestField(context.requestId, "segments", "Every segment needs id and text.");
        }
        segments.push({ id, text: text.slice(0, 2000) });
      }
      const allowedSegmentIDs = new Set(segments.map((segment) => segment.id));
      if (allowedSegmentIDs.size !== segments.length) {
        return badRequestField(context.requestId, "segments", "Segment ids must be distinct.");
      }
      const allowed = await consumeQuota(context, principal.accountId, "chat");
      if (!allowed) return quotaExceeded(context.requestId);
      const policy = await resolveAssistantPolicy(context, "chat", principal.accountId);
      const heardContext = segments
        .map((segment) => `HEARD id=${segment.id}: ${segment.text}`)
        .join("\n");
      const assembled = assembleManagedPrompt({
        subtask: "heard_quiz",
        policySystemPrompt: policy.systemPrompt,
        policyUserPrompt: policy.userPrompt,
        schemaVersion: policy.schemaVersion,
        fields: {
          task: "heard_quiz",
          question: "Create a quick retrieval quiz for this completed passage.",
          source: heardContext,
          context: heardContext,
          segments: heardContext,
          chapterId,
          bookTitle: typeof body.value.bookTitle === "string" ? body.value.bookTitle : "",
          author: typeof body.value.author === "string" ? body.value.author : "",
          chapterTitle: typeof body.value.chapterTitle === "string" ? body.value.chapterTitle : "",
          sourceLanguage,
          targetLanguage,
          learnerLevel,
        },
      });
      const completed = await completeWithPolicy(
        context,
        "chat",
        principal.accountId,
        {
          jsonObject: true,
          messages: [
            { role: "system", content: assembled.effective.system },
            { role: "user", content: assembled.effective.user },
          ],
        },
        assembled,
        "heard_quiz",
        false,
      );
      if (completed === "disabled" || !completed.ok) {
        return qwenFailure(context, "heard_quiz", completed);
      }
      const output = validateManagedPromptOutput("heard_quiz", completed.text, {
        allowedSegmentIDs,
      });
      if (!output.valid) {
        recordOperatorEvent({
          kind: "managed_qwen_failed",
          requestId: context.requestId,
          task: "heard_quiz",
          status: "invalid_output",
          summary: "Managed Qwen heard_quiz returned invalid structured output.",
          metadata: { model: completed.model, promptVersion: policy.promptVersion },
        });
        await captureProductEvent(context.ops, {
          accountId: principal.accountId,
          name: "ai.heard_quiz.failed",
          outcome: "failed",
          requestId: context.requestId,
          properties: { reason: "invalid_output" },
        });
        return problemResponse({
          status: 502,
          code: "invalid_upstream_response",
          title: "Invalid upstream response",
          detail: "Managed Qwen returned an invalid heard quiz.",
          traceId: context.requestId,
        });
      }
      recordOperatorEvent({
        kind: "managed_qwen_ok",
        requestId: context.requestId,
        task: "heard_quiz",
        status: "ok",
        summary: `Managed Qwen heard_quiz succeeded with ${completed.model}.`,
        metadata: { model: completed.model, promptVersion: policy.promptVersion },
      });
      await captureProductEvent(context.ops, {
        accountId: principal.accountId,
        name: "ai.heard_quiz.succeeded",
        requestId: context.requestId,
        properties: { model: completed.model },
      });
      const response: HeardQuizResponse = { raw: completed.text };
      return jsonResponse(response);
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

function badRequestField(requestId: string, field: string, message: string): Response {
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: message,
    traceId: requestId,
    fieldErrors: [{ field, message }],
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
      userPrompt: policy.userPrompt,
      schemaVersion: policy.schemaVersion,
      canaryPercent: policy.canaryPercent,
    })),
    task,
    view?.qwen.model ?? "",
    accountId === undefined ? {} : { accountId },
  );
}

function withPolicySystemPrompt(
  _task: string,
  policyPrompt: string,
  messages: readonly QwenMessage[],
): QwenMessage[] {
  const next = [...messages];
  const first = next[0];
  const extra = first?.role === "system" ? first.content : undefined;
  const composed = composeAssistantSystemPrompt(policyPrompt, extra);
  if (first?.role === "system") {
    next[0] = { role: "system", content: composed };
    return next;
  }
  return [{ role: "system", content: composed }, ...next];
}

async function completeWithPolicy(
  context: AssistantRouteContext,
  task: string,
  accountId: string,
  request: QwenCompletionRequest,
  assembled?: ManagedPromptAssembly,
  eventTask = task,
  recordSuccessfulCompletion = true,
): Promise<QwenCompletionResult | "disabled"> {
  if (assembled !== undefined && !assembled.validation.valid) {
    const detail = `Managed prompt contract validation failed: ${Object.values(assembled.validation.fieldErrors).join(" ")}`;
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "managed_prompt_contract_invalid",
        requestId: context.requestId,
        task: eventTask,
        fieldErrors: Object.keys(assembled.validation.fieldErrors),
      }),
    );
    return { ok: false, code: "rejected", usedModel: "", httpStatus: 422, detail };
  }
  const resolved = await resolveAssistantPolicy(context, task, accountId);
  const view = await context.runtime?.view();
  console.warn(
    JSON.stringify({
      level: "warn",
      message: "managed_qwen_request",
      requestId: context.requestId,
      task: eventTask,
      configured: view?.qwen.apiKeyConfigured === true,
      source: view?.qwen.source ?? "none",
      deskModel: view?.qwen.model ?? "",
      policyModel: resolved.source === "policy" ? resolved.model : "",
      usedModel: resolved.model,
      modelSource: resolved.source,
      promptVersion: resolved.promptVersion,
      systemPromptChars: resolved.systemPrompt.length,
      userPromptChars: resolved.userPrompt.length,
      disabled: resolved.disabled,
      wrappingSource: view?.qwen.wrappingSecretSource,
      secretsDecryptable: view?.qwen.secretsDecryptable,
      qwenBaseUrlHost: hostOf(view?.qwen.baseUrl ?? ""),
    }),
  );
  recordOperatorEvent({
    kind: "managed_qwen_request",
    requestId: context.requestId,
    task: eventTask,
    status: resolved.disabled ? "disabled" : "started",
    summary: resolved.disabled
      ? `Managed Qwen ${eventTask} blocked by policy.`
      : `Managed Qwen ${eventTask} using ${resolved.model || "default"} (${resolved.source}).`,
    metadata: {
      model: resolved.model,
      modelSource: resolved.source,
      promptVersion: resolved.promptVersion,
      systemPromptChars: resolved.systemPrompt.length,
      userPromptChars: resolved.userPrompt.length,
    },
  });
  await captureProductEvent(context.ops, {
    accountId,
    name: `ai.${eventTask === "chapter_summary" ? "summary" : eventTask}.started`,
    outcome: "started",
    requestId: context.requestId,
    properties: { model: resolved.model, modelSource: resolved.source },
  });
  if (resolved.disabled) {
    await captureProductEvent(context.ops, {
      accountId,
      name: `ai.${eventTask === "chapter_summary" ? "summary" : eventTask}.failed`,
      outcome: "failed",
      requestId: context.requestId,
      properties: { reason: "disabled" },
    });
    return "disabled";
  }
  const completed = await context.qwen.complete({
    ...request,
    messages:
      assembled === undefined
        ? withPolicySystemPrompt(task, resolved.systemPrompt, request.messages)
        : request.messages,
    ...(resolved.model === "" ? {} : { model: resolved.model }),
  });
  if (completed.ok && recordSuccessfulCompletion) {
    recordOperatorEvent({
      kind: "managed_qwen_ok",
      requestId: context.requestId,
      task: eventTask,
      status: "ok",
      summary: `Managed Qwen ${eventTask} succeeded with ${completed.model}.`,
      metadata: { model: completed.model, promptVersion: resolved.promptVersion },
    });
    await captureProductEvent(context.ops, {
      accountId,
      name: `ai.${eventTask === "chapter_summary" ? "summary" : eventTask}.succeeded`,
      requestId: context.requestId,
      properties: { model: completed.model },
    });
  } else if (!completed.ok) {
    await captureProductEvent(context.ops, {
      accountId,
      name: `ai.${eventTask === "chapter_summary" ? "summary" : eventTask}.failed`,
      outcome: "failed",
      requestId: context.requestId,
      properties: { code: completed.code },
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
  } else if (
    failure?.httpStatus === 422 &&
    failure.detail?.startsWith("Managed prompt contract validation failed:") === true
  ) {
    detail = failure.detail;
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

/** Reject malformed provider content before it can reach a response, cache, or chat history. */
async function validateManagedRouteOutput(
  context: AssistantRouteContext,
  input: {
    accountId: string;
    eventTask: string;
    outputSubtask: ManagedPromptSubtask;
    text: string;
    model: string;
    promptVersion: string;
    expectedTargetIDs?: ReadonlySet<string>;
  },
): Promise<Record<string, unknown> | Response> {
  const output = validateManagedPromptOutput(input.outputSubtask, input.text, {
    ...(input.expectedTargetIDs === undefined
      ? {}
      : { expectedTargetIDs: input.expectedTargetIDs }),
  });
  if (!output.valid || output.parsed === null) {
    recordOperatorEvent({
      kind: "managed_qwen_failed",
      requestId: context.requestId,
      task: input.outputSubtask,
      status: "invalid_output",
      summary: `Managed Qwen ${input.outputSubtask} returned invalid structured output.`,
      metadata: { model: input.model, promptVersion: input.promptVersion },
    });
    await captureProductEvent(context.ops, {
      accountId: input.accountId,
      name: `ai.${input.eventTask === "chapter_summary" ? "summary" : input.eventTask}.failed`,
      outcome: "failed",
      requestId: context.requestId,
      properties: { code: "invalid_output" },
    });
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "managed_qwen_invalid_output",
        requestId: context.requestId,
        task: input.outputSubtask,
        model: input.model,
        errors: output.errors,
      }),
    );
    return problemResponse({
      status: 502,
      code: "invalid_upstream_response",
      title: "Invalid upstream response",
      detail: `Managed Qwen returned invalid ${input.outputSubtask} output.`,
      traceId: context.requestId,
    });
  }
  recordOperatorEvent({
    kind: "managed_qwen_ok",
    requestId: context.requestId,
    task: input.outputSubtask,
    status: "ok",
    summary: `Managed Qwen ${input.outputSubtask} succeeded with ${input.model}.`,
    metadata: { model: input.model, promptVersion: input.promptVersion },
  });
  await captureProductEvent(context.ops, {
    accountId: input.accountId,
    name: `ai.${input.eventTask === "chapter_summary" ? "summary" : input.eventTask}.succeeded`,
    requestId: context.requestId,
    properties: { model: input.model },
  });
  return output.parsed;
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

function cacheLookupMiss(requestId: string, resource: string): Response {
  return problemResponse({
    status: 404,
    code: "not_found",
    title: "Not found",
    detail: `No cached ${resource} matched this request.`,
    traceId: requestId,
  });
}

function withTranslationIdentity(
  result: TranslationResult,
  identity: { targetId: string; source: string },
): TranslationResult {
  return {
    ...result,
    ...(identity.targetId === "" ? {} : { targetId: identity.targetId }),
    ...(identity.source === "" ? {} : { source: identity.source }),
  };
}

function batchResult(
  results: TranslationResult[],
  missingIds: string[],
  cacheHitCount: number,
  generatedCount: number,
): TranslationBatchResult {
  const byTarget = new Map<string, TranslationResult>();
  for (const result of results) {
    const key = result.targetId ?? result.id;
    if (!byTarget.has(key)) {
      byTarget.set(key, result);
    }
  }
  return {
    results: [...byTarget.values()],
    missingIds,
    cacheHitCount,
    generatedCount,
  };
}

function translationSentences(value: unknown, requestId: string): TranslationSentence[] | Response {
  if (!Array.isArray(value) || value.length === 0) {
    return problemResponse({
      status: 400,
      code: "bad_request",
      title: "Bad request",
      detail: "sentences must contain at least one sentence.",
      traceId: requestId,
    });
  }
  const sentences: TranslationSentence[] = [];
  const seen = new Set<string>();
  for (const item of value.slice(0, 40)) {
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const record = item as Record<string, unknown>;
    const id = typeof record.id === "string" ? record.id.trim() : "";
    const text = typeof record.text === "string" ? record.text.trim() : "";
    if (id === "" || text === "" || seen.has(id)) {
      continue;
    }
    seen.add(id);
    const assistantResultId =
      typeof record.assistantResultId === "string" && UUID_PATTERN.test(record.assistantResultId)
        ? record.assistantResultId
        : undefined;
    sentences.push({ id, text, ...(assistantResultId === undefined ? {} : { assistantResultId }) });
  }
  if (sentences.length === 0) {
    return problemResponse({
      status: 400,
      code: "bad_request",
      title: "Bad request",
      detail: "sentences must contain at least one sentence.",
      traceId: requestId,
    });
  }
  return sentences;
}

function parseBatchTranslations(
  text: string,
  expectedIds: string[],
): Map<string, { translation: string; notes: TranslationResult["notes"] }> {
  const parsed = parseObject(text);
  const expected = new Set(expectedIds);
  const units = new Map<string, { translation: string; notes: TranslationResult["notes"] }>();
  const list = Array.isArray(parsed.translations)
    ? parsed.translations
    : Array.isArray(parsed.results)
      ? parsed.results
      : [];
  for (const item of list) {
    if (typeof item !== "object" || item === null) {
      continue;
    }
    const record = item as Record<string, unknown>;
    const id =
      (typeof record.id === "string" && record.id) ||
      (typeof record.targetId === "string" && record.targetId) ||
      "";
    const translation = stringField(record, "translation") ?? "";
    if (id === "" || translation === "" || !expected.has(id) || units.has(id)) {
      continue;
    }
    units.set(id, {
      translation,
      notes: [...learningNotes(record.notes), ...exampleNotes(record.examples)],
    });
  }
  if (units.size === 0 && expectedIds.length === 1) {
    const translation = stringField(parsed, "translation") ?? "";
    if (translation !== "") {
      units.set(expectedIds[0] ?? "", {
        translation,
        notes: [...learningNotes(parsed.notes), ...exampleNotes(parsed.examples)],
      });
    }
  }
  return units;
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
  const storedNotes = learningNotes(cached.payload.notes);
  const notes = storedNotes.some((note) => note.category === "example")
    ? storedNotes
    : [...storedNotes, ...exampleNotes(cached.payload.examples)];
  const targetId = stringField(cached.payload, "targetId") ?? "";
  const source = stringField(cached.payload, "source") ?? "";
  return withTranslationIdentity(
    {
      id: cached.id,
      sharedCacheEntryID: cached.id,
      translation: stringField(cached.payload, "translation") ?? "",
      notes,
      provenance: "cache_shared_exact",
      policyVersion: cached.policyVersion,
      model: stringField(cached.payload, "model") ?? "",
      promptVersion: stringField(cached.payload, "promptVersion") ?? cached.policyVersion,
      modelPolicyHash: stringField(cached.payload, "modelPolicyHash") ?? "",
      createdAt: cached.createdAt,
    },
    { targetId, source },
  );
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
    sharedCacheEntryID: cached.id,
    overview: stringField(cached.payload, "overview") ?? "",
    keyPoints: stringArray(cached.payload, "keyPoints"),
    charactersOrIdeas: stringArray(cached.payload, "charactersOrIdeas"),
    keyConcepts: conceptArray(cached.payload.keyConcepts),
    themes: stringArray(cached.payload, "themes"),
    provenance: "cache_shared_exact",
    model: stringField(cached.payload, "model") ?? "",
    promptVersion: stringField(cached.payload, "promptVersion") ?? cached.policyVersion,
    modelPolicyHash: stringField(cached.payload, "modelPolicyHash") ?? "",
    policyVersion: cached.policyVersion,
    createdAt: cached.createdAt,
  };
}

async function recordUse(
  context: AssistantRouteContext,
  userId: string,
  resultId: string,
  task: string,
  status: "pending" | "replaced",
  cacheEntryId: string | null,
  outputText: string,
  model?: string,
  promptVersion?: string,
  modelPolicyHash?: string,
  details: {
    resultKind?: "sentenceGloss" | "wordGloss" | "chapterSummary" | "chapterTranslation";
    language?: string;
    sourceText?: string;
    contextText?: string;
    bookTitle?: string;
    chapterTitle?: string;
    targetId?: string;
    timestampSeconds?: number;
    privateContent?: Record<string, unknown>;
  } = {},
): Promise<OpsAssistantResult | undefined> {
  return context.ops?.recordAssistantUse(userId, {
    resultId,
    task,
    status,
    cacheEntryId,
    outputText,
    ...(model === undefined ? {} : { model }),
    ...(promptVersion === undefined ? {} : { promptVersion }),
    ...(modelPolicyHash === undefined ? {} : { modelPolicyHash }),
    ...details,
  });
}

function translationPrivateContent(result: TranslationResult): Record<string, unknown> {
  return {
    translation: result.translation,
    notes: result.notes,
    ...(result.targetId === undefined ? {} : { targetId: result.targetId }),
    ...(result.source === undefined ? {} : { source: result.source }),
  };
}

function translationPrivateText(result: TranslationResult): string {
  const notes = result.notes.length === 0
    ? "LEARNING NOTES:\nNone"
    : `LEARNING NOTES:\n${result.notes.map((note) =>
      `• ${note.source} — [${note.category.replaceAll("_", " ")}] ${note.explanation}`).join("\n")}`;
  return `TRANSLATION:\n${result.translation}\n\n${notes}`;
}

function summaryPrivateContent(result: ChapterSummary): Record<string, unknown> {
  return {
    overview: result.overview,
    keyPoints: result.keyPoints,
    charactersOrIdeas: result.charactersOrIdeas ?? [],
    keyConcepts: result.keyConcepts,
    themes: result.themes,
  };
}

/** A cache UUID is shared provenance; every user-visible use gets its own private result UUID. */
async function materializePrivateTranslationResults(
  context: AssistantRouteContext,
  userId: string,
  results: TranslationResult[],
  model: string,
  promptVersion: string,
  modelPolicyHash: string,
  requestedResultIDs: ReadonlyMap<string, string> = new Map(),
  details: {
    language?: string;
    contextText?: string;
    bookTitle?: string;
    chapterTitle?: string;
  } = {},
): Promise<TranslationResult[]> {
  return Promise.all(results.map(async (cached) => {
    const resultId = requestedResultIDs.get(cached.targetId ?? "") ?? crypto.randomUUID();
    const exactModel = cached.model || model;
    const exactPromptVersion = cached.promptVersion || promptVersion;
    const exactModelPolicyHash = cached.modelPolicyHash || modelPolicyHash;
    const cacheEntryId = cached.sharedCacheEntryID ?? null;
    const recorded = await recordUse(
      context, userId, resultId, "translation",
      requestedResultIDs.has(cached.targetId ?? "") ? "replaced" : "pending",
      cacheEntryId, translationPrivateText(cached),
      exactModel, exactPromptVersion, exactModelPolicyHash,
      {
        resultKind: "sentenceGloss",
        ...details,
        ...(cached.source === undefined
          ? {}
          : { sourceText: cached.source }),
        ...(cached.targetId === undefined || cached.targetId === null
          ? {}
          : { targetId: cached.targetId }),
        privateContent: translationPrivateContent(cached),
      },
    );
    return {
      ...cached,
      id: resultId,
      sharedCacheEntryID: recorded?.cacheEntryId ?? null,
      model: exactModel,
      promptVersion: exactPromptVersion,
      modelPolicyHash: exactModelPolicyHash,
    };
  }));
}

/** Persist a shared cache row without failing the caller. The generated payload is already in hand. */
async function persistAssistantCache(
  context: AssistantRouteContext,
  accountId: string,
  entry: Parameters<NonNullable<OpsStore["putCache"]>>[0],
): Promise<string | null> {
  if (context.ops === undefined) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "assistant_cache_put_skipped",
        requestId: context.requestId,
        task: entry.task,
        reason: "ops_unavailable",
      }),
    );
    return null;
  }
  try {
    const stored = await context.ops.putCache(entry);
    console.warn(
      JSON.stringify({
        level: "info",
        message: "assistant_cache_put_ok",
        requestId: context.requestId,
        task: entry.task,
        cacheId: stored.id,
        cacheKey: stored.cacheKey,
      }),
    );
    await captureProductEvent(context.ops, {
      accountId,
      name: `ai.${entry.task === "chapter_summary" ? "summary" : entry.task}.cached`,
      requestId: context.requestId,
      properties: { cacheId: stored.id },
    });
    return stored.id;
  } catch (error: unknown) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "assistant_cache_put_failed",
        requestId: context.requestId,
        task: entry.task,
        detail: error instanceof Error ? error.message : "unknown",
      }),
    );
    await captureProductEvent(context.ops, {
      accountId,
      name: `ai.${entry.task === "chapter_summary" ? "summary" : entry.task}.cache_failed`,
      outcome: "failed",
      requestId: context.requestId,
      properties: { detail: error instanceof Error ? error.message.slice(0, 180) : "unknown" },
    });
    return null;
  }
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
      "example",
    ] as const;
    notes.push({
      source,
      category: allowed.find((entry) => entry === category) ?? "phrase",
      explanation,
    });
  }
  return notes;
}

function exampleNotes(value: unknown): TranslationResult["notes"] {
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
    const translation = typeof record.translation === "string" ? record.translation : "";
    if (source === "" || translation === "") {
      continue;
    }
    notes.push({ source, category: "example", explanation: translation });
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
