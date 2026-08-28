import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const BOOK_ID = "2c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";
const CHAPTER_ID = "1c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";
const VOCAB_ID = "4c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

function authHeaders(key = "idempotency-key-library-01"): Record<string, string> {
  return {
    authorization: "Bearer test",
    "X-Device-Id": DEVICE_ID,
    "Idempotency-Key": key,
    "content-type": "application/json",
  };
}

async function createBook(app = createTestApp()) {
  const response = await app.fetch(
    new Request("http://localhost/v1/books", {
      method: "POST",
      headers: authHeaders("idempotency-key-library-create"),
      body: JSON.stringify({
        clientId: BOOK_ID,
        title: "Moby-Dick",
        author: "Herman Melville",
        editionFingerprint: "ed-1",
        fingerprintVersion: 1,
        source: "local_folder",
        chapters: [
          {
            clientId: CHAPTER_ID,
            index: 0,
            title: "Loomings",
            chapterFingerprint: "ch-1",
            durationSeconds: 120,
          },
        ],
      }),
    }),
  );
  return { app, response };
}

describe("library API", () => {
  it("rejects unauthenticated book list", async () => {
    const app = createTestApp({ authenticate: () => null });
    const response = await app.fetch(new Request("http://localhost/v1/books"));
    expect(response.status).toBe(401);
  });

  it("creates, lists, patches, and deletes a book", async () => {
    const { app, response } = await createBook();
    expect(response.status).toBe(201);
    const created = await readJson(response);
    expect(isRecord(created)).toBe(true);
    if (!isRecord(created)) {
      return;
    }
    expect(created.title).toBe("Moby-Dick");
    expect(created.chapterCount).toBe(1);

    const listed = await app.fetch(
      new Request("http://localhost/v1/books", { headers: { authorization: "Bearer test" } }),
    );
    expect(listed.status).toBe(200);
    const page = await readJson(listed);
    expect(isRecord(page) && Array.isArray(page.items)).toBe(true);
    if (isRecord(page) && Array.isArray(page.items)) {
      expect(page.items).toHaveLength(1);
    }

    const chapters = await app.fetch(
      new Request(`http://localhost/v1/books/${BOOK_ID}/chapters`, {
        headers: { authorization: "Bearer test" },
      }),
    );
    expect(chapters.status).toBe(200);
    const chapterList = await readJson(chapters);
    expect(Array.isArray(chapterList) && chapterList[0]).toMatchObject({ title: "Loomings" });

    const patched = await app.fetch(
      new Request(`http://localhost/v1/books/${BOOK_ID}`, {
        method: "PATCH",
        headers: authHeaders("idempotency-key-library-patch"),
        body: JSON.stringify({ baseRevision: 0, title: "Moby Dick" }),
      }),
    );
    expect(patched.status).toBe(200);
    const conflicted = await app.fetch(
      new Request(`http://localhost/v1/books/${BOOK_ID}`, {
        method: "PATCH",
        headers: authHeaders("idempotency-key-library-conflict"),
        body: JSON.stringify({ baseRevision: 0, title: "Nope" }),
      }),
    );
    expect(conflicted.status).toBe(409);

    const deleted = await app.fetch(
      new Request(`http://localhost/v1/books/${BOOK_ID}`, {
        method: "DELETE",
        headers: authHeaders("idempotency-key-library-delete"),
      }),
    );
    expect(deleted.status).toBe(204);
  });

  it("upserts progress and vocabulary", async () => {
    const { app } = await createBook();
    const progress = await app.fetch(
      new Request(`http://localhost/v1/progress/${CHAPTER_ID}`, {
        method: "PUT",
        headers: authHeaders("idempotency-key-progress"),
        body: JSON.stringify({
          positionSeconds: 12.5,
          completed: false,
          baseRevision: 0,
          explicitSeek: true,
          occurredAt: "2026-08-27T12:00:00.000Z",
        }),
      }),
    );
    expect(progress.status).toBe(200);
    const vocab = await app.fetch(
      new Request("http://localhost/v1/vocabulary", {
        method: "POST",
        headers: authHeaders("idempotency-key-vocab"),
        body: JSON.stringify({
          clientId: VOCAB_ID,
          bookId: BOOK_ID,
          chapterId: CHAPTER_ID,
          surface: "loom",
          lemma: "loom",
          category: "word",
          context: "Call me Ishmael",
          timestampSeconds: 4,
          state: "learning",
        }),
      }),
    );
    expect(vocab.status).toBe(201);
    const listed = await app.fetch(
      new Request("http://localhost/v1/vocabulary", { headers: { authorization: "Bearer test" } }),
    );
    const page = await readJson(listed);
    expect(isRecord(page) && Array.isArray(page.items)).toBe(true);
    if (isRecord(page) && Array.isArray(page.items)) {
      expect(page.items).toHaveLength(1);
    }
  });

  it("stores transcripts and review events", async () => {
    const { app } = await createBook();
    const transcript = await app.fetch(
      new Request("http://localhost/v1/transcripts", {
        method: "POST",
        headers: authHeaders("idempotency-key-transcript"),
        body: JSON.stringify({
          clientId: "5c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d",
          chapterId: CHAPTER_ID,
          engine: "speech",
          locale: "en-US",
          chapterFingerprint: "ch-1",
          segments: [
            {
              id: "s1",
              startSeconds: 0,
              endSeconds: 1,
              spokenText: "Call me Ishmael",
              words: [{ id: "w1", text: "Call", startSeconds: 0, endSeconds: 0.2 }],
            },
          ],
          quality: { score: 0.9 },
        }),
      }),
    );
    expect(transcript.status).toBe(201);
    const active = await app.fetch(
      new Request(`http://localhost/v1/chapters/${CHAPTER_ID}/transcript`, {
        headers: { authorization: "Bearer test" },
      }),
    );
    expect(active.status).toBe(200);
    await app.fetch(
      new Request("http://localhost/v1/vocabulary", {
        method: "POST",
        headers: authHeaders("idempotency-key-vocab-review"),
        body: JSON.stringify({
          clientId: VOCAB_ID,
          bookId: BOOK_ID,
          chapterId: CHAPTER_ID,
          surface: "loom",
          lemma: "loom",
          category: "word",
          context: "Call me Ishmael",
          timestampSeconds: 4,
          state: "learning",
        }),
      }),
    );
    const reviews = await app.fetch(
      new Request("http://localhost/v1/reviews", {
        method: "POST",
        headers: authHeaders("idempotency-key-reviews"),
        body: JSON.stringify({
          events: [
            {
              id: "6c5ea4c0-4067-11e9-8bad-9b1deb4d3b7d",
              vocabularyId: VOCAB_ID,
              face: "recognition",
              rating: 3,
              reviewedAt: "2026-08-27T12:00:00.000Z",
              deviceId: DEVICE_ID,
            },
          ],
        }),
      }),
    );
    expect(reviews.status).toBe(200);
  });
});
