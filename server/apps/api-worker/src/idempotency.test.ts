import { describe, expect, it } from "vitest";
import { createMemoryIdempotencyStore, withIdempotency } from "./idempotency";

describe("route-level idempotency middleware", () => {
  it("replays the first response for the same key and body", async () => {
    const store = createMemoryIdempotencyStore();
    let calls = 0;
    const handler = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(new Response(`call-${String(calls)}`, { status: 201 }));
    };
    const headers = {
      "Idempotency-Key": "idempotency-key-1",
      "content-type": "application/json",
    };
    const first = await withIdempotency(
      store,
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers,
        body: '{"deviceId":"a"}',
      }),
      handler,
      "trace-1",
    );
    const second = await withIdempotency(
      store,
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers,
        body: '{"deviceId":"a"}',
      }),
      handler,
      "trace-1",
    );
    expect(first.status).toBe(201);
    expect(await first.text()).toBe("call-1");
    expect(second.status).toBe(201);
    expect(await second.text()).toBe("call-1");
    expect(calls).toBe(1);
  });

  it("rejects reuse of a key with a different payload", async () => {
    const store = createMemoryIdempotencyStore();
    const headers = {
      "Idempotency-Key": "idempotency-key-2",
      "content-type": "application/json",
    };
    await withIdempotency(
      store,
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers,
        body: '{"n":1}',
      }),
      () => Promise.resolve(new Response("ok", { status: 200 })),
      "trace-2",
    );
    const conflict = await withIdempotency(
      store,
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers,
        body: '{"n":2}',
      }),
      () => Promise.resolve(new Response("should-not-run", { status: 200 })),
      "trace-2",
    );
    expect(conflict.status).toBe(409);
    expect(conflict.headers.get("content-type")).toMatch(/application\/problem\+json/i);
    const payload: unknown = JSON.parse(await conflict.text());
    expect(typeof payload === "object" && payload !== null && "code" in payload).toBe(true);
    if (typeof payload === "object" && payload !== null && "code" in payload) {
      expect(payload.code).toBe("idempotency_key_conflict");
    }
  });

  it("requires an Idempotency-Key of 16 to 128 characters", async () => {
    const response = await withIdempotency(
      createMemoryIdempotencyStore(),
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      () => Promise.resolve(new Response("ok")),
      "trace-3",
    );
    expect(response.status).toBe(400);
    const payload: unknown = JSON.parse(await response.text());
    expect(typeof payload === "object" && payload !== null && "code" in payload).toBe(true);
    if (typeof payload === "object" && payload !== null && "code" in payload) {
      expect(payload.code).toBe("invalid_idempotency_key");
    }
  });
});
