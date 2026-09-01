import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { CatalogStore, IdentityStore } from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, emptyResponse, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import {
  UUID_PATTERN,
  conflict,
  fieldError,
  isRecord,
  methodNotAllowed,
  notFound,
  pageCursor,
  parseLimit,
  requireBoundDevice,
  requireDeviceId,
  requirePrincipal,
  requiredString,
  requiredUuid,
} from "./route-helpers";

type Book = components["schemas"]["Book"];
type Chapter = components["schemas"]["Chapter"];
type ReadingProgress = components["schemas"]["ReadingProgress"];
type VocabularyOccurrence = components["schemas"]["VocabularyOccurrence"];
type ReviewSchedule = components["schemas"]["ReviewSchedule"];
type Transcript = components["schemas"]["Transcript"];

const BOOK_ITEM = /^\/v1\/books\/([^/]+)$/;
const BOOK_CHAPTERS = /^\/v1\/books\/([^/]+)\/chapters$/;
const BOOK_TRANSCRIPTS = /^\/v1\/books\/([^/]+)\/transcripts$/;
const CHAPTER_ITEM = /^\/v1\/chapters\/([^/]+)$/;
const CHAPTER_TRANSCRIPT = /^\/v1\/chapters\/([^/]+)\/transcript$/;
const PROGRESS_ITEM = /^\/v1\/progress\/([^/]+)$/;
const VOCAB_ITEM = /^\/v1\/vocabulary\/([^/]+)$/;

const METHODS: Record<string, readonly string[]> = {
  "/v1/books": ["GET", "HEAD", "POST"],
  "/v1/books/{bookId}": ["GET", "HEAD", "PATCH", "DELETE"],
  "/v1/books/{bookId}/chapters": ["GET", "HEAD"],
  "/v1/books/{bookId}/transcripts": ["GET", "HEAD", "POST"],
  "/v1/chapters/{chapterId}": ["GET", "HEAD"],
  "/v1/progress/{chapterId}": ["GET", "HEAD", "PUT"],
  "/v1/vocabulary": ["GET", "HEAD", "POST"],
  "/v1/vocabulary/{vocabularyId}": ["GET", "HEAD", "PATCH", "DELETE"],
  "/v1/reviews/due": ["GET", "HEAD"],
  "/v1/reviews": ["POST"],
  "/v1/chapters/{chapterId}/transcript": ["GET", "HEAD"],
  "/v1/transcripts": ["POST"],
};

type Resolved = { route: string; id?: string };

function resolvePath(path: string): Resolved | undefined {
  if (path in METHODS) {
    return { route: path };
  }
  const bookChapters = BOOK_CHAPTERS.exec(path);
  if (bookChapters?.[1] !== undefined) {
    return { route: "/v1/books/{bookId}/chapters", id: bookChapters[1] };
  }
  const bookTranscripts = BOOK_TRANSCRIPTS.exec(path);
  if (bookTranscripts?.[1] !== undefined) {
    return { route: "/v1/books/{bookId}/transcripts", id: bookTranscripts[1] };
  }
  const transcript = CHAPTER_TRANSCRIPT.exec(path);
  if (transcript?.[1] !== undefined) {
    return { route: "/v1/chapters/{chapterId}/transcript", id: transcript[1] };
  }
  const book = BOOK_ITEM.exec(path);
  if (book?.[1] !== undefined) {
    return { route: "/v1/books/{bookId}", id: book[1] };
  }
  const chapter = CHAPTER_ITEM.exec(path);
  if (chapter?.[1] !== undefined) {
    return { route: "/v1/chapters/{chapterId}", id: chapter[1] };
  }
  const progress = PROGRESS_ITEM.exec(path);
  if (progress?.[1] !== undefined) {
    return { route: "/v1/progress/{chapterId}", id: progress[1] };
  }
  const vocab = VOCAB_ITEM.exec(path);
  if (vocab?.[1] !== undefined) {
    return { route: "/v1/vocabulary/{vocabularyId}", id: vocab[1] };
  }
  return undefined;
}

export type LibraryRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  catalog?: CatalogStore;
  identity?: IdentityStore;
};

export function isLibraryPath(path: string): boolean {
  return resolvePath(path) !== undefined;
}

export function libraryMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const resolved = resolvePath(path);
  if (resolved === undefined) {
    return undefined;
  }
  const allowed = METHODS[resolved.route];
  if (allowed === undefined || allowed.includes(method.toUpperCase())) {
    return undefined;
  }
  return methodNotAllowed(allowed, requestId);
}

export async function handleLibraryRoute(
  context: LibraryRouteContext,
): Promise<Response | undefined> {
  const url = new URL(context.request.url);
  const resolved = resolvePath(url.pathname);
  if (resolved === undefined) {
    return undefined;
  }
  const method = context.request.method.toUpperCase();
  const allowed = METHODS[resolved.route];
  if (allowed === undefined || !allowed.includes(method)) {
    return libraryMethodError(url.pathname, method, context.requestId);
  }
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const bound = await requireBoundDevice({
    request: context.request,
    requestId: context.requestId,
    accountId: principal.accountId,
    hasActiveDevice: (accountId, deviceId) =>
      context.identity === undefined
        ? Promise.resolve(false)
        : context.identity.hasActiveDevice(accountId, deviceId),
  });
  if (bound instanceof Response) {
    return bound;
  }
  if (
    resolved.route === "/v1/books/{bookId}/transcripts" ||
    resolved.route === "/v1/chapters/{chapterId}/transcript" ||
    resolved.route === "/v1/transcripts"
  ) {
    return asHead(
      context.request,
      problemResponse({
        status: 426,
        code: "upgrade_required",
        title: "Upgrade required",
        detail: "Inline transcript APIs are retired. Upgrade to v2 transcript revision assets.",
        traceId: context.requestId,
        headers: { "X-Min-App-Version": "2.0.0" },
      }),
    );
  }
  const catalog = context.catalog;
  if (catalog === undefined) {
    return notFound(context.requestId, "Library is not configured.");
  }
  if (resolved.route === "/v1/books" && (method === "GET" || method === "HEAD")) {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const books = await catalog.listBooks(principal.accountId);
    const page = pageCursor(books.map(toBook), url.searchParams.get("cursor"), limit);
    return asHead(context.request, jsonResponse(page));
  }
  if (resolved.route === "/v1/books" && method === "POST") {
    return createBook(context, principal, catalog);
  }
  if (resolved.route === "/v1/books/{bookId}" && resolved.id !== undefined) {
    return bookItem(context, principal, catalog, resolved.id, method);
  }
  if (resolved.route === "/v1/books/{bookId}/chapters" && resolved.id !== undefined) {
    const book = await catalog.getBook(principal.accountId, resolved.id);
    if (book === undefined) {
      return notFound(context.requestId);
    }
    const chapters = await catalog.listChapters(principal.accountId, resolved.id);
    return asHead(context.request, jsonResponse(chapters.map(toChapter)));
  }
  if (resolved.route === "/v1/chapters/{chapterId}" && resolved.id !== undefined) {
    const chapter = await catalog.getChapter(principal.accountId, resolved.id);
    return chapter === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toChapter(chapter)));
  }
  if (resolved.route === "/v1/progress/{chapterId}" && resolved.id !== undefined) {
    return progressItem(context, principal, catalog, resolved.id, method);
  }
  if (resolved.route === "/v1/vocabulary" && (method === "GET" || method === "HEAD")) {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const bookId = url.searchParams.get("bookId") ?? undefined;
    const items = await catalog.listVocabulary(principal.accountId, bookId);
    const page = pageCursor(items.map(toVocabulary), url.searchParams.get("cursor"), limit);
    return asHead(context.request, jsonResponse(page));
  }
  if (resolved.route === "/v1/vocabulary" && method === "POST") {
    return createVocabulary(context, principal, catalog);
  }
  if (resolved.route === "/v1/vocabulary/{vocabularyId}" && resolved.id !== undefined) {
    return vocabularyItem(context, principal, catalog, resolved.id, method);
  }
  if (resolved.route === "/v1/reviews/due") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const due = await catalog.listDueReviews(principal.accountId, new Date().toISOString());
    const page = pageCursor(due.map(toSchedule), url.searchParams.get("cursor"), limit);
    return asHead(context.request, jsonResponse(page));
  }
  if (resolved.route === "/v1/reviews") {
    return submitReviews(context, principal, catalog);
  }
  if (resolved.route === "/v1/chapters/{chapterId}/transcript" && resolved.id !== undefined) {
    const transcript = await catalog.getActiveTranscript(principal.accountId, resolved.id);
    return transcript === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toTranscript(transcript)));
  }
  if (resolved.route === "/v1/transcripts") {
    return createTranscript(context, principal, catalog);
  }
  return undefined;
}

async function createBook(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const clientId = requiredUuid(body.value.clientId, "clientId", context.requestId);
      if (clientId instanceof Response) {
        return clientId;
      }
      const title = requiredString(body.value.title, "title", context.requestId);
      if (title instanceof Response) {
        return title;
      }
      const editionFingerprint = requiredString(
        body.value.editionFingerprint,
        "editionFingerprint",
        context.requestId,
      );
      if (editionFingerprint instanceof Response) {
        return editionFingerprint;
      }
      const fingerprintVersion = body.value.fingerprintVersion;
      if (typeof fingerprintVersion !== "number" || fingerprintVersion < 1) {
        return fieldError(
          context.requestId,
          "fingerprintVersion",
          "fingerprintVersion must be >= 1.",
        );
      }
      const source = body.value.source;
      if (
        source !== "local_folder" &&
        source !== "files" &&
        source !== "device_audiobooks" &&
        source !== "remote_backup"
      ) {
        return fieldError(context.requestId, "source", "source is invalid.");
      }
      if (!Array.isArray(body.value.chapters)) {
        return fieldError(context.requestId, "chapters", "chapters must be an array.");
      }
      const chapters: {
        clientId: string;
        index: number;
        title: string;
        chapterFingerprint: string;
        durationSeconds: number;
        startSeconds?: number;
      }[] = [];
      for (const [index, item] of body.value.chapters.entries()) {
        if (!isRecord(item)) {
          return fieldError(
            context.requestId,
            `chapters.${String(index)}`,
            "chapter must be an object.",
          );
        }
        const chapterId = requiredUuid(
          item.clientId,
          `chapters.${String(index)}.clientId`,
          context.requestId,
        );
        if (chapterId instanceof Response) {
          return chapterId;
        }
        const chapterTitle = requiredString(
          item.title,
          `chapters.${String(index)}.title`,
          context.requestId,
        );
        if (chapterTitle instanceof Response) {
          return chapterTitle;
        }
        const fingerprint = requiredString(
          item.chapterFingerprint,
          `chapters.${String(index)}.chapterFingerprint`,
          context.requestId,
        );
        if (fingerprint instanceof Response) {
          return fingerprint;
        }
        if (typeof item.index !== "number" || typeof item.durationSeconds !== "number") {
          return fieldError(
            context.requestId,
            `chapters.${String(index)}`,
            "index and durationSeconds are required.",
          );
        }
        chapters.push({
          clientId: chapterId,
          index: item.index,
          title: chapterTitle,
          chapterFingerprint: fingerprint,
          durationSeconds: item.durationSeconds,
          ...(typeof item.startSeconds === "number" ? { startSeconds: item.startSeconds } : {}),
        });
      }
      const created = await catalog.createBook(principal.accountId, {
        clientId,
        title,
        author: typeof body.value.author === "string" ? body.value.author : null,
        editionFingerprint,
        fingerprintVersion,
        source,
        chapters,
      });
      return jsonResponse(toBook(created), 201);
    },
    context.requestId,
    principal,
  );
}

async function bookItem(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
  bookId: string,
  method: string,
): Promise<Response> {
  if (!UUID_PATTERN.test(bookId)) {
    return fieldError(context.requestId, "bookId", "bookId must be a UUID.");
  }
  if (method === "GET" || method === "HEAD") {
    const book = await catalog.getBook(principal.accountId, bookId);
    return book === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toBook(book)));
  }
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (method === "DELETE") {
    return withIdempotency(
      context.idempotencyStore,
      context.request,
      async () => {
        const deleted = await catalog.deleteBook(principal.accountId, bookId);
        return deleted ? emptyResponse() : notFound(context.requestId);
      },
      context.requestId,
      principal,
    );
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.baseRevision !== "number") {
        return fieldError(context.requestId, "baseRevision", "baseRevision is required.");
      }
      const patched = await catalog.patchBook(principal.accountId, bookId, {
        baseRevision: body.value.baseRevision,
        ...(typeof body.value.title === "string" ? { title: body.value.title } : {}),
        ...(body.value.author === null || typeof body.value.author === "string"
          ? { author: body.value.author }
          : {}),
      });
      if (patched === undefined) {
        return notFound(context.requestId);
      }
      if (patched === "conflict") {
        return conflict(context.requestId);
      }
      return jsonResponse(toBook(patched));
    },
    context.requestId,
    principal,
  );
}

async function progressItem(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
  chapterId: string,
  method: string,
): Promise<Response> {
  if (!UUID_PATTERN.test(chapterId)) {
    return fieldError(context.requestId, "chapterId", "chapterId must be a UUID.");
  }
  if (method === "GET" || method === "HEAD") {
    const progress = await catalog.getProgress(principal.accountId, chapterId);
    return progress === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toProgress(progress)));
  }
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (
        typeof body.value.positionSeconds !== "number" ||
        typeof body.value.baseRevision !== "number"
      ) {
        return fieldError(
          context.requestId,
          "positionSeconds",
          "positionSeconds and baseRevision are required.",
        );
      }
      const updated = await catalog.putProgress(principal.accountId, chapterId, deviceId, {
        positionSeconds: body.value.positionSeconds,
        completed: body.value.completed === true,
        baseRevision: body.value.baseRevision,
        explicitSeek: body.value.explicitSeek === true,
      });
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      if (updated === "conflict") {
        return conflict(context.requestId);
      }
      return jsonResponse(toProgress(updated));
    },
    context.requestId,
    principal,
  );
}

async function createVocabulary(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const clientId = requiredUuid(body.value.clientId, "clientId", context.requestId);
      if (clientId instanceof Response) {
        return clientId;
      }
      const bookId = requiredUuid(body.value.bookId, "bookId", context.requestId);
      if (bookId instanceof Response) {
        return bookId;
      }
      const chapterId = requiredUuid(body.value.chapterId, "chapterId", context.requestId);
      if (chapterId instanceof Response) {
        return chapterId;
      }
      const surface = requiredString(body.value.surface, "surface", context.requestId);
      if (surface instanceof Response) {
        return surface;
      }
      const lemma = requiredString(body.value.lemma, "lemma", context.requestId);
      if (lemma instanceof Response) {
        return lemma;
      }
      const contextText = requiredString(body.value.context, "context", context.requestId);
      if (contextText instanceof Response) {
        return contextText;
      }
      const category = body.value.category;
      if (category !== "word" && category !== "phrase" && category !== "sentence") {
        return fieldError(context.requestId, "category", "category is invalid.");
      }
      const state = body.value.state;
      if (state !== "unknown" && state !== "learning" && state !== "known" && state !== "ignored") {
        return fieldError(context.requestId, "state", "state is invalid.");
      }
      if (typeof body.value.timestampSeconds !== "number") {
        return fieldError(context.requestId, "timestampSeconds", "timestampSeconds is required.");
      }
      const created = await catalog.createVocabulary(principal.accountId, {
        id: clientId,
        bookId,
        chapterId,
        surface,
        lemma,
        category,
        context: contextText,
        timestampSeconds: body.value.timestampSeconds,
        state,
        segmentId: typeof body.value.segmentId === "string" ? body.value.segmentId : null,
        wordId: typeof body.value.wordId === "string" ? body.value.wordId : null,
        definition: typeof body.value.definition === "string" ? body.value.definition : null,
        note: typeof body.value.note === "string" ? body.value.note : null,
      });
      return jsonResponse(toVocabulary(created), 201);
    },
    context.requestId,
    principal,
  );
}

async function vocabularyItem(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
  vocabularyId: string,
  method: string,
): Promise<Response> {
  if (!UUID_PATTERN.test(vocabularyId)) {
    return fieldError(context.requestId, "vocabularyId", "vocabularyId must be a UUID.");
  }
  if (method === "GET" || method === "HEAD") {
    const item = await catalog.getVocabulary(principal.accountId, vocabularyId);
    return item === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toVocabulary(item)));
  }
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (method === "DELETE") {
    return withIdempotency(
      context.idempotencyStore,
      context.request,
      async () => {
        const deleted = await catalog.deleteVocabulary(principal.accountId, vocabularyId);
        return deleted ? emptyResponse() : notFound(context.requestId);
      },
      context.requestId,
      principal,
    );
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.baseRevision !== "number") {
        return fieldError(context.requestId, "baseRevision", "baseRevision is required.");
      }
      const state = body.value.state;
      const patched = await catalog.patchVocabulary(principal.accountId, vocabularyId, {
        baseRevision: body.value.baseRevision,
        ...(typeof body.value.definition === "string" || body.value.definition === null
          ? { definition: body.value.definition }
          : {}),
        ...(typeof body.value.note === "string" || body.value.note === null
          ? { note: body.value.note }
          : {}),
        ...(state === "unknown" || state === "learning" || state === "known" || state === "ignored"
          ? { state }
          : {}),
      });
      if (patched === undefined) {
        return notFound(context.requestId);
      }
      if (patched === "conflict") {
        return conflict(context.requestId);
      }
      return jsonResponse(toVocabulary(patched));
    },
    context.requestId,
    principal,
  );
}

async function submitReviews(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (!Array.isArray(body.value.events) || body.value.events.length < 1) {
        return fieldError(context.requestId, "events", "events must contain at least one item.");
      }
      const events = [];
      for (const [index, item] of body.value.events.entries()) {
        if (!isRecord(item)) {
          return fieldError(
            context.requestId,
            `events.${String(index)}`,
            "event must be an object.",
          );
        }
        const id = requiredUuid(item.id, `events.${String(index)}.id`, context.requestId);
        if (id instanceof Response) {
          return id;
        }
        const vocabularyId = requiredUuid(
          item.vocabularyId,
          `events.${String(index)}.vocabularyId`,
          context.requestId,
        );
        if (vocabularyId instanceof Response) {
          return vocabularyId;
        }
        if (
          typeof item.face !== "string" ||
          typeof item.rating !== "number" ||
          typeof item.reviewedAt !== "string"
        ) {
          return fieldError(
            context.requestId,
            `events.${String(index)}`,
            "face, rating, and reviewedAt are required.",
          );
        }
        events.push({
          id,
          vocabularyId,
          face: item.face,
          rating: item.rating,
          reviewedAt: item.reviewedAt,
          deviceId,
          responseTimeMs: typeof item.responseTimeMs === "number" ? item.responseTimeMs : null,
        });
      }
      const schedules = await catalog.submitReviews(principal.accountId, deviceId, events);
      return jsonResponse({ schedules: schedules.map(toSchedule) });
    },
    context.requestId,
    principal,
  );
}

async function createTranscript(
  context: LibraryRouteContext,
  principal: Principal,
  catalog: CatalogStore,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const clientId = requiredUuid(body.value.clientId, "clientId", context.requestId);
      if (clientId instanceof Response) {
        return clientId;
      }
      const chapterId = requiredUuid(body.value.chapterId, "chapterId", context.requestId);
      if (chapterId instanceof Response) {
        return chapterId;
      }
      const engine = requiredString(body.value.engine, "engine", context.requestId);
      if (engine instanceof Response) {
        return engine;
      }
      const locale = requiredString(body.value.locale, "locale", context.requestId);
      if (locale instanceof Response) {
        return locale;
      }
      const fingerprint = requiredString(
        body.value.chapterFingerprint,
        "chapterFingerprint",
        context.requestId,
      );
      if (fingerprint instanceof Response) {
        return fingerprint;
      }
      if (!Array.isArray(body.value.segments)) {
        return fieldError(context.requestId, "segments", "segments must be an array.");
      }
      const created = await catalog.createTranscript(principal.accountId, {
        id: clientId,
        chapterId,
        engine,
        engineVersion:
          typeof body.value.engineVersion === "string" ? body.value.engineVersion : null,
        locale,
        chapterFingerprint: fingerprint,
        segments: body.value.segments,
        quality: isRecord(body.value.quality) ? body.value.quality : {},
        ebookAlignment: isRecord(body.value.ebookAlignment) ? body.value.ebookAlignment : null,
      });
      return jsonResponse(toTranscript(created), 201);
    },
    context.requestId,
    principal,
  );
}

function toBook(book: Awaited<ReturnType<CatalogStore["createBook"]>>): Book {
  return {
    id: book.id,
    accountId: book.accountId,
    title: book.title,
    author: book.author,
    editionFingerprint: book.editionFingerprint,
    fingerprintVersion: book.fingerprintVersion,
    source: book.source,
    chapterCount: book.chapterCount,
    revision: book.revision,
    createdAt: book.createdAt,
    updatedAt: book.updatedAt,
    deletedAt: book.deletedAt,
    audioManifestHash: book.audioManifestHash,
    ebookTextHash: book.ebookTextHash,
    workId: book.workId,
    editionId: book.editionId,
    coverAssetId: book.coverAssetId,
  };
}

function toChapter(chapter: Awaited<ReturnType<CatalogStore["listChapters"]>>[number]): Chapter {
  return {
    id: chapter.id,
    bookId: chapter.bookId,
    index: chapter.index,
    title: chapter.title,
    chapterFingerprint: chapter.chapterFingerprint,
    durationSeconds: chapter.durationSeconds,
    audioAssetId: chapter.audioAssetId,
    revision: chapter.revision,
    createdAt: chapter.createdAt,
    updatedAt: chapter.updatedAt,
    ...(chapter.startSeconds === null ? {} : { startSeconds: chapter.startSeconds }),
  };
}

function toProgress(
  progress: NonNullable<Awaited<ReturnType<CatalogStore["getProgress"]>>>,
): ReadingProgress {
  return {
    chapterId: progress.chapterId,
    positionSeconds: progress.positionSeconds,
    completed: progress.completed,
    revision: progress.revision,
    deviceId: progress.deviceId,
    updatedAt: progress.updatedAt,
    explicitSeek: progress.explicitSeek,
    ...(progress.segmentId === null ? {} : { segmentId: progress.segmentId }),
    ...(progress.wordId === null ? {} : { wordId: progress.wordId }),
  };
}

function toVocabulary(
  item: NonNullable<Awaited<ReturnType<CatalogStore["getVocabulary"]>>>,
): VocabularyOccurrence {
  return {
    id: item.id,
    bookId: item.bookId,
    chapterId: item.chapterId,
    surface: item.surface,
    lemma: item.lemma,
    category: item.category,
    context: item.context,
    timestampSeconds: item.timestampSeconds,
    state: item.state,
    revision: item.revision,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
    deletedAt: item.deletedAt,
    definition: item.definition,
    note: item.note,
    ...(item.segmentId === null ? {} : { segmentId: item.segmentId }),
    ...(item.wordId === null ? {} : { wordId: item.wordId }),
  };
}

function toSchedule(
  item: Awaited<ReturnType<CatalogStore["listDueReviews"]>>[number],
): ReviewSchedule {
  return {
    vocabularyId: item.vocabularyId,
    dueAt: item.dueAt,
    stability: item.stability,
    difficulty: item.difficulty,
    reviewCount: item.reviewCount,
    lastReviewedAt: item.lastReviewedAt,
    updatedAt: item.updatedAt,
  };
}

function toTranscript(
  item: NonNullable<Awaited<ReturnType<CatalogStore["getActiveTranscript"]>>>,
): Transcript {
  return {
    id: item.id,
    chapterId: item.chapterId,
    version: item.version,
    engine: item.engine,
    locale: item.locale,
    chapterFingerprint: item.chapterFingerprint,
    segments: item.segments as Transcript["segments"],
    quality: item.quality,
    ebookAlignment: item.ebookAlignment,
    active: item.active,
    createdAt: item.createdAt,
    ...(item.engineVersion === null ? {} : { engineVersion: item.engineVersion }),
  };
}
