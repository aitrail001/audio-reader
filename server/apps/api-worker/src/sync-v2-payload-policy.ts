import type { SyncEntityType } from "@audio-reader/database";

const MAX_PAYLOAD_BYTES = 256 * 1024;
const MAX_DEPTH = 8;
const MAX_ARRAY_ITEMS = 4_096;
const MAX_STRING_BYTES = 64 * 1024;
const INLINE_CONTENT_KEY = /(?:^|_)(?:bytes?|blob|binary|base64|data|content|body)(?:$|_)/i;

const ALLOWED_KEYS: Record<Exclude<SyncEntityType, "transcript" | "asset">, ReadonlySet<string>> = {
  settings: set("sourceLanguage", "targetLanguage", "readerLevel", "playbackRate", "skipSeconds", "appearance"),
  book: set("localId", "title", "author", "source", "chapters"),
  chapter: set("localId", "index", "title", "duration", "startTime", "bookId", "localBookId"),
  progress: set(
    "progressKind", "localProgressId", "bookId", "chapterId", "localBookId", "localChapterId",
    "relativeSeconds", "updatedAt", "deviceId", "revision", "vocabularyId", "reviewCount",
    "nextReview", "lastReviewedAt", "lastReviewQuality", "reviewIntervalDays", "reviewEaseFactor",
  ),
  vocabulary: set(
    "vocabularySchemaVersion", "bookId", "chapterId", "localBookId", "localChapterId", "bookTitle",
    "chapterTitle", "surface", "lemma", "partOfSpeech", "senseId", "canonicalizationSource",
    "canonicalizationConfidence", "canonicalizationStatus", "canonicalizationTraceId", "captureSource",
    "reviewEligible", "category", "context", "timestampSeconds", "state", "definition", "note",
    "segmentId", "wordId", "spokenText", "ebookText", "translationLanguage", "translationModel",
    "sourceLanguage", "localId",
  ),
  lexeme_state: set("language", "lemma", "state"),
  review_event: set("vocabularyId", "cardId", "face", "rating", "reviewedAt"),
  transcript_overlay: set("chapterId", "localChapterId", "segmentId", "overlayJSON"),
  assistant_result: set("result", "vocabulary", "removedVocabularyIDs"),
  chat_message: set("threadId", "messageId", "role", "text", "createdAt"),
  study_activity: set("day"),
};

const NESTED_KEYS: Record<string, ReadonlySet<string>> = {
  chapters: set("localId", "index", "title", "duration", "startTime"),
  result: set(
    "id", "kind", "status", "language", "model", "bookID", "bookTitle", "chapterID", "chapterTitle",
    "source", "text", "context", "timestamp", "createdAt", "decidedAt", "replacedText", "replacedModel",
    "promptVersion", "modelPolicyHash", "sharedCacheEntryID", "targetID", "privateContentJSON",
  ),
  vocabulary: set(
    "id", "bookID", "chapterID", "bookTitle", "chapterTitle", "word", "translation", "definition",
    "context", "timestamp", "addedAt", "category", "segmentID", "wordID", "spokenText", "ebookText",
    "translationLanguage", "translationModel", "sourceLanguage", "canonicalForm", "partOfSpeech", "senseID",
    "canonicalizationSource", "canonicalizationConfidence", "canonicalizationStatus", "canonicalizationTraceID",
    "captureSource", "reviewEligible", "reviewCount", "nextReview", "lastReviewedAt", "lastReviewQuality",
    "reviewIntervalDays", "reviewEaseFactor", "isInLearnList",
  ),
};

export type SyncPayloadProblem = { field: string; message: string };

/** v2 accepts only compact, entity-shaped JSON; immutable bytes have no JSON representation. */
export function validateSyncV2Payload(
  entityType: SyncEntityType,
  payload: Record<string, unknown>,
): SyncPayloadProblem | undefined {
  if (entityType === "transcript" || entityType === "asset") {
    return { field: "entityType", message: "Immutable objects are server-published only." };
  }
  if (new TextEncoder().encode(JSON.stringify(payload)).byteLength > MAX_PAYLOAD_BYTES) {
    return { field: "payload", message: "payload exceeds the compact sync limit." };
  }
  const unknown = Object.keys(payload).find((key) => !ALLOWED_KEYS[entityType].has(key));
  if (unknown !== undefined) {
    return { field: `payload.${unknown}`, message: "field is not allowed for this entity type." };
  }
  return validateValue(payload, "payload", 0);
}

function validateValue(value: unknown, path: string, depth: number): SyncPayloadProblem | undefined {
  if (depth > MAX_DEPTH) return { field: path, message: "nested payload is too deep." };
  if (typeof value === "string" && new TextEncoder().encode(value).byteLength > MAX_STRING_BYTES) {
    return { field: path, message: "string is too large for compact sync." };
  }
  if (Array.isArray(value)) {
    if (value.length > MAX_ARRAY_ITEMS) return { field: path, message: "array has too many items." };
    const schema = NESTED_KEYS[path.split(".").at(-1) ?? ""];
    for (const [index, item] of value.entries()) {
      const problem = validateNestedObject(item, `${path}.${String(index)}`, depth + 1, schema);
      if (problem !== undefined) return problem;
    }
    return undefined;
  }
  if (isRecord(value)) {
    const schema = NESTED_KEYS[path.split(".").at(-1) ?? ""];
    return validateNestedObject(value, path, depth + 1, schema);
  }
  return undefined;
}

function validateNestedObject(
  value: unknown,
  path: string,
  depth: number,
  schema?: ReadonlySet<string>,
): SyncPayloadProblem | undefined {
  if (!isRecord(value)) return validateValue(value, path, depth);
  if (schema === undefined && depth > 1) {
    return { field: path, message: "nested object is not allowed by this entity schema." };
  }
  for (const [key, nested] of Object.entries(value)) {
    if (INLINE_CONTENT_KEY.test(key)) {
      return { field: `${path}.${key}`, message: "inline byte or blob fields are forbidden." };
    }
    if (schema !== undefined && !schema.has(key)) {
      return { field: `${path}.${key}`, message: "nested field is not allowed by this entity schema." };
    }
    const problem = validateValue(nested, `${path}.${key}`, depth);
    if (problem !== undefined) return problem;
  }
  return undefined;
}

function set(...keys: string[]): ReadonlySet<string> { return new Set(keys); }
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
