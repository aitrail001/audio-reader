import { restRow, restRows, type RestClient } from "./rest";

export type CatalogBook = {
  id: string;
  accountId: string;
  title: string;
  author: string | null;
  editionFingerprint: string;
  fingerprintVersion: number;
  source: "local_folder" | "files" | "device_audiobooks" | "remote_backup";
  chapterCount: number;
  revision: number;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  audioManifestHash: string | null;
  ebookTextHash: string | null;
  workId: string | null;
  editionId: string | null;
  coverAssetId: string | null;
};

export type CatalogChapter = {
  id: string;
  bookId: string;
  index: number;
  title: string;
  chapterFingerprint: string;
  durationSeconds: number;
  startSeconds: number | null;
  audioAssetId: string | null;
  revision: number;
  createdAt: string;
  updatedAt: string;
};

export type CatalogProgress = {
  chapterId: string;
  positionSeconds: number;
  completed: boolean;
  revision: number;
  deviceId: string;
  updatedAt: string;
  segmentId: string | null;
  wordId: string | null;
  explicitSeek: boolean;
};

export type CatalogVocabulary = {
  id: string;
  bookId: string;
  chapterId: string;
  surface: string;
  lemma: string;
  category: "word" | "phrase" | "sentence";
  context: string;
  timestampSeconds: number;
  state: "unknown" | "learning" | "known" | "ignored";
  revision: number;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  segmentId: string | null;
  wordId: string | null;
  definition: string | null;
  note: string | null;
};

export type CatalogReviewEvent = {
  id: string;
  vocabularyId: string;
  face: string;
  rating: number;
  reviewedAt: string;
  deviceId: string;
  responseTimeMs: number | null;
};

export type CatalogReviewSchedule = {
  vocabularyId: string;
  dueAt: string;
  stability: number;
  difficulty: number;
  reviewCount: number;
  lastReviewedAt: string | null;
  updatedAt: string;
};

export type CatalogTranscript = {
  id: string;
  chapterId: string;
  version: number;
  engine: string;
  engineVersion: string | null;
  locale: string;
  chapterFingerprint: string;
  segments: unknown[];
  quality: Record<string, unknown>;
  ebookAlignment: Record<string, unknown> | null;
  active: boolean;
  createdAt: string;
};

export type CatalogLemma = {
  id: string;
  language: string;
  lemma: string;
  state: CatalogVocabulary["state"];
  revision: number;
  updatedAt: string;
};

export type CatalogStore = {
  listBooks(userId: string): Promise<CatalogBook[]>;
  createBook(
    userId: string,
    input: {
      clientId: string;
      title: string;
      author?: string | null;
      editionFingerprint: string;
      fingerprintVersion: number;
      source: CatalogBook["source"];
      audioManifestHash?: string | null;
      ebookTextHash?: string | null;
      chapters: {
        clientId: string;
        index: number;
        title: string;
        chapterFingerprint: string;
        durationSeconds: number;
        startSeconds?: number;
      }[];
    },
  ): Promise<CatalogBook>;
  getBook(userId: string, bookId: string): Promise<CatalogBook | undefined>;
  patchBook(
    userId: string,
    bookId: string,
    patch: { baseRevision: number; title?: string; author?: string | null },
  ): Promise<CatalogBook | "conflict" | undefined>;
  deleteBook(userId: string, bookId: string): Promise<boolean>;
  listChapters(userId: string, bookId: string): Promise<CatalogChapter[]>;
  getChapter(userId: string, chapterId: string): Promise<CatalogChapter | undefined>;
  getProgress(userId: string, chapterId: string): Promise<CatalogProgress | undefined>;
  putProgress(
    userId: string,
    chapterId: string,
    deviceId: string,
    input: {
      positionSeconds: number;
      completed: boolean;
      baseRevision: number;
      explicitSeek: boolean;
      segmentId?: string | null;
      wordId?: string | null;
    },
  ): Promise<CatalogProgress | "conflict" | undefined>;
  listVocabulary(userId: string, bookId?: string): Promise<CatalogVocabulary[]>;
  createVocabulary(
    userId: string,
    input: Omit<CatalogVocabulary, "revision" | "createdAt" | "updatedAt" | "deletedAt">,
  ): Promise<CatalogVocabulary>;
  getVocabulary(userId: string, id: string): Promise<CatalogVocabulary | undefined>;
  patchVocabulary(
    userId: string,
    id: string,
    patch: {
      baseRevision: number;
      definition?: string | null;
      note?: string | null;
      state?: CatalogVocabulary["state"];
    },
  ): Promise<CatalogVocabulary | "conflict" | undefined>;
  deleteVocabulary(userId: string, id: string): Promise<boolean>;
  listDueReviews(userId: string, nowIso: string): Promise<CatalogReviewSchedule[]>;
  submitReviews(
    userId: string,
    deviceId: string,
    events: CatalogReviewEvent[],
  ): Promise<CatalogReviewSchedule[]>;
  getActiveTranscript(userId: string, chapterId: string): Promise<CatalogTranscript | undefined>;
  createTranscript(
    userId: string,
    input: Omit<CatalogTranscript, "version" | "active" | "createdAt">,
  ): Promise<CatalogTranscript>;
  listLemmas(userId: string): Promise<CatalogLemma[]>;
  upsertLemma(
    userId: string,
    input: { id: string; language: string; lemma: string; state: CatalogVocabulary["state"] },
  ): Promise<CatalogLemma>;
};

export function createMemoryCatalogStore(): CatalogStore {
  const books = new Map<string, CatalogBook>();
  const chapters = new Map<string, CatalogChapter>();
  const progress = new Map<string, CatalogProgress>();
  const vocabulary = new Map<string, CatalogVocabulary>();
  const reviews = new Map<string, CatalogReviewSchedule>();
  const transcripts = new Map<string, CatalogTranscript[]>();
  const lemmas = new Map<string, CatalogLemma>();

  function bookKey(userId: string, id: string): string {
    return `${userId}:${id}`;
  }

  function ownsBook(userId: string, bookId: string): boolean {
    const book = books.get(bookKey(userId, bookId));
    return book !== undefined && book.accountId === userId && book.deletedAt === null;
  }

  return {
    listBooks(userId) {
      const items = [...books.values()]
        .filter((book) => book.accountId === userId && book.deletedAt === null)
        .sort((left, right) => left.createdAt.localeCompare(right.createdAt));
      return Promise.resolve(items.map((book) => ({ ...book })));
    },

    createBook(userId, input) {
      const now = new Date().toISOString();
      const book: CatalogBook = {
        id: input.clientId,
        accountId: userId,
        title: input.title,
        author: input.author ?? null,
        editionFingerprint: input.editionFingerprint,
        fingerprintVersion: input.fingerprintVersion,
        source: input.source,
        chapterCount: input.chapters.length,
        revision: 0,
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
        audioManifestHash: input.audioManifestHash ?? null,
        ebookTextHash: input.ebookTextHash ?? null,
        workId: null,
        editionId: null,
        coverAssetId: null,
      };
      books.set(bookKey(userId, book.id), book);
      for (const chapter of input.chapters) {
        chapters.set(bookKey(userId, chapter.clientId), {
          id: chapter.clientId,
          bookId: book.id,
          index: chapter.index,
          title: chapter.title,
          chapterFingerprint: chapter.chapterFingerprint,
          durationSeconds: chapter.durationSeconds,
          startSeconds: chapter.startSeconds ?? null,
          audioAssetId: null,
          revision: 0,
          createdAt: now,
          updatedAt: now,
        });
      }
      return Promise.resolve({ ...book });
    },

    getBook(userId, bookId) {
      const book = books.get(bookKey(userId, bookId));
      return Promise.resolve(
        book === undefined || book.deletedAt !== null ? undefined : { ...book },
      );
    },

    patchBook(userId, bookId, patch) {
      const book = books.get(bookKey(userId, bookId));
      if (book === undefined || book.deletedAt !== null) {
        return Promise.resolve(undefined);
      }
      if (book.revision !== patch.baseRevision) {
        return Promise.resolve("conflict");
      }
      if (patch.title !== undefined) {
        book.title = patch.title;
      }
      if (patch.author !== undefined) {
        book.author = patch.author;
      }
      book.revision += 1;
      book.updatedAt = new Date().toISOString();
      return Promise.resolve({ ...book });
    },

    deleteBook(userId, bookId) {
      const book = books.get(bookKey(userId, bookId));
      if (book === undefined || book.deletedAt !== null) {
        return Promise.resolve(false);
      }
      book.deletedAt = new Date().toISOString();
      book.updatedAt = book.deletedAt;
      return Promise.resolve(true);
    },

    listChapters(userId, bookId) {
      if (!ownsBook(userId, bookId)) {
        return Promise.resolve([]);
      }
      const items = [...chapters.values()]
        .filter((chapter) => chapter.bookId === bookId && ownsBook(userId, bookId))
        .sort((left, right) => left.index - right.index);
      return Promise.resolve(items.map((chapter) => ({ ...chapter })));
    },

    getChapter(userId, chapterId) {
      const chapter = chapters.get(bookKey(userId, chapterId));
      if (chapter === undefined || !ownsBook(userId, chapter.bookId)) {
        return Promise.resolve(undefined);
      }
      return Promise.resolve({ ...chapter });
    },

    getProgress(userId, chapterId) {
      const chapter = chapters.get(bookKey(userId, chapterId));
      if (chapter === undefined || !ownsBook(userId, chapter.bookId)) {
        return Promise.resolve(undefined);
      }
      const current = progress.get(bookKey(userId, chapterId));
      return Promise.resolve(current === undefined ? undefined : { ...current });
    },

    putProgress(userId, chapterId, deviceId, input) {
      const chapter = chapters.get(bookKey(userId, chapterId));
      if (chapter === undefined || !ownsBook(userId, chapter.bookId)) {
        return Promise.resolve(undefined);
      }
      const key = bookKey(userId, chapterId);
      const current = progress.get(key);
      if (current !== undefined && current.revision !== input.baseRevision) {
        return Promise.resolve("conflict");
      }
      const next: CatalogProgress = {
        chapterId,
        positionSeconds: input.positionSeconds,
        completed: input.completed,
        revision: (current?.revision ?? 0) + 1,
        deviceId,
        updatedAt: new Date().toISOString(),
        segmentId: input.segmentId ?? null,
        wordId: input.wordId ?? null,
        explicitSeek: input.explicitSeek,
      };
      progress.set(key, next);
      return Promise.resolve({ ...next });
    },

    listVocabulary(userId, bookId) {
      const items = [...vocabulary.values()].filter((item) => {
        if (item.deletedAt !== null || !ownsBook(userId, item.bookId)) {
          return false;
        }
        return bookId === undefined || item.bookId === bookId;
      });
      return Promise.resolve(items.map((item) => ({ ...item })));
    },

    createVocabulary(userId, input) {
      const now = new Date().toISOString();
      const created: CatalogVocabulary = {
        ...input,
        revision: 0,
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
      };
      vocabulary.set(bookKey(userId, created.id), created);
      return Promise.resolve({ ...created });
    },

    getVocabulary(userId, id) {
      const item = vocabulary.get(bookKey(userId, id));
      return Promise.resolve(
        item === undefined || item.deletedAt !== null ? undefined : { ...item },
      );
    },

    patchVocabulary(userId, id, patch) {
      const item = vocabulary.get(bookKey(userId, id));
      if (item === undefined || item.deletedAt !== null) {
        return Promise.resolve(undefined);
      }
      if (item.revision !== patch.baseRevision) {
        return Promise.resolve("conflict");
      }
      if (patch.definition !== undefined) {
        item.definition = patch.definition;
      }
      if (patch.note !== undefined) {
        item.note = patch.note;
      }
      if (patch.state !== undefined) {
        item.state = patch.state;
      }
      item.revision += 1;
      item.updatedAt = new Date().toISOString();
      return Promise.resolve({ ...item });
    },

    deleteVocabulary(userId, id) {
      const item = vocabulary.get(bookKey(userId, id));
      if (item === undefined || item.deletedAt !== null) {
        return Promise.resolve(false);
      }
      item.deletedAt = new Date().toISOString();
      item.updatedAt = item.deletedAt;
      return Promise.resolve(true);
    },

    listDueReviews(userId, nowIso) {
      const items = [...reviews.entries()]
        .filter(([key, schedule]) => key.startsWith(`${userId}:`) && schedule.dueAt <= nowIso)
        .map(([, schedule]) => ({ ...schedule }));
      return Promise.resolve(items);
    },

    submitReviews(userId, deviceId, events) {
      void deviceId;
      const now = new Date().toISOString();
      const updated: CatalogReviewSchedule[] = [];
      for (const event of events) {
        const key = bookKey(userId, event.vocabularyId);
        const current = reviews.get(key);
        const due = new Date(
          Date.parse(event.reviewedAt) + event.rating * 86_400_000,
        ).toISOString();
        const next: CatalogReviewSchedule = {
          vocabularyId: event.vocabularyId,
          dueAt: due,
          stability: (current?.stability ?? 0) + event.rating,
          difficulty: current?.difficulty ?? 5,
          reviewCount: (current?.reviewCount ?? 0) + 1,
          lastReviewedAt: event.reviewedAt,
          updatedAt: now,
        };
        reviews.set(key, next);
        updated.push({ ...next });
      }
      return Promise.resolve(updated);
    },

    getActiveTranscript(userId, chapterId) {
      const list = transcripts.get(bookKey(userId, chapterId)) ?? [];
      const active = [...list].reverse().find((item) => item.active);
      return Promise.resolve(
        active === undefined ? undefined : { ...active, segments: [...active.segments] },
      );
    },

    createTranscript(userId, input) {
      const key = bookKey(userId, input.chapterId);
      const list = transcripts.get(key) ?? [];
      for (const item of list) {
        item.active = false;
      }
      const created: CatalogTranscript = {
        ...input,
        version: list.length + 1,
        active: true,
        createdAt: new Date().toISOString(),
      };
      list.push(created);
      transcripts.set(key, list);
      return Promise.resolve({ ...created, segments: [...created.segments] });
    },

    listLemmas(userId) {
      const items = [...lemmas.entries()]
        .filter(([key]) => key.startsWith(`${userId}:`))
        .map(([, lemma]) => ({ ...lemma }));
      return Promise.resolve(items);
    },

    upsertLemma(userId, input) {
      const now = new Date().toISOString();
      const key = bookKey(userId, input.id);
      const existing = lemmas.get(key);
      const next: CatalogLemma = {
        id: input.id,
        language: input.language,
        lemma: input.lemma,
        state: input.state,
        revision: (existing?.revision ?? 0) + (existing === undefined ? 0 : 1),
        updatedAt: now,
      };
      lemmas.set(key, next);
      return Promise.resolve({ ...next });
    },
  };
}

export function createUnavailableCatalogStore(): CatalogStore {
  const fail = () => Promise.reject(new Error("database unavailable"));
  return {
    listBooks: fail,
    createBook: fail,
    getBook: () => Promise.resolve(undefined),
    patchBook: () => Promise.resolve(undefined),
    deleteBook: () => Promise.resolve(false),
    listChapters: () => Promise.resolve([]),
    getChapter: () => Promise.resolve(undefined),
    getProgress: () => Promise.resolve(undefined),
    putProgress: () => Promise.resolve(undefined),
    listVocabulary: () => Promise.resolve([]),
    createVocabulary: fail,
    getVocabulary: () => Promise.resolve(undefined),
    patchVocabulary: () => Promise.resolve(undefined),
    deleteVocabulary: () => Promise.resolve(false),
    listDueReviews: () => Promise.resolve([]),
    submitReviews: fail,
    getActiveTranscript: () => Promise.resolve(undefined),
    createTranscript: fail,
    listLemmas: () => Promise.resolve([]),
    upsertLemma: fail,
  };
}

export function createSupabaseCatalogStore(rest: RestClient): CatalogStore {
  async function selectBook(userId: string, bookId: string): Promise<CatalogBook | undefined> {
    const response = await rest.request({
      method: "GET",
      path: "/books",
      query: {
        user_id: `eq.${userId}`,
        id: `eq.${bookId}`,
        deleted_at: "is.null",
        select: "*",
        limit: "1",
      },
    });
    const row = restRow(response.body);
    return row === undefined ? undefined : bookFromRow(row);
  }

  return {
    async listBooks(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/books",
        query: {
          user_id: `eq.${userId}`,
          deleted_at: "is.null",
          select: "*",
          order: "created_at.asc,id.asc",
        },
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(bookFromRow);
    },

    async createBook(userId, input) {
      const now = new Date().toISOString();
      const created = await rest.request({
        method: "POST",
        path: "/books",
        prefer: "return=representation",
        body: {
          id: input.clientId,
          user_id: userId,
          title: input.title,
          author: input.author ?? null,
          edition_fingerprint: input.editionFingerprint,
          fingerprint_version: input.fingerprintVersion,
          source: input.source,
          chapter_count: input.chapters.length,
          audio_manifest_hash: input.audioManifestHash ?? null,
          ebook_text_hash: input.ebookTextHash ?? null,
          server_version: 0,
        },
      });
      const bookRow = restRow(created.body);
      for (const chapter of input.chapters) {
        await rest.request({
          method: "POST",
          path: "/chapters",
          prefer: "return=minimal",
          body: {
            id: chapter.clientId,
            user_id: userId,
            book_id: input.clientId,
            index: chapter.index,
            title: chapter.title,
            chapter_fingerprint: chapter.chapterFingerprint,
            duration_seconds: chapter.durationSeconds,
            start_seconds: chapter.startSeconds ?? null,
            server_version: 0,
          },
        });
      }
      return bookRow === undefined
        ? {
            id: input.clientId,
            accountId: userId,
            title: input.title,
            author: input.author ?? null,
            editionFingerprint: input.editionFingerprint,
            fingerprintVersion: input.fingerprintVersion,
            source: input.source,
            chapterCount: input.chapters.length,
            revision: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: null,
            audioManifestHash: input.audioManifestHash ?? null,
            ebookTextHash: input.ebookTextHash ?? null,
            workId: null,
            editionId: null,
            coverAssetId: null,
          }
        : bookFromRow(bookRow);
    },

    getBook(userId, bookId) {
      return selectBook(userId, bookId);
    },

    async patchBook(userId, bookId, patch) {
      const current = await selectBook(userId, bookId);
      if (current === undefined) {
        return undefined;
      }
      if (current.revision !== patch.baseRevision) {
        return "conflict";
      }
      const response = await rest.request({
        method: "PATCH",
        path: "/books",
        query: {
          user_id: `eq.${userId}`,
          id: `eq.${bookId}`,
          server_version: `eq.${String(current.revision)}`,
        },
        prefer: "return=representation",
        body: {
          ...(patch.title === undefined ? {} : { title: patch.title }),
          ...(patch.author === undefined ? {} : { author: patch.author }),
          server_version: current.revision + 1,
          updated_at: new Date().toISOString(),
        },
      });
      const row = restRow(response.body);
      return row === undefined ? "conflict" : bookFromRow(row);
    },

    async deleteBook(userId, bookId) {
      const response = await rest.request({
        method: "PATCH",
        path: "/books",
        query: { user_id: `eq.${userId}`, id: `eq.${bookId}`, deleted_at: "is.null" },
        prefer: "return=representation",
        body: { deleted_at: new Date().toISOString(), updated_at: new Date().toISOString() },
      });
      return restRow(response.body) !== undefined;
    },

    async listChapters(userId, bookId) {
      const book = await selectBook(userId, bookId);
      if (book === undefined) {
        return [];
      }
      const response = await rest.request({
        method: "GET",
        path: "/chapters",
        query: {
          user_id: `eq.${userId}`,
          book_id: `eq.${bookId}`,
          select: "*",
          order: "index.asc,id.asc",
        },
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(chapterFromRow);
    },

    async getChapter(userId, chapterId) {
      const response = await rest.request({
        method: "GET",
        path: "/chapters",
        query: { user_id: `eq.${userId}`, id: `eq.${chapterId}`, select: "*", limit: "1" },
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : chapterFromRow(row);
    },

    async getProgress(userId, chapterId) {
      const response = await rest.request({
        method: "GET",
        path: "/reading_progress",
        query: { user_id: `eq.${userId}`, chapter_id: `eq.${chapterId}`, select: "*", limit: "1" },
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : progressFromRow(row);
    },

    async putProgress(userId, chapterId, deviceId, input) {
      const current = await this.getProgress(userId, chapterId);
      if (current !== undefined && current.revision !== input.baseRevision) {
        return "conflict";
      }
      const chapter = await this.getChapter(userId, chapterId);
      if (chapter === undefined) {
        return undefined;
      }
      const body = {
        user_id: userId,
        book_id: chapter.bookId,
        chapter_id: chapterId,
        position_seconds: input.positionSeconds,
        completed: input.completed,
        explicit_seek: input.explicitSeek,
        device_id: deviceId,
        segment_id: input.segmentId ?? null,
        word_id: input.wordId ?? null,
        server_version: (current?.revision ?? 0) + 1,
        updated_at: new Date().toISOString(),
      };
      const response = await rest.request({
        method: current === undefined ? "POST" : "PATCH",
        path: current === undefined ? "/reading_progress" : "/reading_progress",
        ...(current === undefined
          ? {}
          : { query: { user_id: `eq.${userId}`, chapter_id: `eq.${chapterId}` } }),
        prefer: "return=representation",
        body,
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : progressFromRow(row);
    },

    async listVocabulary(userId, bookId) {
      const query: Record<string, string> = {
        user_id: `eq.${userId}`,
        deleted_at: "is.null",
        select: "*",
        order: "created_at.asc,id.asc",
      };
      if (bookId !== undefined) {
        query.book_id = `eq.${bookId}`;
      }
      const response = await rest.request({
        method: "GET",
        path: "/vocabulary_occurrences",
        query,
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(vocabularyFromRow);
    },

    async createVocabulary(userId, input) {
      const response = await rest.request({
        method: "POST",
        path: "/vocabulary_occurrences",
        prefer: "return=representation",
        body: {
          id: input.id,
          user_id: userId,
          book_id: input.bookId,
          chapter_id: input.chapterId,
          surface: input.surface,
          lemma: input.lemma,
          category: input.category,
          context: input.context,
          timestamp_seconds: input.timestampSeconds,
          state: input.state,
          segment_id: input.segmentId,
          word_id: input.wordId,
          definition: input.definition,
          note: input.note,
          server_version: 0,
        },
      });
      const row = restRow(response.body);
      return row === undefined
        ? {
            ...input,
            revision: 0,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            deletedAt: null,
          }
        : vocabularyFromRow(row);
    },

    async getVocabulary(userId, id) {
      const response = await rest.request({
        method: "GET",
        path: "/vocabulary_occurrences",
        query: {
          user_id: `eq.${userId}`,
          id: `eq.${id}`,
          deleted_at: "is.null",
          select: "*",
          limit: "1",
        },
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : vocabularyFromRow(row);
    },

    async patchVocabulary(userId, id, patch) {
      const current = await this.getVocabulary(userId, id);
      if (current === undefined) {
        return undefined;
      }
      if (current.revision !== patch.baseRevision) {
        return "conflict";
      }
      const response = await rest.request({
        method: "PATCH",
        path: "/vocabulary_occurrences",
        query: {
          user_id: `eq.${userId}`,
          id: `eq.${id}`,
          server_version: `eq.${String(current.revision)}`,
        },
        prefer: "return=representation",
        body: {
          ...(patch.definition === undefined ? {} : { definition: patch.definition }),
          ...(patch.note === undefined ? {} : { note: patch.note }),
          ...(patch.state === undefined ? {} : { state: patch.state }),
          server_version: current.revision + 1,
          updated_at: new Date().toISOString(),
        },
      });
      const row = restRow(response.body);
      return row === undefined ? "conflict" : vocabularyFromRow(row);
    },

    async deleteVocabulary(userId, id) {
      const response = await rest.request({
        method: "PATCH",
        path: "/vocabulary_occurrences",
        query: { user_id: `eq.${userId}`, id: `eq.${id}`, deleted_at: "is.null" },
        prefer: "return=representation",
        body: { deleted_at: new Date().toISOString(), updated_at: new Date().toISOString() },
      });
      return restRow(response.body) !== undefined;
    },

    async listDueReviews(userId, nowIso) {
      const response = await rest.request({
        method: "GET",
        path: "/review_cards",
        query: {
          user_id: `eq.${userId}`,
          due_at: `lte.${nowIso}`,
          deleted_at: "is.null",
          select: "*",
          order: "due_at.asc",
        },
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(scheduleFromRow);
    },

    async submitReviews(userId, deviceId, events) {
      const schedules: CatalogReviewSchedule[] = [];
      for (const event of events) {
        await rest.request({
          method: "POST",
          path: "/review_events",
          prefer: "return=minimal",
          body: {
            id: event.id,
            user_id: userId,
            vocabulary_id: event.vocabularyId,
            face: event.face,
            rating: event.rating,
            reviewed_at: event.reviewedAt,
            device_id: deviceId,
            response_time_ms: event.responseTimeMs,
            server_version: 0,
          },
        });
        const due = new Date(
          Date.parse(event.reviewedAt) + event.rating * 86_400_000,
        ).toISOString();
        const patched = await rest.request({
          method: "POST",
          path: "/review_cards?on_conflict=user_id,vocabulary_id,face",
          prefer: "resolution=merge-duplicates,return=representation",
          body: {
            user_id: userId,
            vocabulary_id: event.vocabularyId,
            face: event.face,
            due_at: due,
            last_reviewed_at: event.reviewedAt,
            review_count: 1,
            stability: event.rating,
            difficulty: 5,
          },
        });
        const row = restRow(patched.body);
        if (row !== undefined) {
          schedules.push(scheduleFromRow(row));
        } else {
          schedules.push({
            vocabularyId: event.vocabularyId,
            dueAt: due,
            stability: event.rating,
            difficulty: 5,
            reviewCount: 1,
            lastReviewedAt: event.reviewedAt,
            updatedAt: new Date().toISOString(),
          });
        }
      }
      return schedules;
    },

    async getActiveTranscript(userId, chapterId) {
      const response = await rest.request({
        method: "GET",
        path: "/transcript_revisions",
        query: {
          user_id: `eq.${userId}`,
          chapter_id: `eq.${chapterId}`,
          is_active: "eq.true",
          select: "*",
          limit: "1",
        },
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : transcriptFromRow(row);
    },

    async createTranscript(userId, input) {
      await rest.request({
        method: "PATCH",
        path: "/transcript_revisions",
        query: {
          user_id: `eq.${userId}`,
          chapter_id: `eq.${input.chapterId}`,
          is_active: "eq.true",
        },
        prefer: "return=minimal",
        body: { is_active: false, updated_at: new Date().toISOString() },
      });
      const existing = await rest.request({
        method: "GET",
        path: "/transcript_revisions",
        query: { user_id: `eq.${userId}`, chapter_id: `eq.${input.chapterId}`, select: "version" },
      });
      const version = restRows(existing.body).length + 1;
      const chapter = await this.getChapter(userId, input.chapterId);
      const response = await rest.request({
        method: "POST",
        path: "/transcript_revisions",
        prefer: "return=representation",
        body: {
          id: input.id,
          user_id: userId,
          book_id: chapter?.bookId,
          chapter_id: input.chapterId,
          version,
          engine: input.engine,
          engine_version: input.engineVersion,
          locale: input.locale,
          chapter_fingerprint: input.chapterFingerprint,
          quality: input.quality,
          ebook_alignment: input.ebookAlignment,
          is_active: true,
          server_version: 0,
        },
      });
      const row = restRow(response.body);
      return row === undefined
        ? { ...input, version, active: true, createdAt: new Date().toISOString() }
        : { ...transcriptFromRow(row), segments: input.segments };
    },

    async listLemmas(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/known_lemmas",
        query: { user_id: `eq.${userId}`, deleted_at: "is.null", select: "*" },
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(lemmaFromRow);
    },

    async upsertLemma(userId, input) {
      const response = await rest.request({
        method: "POST",
        path: "/known_lemmas?on_conflict=id",
        prefer: "resolution=merge-duplicates,return=representation",
        body: {
          id: input.id,
          user_id: userId,
          language: input.language,
          lemma: input.lemma,
          state: input.state,
        },
      });
      const row = restRow(response.body);
      return row === undefined
        ? {
            id: input.id,
            language: input.language,
            lemma: input.lemma,
            state: input.state,
            revision: 0,
            updatedAt: new Date().toISOString(),
          }
        : lemmaFromRow(row);
    },
  };
}

function bookFromRow(row: Record<string, unknown>): CatalogBook {
  const source = row.source;
  return {
    id: stringValue(row.id),
    accountId: stringValue(row.user_id),
    title: stringValue(row.title),
    author: nullable(row.author),
    editionFingerprint: stringValue(row.edition_fingerprint),
    fingerprintVersion: numberValue(row.fingerprint_version, 1),
    source:
      source === "files" || source === "device_audiobooks" || source === "remote_backup"
        ? source
        : "local_folder",
    chapterCount: numberValue(row.chapter_count, 0),
    revision: numberValue(row.server_version, 0),
    createdAt: stringValue(row.created_at, new Date().toISOString()),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
    deletedAt: nullable(row.deleted_at),
    audioManifestHash: nullable(row.audio_manifest_hash),
    ebookTextHash: nullable(row.ebook_text_hash),
    workId: nullable(row.work_id),
    editionId: nullable(row.edition_id),
    coverAssetId: nullable(row.cover_asset_id),
  };
}

function chapterFromRow(row: Record<string, unknown>): CatalogChapter {
  return {
    id: stringValue(row.id),
    bookId: stringValue(row.book_id),
    index: numberValue(row.index, 0),
    title: stringValue(row.title),
    chapterFingerprint: stringValue(row.chapter_fingerprint),
    durationSeconds: numberValue(row.duration_seconds, 0),
    startSeconds: typeof row.start_seconds === "number" ? row.start_seconds : null,
    audioAssetId: nullable(row.audio_asset_id),
    revision: numberValue(row.server_version, 0),
    createdAt: stringValue(row.created_at, new Date().toISOString()),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
  };
}

function progressFromRow(row: Record<string, unknown>): CatalogProgress {
  return {
    chapterId: stringValue(row.chapter_id),
    positionSeconds: numberValue(row.position_seconds, 0),
    completed: row.completed === true,
    revision: numberValue(row.server_version, 0),
    deviceId: stringValue(row.device_id),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
    segmentId: nullable(row.segment_id),
    wordId: nullable(row.word_id),
    explicitSeek: row.explicit_seek === true,
  };
}

function vocabularyFromRow(row: Record<string, unknown>): CatalogVocabulary {
  const category = row.category;
  const state = row.state;
  return {
    id: stringValue(row.id),
    bookId: stringValue(row.book_id),
    chapterId: stringValue(row.chapter_id),
    surface: stringValue(row.surface),
    lemma: stringValue(row.lemma),
    category: category === "phrase" || category === "sentence" ? category : "word",
    context: stringValue(row.context),
    timestampSeconds: numberValue(row.timestamp_seconds, 0),
    state: state === "learning" || state === "known" || state === "ignored" ? state : "unknown",
    revision: numberValue(row.server_version, 0),
    createdAt: stringValue(row.created_at, new Date().toISOString()),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
    deletedAt: nullable(row.deleted_at),
    segmentId: nullable(row.segment_id),
    wordId: nullable(row.word_id),
    definition: nullable(row.definition),
    note: nullable(row.note),
  };
}

function scheduleFromRow(row: Record<string, unknown>): CatalogReviewSchedule {
  return {
    vocabularyId: stringValue(row.vocabulary_id),
    dueAt: stringValue(row.due_at, new Date().toISOString()),
    stability: numberValue(row.stability, 0),
    difficulty: numberValue(row.difficulty, 0),
    reviewCount: numberValue(row.review_count, 0),
    lastReviewedAt: nullable(row.last_reviewed_at),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
  };
}

function transcriptFromRow(row: Record<string, unknown>): CatalogTranscript {
  return {
    id: stringValue(row.id),
    chapterId: stringValue(row.chapter_id),
    version: numberValue(row.version, 1),
    engine: stringValue(row.engine),
    engineVersion: nullable(row.engine_version),
    locale: stringValue(row.locale),
    chapterFingerprint: stringValue(row.chapter_fingerprint),
    segments: [],
    quality: isRecord(row.quality) ? row.quality : {},
    ebookAlignment: isRecord(row.ebook_alignment) ? row.ebook_alignment : null,
    active: row.is_active === true,
    createdAt: stringValue(row.created_at, new Date().toISOString()),
  };
}

function lemmaFromRow(row: Record<string, unknown>): CatalogLemma {
  const state = row.state;
  return {
    id: stringValue(row.id),
    language: stringValue(row.language),
    lemma: stringValue(row.lemma),
    state: state === "learning" || state === "known" || state === "ignored" ? state : "unknown",
    revision: numberValue(row.server_version, 0),
    updatedAt: stringValue(row.updated_at, new Date().toISOString()),
  };
}

function stringValue(value: unknown, fallback = ""): string {
  return typeof value === "string" && value !== "" ? value : fallback;
}

function nullable(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

function numberValue(value: unknown, fallback: number): number {
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
