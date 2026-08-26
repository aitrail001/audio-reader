import { createFakePrincipal } from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { REQUEST_ID_HEADER } from "@audio-reader/observability";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { describe, expect, it } from "vitest";
import { createApiAppFromEnv, createTestApp } from "./app";
import { DEFAULT_MAX_BODY_BYTES } from "./body";
import { createFakeObjectStore } from "./object-store";

const HEALTH_PATHS = ["/v1/health", "/healthz", "/readyz"] as const;

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

describe("api-worker HTTP contract", () => {
  it("GET /v1/health matches the OpenAPI Health schema", async () => {
    const response = await createTestApp().fetch(new Request("http://localhost/v1/health"));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/application\/json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.status).toBe("ok");
    expect(payload.version).toBe("1.0.0-draft.1");
    expect(typeof payload.time).toBe("string");
    expect(Number.isNaN(Date.parse(String(payload.time)))).toBe(false);
    expect(payload.dependencies).toEqual({
      database: "ok",
      r2: "ok",
      qwen: "ok",
    });
  });

  it("GET /healthz is liveness and stays ok when dependencies are down", async () => {
    const app = createTestApp({
      database: createFakeDatabaseClient({ status: "unavailable" }),
      r2: createFakeObjectStore({ status: "unavailable" }),
      qwen: createFakeQwenClient({ status: "unavailable" }),
    });
    const response = await app.fetch(new Request("http://localhost/healthz"));
    expect(response.status).toBe(200);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.status).toBe("ok");
    expect(payload.dependencies).toBeUndefined();
  });

  it("GET /readyz is 200 with Health when dependencies are ready", async () => {
    const response = await createTestApp().fetch(new Request("http://localhost/readyz"));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/application\/json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.status).toBe("ok");
    expect(payload.dependencies).toEqual({
      database: "ok",
      r2: "ok",
      qwen: "ok",
    });
  });

  it("GET /readyz returns problem+json 503 when a dependency is unavailable", async () => {
    const app = createTestApp({
      database: createFakeDatabaseClient({ status: "unavailable" }),
    });
    const response = await app.fetch(new Request("http://localhost/readyz"));
    expect(response.status).toBe(503);
    expect(response.headers.get("content-type")).toMatch(/application\/problem\+json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.status).toBe(503);
    expect(payload.code).toBe("not_ready");
    expect(payload.type).toBe("https://api.example.com/problems/not_ready");
    expect(typeof payload.traceId).toBe("string");
    expect(payload.traceId).toBe(response.headers.get(REQUEST_ID_HEADER));
  });

  it("GET /v1/health is degraded (still 200) when a dependency is unavailable", async () => {
    const app = createTestApp({
      r2: createFakeObjectStore({ status: "unavailable" }),
    });
    const response = await app.fetch(new Request("http://localhost/v1/health"));
    expect(response.status).toBe(200);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.status).toBe("degraded");
    expect(payload.dependencies).toMatchObject({ r2: "unavailable" });
  });

  it("unknown routes return structured application/problem+json", async () => {
    const response = await createTestApp().fetch(new Request("http://localhost/v1/missing"));
    expect(response.status).toBe(404);
    expect(response.headers.get("content-type")).toMatch(/application\/problem\+json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.type).toBe("https://api.example.com/problems/not_found");
    expect(payload.title).toBe("Not found");
    expect(payload.status).toBe(404);
    expect(payload.code).toBe("not_found");
    expect(typeof payload.traceId).toBe("string");
    expect(payload.retryAfterSeconds).toBeNull();
    expect(payload.fieldErrors).toEqual([]);
  });

  it.each(HEALTH_PATHS)("echoes X-Request-Id on %s", async (path) => {
    const response = await createTestApp().fetch(
      new Request(`http://localhost${path}`, {
        headers: { [REQUEST_ID_HEADER]: "client-request-1" },
      }),
    );
    expect(response.headers.get(REQUEST_ID_HEADER)).toBe("client-request-1");
  });

  it("generates X-Request-Id when the client omits it", async () => {
    const response = await createTestApp().fetch(new Request("http://localhost/v1/health"));
    const requestId = response.headers.get(REQUEST_ID_HEADER);
    expect(requestId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });

  it("allows configured CORS origins and rejects others", async () => {
    const app = createTestApp({
      environment: "production",
      corsOrigins: ["https://admin.example.com"],
    });
    const allowed = await app.fetch(
      new Request("http://localhost/v1/health", {
        headers: { origin: "https://admin.example.com" },
      }),
    );
    expect(allowed.headers.get("access-control-allow-origin")).toBe("https://admin.example.com");
    expect(allowed.headers.get("access-control-expose-headers")).toMatch(/X-Request-Id/i);

    const blocked = await app.fetch(
      new Request("http://localhost/v1/health", {
        headers: { origin: "https://evil.example" },
      }),
    );
    expect(blocked.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("adds local development origins to the CORS allowlist", async () => {
    const app = createTestApp({
      environment: "local",
      corsOrigins: [],
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/health", {
        headers: { origin: "http://localhost:5173" },
      }),
    );
    expect(response.headers.get("access-control-allow-origin")).toBe("http://localhost:5173");
  });

  it("does not add local CORS defaults in production", async () => {
    const app = createTestApp({
      environment: "production",
      corsOrigins: ["https://admin.example.com"],
    });
    const response = await app.fetch(
      new Request("http://localhost/v1/health", {
        headers: { origin: "http://localhost:5173" },
      }),
    );
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("answers CORS preflight for an allowed origin", async () => {
    const response = await createTestApp({
      corsOrigins: ["https://admin.example.com"],
    }).fetch(
      new Request("http://localhost/v1/health", {
        method: "OPTIONS",
        headers: {
          origin: "https://admin.example.com",
          "access-control-request-method": "GET",
        },
      }),
    );
    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-origin")).toBe("https://admin.example.com");
    expect(response.headers.get("access-control-allow-headers")).toMatch(/Idempotency-Key/i);
  });

  it("rejects an oversized body with problem+json", async () => {
    const app = createTestApp({ maxBodyBytes: 32 });
    const response = await app.fetch(
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "x".repeat(33),
      }),
    );
    expect(response.status).toBe(413);
    expect(response.headers.get("content-type")).toMatch(/application\/problem\+json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.code).toBe("payload_too_large");
    expect(payload.status).toBe(413);
  });

  it("uses the default JSON body limit", () => {
    expect(DEFAULT_MAX_BODY_BYTES).toBe(1_048_576);
  });

  it("rejects a missing content-type on JSON writes with problem+json", async () => {
    const response = await createTestApp().fetch(
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        body: new Uint8Array([123, 125]),
      }),
    );
    expect(response.status).toBe(415);
    expect(response.headers.get("content-type")).toMatch(/application\/problem\+json/i);
    const payload = await readJson(response);
    expect(isRecord(payload)).toBe(true);
    if (!isRecord(payload)) {
      return;
    }
    expect(payload.code).toBe("unsupported_media_type");
    expect(payload.status).toBe(415);
  });

  it("rejects a non-JSON content-type on writes", async () => {
    const response = await createTestApp().fetch(
      new Request("http://localhost/v1/auth/bootstrap", {
        method: "POST",
        headers: { "content-type": "text/plain" },
        body: "{}",
      }),
    );
    expect(response.status).toBe(415);
    const payload = await readJson(response);
    expect(isRecord(payload) && payload.code).toBe("unsupported_media_type");
  });

  it("installs a fake authentication principal for tests only", async () => {
    const principal = createFakePrincipal({ subject: "tester" });
    const testApp = createTestApp({ authenticate: () => principal });
    await expect(testApp.authenticate(new Request("http://localhost/v1/health"))).resolves.toEqual(
      principal,
    );

    const production = createApiAppFromEnv({
      ENVIRONMENT: "production",
      APP_VERSION: "1.0.0-draft.1",
    });
    await expect(
      production.authenticate(new Request("http://localhost/v1/health")),
    ).resolves.toBeNull();
  });
});
