import { createFakePrincipal } from "@audio-reader/auth";
import { createFakeDatabaseClient, RestPersistenceError } from "@audio-reader/database";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { describe, expect, it, vi } from "vitest";
import { createTestApp } from "./app";
import { buildAccountExportPayload } from "./account-export";
import { assistantMethodError, isAssistantPath } from "./assistant-routes";
import { listOperatorEvents } from "./operator-events";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const AUTH_HEADERS = {
  authorization: "Bearer test",
  "content-type": "application/json",
  "X-Device-Id": DEVICE_ID,
} as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

function postAssistant(
  app: ReturnType<typeof createTestApp>,
  path: string,
  body: unknown,
  idempotencyKey: string,
): Promise<Response> {
  return app.fetch(
    new Request(`http://localhost${path}`, {
      method: "POST",
      headers: { ...AUTH_HEADERS, "Idempotency-Key": idempotencyKey },
      body: JSON.stringify(body),
    }),
  );
}

function sentenceBody(
  source: string,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    task: "sentence",
    sourceLanguage: "en",
    targetLanguage: "zh",
    learnerLevel: "intermediate",
    source,
    editionFingerprint: "ed-1",
    chapterFingerprint: "ch-1",
    promptVersion: "v1",
    ...extra,
  };
}

function batchBody(
  sentences: Array<{ id: string; text: string }>,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    task: "chapter_batch",
    sourceLanguage: "en",
    targetLanguage: "zh",
    learnerLevel: "intermediate",
    sentences,
    editionFingerprint: "ed-1",
    chapterFingerprint: "ch-1",
    ...extra,
  };
}

function summaryBody(
  segments: string[],
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    chapterId: DEVICE_ID,
    sourceLanguage: "en",
    targetLanguage: "zh",
    learnerLevel: "intermediate",
    segments,
    ...extra,
  };
}

describe("managed Qwen assistant API", () => {
  it("rejects unauthenticated translation requests", async () => {
    const app = createTestApp({ authenticate: () => null });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-01",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-1",
          chapterFingerprint: "ch-1",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(401);
  });

  it("returns a generated translation from the managed Qwen client", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-02",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-1",
          chapterFingerprint: "ch-1",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body)).toBe(true);
    if (!isRecord(body)) {
      return;
    }
    expect(body.translation).toBe("你好");
    expect(body.provenance).toBe("generated");
    expect(body.policyVersion).toBe("qwen-managed-v1");
    expect(typeof body.id).toBe("string");
    expect(typeof body.sharedCacheEntryID).toBe("string");
    expect(body.id).not.toBe(body.sharedCacheEntryID);
    expect(typeof body.model).toBe("string");
    expect(body.model).not.toBe("Managed Qwen");
    expect(body.promptVersion).toBe("qwen-managed-v1");
    expect(body.modelPolicyHash).toMatch(/^[0-9a-f]{64}$/);
    const privateRows = await database.ops.listAssistantResults(createFakePrincipal().accountId);
    expect(privateRows).toHaveLength(1);
    expect(privateRows[0]).toMatchObject({
      id: body.id,
      cacheEntryId: body.sharedCacheEntryID,
      model: body.model,
      promptVersion: body.promptVersion,
      modelPolicyHash: body.modelPolicyHash,
    });
    expect(privateRows[0]?.outputText).toContain("你好");

    const cached = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-02b",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-1",
          chapterFingerprint: "ch-1",
          promptVersion: "v1",
        }),
      }),
    );
    expect(cached.status).toBe(200);
    const cachedBody = await readJson(cached);
    expect(isRecord(cachedBody) && cachedBody.provenance).toBe("cache_shared_exact");
    if (!isRecord(cachedBody)) return;
    expect(cachedBody.sharedCacheEntryID).toBe(body.sharedCacheEntryID);
    expect(cachedBody.id).not.toBe(body.id);
    expect(cachedBody.id).not.toBe(cachedBody.sharedCacheEntryID);
  });

  it("creates a private result without a cache reference when the shared cache write fails", async () => {
    const database = createFakeDatabaseClient();
    database.ops.putCache = () => Promise.reject(new Error("cache unavailable"));
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' }),
    });

    const response = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Private even without cache"),
      "idempotency-key-cache-write-failure",
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && body.sharedCacheEntryID).toBeNull();
    const rows = await database.ops.listAssistantResults(createFakePrincipal().accountId);
    expect(rows).toHaveLength(1);
    expect(rows[0]?.cacheEntryId).toBeNull();
    expect(rows[0]?.outputText).toContain("你好");
  });

  it.each([
    {
      label: "single translation",
      path: "/v1/ai/translations",
      body: sentenceBody("Do not log this single source"),
      output: '{"translation":"保留单句","notes":[]}',
      expected: "保留单句",
    },
    {
      label: "translation batch",
      path: "/v1/ai/translation-batches",
      body: batchBody([{ id: "s1", text: "Do not log this batch source" }]),
      output: '{"translations":[{"id":"s1","translation":"保留批次","notes":[]}]}',
      expected: "保留批次",
    },
  ])(
    "returns a generated and cached $label when private-result persistence fails",
    async (testCase) => {
      const database = createFakeDatabaseClient();
      const failureDetail = "private persistence failed with secret material";
      database.ops.recordAssistantUse = () =>
        Promise.reject(new RestPersistenceError(502, failureDetail));
      const app = createTestApp({
        database,
        qwen: createFakeQwenClient({ text: testCase.output }),
      });
      const requestId = `assistant-persistence-${testCase.label.replaceAll(" ", "-")}`;
      const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);

      const response = await app.fetch(
        new Request(`http://localhost${testCase.path}`, {
          method: "POST",
          headers: {
            ...AUTH_HEADERS,
            "Idempotency-Key": requestId,
            "X-Request-Id": requestId,
          },
          body: JSON.stringify(testCase.body),
        }),
      );
      const persistenceLogs = warning.mock.calls
        .map(([value]) => String(value))
        .filter((value) => value.includes("assistant_result_persistence_failed"));
      warning.mockRestore();

      expect(response.status).toBe(200);
      const body = await readJson(response);
      const result =
        isRecord(body) && Array.isArray(body.results) ? (body.results[0] as unknown) : body;
      expect(isRecord(result) && result.translation).toBe(testCase.expected);
      expect(isRecord(result) && result.provenance).toBe("generated");
      expect(isRecord(result) && typeof result.sharedCacheEntryID).toBe("string");
      expect(persistenceLogs).toHaveLength(1);
      expect(JSON.parse(persistenceLogs[0] ?? "{}")).toMatchObject({
        message: "assistant_result_persistence_failed",
        requestId,
        task: "translation",
        errorName: "RestPersistenceError",
      });
      expect(persistenceLogs.join("\n")).not.toContain(failureDetail);
      expect(persistenceLogs.join("\n")).not.toContain("Do not log this");
    },
  );

  it("uses the winning shared cache UUID when a concurrent insert wins", async () => {
    const database = createFakeDatabaseClient();
    const originalPut = database.ops.putCache.bind(database.ops);
    const winnerID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    database.ops.putCache = (input) => originalPut({ ...input, id: winnerID });
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' }),
    });

    const response = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Concurrent cache winner"),
      "idempotency-key-cache-conflict-winner",
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && body.sharedCacheEntryID).toBe(winnerID);
    const rows = await database.ops.listAssistantResults(createFakePrincipal().accountId);
    expect(rows[0]?.cacheEntryId).toBe(winnerID);
  });

  it("keeps a generated structured summary private through cache deletion, bootstrap, and export", async () => {
    const database = createFakeDatabaseClient();
    const structured = {
      overview: "完整概述",
      keyPoints: ["要点一", "要点二"],
      charactersOrIdeas: ["人物甲"],
      keyConcepts: [{ name: "概念", explanation: "解释" }],
      themes: ["主题"],
    };
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({ text: JSON.stringify(structured) }),
    });

    const response = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["chapter text"], {
        bookTitle: "Private Book",
        chapterTitle: "Private Chapter",
      }),
      "idempotency-key-private-structured-summary",
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body)).toBe(true);
    if (!isRecord(body)) return;
    const resultID = String(body.id);
    const cacheID = String(body.sharedCacheEntryID);
    await database.ops.actOnCache(cacheID, "purge");

    const rows = await database.ops.listAssistantResults(createFakePrincipal().accountId);
    expect(rows).toHaveLength(1);
    expect(JSON.parse(rows[0]?.outputText ?? "{}")).toEqual(structured);
    expect(rows[0]?.history[0]).toMatchObject({ privateContent: structured });
    const bootstrap = await database.syncV2.bootstrap({
      userId: createFakePrincipal().accountId,
      cursor: null,
      offset: 0,
      limit: 100,
    });
    const bootstrapped = bootstrap.entities.find(
      (entity) => entity.entityType === "assistant_result" && entity.entityId === resultID,
    );
    expect(bootstrapped).toBeDefined();
    const bootstrappedResult: unknown = bootstrapped?.payload.result;
    expect(isRecord(bootstrappedResult)).toBe(true);
    if (!isRecord(bootstrappedResult)) return;
    expect(bootstrappedResult.id).toBe(resultID);
    expect(bootstrappedResult.text).toBe(JSON.stringify(structured));
    const exported = await buildAccountExportPayload({
      accountId: createFakePrincipal().accountId,
      ops: database.ops,
      sync: database.syncV2,
    });
    const exportedResults: unknown = exported.assistantResults;
    expect(Array.isArray(exportedResults)).toBe(true);
    if (!Array.isArray(exportedResults)) return;
    expect(exportedResults).toHaveLength(1);
    const exportedResult: unknown = exportedResults[0];
    expect(isRecord(exportedResult)).toBe(true);
    if (!isRecord(exportedResult)) return;
    expect(exportedResult.id).toBe(resultID);
    expect(exportedResult.sharedCacheReference).toEqual({ entryId: cacheID });
    const privateContent: unknown = exportedResult.privateContent;
    expect(isRecord(privateContent)).toBe(true);
    if (!isRecord(privateContent)) return;
    expect(privateContent.structured).toEqual(structured);
  });

  it("single-flights identical translation misses through one Qwen call", async () => {
    let completions = 0;
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        delayMs: 40,
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const body = JSON.stringify({
      task: "sentence",
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      source: "Single flight please",
      editionFingerprint: "ed-sf",
      chapterFingerprint: "ch-sf",
      promptVersion: "v1",
    });
    const [first, second] = await Promise.all([
      app.fetch(
        new Request("http://localhost/v1/ai/translations", {
          method: "POST",
          headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sf-1" },
          body,
        }),
      ),
      app.fetch(
        new Request("http://localhost/v1/ai/translations", {
          method: "POST",
          headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sf-2" },
          body,
        }),
      ),
    ]);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("asks Qwen for in-sentence examples on a word task and stores them as notes", async () => {
    const messages: { role: string; content: string }[] = [];
    let enableThinking: boolean | undefined;
    const inner = createFakeQwenClient({
      text: JSON.stringify({
        translation: "noun — the frozen sea in this chapter",
        connection: "Here it is the ice that traps the ship.",
        examples: [
          { source: "The ice closed over the channel.", translation: "冰封住了航道。" },
          { source: "The lake froze overnight.", translation: "湖一夜结了冰。" },
        ],
        notes: [],
      }),
    });
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          enableThinking = request.enableThinking;
          for (const message of request.messages) {
            messages.push({ role: message.role, content: message.content });
          }
          return inner.complete(request);
        },
      },
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-word-01",
        },
        body: JSON.stringify({
          task: "word",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "ice",
          contextBefore: "The ice closed over the channel.",
          editionFingerprint: "ed-word",
          chapterFingerprint: "ch-word",
          bookTitle: "Frankenstein",
          chapterTitle: "Letter I",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body)).toBe(true);
    if (!isRecord(body)) {
      return;
    }
    expect(body.translation).toContain("noun — the frozen sea in this chapter");
    expect(body.translation).toContain("Here it is the ice that traps the ship.");
    expect(body.notes).toEqual([
      {
        source: "The ice closed over the channel.",
        category: "example",
        explanation: "冰封住了航道。",
      },
      {
        source: "The lake froze overnight.",
        category: "example",
        explanation: "湖一夜结了冰。",
      },
    ]);
    const system = messages.find((message) => message.role === "system")?.content ?? "";
    const user = messages.find((message) => message.role === "user")?.content ?? "";
    expect(system).toContain("examples MUST contain exactly two");
    expect(user).toContain("The ice closed over the channel.");
    expect(user).toContain("ice");
    expect(enableThinking).toBe(false);

    const listed = await createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    }).fetch(
      new Request("http://localhost/v1/admin/cache", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(listed.status).toBe(200);
    const page = await readJson(listed);
    const items =
      isRecord(page) && Array.isArray(page.items) ? (page.items as Record<string, unknown>[]) : [];
    const entry = items.find((item) => item.id === body.sharedCacheEntryID);
    expect(entry).toBeDefined();
    expect(isRecord(entry) && entry.hitCount).toBe(0);
    const payload = isRecord(entry) && isRecord(entry.payload) ? entry.payload : {};
    expect(payload.source).toBeUndefined();
    expect(payload.context).toBeUndefined();
    expect(payload.bookTitle).toBeUndefined();
    expect(payload.translation).toContain("frozen sea");
  });

  it("accepts a complete word meaning when Qwen omits only empty optional fields", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translation: "名词 — 句中指冰层",
          examples: [
            { source: "Ice covered the lake.", translation: "冰覆盖了湖面。" },
            { source: "The ice began to crack.", translation: "冰开始裂开。" },
          ],
        }),
      }),
    });

    const response = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("ice", {
        task: "word",
        contextBefore: "The ice closed over the channel.",
        editionFingerprint: "ed-word-empty-fields",
        chapterFingerprint: "ch-word-empty-fields",
      }),
      "idempotency-key-qwen-word-empty-fields",
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && body.translation).toBe("名词 — 句中指冰层");
  });

  it("returns a chat reply that can be fetched on the stream URL", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ text: '{"answer":"The ice is a metaphor."}' }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/chat", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-chat-01",
        },
        body: JSON.stringify({
          chapterId: DEVICE_ID,
          question: "What does the ice mean?",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
        }),
      }),
    );
    expect(response.status).toBe(202);
    const accepted = await readJson(response);
    expect(isRecord(accepted)).toBe(true);
    if (!isRecord(accepted) || typeof accepted.streamUrl !== "string") {
      return;
    }
    const message = await app.fetch(
      new Request(`http://localhost${accepted.streamUrl}`, {
        headers: { authorization: "Bearer test", "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(message.status).toBe(200);
    const payload = await readJson(message);
    expect(isRecord(payload) && payload.text).toBe("The ice is a metaphor.");
    expect(isRecord(payload) && payload.role).toBe("assistant");
  });

  it("returns validated raw heard_quiz JSON assembled from only supplied heard segments", async () => {
    const requests: Array<{ messages: readonly { role: string; content: string }[] }> = [];
    const database = createFakeDatabaseClient();
    await database.ops.putAnalyticsPreference(createFakePrincipal().accountId, true);
    const inner = createFakeQwenClient({
      text: '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What happened?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"A follows the passage.","segmentID":"s1"},{"id":"q2","kind":"sequencing","prompt":"What came next?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"B follows the passage.","segmentID":"s2"}]}',
    });
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: (request) => {
          requests.push(request);
          return inner.complete(request);
        },
      },
    });
    const response = await postAssistant(
      app,
      "/v1/ai/heard-quizzes",
      {
        task: "heard_quiz",
        chapterId: DEVICE_ID,
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "B1",
        bookTitle: "The Example Book",
        author: "Ada Author",
        chapterTitle: "An Arrival",
        segments: [
          { id: "s1", text: "First completed sentence." },
          { id: "s2", text: "Second completed sentence." },
        ],
      },
      "idempotency-key-heard-quiz-01",
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(
      isRecord(body) && typeof body.raw === "string" ? JSON.parse(body.raw) : null,
    ).toMatchObject({
      questions: [{ segmentID: "s1" }, { segmentID: "s2" }],
    });
    const prompt = requests[0]?.messages.map((message) => message.content).join("\n") ?? "";
    expect(prompt).toContain("Task: heard_quiz");
    expect(prompt).toContain("HEARD id=s1");
    expect(prompt).toContain("The Example Book");
    expect(prompt).not.toContain("future sentence");
    const events = await database.ops.listProductEvents();
    expect(events.map((event) => event.name)).toContain("ai.heard_quiz.succeeded");
    expect(JSON.stringify(events)).not.toContain("First completed sentence");
    expect(JSON.stringify(events)).not.toContain("The Example Book");
    const requestId = response.headers.get("X-Request-Id") ?? "";
    const terminal = listOperatorEvents({ requestId }).filter((event) =>
      ["managed_qwen_ok", "managed_qwen_failed"].includes(event.kind),
    );
    expect(terminal).toHaveLength(1);
    expect(terminal[0]).toMatchObject({
      kind: "managed_qwen_ok",
      requestId,
      task: "heard_quiz",
      metadata: { promptVersion: "qwen-managed-v1" },
    });
    expect(typeof terminal[0]?.metadata?.model).toBe("string");
    expect(terminal[0]?.metadata?.model).not.toBe("");
    expect(JSON.stringify(terminal)).not.toMatch(
      /First completed sentence|Second completed sentence|The Example Book|questions|HEARD id=/,
    );
  });

  it("rejects heard_quiz output that cites a segment outside the bounded request", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: '{"questions":[{"id":"q1","kind":"comprehension","prompt":"What happened?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"A.","segmentID":"future"},{"id":"q2","kind":"sequencing","prompt":"Then?","choices":["A","B","C","D"],"answerIndex":1,"rationale":"B.","segmentID":"s1"}]}',
      }),
    });
    const response = await postAssistant(
      app,
      "/v1/ai/heard-quizzes",
      {
        task: "heard_quiz",
        chapterId: DEVICE_ID,
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        learnerLevel: "B1",
        segments: [{ id: "s1", text: "Only heard sentence." }],
      },
      "idempotency-key-heard-quiz-02",
    );
    expect(response.status).toBe(502);
    const body = await readJson(response);
    expect(isRecord(body) && body.code).toBe("invalid_upstream_response");
    const requestId = response.headers.get("X-Request-Id") ?? "";
    const terminal = listOperatorEvents({ requestId }).filter((event) =>
      ["managed_qwen_ok", "managed_qwen_failed"].includes(event.kind),
    );
    expect(terminal).toHaveLength(1);
    expect(terminal[0]).toMatchObject({
      kind: "managed_qwen_failed",
      requestId,
      task: "heard_quiz",
      status: "invalid_output",
      metadata: { promptVersion: "qwen-managed-v1" },
    });
    expect(typeof terminal[0]?.metadata?.model).toBe("string");
    expect(terminal[0]?.metadata?.model).not.toBe("");
    expect(JSON.stringify(terminal)).not.toMatch(/Only heard sentence|future|questions|HEARD id=/);
  });

  it.each([
    {
      name: "sentence",
      path: "/v1/ai/translations",
      output: "a bare translation",
      body: sentenceBody("Malformed sentence output", {
        editionFingerprint: "ed-invalid-sentence",
        chapterFingerprint: "ch-invalid-sentence",
      }),
    },
    {
      name: "word",
      path: "/v1/ai/translations",
      output: '{"translation":"noun — ice"}',
      body: sentenceBody("ice", {
        task: "word",
        contextBefore: "The ice closed over the channel.",
        editionFingerprint: "ed-invalid-word",
        chapterFingerprint: "ch-invalid-word",
      }),
    },
    {
      name: "chapter_batch",
      path: "/v1/ai/translation-batches",
      output: '{"translations":[{"id":"s1","translation":"一。","notes":[]}]}',
      body: batchBody(
        [
          { id: "s1", text: "One." },
          { id: "s2", text: "Two." },
        ],
        {
          editionFingerprint: "ed-invalid-batch",
          chapterFingerprint: "ch-invalid-batch",
        },
      ),
    },
    {
      name: "chapter_summary",
      path: "/v1/ai/chapter-summaries",
      output: '{"overview":"Only one field"}',
      body: summaryBody(["Malformed summary output."], {
        editionFingerprint: "ed-invalid-summary",
        chapterFingerprint: "ch-invalid-summary",
      }),
    },
    {
      name: "chat",
      path: "/v1/ai/chat",
      output: "a bare chat answer",
      body: {
        chapterId: DEVICE_ID,
        question: "What happened?",
        sourceLanguage: "en",
        targetLanguage: "zh",
        learnerLevel: "intermediate",
      },
    },
  ])("rejects malformed $name output before returning or caching it", async (testCase) => {
    const app = createTestApp({ qwen: createFakeQwenClient({ text: testCase.output }) });
    const response = await postAssistant(
      app,
      testCase.path,
      testCase.body,
      `idempotency-key-invalid-${testCase.name}`,
    );

    expect(response.status).toBe(502);
    const body = await readJson(response);
    expect(isRecord(body) && body.code).toBe("invalid_upstream_response");
  });

  it("returns 503 when managed Qwen is unavailable", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ status: "unavailable" }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-03",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-1",
          chapterFingerprint: "ch-1",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(503);
    const body = await readJson(response);
    expect(isRecord(body) && body.detail).toBe(
      "Managed Qwen has no API key. Save a Qwen key on operator Desk, or set Worker secret QWEN_API_KEY.",
    );
  });

  it("names the Qwen HTTP failure when a key is configured", async () => {
    const database = createFakeDatabaseClient();
    await database.identity.ensureProfile({
      userId: "00000000-0000-4000-8000-000000000002",
      email: "fake@example.com",
    });
    await database.identity.grantAdminRole("00000000-0000-4000-8000-000000000002");
    const app = createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
      qwen: createFakeQwenClient({ status: "unavailable" }),
    });
    const saved = await app.fetch(
      new Request("http://localhost/v1/admin/runtime-config", {
        method: "PUT",
        headers: {
          authorization: "Bearer admin",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-key-01",
        },
        body: JSON.stringify({
          reason: "set qwen key for failure test",
          qwen: { apiKey: "sk-test-key" },
        }),
      }),
    );
    expect(saved.status).toBe(200);
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer admin",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-04",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-2",
          chapterFingerprint: "ch-2",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(503);
    const body = await readJson(response);
    expect(isRecord(body) && typeof body.detail === "string").toBe(true);
    expect(String(isRecord(body) ? body.detail : "")).toContain(
      "Managed Qwen endpoint is unreachable",
    );
    expect(String(isRecord(body) ? body.detail : "")).toContain("qwen3.7-plus");
  });

  it("returns 503 when every matching Qwen policy is disabled", async () => {
    const database = createFakeDatabaseClient();
    for (const policy of await database.ops.listPolicies()) {
      await database.ops.patchPolicy(policy.id, { enabled: false });
    }
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient(),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-05",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-3",
          chapterFingerprint: "ch-3",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(503);
    const body = await readJson(response);
    expect(isRecord(body) && body.detail).toBe("Managed Qwen policy for translation is disabled.");
  });

  it("fails closed before calling Qwen when a persisted prompt contract is invalid", async () => {
    const database = createFakeDatabaseClient();
    const translation = (await database.ops.listPolicies()).find(
      (policy) => policy.task === "translation",
    );
    expect(translation).toBeDefined();
    if (translation === undefined) return;
    await database.ops.patchPolicy(translation.id, { schemaVersion: "2" });
    let completions = 0;
    const inner = createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' });
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: (request) => {
          completions += 1;
          return inner.complete(request);
        },
      },
    });

    const response = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Invalid persisted prompt contract.", {
        editionFingerprint: "ed-invalid-contract",
        chapterFingerprint: "ch-invalid-contract",
      }),
      "idempotency-key-invalid-prompt-contract",
    );

    expect(response.status).toBe(503);
    expect(completions).toBe(0);
    const body = await readJson(response);
    expect(String(isRecord(body) ? body.detail : "")).toContain(
      "prompt contract validation failed",
    );
  });

  it("sends the operator system prompt instead of the hard-coded default", async () => {
    const database = createFakeDatabaseClient();
    const policies = await database.ops.listPolicies();
    const translation = policies.find((policy) => policy.task === "translation");
    expect(translation).toBeDefined();
    if (translation === undefined) {
      return;
    }
    await database.ops.patchPolicy(translation.id, {
      systemPrompt: "Return JSON with keys translation and notes. Operator prompt v2.",
      promptVersion: "operator-v2",
    });
    const seen: string[] = [];
    const inner = createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' });
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          const system = request.messages.find((message) => message.role === "system");
          if (system !== undefined) {
            seen.push(system.content);
          }
          const user = request.messages.find((message) => message.role === "user");
          if (user !== undefined) {
            seen.push(`user:${user.content}`);
          }
          return inner.complete(request);
        },
      },
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-06",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-4",
          chapterFingerprint: "ch-4",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && body.policyVersion).toBe("operator-v2");
    expect(seen[0]).toContain("Operator prompt v2.");
    expect(seen[0]).toContain("Additional task instructions from the app:");
    expect(seen[0]).toContain("notes[].explanation MUST be in the target language");
    expect(seen[0]).toContain("Simplified Chinese");
    expect(seen[0]).toContain("App Translate into setting: zh");
    expect(seen[1]?.startsWith("user:")).toBe(true);
    expect(seen[1]).toContain("Hello");
    expect(seen[1]).toContain("Task: sentence");
  });

  it("rejects assistant calls from an unregistered device", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          "Idempotency-Key": "idempotency-key-qwen-unregistered",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Hello",
          editionFingerprint: "ed-1",
          chapterFingerprint: "ch-1",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(401);
  });

  it("asks Qwen to write chapter summaries in the target language", async () => {
    const messages: { role: string; content: string }[] = [];
    const inner = createFakeQwenClient({
      text: JSON.stringify({
        overview: "维克多把生物唤醒后逃走。",
        keyPoints: ["造物在雨夜中醒来"],
        charactersOrIdeas: ["维克多"],
        keyConcepts: [{ name: "造物", explanation: "被唤醒的生命" }],
        themes: ["恐惧"],
      }),
    });
    const app = createTestApp({
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          for (const message of request.messages) {
            messages.push({ role: message.role, content: message.content });
          }
          return inner.complete(request);
        },
      },
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-summary-01",
        },
        body: JSON.stringify({
          chapterId: DEVICE_ID,
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          segments: ["It was on a dreary night of November."],
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && body.overview).toBe("维克多把生物唤醒后逃走。");
    const system = messages.find((message) => message.role === "system")?.content ?? "";
    expect(system).toContain("Write the entire summary in the target language");
    expect(system).toContain("Simplified Chinese");
  });

  it("uses sentence neighbor context without storing it in the shared cache", async () => {
    const users: string[] = [];
    const inner = createFakeQwenClient({ text: '{"translation":"她打破了沉默。","notes":[]}' });
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          const user = request.messages.find((message) => message.role === "user");
          if (user !== undefined) {
            users.push(user.content);
          }
          return inner.complete(request);
        },
      },
    });
    const contextBefore =
      "PREVIOUS: The room fell silent.\nTARGET id=s1: She broke the ice.\nNEXT: Everyone relaxed.";
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-sentence-context",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "She broke the ice.",
          contextBefore,
          editionFingerprint: "ed-ctx",
          chapterFingerprint: "ch-ctx",
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(users[0]).toContain("The room fell silent.");
    expect(users[0]).toContain("Everyone relaxed.");
    const listed = await createTestApp({
      database,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    }).fetch(
      new Request("http://localhost/v1/admin/cache", {
        headers: { authorization: "Bearer admin" },
      }),
    );
    expect(listed.status).toBe(200);
    const page = await readJson(listed);
    const items =
      isRecord(page) && Array.isArray(page.items) ? (page.items as Record<string, unknown>[]) : [];
    const entry = items.find((item) => isRecord(body) && item.id === body.id);
    const payload = isRecord(entry) && isRecord(entry.payload) ? entry.payload : {};
    expect(payload.context).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain("The room fell silent.");
    expect(JSON.stringify(payload)).not.toContain("Everyone relaxed.");
  });

  it("trims sentence neighbors to the operator Desk context count", async () => {
    const users: string[] = [];
    const inner = createFakeQwenClient({ text: '{"translation":"她打破了沉默。","notes":[]}' });
    const database = createFakeDatabaseClient();
    await database.ops.putOperatorSettings({
      id: "default",
      payload: { sentenceContextCount: 1 },
      ciphertext: null,
      nonce: null,
      updatedBy: "00000000-0000-4000-8000-000000000002",
    });
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          const user = request.messages.find((message) => message.role === "user");
          if (user !== undefined) {
            users.push(user.content);
          }
          return inner.complete(request);
        },
      },
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-sentence-radius",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          learnerLevel: "intermediate",
          source: "She broke the ice.",
          contextPrevious: ["The room fell silent.", "Nobody spoke."],
          contextNext: ["Everyone relaxed.", "Then they sat."],
          editionFingerprint: "ed-radius",
          chapterFingerprint: "ch-radius",
        }),
      }),
    );
    expect(response.status).toBe(200);
    expect(users[0]).toContain("PREVIOUS: Nobody spoke.");
    expect(users[0]).toContain("TARGET: She broke the ice.");
    expect(users[0]).toContain("NEXT: Everyone relaxed.");
    expect(users[0]).not.toContain("The room fell silent.");
    expect(users[0]).not.toContain("Then they sat.");
    expect(users[0]).toContain("Simplified Chinese");
  });

  it("does not consume quota on a translation cache hit", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 1);
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({ text: '{"translation":"你好","notes":[]}' }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const payload = {
      task: "sentence",
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      source: "Quota hello",
      editionFingerprint: "ed-quota",
      chapterFingerprint: "ch-quota",
      promptVersion: "v1",
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-quota-1" },
        body: JSON.stringify(payload),
      }),
    );
    const cached = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-quota-2" },
        body: JSON.stringify(payload),
      }),
    );
    const other = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-quota-3" },
        body: JSON.stringify({ ...payload, source: "Quota other" }),
      }),
    );
    expect(first.status).toBe(200);
    expect(cached.status).toBe(200);
    const cachedBody = await readJson(cached);
    expect(isRecord(cachedBody) && cachedBody.provenance).toBe("cache_shared_exact");
    expect(other.status).toBe(429);
  });

  it("returns 404 for lookupOnly translation misses without calling Qwen", async () => {
    let completions = 0;
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-lookup-miss",
        },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Lookup miss",
          lookupOnly: true,
          editionFingerprint: "ed-lookup",
          chapterFingerprint: "ch-lookup",
          promptVersion: "v1",
        }),
      }),
    );
    expect(response.status).toBe(404);
    expect(completions).toBe(0);
  });

  it("translates a sentence block once and reuses each sentence from cache", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translations: [
            { id: "s1", translation: "第一句。", notes: [] },
            { id: "s2", translation: "第二句。", notes: [] },
            { id: "s3", translation: "第三句。", notes: [] },
          ],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const batch = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-1" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          learnerLevel: "intermediate",
          sentences: [
            { id: "s1", text: "The room fell silent." },
            { id: "s2", text: "She broke the ice." },
            { id: "s3", text: "Everyone relaxed." },
          ],
          contextPrevious: ["Earlier."],
          contextNext: ["Later."],
          editionFingerprint: "ed-batch",
          chapterFingerprint: "ch-batch",
        }),
      }),
    );
    expect(batch.status).toBe(200);
    const body = await readJson(batch);
    expect(isRecord(body) && Array.isArray(body.results) && body.results).toHaveLength(3);
    expect(isRecord(body) && body.generatedCount).toBe(3);
    expect(isRecord(body) && body.cacheHitCount).toBe(0);
    expect(completions).toBe(1);

    const lookup = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-2" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          learnerLevel: "intermediate",
          sentences: [{ id: "s2", text: "She broke the ice." }],
          lookupOnly: true,
          editionFingerprint: "ed-batch",
          chapterFingerprint: "ch-batch",
        }),
      }),
    );
    expect(lookup.status).toBe(200);
    const looked = await readJson(lookup);
    expect(isRecord(looked) && looked.cacheHitCount).toBe(1);
    expect(isRecord(looked) && looked.generatedCount).toBe(0);
    const results = isRecord(looked) ? looked.results : undefined;
    const hit: unknown = Array.isArray(results) ? results[0] : undefined;
    expect(isRecord(hit) && hit.translation).toBe("第二句。");
    expect(isRecord(hit) && hit.provenance).toBe("cache_shared_exact");
    expect(completions).toBe(1);

    const single = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-3" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          learnerLevel: "intermediate",
          source: "She broke the ice.",
          lookupOnly: true,
          editionFingerprint: "ed-batch",
          chapterFingerprint: "ch-batch",
          promptVersion: "v1",
        }),
      }),
    );
    expect(single.status).toBe(200);
    const singleBody = await readJson(single);
    expect(isRecord(singleBody) && singleBody.provenance).toBe("cache_shared_exact");
    expect(completions).toBe(1);
  });

  it("returns 404 for lookupOnly summary misses and hydrates hits without Qwen", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const qwen = createFakeQwenClient({
      text: JSON.stringify({
        overview: "维克多把生物唤醒后逃走。",
        keyPoints: ["造物在雨夜中醒来"],
        charactersOrIdeas: ["维克多"],
        keyConcepts: [{ name: "造物", explanation: "被唤醒的生命" }],
        themes: ["恐惧"],
      }),
      onComplete: () => {
        completions += 1;
      },
    });
    const app = createTestApp({ database, qwen });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const miss = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-lookup-miss" },
        body: JSON.stringify({
          chapterId: DEVICE_ID,
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          segments: ["It was on a dreary night of November."],
          lookupOnly: true,
        }),
      }),
    );
    expect(miss.status).toBe(404);
    expect(completions).toBe(0);

    const generated = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-generate" },
        body: JSON.stringify({
          chapterId: DEVICE_ID,
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          segments: ["It was on a dreary night of November."],
        }),
      }),
    );
    expect(generated.status).toBe(200);
    expect(completions).toBe(1);

    const hit = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-lookup-hit" },
        body: JSON.stringify({
          chapterId: DEVICE_ID,
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          segments: ["It was on a dreary night of November."],
          lookupOnly: true,
        }),
      }),
    );
    expect(hit.status).toBe(200);
    const body = await readJson(hit);
    expect(isRecord(body) && body.provenance).toBe("cache_shared_exact");
    expect(completions).toBe(1);
  });

  it("regenerates a translation when refresh is true", async () => {
    let translationText = '{"translation":"旧译文","notes":[]}';
    const inner = createFakeQwenClient({ text: '{"translation":"unused","notes":[]}' });
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: () => Promise.resolve({ ok: true, text: translationText, model: "qwen3.7-plus" }),
      },
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const payload = {
      task: "sentence",
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      source: "Refresh hello",
      editionFingerprint: "ed-refresh",
      chapterFingerprint: "ch-refresh",
      promptVersion: "v1",
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-refresh-1" },
        body: JSON.stringify(payload),
      }),
    );
    expect(first.status).toBe(200);
    const firstBody = await readJson(first);
    expect(isRecord(firstBody) && firstBody.translation).toBe("旧译文");
    expect(isRecord(firstBody) && firstBody.provenance).toBe("generated");

    translationText = '{"translation":"新译文","notes":[]}';
    const refreshed = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-refresh-2" },
        body: JSON.stringify({ ...payload, refresh: true }),
      }),
    );
    expect(refreshed.status).toBe(200);
    const refreshedBody = await readJson(refreshed);
    expect(isRecord(refreshedBody) && refreshedBody.translation).toBe("新译文");
    expect(isRecord(refreshedBody) && refreshedBody.provenance).toBe("generated");
  });

  it("regenerates a chapter summary when refresh is true", async () => {
    let summaryText = JSON.stringify({
      overview: "旧概述",
      keyPoints: ["旧要点"],
      charactersOrIdeas: ["维克多"],
      keyConcepts: [{ name: "造物", explanation: "被唤醒的生命" }],
      themes: ["恐惧"],
    });
    const inner = createFakeQwenClient({ text: "{}" });
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: () => Promise.resolve({ ok: true, text: summaryText, model: "qwen3.7-plus" }),
      },
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const payload = {
      chapterId: DEVICE_ID,
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      segments: ["It was on a dreary night of November."],
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-refresh-1" },
        body: JSON.stringify(payload),
      }),
    );
    expect(first.status).toBe(200);
    const firstBody = await readJson(first);
    expect(isRecord(firstBody) && firstBody.overview).toBe("旧概述");
    expect(isRecord(firstBody) && firstBody.provenance).toBe("generated");

    summaryText = JSON.stringify({
      overview: "新概述",
      keyPoints: ["新要点"],
      charactersOrIdeas: ["维克多"],
      keyConcepts: [{ name: "造物", explanation: "被唤醒的生命" }],
      themes: ["恐惧"],
    });
    const refreshed = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-refresh-2" },
        body: JSON.stringify({ ...payload, refresh: true }),
      }),
    );
    expect(refreshed.status).toBe(200);
    const refreshedBody = await readJson(refreshed);
    expect(isRecord(refreshedBody) && refreshedBody.overview).toBe("新概述");
    expect(isRecord(refreshedBody) && refreshedBody.provenance).toBe("generated");
  });

  it("includes in-block neighbors from contextBefore without targeting them", async () => {
    const users: string[] = [];
    const inner = createFakeQwenClient({
      text: JSON.stringify({
        translations: [{ id: "s2", translation: "她打破了沉默。", notes: [] }],
      }),
    });
    const app = createTestApp({
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: async (request) => {
          const user = request.messages.find((message) => message.role === "user");
          if (user !== undefined) {
            users.push(user.content);
          }
          return inner.complete(request);
        },
      },
    });
    const neighbor = "The room fell silent.";
    const contextBefore = `PREVIOUS: ${neighbor}\nTARGET id=s2: She broke the ice.\nNEXT: Everyone relaxed.`;
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-batch-context",
        },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh-Hans",
          learnerLevel: "intermediate",
          sentences: [{ id: "s2", text: "She broke the ice." }],
          contextBefore,
          editionFingerprint: "ed-batch-ctx",
          chapterFingerprint: "ch-batch-ctx",
        }),
      }),
    );
    expect(response.status).toBe(200);
    expect(users[0]).toContain(neighbor);
    expect(users[0]).toContain("Everyone relaxed.");
    expect(users[0]).toContain("TARGET id=s2:");
    expect(users[0]).not.toMatch(/TARGET id=(?!s2:)/);
  });

  it("rejects an empty translation batch without calling Qwen", async () => {
    let completions = 0;
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: '{"translations":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-batch-empty",
        },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [],
          editionFingerprint: "ed-empty",
          chapterFingerprint: "ch-empty",
        }),
      }),
    );
    expect(response.status).toBe(400);
    expect(completions).toBe(0);
  });

  it("returns 405 for GET on translation batches", async () => {
    const response = await createTestApp().fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "GET",
        headers: { authorization: "Bearer test", "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toContain("POST");
  });

  it("lookupOnly sentence hits skip Qwen after a generated cache row", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const payload = {
      task: "sentence",
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      source: "Lookup hit please",
      editionFingerprint: "ed-lookup-hit",
      chapterFingerprint: "ch-lookup-hit",
      promptVersion: "v1",
    };
    const generated = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-lookup-hit-1" },
        body: JSON.stringify(payload),
      }),
    );
    expect(generated.status).toBe(200);
    const lookup = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-lookup-hit-2" },
        body: JSON.stringify({ ...payload, lookupOnly: true }),
      }),
    );
    expect(lookup.status).toBe(200);
    const body = await readJson(lookup);
    expect(isRecord(body) && body.provenance).toBe("cache_shared_exact");
    expect(completions).toBe(1);
  });

  it("does not consume quota on lookupOnly misses", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 1);
    let completions = 0;
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const miss = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-lookup-quota-1" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Lookup quota miss",
          lookupOnly: true,
          editionFingerprint: "ed-lookup-quota",
          chapterFingerprint: "ch-lookup-quota",
          promptVersion: "v1",
        }),
      }),
    );
    expect(miss.status).toBe(404);
    expect(completions).toBe(0);
    const generated = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-lookup-quota-2" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Lookup quota generate",
          editionFingerprint: "ed-lookup-quota",
          chapterFingerprint: "ch-lookup-quota",
          promptVersion: "v1",
        }),
      }),
    );
    expect(generated.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("reuses a sentence cache row even when neighbor context changes", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"她打破了沉默。","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sentence-ctx-1" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "She broke the ice.",
          contextPrevious: ["The room fell silent."],
          contextNext: ["Everyone relaxed."],
          editionFingerprint: "ed-sentence-ctx",
          chapterFingerprint: "ch-sentence-ctx",
          promptVersion: "v1",
        }),
      }),
    );
    expect(first.status).toBe(200);
    const lookup = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sentence-ctx-2" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "She broke the ice.",
          lookupOnly: true,
          editionFingerprint: "ed-sentence-ctx",
          chapterFingerprint: "ch-sentence-ctx",
          promptVersion: "v1",
        }),
      }),
    );
    expect(lookup.status).toBe(200);
    const body = await readJson(lookup);
    expect(isRecord(body) && body.provenance).toBe("cache_shared_exact");
    expect(completions).toBe(1);
  });

  it("keeps word cache rows scoped to the containing sentence", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translation: "noun — ice",
          connection: "",
          examples: [
            { source: "The ice closed.", translation: "冰封了。" },
            { source: "The lake froze.", translation: "湖结冰了。" },
          ],
          notes: [],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-word-ctx-1" },
        body: JSON.stringify({
          task: "word",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "ice",
          contextBefore: "The ice closed over the channel.",
          editionFingerprint: "ed-word-ctx",
          chapterFingerprint: "ch-word-ctx",
          promptVersion: "v1",
        }),
      }),
    );
    expect(first.status).toBe(200);
    const miss = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-word-ctx-2" },
        body: JSON.stringify({
          task: "word",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "ice",
          contextBefore: "She broke the ice.",
          lookupOnly: true,
          editionFingerprint: "ed-word-ctx",
          chapterFingerprint: "ch-word-ctx",
          promptVersion: "v1",
        }),
      }),
    );
    expect(miss.status).toBe(404);
    const hit = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-word-ctx-3" },
        body: JSON.stringify({
          task: "word",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "ice",
          contextBefore: "The ice closed over the channel.",
          lookupOnly: true,
          editionFingerprint: "ed-word-ctx",
          chapterFingerprint: "ch-word-ctx",
          promptVersion: "v1",
        }),
      }),
    );
    expect(hit.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("returns empty batch lookup hits without generating", async () => {
    let completions = 0;
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: '{"translations":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-batch-lookup-empty",
        },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [
            { id: "s1", text: "One." },
            { id: "s2", text: "Two." },
          ],
          lookupOnly: true,
          editionFingerprint: "ed-batch-empty",
          chapterFingerprint: "ch-batch-empty",
        }),
      }),
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && Array.isArray(body.results) ? body.results : []).toHaveLength(0);
    expect(isRecord(body) && body.missingIds).toEqual(["s1", "s2"]);
    expect(isRecord(body) && body.generatedCount).toBe(0);
    expect(completions).toBe(0);
  });

  it("charges one quota for a multi-sentence batch generate", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 1);
    let completions = 0;
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translations: [
            { id: "s1", translation: "一。", notes: [] },
            { id: "s2", translation: "二。", notes: [] },
          ],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const batch = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-quota-1" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [
            { id: "s1", text: "One." },
            { id: "s2", text: "Two." },
          ],
          editionFingerprint: "ed-batch-quota",
          chapterFingerprint: "ch-batch-quota",
        }),
      }),
    );
    expect(batch.status).toBe(200);
    expect(completions).toBe(1);
    const cached = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-quota-2" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [{ id: "s1", text: "One." }],
          lookupOnly: true,
          editionFingerprint: "ed-batch-quota",
          chapterFingerprint: "ch-batch-quota",
        }),
      }),
    );
    expect(cached.status).toBe(200);
    const other = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-quota-3" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "Three.",
          editionFingerprint: "ed-batch-quota",
          chapterFingerprint: "ch-batch-quota",
          promptVersion: "v1",
        }),
      }),
    );
    expect(other.status).toBe(429);
    expect(completions).toBe(1);
  });

  it("regenerates only refreshIds in a translation batch", async () => {
    let completions = 0;
    let text = JSON.stringify({
      translations: [
        { id: "s1", translation: "旧一。", notes: [] },
        { id: "s2", translation: "旧二。", notes: [] },
      ],
    });
    const inner = createFakeQwenClient({ text: '{"translations":[]}' });
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: {
        ping: () => inner.ping(),
        pingDetailed: () => inner.pingDetailed(),
        complete: () => {
          completions += 1;
          return Promise.resolve({ ok: true, text, model: "qwen3.7-plus" });
        },
      },
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-refresh-1" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [
            { id: "s1", text: "One." },
            { id: "s2", text: "Two." },
          ],
          editionFingerprint: "ed-batch-refresh",
          chapterFingerprint: "ch-batch-refresh",
        }),
      }),
    );
    expect(first.status).toBe(200);
    text = JSON.stringify({
      translations: [{ id: "s2", translation: "新二。", notes: [] }],
    });
    const refreshed = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-batch-refresh-2" },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [
            { id: "s1", text: "One." },
            { id: "s2", text: "Two." },
          ],
          refreshIds: ["s2"],
          editionFingerprint: "ed-batch-refresh",
          chapterFingerprint: "ch-batch-refresh",
        }),
      }),
    );
    expect(refreshed.status).toBe(200);
    expect(completions).toBe(2);
    const body = await readJson(refreshed);
    const results =
      isRecord(body) && Array.isArray(body.results)
        ? (body.results as Record<string, unknown>[])
        : [];
    const byId = new Map(results.map((item) => [item.targetId, item]));
    expect(byId.get("s1")?.translation).toBe("旧一。");
    expect(byId.get("s1")?.provenance).toBe("cache_shared_exact");
    expect(byId.get("s2")?.translation).toBe("新二。");
    expect(byId.get("s2")?.provenance).toBe("generated");
  });

  it("rejects a single-object translation payload for a one-sentence batch", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ text: '{"translation":"一句。","notes":[]}' }),
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/ai/translation-batches", {
        method: "POST",
        headers: {
          authorization: "Bearer test",
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-qwen-batch-single",
        },
        body: JSON.stringify({
          task: "chapter_batch",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          sentences: [{ id: "s1", text: "One sentence." }],
          editionFingerprint: "ed-batch-single",
          chapterFingerprint: "ch-batch-single",
        }),
      }),
    );
    expect(response.status).toBe(502);
    const body = await readJson(response);
    expect(isRecord(body) && body.code).toBe("invalid_upstream_response");
  });

  it("does not consume summary quota on a cache hit", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 1);
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          overview: "概述",
          keyPoints: ["要点"],
          charactersOrIdeas: [],
          keyConcepts: [],
          themes: [],
        }),
      }),
    });
    const headers = {
      authorization: "Bearer test",
      "content-type": "application/json",
      "X-Device-Id": DEVICE_ID,
    };
    const payload = {
      chapterId: DEVICE_ID,
      sourceLanguage: "en",
      targetLanguage: "zh",
      learnerLevel: "intermediate",
      segments: ["It was on a dreary night of November."],
    };
    const first = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-quota-1" },
        body: JSON.stringify(payload),
      }),
    );
    expect(first.status).toBe(200);
    const cached = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-quota-2" },
        body: JSON.stringify({ ...payload, lookupOnly: true }),
      }),
    );
    expect(cached.status).toBe(200);
    const other = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...headers, "Idempotency-Key": "idempotency-key-qwen-sum-quota-3" },
        body: JSON.stringify({
          task: "sentence",
          sourceLanguage: "en",
          targetLanguage: "zh",
          learnerLevel: "intermediate",
          source: "After summary quota.",
          editionFingerprint: "ed-sum-quota",
          chapterFingerprint: "ch-sum-quota",
          promptVersion: "v1",
        }),
      }),
    );
    expect(other.status).toBe(429);
  });
});

describe("assistant route helpers", () => {
  it("recognizes assistant paths and rejects the wrong HTTP methods", () => {
    expect(isAssistantPath("/v1/ai/translations")).toBe(true);
    expect(isAssistantPath("/v1/ai/translation-batches")).toBe(true);
    expect(isAssistantPath("/v1/ai/chapter-summaries")).toBe(true);
    expect(isAssistantPath("/v1/ai/chat")).toBe(true);
    expect(isAssistantPath(`/v1/ai/chat/${DEVICE_ID}/messages/${DEVICE_ID}`)).toBe(true);
    expect(isAssistantPath("/v1/health")).toBe(false);

    expect(assistantMethodError("/v1/ai/translations", "POST", "rid")).toBeUndefined();
    expect(
      assistantMethodError(`/v1/ai/chat/${DEVICE_ID}/messages/${DEVICE_ID}`, "GET", "rid"),
    ).toBeUndefined();

    const getTranslations = assistantMethodError("/v1/ai/translations", "GET", "rid");
    expect(getTranslations?.status).toBe(405);
    expect(getTranslations?.headers.get("Allow")).toBe("POST");

    const postChatMessage = assistantMethodError(
      `/v1/ai/chat/${DEVICE_ID}/messages/${DEVICE_ID}`,
      "POST",
      "rid",
    );
    expect(postChatMessage?.status).toBe(405);
    expect(postChatMessage?.headers.get("Allow")).toBe("GET");
  });
});

describe("managed Qwen cache identity and batch edge cases", () => {
  it("rejects unauthenticated batches and summaries", async () => {
    const app = createTestApp({ authenticate: () => null });
    const batch = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "Hello." }]),
      "idempotency-key-qwen-unauth-batch",
    );
    const summary = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["Hello."]),
      "idempotency-key-qwen-unauth-summary",
    );
    expect(batch.status).toBe(401);
    expect(summary.status).toBe(401);
  });

  it("returns 405 for GET on translations and summaries", async () => {
    const app = createTestApp();
    const translations = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "GET",
        headers: { authorization: "Bearer test", "X-Device-Id": DEVICE_ID },
      }),
    );
    const summaries = await app.fetch(
      new Request("http://localhost/v1/ai/chapter-summaries", {
        method: "GET",
        headers: { authorization: "Bearer test", "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(translations.status).toBe(405);
    expect(translations.headers.get("Allow")).toContain("POST");
    expect(summaries.status).toBe(405);
    expect(summaries.headers.get("Allow")).toContain("POST");
  });

  it("returns 405 for POST on a chat message URL", async () => {
    const response = await createTestApp().fetch(
      new Request(`http://localhost/v1/ai/chat/${DEVICE_ID}/messages/${DEVICE_ID}`, {
        method: "POST",
        headers: AUTH_HEADERS,
        body: JSON.stringify({ text: "nope" }),
      }),
    );
    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("GET");
  });

  it("rejects invalid JSON and missing translation source language", async () => {
    const app = createTestApp();
    const invalid = await app.fetch(
      new Request("http://localhost/v1/ai/translations", {
        method: "POST",
        headers: { ...AUTH_HEADERS, "Idempotency-Key": "idempotency-key-qwen-invalid-json" },
        body: "{not-json",
      }),
    );
    const missingLanguage = await postAssistant(
      app,
      "/v1/ai/translations",
      {
        task: "sentence",
        targetLanguage: "zh",
        learnerLevel: "intermediate",
        source: "Hello",
        editionFingerprint: "ed-1",
        chapterFingerprint: "ch-1",
        promptVersion: "v1",
      },
      "idempotency-key-qwen-missing-lang",
    );
    expect(invalid.status).toBe(400);
    expect(missingLanguage.status).toBe(400);
  });

  it("rejects batches whose sentences have no usable id or text", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ text: '{"translations":[]}' }),
    });
    const response = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([
        { id: "  ", text: "Hello." },
        { id: "s1", text: "   " },
      ]),
      "idempotency-key-qwen-batch-blank",
    );
    expect(response.status).toBe(400);
  });

  it("keeps the first sentence when a batch repeats the same id", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: JSON.stringify({ translations: [{ id: "s1", translation: "你好。", notes: [] }] }),
      }),
    });
    const response = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([
        { id: "s1", text: "Hello." },
        { id: "s1", text: "Hello again." },
      ]),
      "idempotency-key-qwen-batch-dup",
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    const results =
      isRecord(body) && Array.isArray(body.results)
        ? (body.results as Record<string, unknown>[])
        : [];
    expect(results).toHaveLength(1);
    expect(results[0]?.targetId).toBe("s1");
    expect(results[0]?.source).toBe("Hello.");
  });

  it("caps a translation batch at forty sentences", async () => {
    const sentences = Array.from({ length: 41 }, (_, index) => ({
      id: `s${String(index + 1)}`,
      text: `Sentence ${String(index + 1)}.`,
    }));
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translations: sentences.slice(0, 40).map((sentence) => ({
            id: sentence.id,
            translation: sentence.text,
            notes: [],
          })),
        }),
      }),
    });
    const response = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody(sentences, { editionFingerprint: "ed-cap", chapterFingerprint: "ch-cap" }),
      "idempotency-key-qwen-batch-cap",
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(isRecord(body) && Array.isArray(body.results) ? body.results : []).toHaveLength(40);
  });

  it("returns mixed lookupOnly hits without generating the misses", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"第一句。","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("One.", { editionFingerprint: "ed-mix", chapterFingerprint: "ch-mix" }),
      "idempotency-key-qwen-mix-1",
    );
    expect(generated.status).toBe(200);
    const lookup = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody(
        [
          { id: "s1", text: "One." },
          { id: "s2", text: "Two." },
        ],
        { lookupOnly: true, editionFingerprint: "ed-mix", chapterFingerprint: "ch-mix" },
      ),
      "idempotency-key-qwen-mix-2",
    );
    expect(lookup.status).toBe(200);
    const body = await readJson(lookup);
    expect(isRecord(body) && body.cacheHitCount).toBe(1);
    expect(isRecord(body) && body.generatedCount).toBe(0);
    expect(isRecord(body) && body.missingIds).toEqual(["s2"]);
    const results =
      isRecord(body) && Array.isArray(body.results)
        ? (body.results as Record<string, unknown>[])
        : [];
    expect(results[0]?.translation).toBe("第一句。");
    expect(completions).toBe(1);
  });

  it("rejects a batch when Qwen omits a requested sentence", async () => {
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({ translations: [{ id: "s1", translation: "一。", notes: [] }] }),
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody(
        [
          { id: "s1", text: "One." },
          { id: "s2", text: "Two." },
        ],
        { editionFingerprint: "ed-partial", chapterFingerprint: "ch-partial" },
      ),
      "idempotency-key-qwen-partial-1",
    );
    expect(generated.status).toBe(502);
    const body = await readJson(generated);
    expect(isRecord(body) && body.code).toBe("invalid_upstream_response");

    const lookup = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody(
        [
          { id: "s1", text: "One." },
          { id: "s2", text: "Two." },
        ],
        { lookupOnly: true, editionFingerprint: "ed-partial", chapterFingerprint: "ch-partial" },
      ),
      "idempotency-key-qwen-partial-2",
    );
    const looked = await readJson(lookup);
    expect(isRecord(looked) && looked.cacheHitCount).toBe(0);
    expect(isRecord(looked) && looked.missingIds).toEqual(["s1", "s2"]);
  });

  it("accepts Qwen translation notes that use the Chinese explanation key", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translations: [
            {
              id: "s1",
              translation: "你好。",
              notes: [{ source: "Hello", category: "phrase", 解释: "问候语" }],
            },
          ],
        }),
      }),
    });

    const response = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "Hello." }], {
        editionFingerprint: "ed-localized-note",
        chapterFingerprint: "ch-localized-note",
      }),
      "idempotency-key-qwen-localized-note",
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    const results = isRecord(body) && Array.isArray(body.results) ? body.results : [];
    expect(results).toMatchObject([
      {
        translation: "你好。",
        notes: [{ source: "Hello", category: "phrase", explanation: "问候语" }],
      },
    ]);
  });

  it("rejects legacy results and targetId fields outside the batch contract", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          results: [
            { targetId: "s1", translation: "一。", notes: [] },
            { id: "ignored", translation: "丢弃。", notes: [] },
          ],
        }),
      }),
    });
    const response = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "One." }], {
        editionFingerprint: "ed-results",
        chapterFingerprint: "ch-results",
      }),
      "idempotency-key-qwen-batch-results",
    );
    expect(response.status).toBe(502);
    const body = await readJson(response);
    expect(isRecord(body) && body.code).toBe("invalid_upstream_response");
  });

  it("returns 503 when a batch generate cannot reach Qwen", async () => {
    const response = await postAssistant(
      createTestApp({ qwen: createFakeQwenClient({ status: "unavailable" }) }),
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "Hello." }], {
        editionFingerprint: "ed-unavail",
        chapterFingerprint: "ch-unavail",
      }),
      "idempotency-key-qwen-batch-unavail",
    );
    expect(response.status).toBe(503);
  });

  it("returns 429 before calling Qwen when the daily quota is already exhausted", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 0);
    let completions = 0;
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const translation = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Quota zero.", { editionFingerprint: "ed-zero", chapterFingerprint: "ch-zero" }),
      "idempotency-key-qwen-quota-zero-1",
    );
    const batch = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "Quota zero batch." }], {
        editionFingerprint: "ed-zero",
        chapterFingerprint: "ch-zero",
      }),
      "idempotency-key-qwen-quota-zero-2",
    );
    expect(translation.status).toBe(429);
    expect(batch.status).toBe(429);
    expect(completions).toBe(0);
  });

  it("misses cache when learner level, language, or edition change", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Identity hello.", { editionFingerprint: "ed-id" }),
      "idempotency-key-qwen-id-1",
    );
    expect(generated.status).toBe(200);
    const beginner = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Identity hello.", {
        learnerLevel: "beginner",
        lookupOnly: true,
        editionFingerprint: "ed-id",
      }),
      "idempotency-key-qwen-id-2",
    );
    const japanese = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Identity hello.", {
        targetLanguage: "ja",
        lookupOnly: true,
        editionFingerprint: "ed-id",
      }),
      "idempotency-key-qwen-id-3",
    );
    const otherEdition = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Identity hello.", { lookupOnly: true, editionFingerprint: "ed-other" }),
      "idempotency-key-qwen-id-4",
    );
    const exact = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Identity hello.", { lookupOnly: true, editionFingerprint: "ed-id" }),
      "idempotency-key-qwen-id-5",
    );
    expect(beginner.status).toBe(404);
    expect(japanese.status).toBe(404);
    expect(otherEdition.status).toBe(404);
    expect(exact.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("lookupOnly plus refresh never generates even when a cache row exists", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"translation":"你好","notes":[]}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Refresh lookup.", { editionFingerprint: "ed-rl" }),
      "idempotency-key-qwen-rl-1",
    );
    expect(generated.status).toBe(200);
    const lookup = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("Refresh lookup.", {
        lookupOnly: true,
        refresh: true,
        editionFingerprint: "ed-rl",
      }),
      "idempotency-key-qwen-rl-2",
    );
    expect(lookup.status).toBe(404);
    expect(completions).toBe(1);
  });

  it("lookupOnly plus refreshIds returns missing ids without generating", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({ translations: [{ id: "s1", translation: "一。", notes: [] }] }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "One." }], {
        editionFingerprint: "ed-rlb",
        chapterFingerprint: "ch-rlb",
      }),
      "idempotency-key-qwen-rlb-1",
    );
    expect(generated.status).toBe(200);
    const lookup = await postAssistant(
      app,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "One." }], {
        lookupOnly: true,
        refreshIds: ["s1"],
        editionFingerprint: "ed-rlb",
        chapterFingerprint: "ch-rlb",
      }),
      "idempotency-key-qwen-rlb-2",
    );
    expect(lookup.status).toBe(200);
    const body = await readJson(lookup);
    expect(isRecord(body) && body.missingIds).toEqual(["s1"]);
    expect(isRecord(body) && Array.isArray(body.results) ? body.results : []).toHaveLength(0);
    expect(completions).toBe(1);
  });

  it("misses a chapter summary when the joined segments change", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          overview: "概述",
          keyPoints: [],
          charactersOrIdeas: [],
          keyConcepts: [],
          themes: [],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["It was on a dreary night of November."]),
      "idempotency-key-qwen-sum-seg-1",
    );
    expect(generated.status).toBe(200);
    const miss = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["A different chapter."], { lookupOnly: true }),
      "idempotency-key-qwen-sum-seg-2",
    );
    const hit = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["It was on a dreary night of November."], { lookupOnly: true }),
      "idempotency-key-qwen-sum-seg-3",
    );
    expect(miss.status).toBe(404);
    expect(hit.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("lookupOnly plus refresh on a summary is a miss without a second Qwen call", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          overview: "概述",
          keyPoints: [],
          charactersOrIdeas: [],
          keyConcepts: [],
          themes: [],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const generated = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["Refresh summary."]),
      "idempotency-key-qwen-sum-rl-1",
    );
    expect(generated.status).toBe(200);
    const lookup = await postAssistant(
      app,
      "/v1/ai/chapter-summaries",
      summaryBody(["Refresh summary."], { lookupOnly: true, refresh: true }),
      "idempotency-key-qwen-sum-rl-2",
    );
    expect(lookup.status).toBe(404);
    expect(completions).toBe(1);
  });

  it("does not consume quota on a word lookupOnly miss", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.patchQuota("qwen_tasks_day", 1);
    let completions = 0;
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: JSON.stringify({
          translation: "noun — ice",
          connection: "",
          examples: [
            { source: "The ice melted.", translation: "冰融化了。" },
            { source: "Ice covered the lake.", translation: "冰覆盖着湖面。" },
          ],
          notes: [],
        }),
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const miss = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("ice", {
        task: "word",
        lookupOnly: true,
        contextBefore: "The ice closed.",
        editionFingerprint: "ed-word-q",
      }),
      "idempotency-key-qwen-word-q-1",
    );
    expect(miss.status).toBe(404);
    const generated = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("ice", {
        task: "word",
        contextBefore: "The ice closed.",
        editionFingerprint: "ed-word-q",
      }),
      "idempotency-key-qwen-word-q-2",
    );
    expect(generated.status).toBe(200);
    expect(completions).toBe(1);
  });

  it("blocks assistant calls in maintenance mode and when managed Qwen is disabled", async () => {
    const maintenance = createFakeDatabaseClient();
    await maintenance.ops.patchFlag("maintenance_mode", { enabled: true });
    const maintenanceApp = createTestApp({ database: maintenance });
    const maintained = await postAssistant(
      maintenanceApp,
      "/v1/ai/translations",
      sentenceBody("Hello."),
      "idempotency-key-qwen-maint",
    );
    expect(maintained.status).toBe(503);

    const disabled = createFakeDatabaseClient();
    await disabled.ops.patchFlag("managed_qwen", { enabled: false });
    const disabledApp = createTestApp({ database: disabled });
    const forbidden = await postAssistant(
      disabledApp,
      "/v1/ai/translation-batches",
      batchBody([{ id: "s1", text: "Hello." }]),
      "idempotency-key-qwen-disabled",
    );
    expect(forbidden.status).toBe(403);
  });

  it("does not write a translation cache row from chat", async () => {
    let completions = 0;
    const database = createFakeDatabaseClient();
    const app = createTestApp({
      database,
      qwen: createFakeQwenClient({
        text: '{"answer":"Chat about ice."}',
        onComplete: () => {
          completions += 1;
        },
      }),
    });
    const chat = await postAssistant(
      app,
      "/v1/ai/chat",
      {
        chapterId: DEVICE_ID,
        question: "What does the ice mean?",
        sourceLanguage: "en",
        targetLanguage: "zh",
        learnerLevel: "intermediate",
      },
      "idempotency-key-qwen-chat-cache-1",
    );
    expect(chat.status).toBe(202);
    const lookup = await postAssistant(
      app,
      "/v1/ai/translations",
      sentenceBody("What does the ice mean?", { lookupOnly: true, editionFingerprint: "ed-chat" }),
      "idempotency-key-qwen-chat-cache-2",
    );
    expect(lookup.status).toBe(404);
    expect(completions).toBe(1);
  });
});
