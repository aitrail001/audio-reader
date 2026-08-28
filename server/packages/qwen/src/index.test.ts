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
    const calls: { url: string; method: string; authorization: string | undefined }[] = [];
    const fetchImpl: QwenFetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const headers = new Headers(init?.headers);
      calls.push({
        url,
        method: init?.method ?? "GET",
        authorization: headers.get("authorization") ?? undefined,
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
    });
    expect(completed).toEqual({
      ok: true,
      text: '{"gloss":"hello"}',
      model: "qwen-plus",
    });
    expect(calls[0]?.url).toBe(`${DEFAULT_QWEN_BASE_URL}/models`);
    expect(calls[0]?.authorization).toBe("Bearer sk-test");
    expect(calls[1]?.url).toBe(`${DEFAULT_QWEN_BASE_URL}/chat/completions`);
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
});
