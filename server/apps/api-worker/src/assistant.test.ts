import { createFakePrincipal } from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { describe, expect, it } from "vitest";
import { createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
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
    const app = createTestApp({
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
    const entry = items.find((item) => item.id === body.id);
    expect(entry).toBeDefined();
    expect(isRecord(entry) && entry.hitCount).toBe(0);
    const payload = isRecord(entry) && isRecord(entry.payload) ? entry.payload : {};
    expect(payload.source).toBe("ice");
    expect(payload.bookTitle).toBe("Frankenstein");
    expect(payload.translation).toContain("frozen sea");
  });

  it("returns a chat reply that can be fetched on the stream URL", async () => {
    const app = createTestApp({
      qwen: createFakeQwenClient({ text: "The ice is a metaphor." }),
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

  it("stores sentence neighbor context on the cache payload", async () => {
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
    expect(payload.context).toBe(contextBefore);
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
    const hit = isRecord(looked) && Array.isArray(looked.results) ? looked.results[0] : undefined;
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
        complete: async () => ({ ok: true, text: translationText, model: "qwen3.7-plus" }),
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
        complete: async () => ({ ok: true, text: summaryText, model: "qwen3.7-plus" }),
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
});
