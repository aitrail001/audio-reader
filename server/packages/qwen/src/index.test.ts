import { describe, expect, it } from "vitest";
import {
  DEFAULT_QWEN_BASE_URL,
  createFakeQwenClient,
  createQwenClient,
  hmacCacheKey,
  packageId,
  sharedCacheMaterial,
  type QwenFetch,
} from "./index";

describe("@audio-reader/qwen", () => {
  it("identifies the qwen package", () => {
    expect(packageId).toBe("@audio-reader/qwen");
  });

  it("creates a ready fake Qwen adapter", async () => {
    const client = createFakeQwenClient();
    await expect(client.ping()).resolves.toBe("ok");
    await expect(client.complete({ messages: [{ role: "user", content: "hi" }] })).resolves.toEqual(
      {
        ok: true,
        text: '{"ok":true}',
        model: "qwen3.7-plus",
      },
    );
  });

  it("can simulate Qwen unavailability", async () => {
    const client = createFakeQwenClient({ status: "unavailable" });
    await expect(client.ping()).resolves.toBe("unavailable");
    await expect(client.pingDetailed()).resolves.toMatchObject({
      status: "unavailable",
      httpStatus: 503,
    });
    await expect(client.complete({ messages: [{ role: "user", content: "hi" }] })).resolves.toEqual(
      {
        ok: false,
        code: "unavailable",
        usedModel: "qwen3.7-plus",
        detail: "fake qwen client is unavailable",
      },
    );
  });

  it("pings and completes against the OpenAI-compatible Singapore endpoint", async () => {
    const calls: {
      url: string;
      method: string;
      authorization: string | undefined;
      body?: Record<string, unknown>;
    }[] = [];
    const fetchImpl: QwenFetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const headers = new Headers(init?.headers);
      calls.push({
        url,
        method: init?.method ?? "GET",
        authorization: headers.get("authorization") ?? undefined,
        ...(typeof init?.body === "string"
          ? { body: JSON.parse(init.body) as Record<string, unknown> }
          : {}),
      });
      if (url.endsWith("/models")) {
        return Promise.resolve(
          new Response(JSON.stringify({ data: [{ id: "qwen-plus" }] }), { status: 200 }),
        );
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            model: "qwen-plus",
            choices: [{ message: { role: "assistant", content: '{"gloss":"hello"}' } }],
          }),
          { status: 200 },
        ),
      );
    };
    const client = createQwenClient({
      apiKey: "sk-test",
      fetch: fetchImpl,
    });
    await expect(client.ping()).resolves.toBe("ok");
    const completed = await client.complete({
      messages: [{ role: "user", content: "translate hi" }],
      jsonObject: true,
      enableThinking: false,
    });
    expect(completed).toEqual({
      ok: true,
      text: '{"gloss":"hello"}',
      model: "qwen-plus",
    });
    expect(calls[0]?.url).toBe(`${DEFAULT_QWEN_BASE_URL}/models`);
    expect(calls[0]?.authorization).toBe("Bearer sk-test");
    expect(calls[1]?.url).toBe(`${DEFAULT_QWEN_BASE_URL}/chat/completions`);
    expect(calls[1]?.body).toMatchObject({
      enable_thinking: false,
      response_format: { type: "json_object" },
    });
  });

  it("returns ping HTTP status and redacts provider error bodies", async () => {
    const fetchImpl: QwenFetch = (input) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (url.endsWith("/models")) {
        return Promise.resolve(
          new Response(JSON.stringify({ error: "invalid Bearer sk-live-secret" }), { status: 401 }),
        );
      }
      return Promise.resolve(
        new Response(JSON.stringify({ error: "unknown model Bearer sk-live-secret" }), {
          status: 400,
        }),
      );
    };
    const client = createQwenClient({ apiKey: "sk-test", fetch: fetchImpl });
    await expect(client.pingDetailed()).resolves.toMatchObject({
      status: "unavailable",
      httpStatus: 401,
    });
    const ping = await client.pingDetailed();
    expect(ping.detail ?? "").not.toContain("sk-live-secret");
    const completed = await client.complete({
      messages: [{ role: "user", content: "hi" }],
      model: "missing-model",
    });
    expect(completed).toMatchObject({
      ok: false,
      code: "rejected",
      usedModel: "missing-model",
      httpStatus: 400,
    });
    if (completed.ok) {
      return;
    }
    expect(completed.detail ?? "").not.toContain("sk-live-secret");
    expect(completed.detail ?? "").toContain("Bearer [redacted]");
  });

  it("HMACs shared cache material so the same passage maps to one keyed hash", async () => {
    const material = await sharedCacheMaterial({
      taskType: "translation",
      sourceLanguage: "en",
      targetLanguage: "zh",
      source: "Hello",
      editionFingerprint: "ed-1",
    });
    const first = await hmacCacheKey("cache-secret", material);
    const second = await hmacCacheKey("cache-secret", material);
    const otherSecret = await hmacCacheKey("other-secret", material);
    expect(first).toBe(second);
    expect(first).toHaveLength(64);
    expect(otherSecret).not.toBe(first);
    expect(material.startsWith("translation|")).toBe(true);
    expect(material.includes("Hello")).toBe(false);
  });

  it("changes the cache material when neighbor context is part of the key", async () => {
    const base = {
      taskType: "translation",
      sourceLanguage: "en",
      targetLanguage: "zh",
      source: "ice",
      editionFingerprint: "ed-1",
    };
    const withoutContext = await sharedCacheMaterial(base);
    const withContext = await sharedCacheMaterial({
      ...base,
      context: "The ice closed over the channel.",
    });
    const emptyContext = await sharedCacheMaterial({ ...base, context: "" });
    expect(withoutContext).toBe(emptyContext);
    expect(withContext).not.toBe(emptyContext);
  });

  it("changes the cache material when language, level, or edition change", async () => {
    const base = {
      taskType: "translation",
      sourceLanguage: "en",
      targetLanguage: "zh",
      source: "Hello",
      editionFingerprint: "ed-1",
      learnerProfileBucket: "intermediate",
    };
    const original = await sharedCacheMaterial(base);
    const otherLanguage = await sharedCacheMaterial({ ...base, targetLanguage: "ja" });
    const otherLevel = await sharedCacheMaterial({ ...base, learnerProfileBucket: "beginner" });
    const otherEdition = await sharedCacheMaterial({ ...base, editionFingerprint: "ed-2" });
    const defaultLevel = await sharedCacheMaterial({
      taskType: "translation",
      sourceLanguage: "en",
      targetLanguage: "zh",
      source: "Hello",
      editionFingerprint: "ed-1",
    });
    expect(otherLanguage).not.toBe(original);
    expect(otherLevel).not.toBe(original);
    expect(otherEdition).not.toBe(original);
    expect(defaultLevel).toBe(original);
  });
});
