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
    expect(seen[0]).toBe("Return JSON with keys translation and notes. Operator prompt v2.");
  });
});
