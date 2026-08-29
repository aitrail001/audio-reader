import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import {
  AdminApiError,
  AdminSessionError,
  getJson,
  loadStoredSession,
  logoutSession,
  refreshAccessToken,
  storeSession,
  subscribeSession,
  readError,
} from "./api";

const ACCESS = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.e30.sig";
const ACCESS_NEXT = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.e30.sig2";
const REFRESH = "rt-admin-1";

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => {
      map.set(key, value);
    },
    removeItem: (key: string) => {
      map.delete(key);
    },
    clear: () => {
      map.clear();
    },
  };
}

describe("operator session refresh", () => {
  let warn: MockInstance<typeof console.warn>;

  beforeEach(() => {
    const local = memoryStorage();
    const session = memoryStorage();
    vi.stubGlobal("localStorage", local);
    vi.stubGlobal("sessionStorage", session);
    vi.stubGlobal("window", { localStorage: local, sessionStorage: session });
    warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    warn.mockRestore();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  function expectLogsRedacted(): void {
    for (const args of warn.mock.calls) {
      const line = String(args[0] ?? "");
      expect(line).not.toContain(REFRESH);
      expect(line).not.toContain(ACCESS);
      expect(line).not.toContain(ACCESS_NEXT);
    }
  }

  it("keeps the stored session when refresh returns 503", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("unavailable", { status: 503 }))),
    );
    await expect(refreshAccessToken()).resolves.toEqual({ status: "unavailable" });
    expect(loadStoredSession()).toEqual({ accessToken: ACCESS, refreshToken: REFRESH });
    expectLogsRedacted();
  });

  it("keeps the stored session when refresh fails on the network", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new TypeError("Failed to fetch"))),
    );
    await expect(refreshAccessToken()).resolves.toEqual({ status: "unavailable" });
    expect(loadStoredSession()).toEqual({ accessToken: ACCESS, refreshToken: REFRESH });
  });

  it("wipes the stored session when refresh is rejected", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ detail: "The refresh token is invalid." }), {
            status: 401,
          }),
        ),
      ),
    );
    await expect(refreshAccessToken()).resolves.toEqual({ status: "invalid" });
    expect(loadStoredSession()).toBeNull();
    expectLogsRedacted();
  });

  it("does not treat a 401 after an unavailable refresh as a stored-session wipe", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = input instanceof Request ? input.url : input.toString();
        if (url.includes("/v1/auth/token/refresh")) {
          return Promise.resolve(new Response("unavailable", { status: 503 }));
        }
        return Promise.resolve(
          new Response(JSON.stringify({ detail: "Authentication required." }), { status: 401 }),
        );
      }),
    );
    await expect(getJson("/v1/admin/users", ACCESS)).rejects.toMatchObject({
      name: "AdminSessionError",
      outcome: "unavailable",
    });
    expect(loadStoredSession()).toEqual({ accessToken: ACCESS, refreshToken: REFRESH });
  });

  it("publishes the refreshed access token as the stored session", async () => {
    const seen: string[] = [];
    const stop = subscribeSession((session) => {
      if (session !== null) {
        seen.push(session.accessToken);
      }
    });
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ accessToken: ACCESS_NEXT, refreshToken: "rt-admin-2" }), {
            status: 200,
          }),
        ),
      ),
    );
    await expect(refreshAccessToken()).resolves.toEqual({
      status: "refreshed",
      accessToken: ACCESS_NEXT,
    });
    expect(loadStoredSession()?.accessToken).toBe(ACCESS_NEXT);
    expect(seen.at(-1)).toBe(ACCESS_NEXT);
    stop();
    expectLogsRedacted();
  });

  it("posts logout then clears the session even when logout fails", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    const fetchMock = vi.fn(() => Promise.reject(new TypeError("Failed to fetch")));
    vi.stubGlobal("fetch", fetchMock);
    await logoutSession();
    const logoutCall = fetchMock.mock.calls[0] as [string, RequestInit] | undefined;
    expect(logoutCall).toBeDefined();
    expect(String(logoutCall?.[0])).toContain("/v1/auth/logout");
    expect(logoutCall?.[1]).toMatchObject({
      method: "POST",
      body: JSON.stringify({ refreshToken: REFRESH }),
    });
    expect(loadStoredSession()).toBeNull();
  });

  it("throws AdminSessionError invalid when the server rejects the refresh token during getJson", async () => {
    storeSession({ accessToken: ACCESS, refreshToken: REFRESH });
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(
          new Response(JSON.stringify({ detail: "Authentication required." }), { status: 401 }),
        ),
      ),
    );
    await expect(getJson("/v1/admin/users", ACCESS)).rejects.toBeInstanceOf(AdminSessionError);
    expect(loadStoredSession()).toBeNull();
  });
});

describe("AdminApiError", () => {
  it("preserves RFC 9457 fields, retry timing, and the response request id", async () => {
    const response = new Response(
      JSON.stringify({
        type: "https://audio-reader.example/problems/invalid-field",
        title: "Invalid field",
        status: 422,
        code: "invalid_field",
        detail: "Correct the highlighted value.",
        traceId: "body-trace",
        retryAfterSeconds: 7,
        fieldErrors: [{ field: "model", message: "Model is required." }],
      }),
      {
        status: 422,
        headers: { "X-Request-Id": "header-trace", "Retry-After": "9" },
      },
    );

    const error = await readError(response);
    expect(error).toBeInstanceOf(AdminApiError);
    expect(error).toMatchObject({
      status: 422,
      code: "invalid_field",
      traceId: "body-trace",
      retryAfterSeconds: 7,
      fieldErrors: [{ field: "model", message: "Model is required." }],
    });
    expect(error.message).toBe("Correct the highlighted value.");
  });

  it("falls back to response headers without discarding the trace id", async () => {
    const error = await readError(
      new Response("gateway unavailable", {
        status: 503,
        headers: { "X-Request-Id": "trace-503", "Retry-After": "12" },
      }),
    );
    expect(error).toMatchObject({
      status: 503,
      code: "http_503",
      traceId: "trace-503",
      retryAfterSeconds: 12,
    });
  });
});
