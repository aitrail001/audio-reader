import { createFakePrincipal } from "@audio-reader/auth";
import { describe, expect, it, vi } from "vitest";
import { createMemoryIdempotencyStore, withIdempotency } from "./idempotency";

const jsonHeaders = {
  "Idempotency-Key": "idempotency-key-1",
  "content-type": "application/json",
};

function writeRequest(
  url = "http://localhost/v1/auth/bootstrap",
  body = "{}",
  headers: Record<string, string> = jsonHeaders,
): Request {
  return new Request(url, {
    method: "POST",
    headers,
    body,
  });
}

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

  it("uses a caller-provided content digest without weakening conflict detection", async () => {
    const store = createMemoryIdempotencyStore();
    let calls = 0;
    const headers = {
      "Idempotency-Key": "idempotency-key-digest",
      "content-type": "application/json",
    };
    const first = await withIdempotency(
      store,
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers,
        body: '{"large":"first"}',
      }),
      () => {
        calls += 1;
        return Promise.resolve(new Response("ok"));
      },
      "trace-digest",
      createFakePrincipal({ subject: "reader" }),
      "a".repeat(64),
    );
    const replay = await withIdempotency(
      store,
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers,
        body: '{"large":"second"}',
      }),
      () => Promise.resolve(new Response("should-not-run")),
      "trace-digest",
      createFakePrincipal({ subject: "reader" }),
      "a".repeat(64),
    );
    const conflict = await withIdempotency(
      store,
      new Request("http://localhost/v1/sync/push", {
        method: "POST",
        headers,
        body: '{"large":"third"}',
      }),
      () => Promise.resolve(new Response("should-not-run")),
      "trace-digest",
      createFakePrincipal({ subject: "reader" }),
      "b".repeat(64),
    );

    expect(first.status).toBe(200);
    expect(replay.status).toBe(200);
    expect(await replay.text()).toBe("ok");
    expect(conflict.status).toBe(409);
    expect(calls).toBe(1);
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

  it("scopes stored responses by principal so keys are not shared across users", async () => {
    const store = createMemoryIdempotencyStore();
    let calls = 0;
    const handler = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(new Response(`call-${String(calls)}`, { status: 200 }));
    };
    const alice = await withIdempotency(
      store,
      writeRequest(),
      handler,
      "trace-4",
      createFakePrincipal({ subject: "alice" }),
    );
    const bob = await withIdempotency(
      store,
      writeRequest(),
      handler,
      "trace-4",
      createFakePrincipal({ subject: "bob" }),
    );
    expect(await alice.text()).toBe("call-1");
    expect(await bob.text()).toBe("call-2");
    expect(calls).toBe(2);
  });

  it("treats a different query string or device id as a conflict", async () => {
    const store = createMemoryIdempotencyStore();
    await withIdempotency(
      store,
      writeRequest("http://localhost/v1/auth/bootstrap?n=1"),
      () => Promise.resolve(new Response("ok", { status: 200 })),
      "trace-5",
    );
    const queryConflict = await withIdempotency(
      store,
      writeRequest("http://localhost/v1/auth/bootstrap?n=2"),
      () => Promise.resolve(new Response("should-not-run", { status: 200 })),
      "trace-5",
    );
    expect(queryConflict.status).toBe(409);

    const deviceStore = createMemoryIdempotencyStore();
    const deviceHeaders = { ...jsonHeaders, "X-Device-Id": "device-a" };
    await withIdempotency(
      deviceStore,
      writeRequest("http://localhost/v1/auth/bootstrap", "{}", deviceHeaders),
      () => Promise.resolve(new Response("ok", { status: 200 })),
      "trace-6",
    );
    const deviceConflict = await withIdempotency(
      deviceStore,
      writeRequest("http://localhost/v1/auth/bootstrap", "{}", {
        ...jsonHeaders,
        "X-Device-Id": "device-b",
      }),
      () => Promise.resolve(new Response("should-not-run", { status: 200 })),
      "trace-6",
    );
    expect(deviceConflict.status).toBe(409);
  });

  it("does not cache 5xx responses", async () => {
    const store = createMemoryIdempotencyStore();
    let calls = 0;
    const handler = (): Promise<Response> => {
      calls += 1;
      return Promise.resolve(new Response("err", { status: 500 }));
    };
    const first = await withIdempotency(store, writeRequest(), handler, "trace-7");
    const second = await withIdempotency(store, writeRequest(), handler, "trace-7");
    expect(first.status).toBe(500);
    expect(second.status).toBe(500);
    expect(calls).toBe(2);
  });

  it("does not re-execute a concurrent first request for the same key", async () => {
    const store = createMemoryIdempotencyStore();
    let started = 0;
    let release = (): void => undefined;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const handler = async (): Promise<Response> => {
      started += 1;
      await gate;
      return new Response("ok", { status: 200 });
    };
    const first = withIdempotency(store, writeRequest(), handler, "trace-8");
    const second = withIdempotency(store, writeRequest(), handler, "trace-8");
    await vi.waitFor(() => {
      expect(started).toBe(1);
    });
    release();
    const [a, b] = await Promise.all([first, second]);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(await a.text()).toBe("ok");
    expect(await b.text()).toBe("ok");
    expect(started).toBe(1);
  });

  it("serializes retries so three in-flight 500s never overlap next()", async () => {
    const store = createMemoryIdempotencyStore();
    let inFlight = 0;
    let maxInFlight = 0;
    let calls = 0;
    const handler = async (): Promise<Response> => {
      calls += 1;
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 25);
      });
      inFlight -= 1;
      return new Response("err", { status: 500 });
    };
    const results = await Promise.all([
      withIdempotency(store, writeRequest(), handler, "trace-9"),
      withIdempotency(store, writeRequest(), handler, "trace-9"),
      withIdempotency(store, writeRequest(), handler, "trace-9"),
    ]);
    expect(results.map((response) => response.status)).toEqual([500, 500, 500]);
    expect(maxInFlight).toBe(1);
    expect(calls).toBe(3);
  });
});
