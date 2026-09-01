import {
  LOCAL_JWT_CONFIG,
  createFakePrincipal,
  createHostedAuthService,
  createMemoryAuthService,
  createMemoryPasswordlessLimiter,
  hashIdentifier,
  normalizeEmail,
  signAccessToken,
  type MemoryPasswordlessLimiterOptions,
} from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { REQUEST_ID_HEADER } from "@audio-reader/observability";
import { describe, expect, it, vi } from "vitest";
import { createApiAppFromEnv, createTestApp } from "./app";
import { createUnavailableObjectStore, type ObjectStore } from "./object-store";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const DEVICE_B = "3fa85f64-5717-4562-b3fc-2c963f66afa7";
const EMAIL = "reader@example.com";
const ALICE_EMAIL = "alice@example.com";
const BOB_EMAIL = "bob@example.com";
const UNKNOWN_EMAIL = "unknown@example.com";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readJson(response: Response): Promise<unknown> {
  return JSON.parse(await response.text()) as unknown;
}

function jsonPost(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`http://localhost${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function createAuthApp(
  options: {
    now?: () => Date;
    generateOtp?: () => string;
    verifyTurnstile?: (token: string, ip: string) => Promise<boolean>;
    passwordlessLimits?: MemoryPasswordlessLimiterOptions["limits"];
    storage?: ObjectStore;
  } = {},
) {
  const now = options.now ?? (() => new Date());
  const auth = createMemoryAuthService({
    jwt: LOCAL_JWT_CONFIG,
    now,
    generateOtp: options.generateOtp ?? (() => "123456"),
  });
  const passwordlessLimiter = createMemoryPasswordlessLimiter({
    now,
    ...(options.verifyTurnstile === undefined ? {} : { verifyTurnstile: options.verifyTurnstile }),
    ...(options.passwordlessLimits === undefined ? {} : { limits: options.passwordlessLimits }),
  });
  const database = createFakeDatabaseClient();
  return {
    auth,
    database,
    passwordlessLimiter,
    app: createTestApp({
      auth,
      database,
      passwordlessLimiter,
      authenticate: (request) => auth.authenticate(request),
      ...(options.storage === undefined ? {} : { storage: options.storage }),
    }),
  };
}

function bearer(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

function sessionHeaders(token: string, deviceId = DEVICE_ID): Record<string, string> {
  return { ...bearer(token), "X-Device-Id": deviceId };
}

function accessToken(tokens: unknown): string {
  if (!isRecord(tokens) || typeof tokens.accessToken !== "string") {
    throw new Error("expected token pair");
  }
  return tokens.accessToken;
}

function refreshToken(tokens: unknown): string {
  if (!isRecord(tokens) || typeof tokens.refreshToken !== "string") {
    throw new Error("expected token pair");
  }
  return tokens.refreshToken;
}

async function signIn(
  app: { fetch(request: Request): Promise<Response> },
  email: string,
  deviceId: string,
): Promise<{ accessToken: string; refreshToken: string }> {
  await app.fetch(jsonPost("/v1/auth/email-otp/request", { email }));
  const verified = await app.fetch(
    jsonPost("/v1/auth/email-otp/verify", { email, code: "123456", deviceId }),
  );
  const tokens = await readJson(verified);
  return { accessToken: accessToken(tokens), refreshToken: refreshToken(tokens) };
}

async function bootstrapDevice(
  app: { fetch(request: Request): Promise<Response> },
  access: string,
  deviceId: string,
  idempotencyKey: string,
): Promise<Response> {
  return app.fetch(
    jsonPost(
      "/v1/auth/bootstrap",
      { deviceId, platform: "macos", appVersion: "1.0.0" },
      {
        ...bearer(access),
        "X-Device-Id": deviceId,
        "Idempotency-Key": idempotencyKey,
      },
    ),
  );
}

async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  const verifier = btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const challengeBytes = new Uint8Array(digest);
  let challengeBinary = "";
  for (const byte of challengeBytes) {
    challengeBinary += String.fromCharCode(byte);
  }
  const challenge = btoa(challengeBinary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
  return { verifier, challenge };
}

describe("product authentication API", () => {
  it("honors LOCAL_DEV_OTP when ENVIRONMENT is local", async () => {
    const app = createApiAppFromEnv({ ENVIRONMENT: "local", LOCAL_DEV_OTP: "654321" });
    const requested = await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    expect(requested.status).toBe(202);
    const wrong = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(wrong.status).toBe(401);
    const verified = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "654321",
        deviceId: DEVICE_ID,
      }),
    );
    expect(verified.status).toBe(200);
  });

  it("does not issue a local OTP code in production", async () => {
    const app = createApiAppFromEnv({
      ENVIRONMENT: "production",
      LOCAL_DEV_OTP: "123456",
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_JWT_SECRET: "super-secret",
    });
    const requested = await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    expect(requested.status).toBe(503);
  });

  it("issues production OTP through GoTrue when the anon key is configured", async () => {
    const jwt = {
      issuer: "https://example.supabase.co/auth/v1",
      audience: "authenticated",
      secret: "super-secret",
      accessTokenTtlSeconds: 3600,
      clockSkewSeconds: 0,
    };
    const accessToken = await signAccessToken({ sub: "user-hosted", email: EMAIL }, jwt);
    const fetchMock = vi.fn(
      (input: Request | URL | string, init?: RequestInit): Promise<Response> => {
        const url =
          typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (url.endsWith("/otp")) {
          return Promise.resolve(new Response(null, { status: 200 }));
        }
        if (url.endsWith("/verify")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                access_token: accessToken,
                refresh_token: "refresh-hosted",
                expires_in: 3600,
                token_type: "bearer",
              }),
              { status: 200, headers: { "content-type": "application/json" } },
            ),
          );
        }
        return Promise.resolve(
          new Response(JSON.stringify({ message: "unexpected", url, method: init?.method }), {
            status: 500,
          }),
        );
      },
    );
    vi.stubGlobal("fetch", fetchMock);
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const app = createApiAppFromEnv({
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_JWT_SECRET: "super-secret",
        SUPABASE_ANON_KEY: "anon-key",
      });
      const requested = await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
      expect(requested.status).toBe(202);
      const verified = await app.fetch(
        jsonPost("/v1/auth/email-otp/verify", {
          email: EMAIL,
          code: "424242",
          deviceId: DEVICE_ID,
        }),
      );
      expect(verified.status).toBe(200);
      const tokens = await readJson(verified);
      expect(isRecord(tokens) && tokens.refreshToken).toBe("refresh-hosted");
      const bootstrapped = await app.fetch(
        jsonPost(
          "/v1/auth/bootstrap",
          { deviceId: DEVICE_ID, platform: "macos", appVersion: "1.0.0" },
          {
            ...bearer(accessToken),
            "X-Device-Id": DEVICE_ID,
            "Idempotency-Key": "hosted-otp-boot-01",
          },
        ),
      );
      expect(bootstrapped.status).toBe(200);
      const me = await app.fetch(
        new Request("http://localhost/v1/me", { headers: sessionHeaders(accessToken) }),
      );
      expect(me.status).toBe(200);
    } finally {
      spy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("returns hosted GoTrue authorize URLs instead of local-complete", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const app = createApiAppFromEnv({
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_JWT_SECRET: "super-secret",
        SUPABASE_ANON_KEY: "anon-key",
      });
      const pkce = await pkcePair();
      const authorize = await app.fetch(
        jsonPost("/v1/auth/oauth/authorize", {
          provider: "microsoft",
          redirectUri: "audioreader://auth/callback",
          codeChallenge: pkce.challenge,
          state: "oauth-hosted-state",
        }),
      );
      expect(authorize.status).toBe(200);
      const started = await readJson(authorize);
      expect(isRecord(started)).toBe(true);
      if (!isRecord(started)) {
        return;
      }
      const authorizationUrl = new URL(String(started.authorizationUrl));
      expect(authorizationUrl.pathname).toBe("/auth/v1/authorize");
      expect(authorizationUrl.searchParams.get("provider")).toBe("azure");
      expect(authorizationUrl.searchParams.get("code_challenge")).toBe(pkce.challenge);
      expect(String(started.authorizationUrl)).not.toContain("local-complete");

      const complete = await app.fetch(
        new Request(
          "http://localhost/v1/auth/oauth/local-complete?code=abc&state=oauth-hosted-state&redirect_uri=audioreader://auth/callback",
        ),
      );
      expect(complete.status).toBe(404);
    } finally {
      spy.mockRestore();
    }
  });

  it("GET /v1/auth/config lists Google, Microsoft, and email OTP", async () => {
    const response = await createTestApp().fetch(new Request("http://localhost/v1/auth/config"));
    expect(response.status).toBe(200);
    const payload = await readJson(response);
    expect(payload).toEqual({
      providers: [{ id: "google" }, { id: "microsoft" }, { id: "email_otp" }],
    });
  });

  it("returns the same public OTP request response for existing and unknown emails", async () => {
    const { app } = createAuthApp();
    const existingRequest = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: EMAIL }),
    );
    expect(existingRequest.status).toBe(202);
    const verify = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(verify.status).toBe(200);

    const headers = { [REQUEST_ID_HEADER]: "otp-request-1" };
    const againExisting = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: EMAIL }, headers),
    );
    const unknown = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: UNKNOWN_EMAIL }, headers),
    );
    expect(againExisting.status).toBe(202);
    expect(unknown.status).toBe(202);
    expect(againExisting.headers.get("content-type")).toBe(unknown.headers.get("content-type"));
    const existingBody = await againExisting.text();
    const unknownBody = await unknown.text();
    expect(existingBody).toBe(unknownBody);
    expect(existingBody).toBe("");
  });

  it("rejects a wrong or expired email OTP", async () => {
    const { app } = createAuthApp();
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    const wrong = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "000000",
        deviceId: DEVICE_ID,
      }),
    );
    expect(wrong.status).toBe(401);
    const wrongBody = await readJson(wrong);
    expect(isRecord(wrongBody) && wrongBody.code).toBe("unauthorized");

    const clock = { now: new Date("2026-01-01T00:00:00.000Z") };
    const expired = createAuthApp({
      now: () => clock.now,
      generateOtp: () => "654321",
    });
    await expired.app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    clock.now = new Date("2026-01-01T00:15:00.000Z");
    const expiredResponse = await expired.app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "654321",
        deviceId: DEVICE_ID,
      }),
    );
    expect(expiredResponse.status).toBe(401);
    const expiredBody = await readJson(expiredResponse);
    expect(isRecord(expiredBody) && expiredBody.code).toBe("unauthorized");
  });

  it("rate limits OTP resend per email hash without enumerating accounts", async () => {
    const { app } = createAuthApp();
    const first = await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    expect(first.status).toBe(202);
    const headers = { [REQUEST_ID_HEADER]: "otp-resend-1" };
    const existing = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: EMAIL }, headers),
    );
    const unknownFirst = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: UNKNOWN_EMAIL }),
    );
    const unknownSecond = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: UNKNOWN_EMAIL }, headers),
    );
    expect(existing.status).toBe(429);
    expect(unknownFirst.status).toBe(202);
    expect(unknownSecond.status).toBe(429);
    const existingBody = await readJson(existing);
    const unknownBody = await readJson(unknownSecond);
    expect(isRecord(existingBody) && existingBody.code).toBe("rate_limited");
    expect(isRecord(unknownBody) && unknownBody.code).toBe("rate_limited");
    expect(isRecord(existingBody) && existingBody.status).toBe(429);
    expect(existing.headers.get("Retry-After")).toEqual(expect.any(String));
    expect(JSON.stringify(existingBody)).not.toContain(EMAIL);
    expect(JSON.stringify(unknownBody)).not.toContain(UNKNOWN_EMAIL);
  });

  it("rate limits brute-force OTP verification including the correct code after lockout", async () => {
    const { app } = createAuthApp({
      passwordlessLimits: {
        verifyEmail: { max: 3, challengeAfter: 3 },
      },
    });
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    for (let index = 0; index < 3; index += 1) {
      const wrong = await app.fetch(
        jsonPost("/v1/auth/email-otp/verify", {
          email: EMAIL,
          code: "000000",
          deviceId: DEVICE_ID,
        }),
      );
      expect(wrong.status).toBe(401);
    }
    const locked = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(locked.status).toBe(429);
    const body = await readJson(locked);
    expect(isRecord(body) && body.code).toBe("rate_limited");
    expect(JSON.stringify(body)).not.toContain(EMAIL);
  });

  it("requires a Turnstile token after repeated OTP failures", async () => {
    const { app } = createAuthApp({
      verifyTurnstile: (token) => Promise.resolve(token === "turnstile-ok"),
      passwordlessLimits: {
        verifyEmail: { max: 5, challengeAfter: 2 },
      },
    });
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    for (let index = 0; index < 2; index += 1) {
      const wrong = await app.fetch(
        jsonPost("/v1/auth/email-otp/verify", {
          email: EMAIL,
          code: "000000",
          deviceId: DEVICE_ID,
        }),
      );
      expect(wrong.status).toBe(401);
    }
    const challenged = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(challenged.status).toBe(403);
    const challengedBody = await readJson(challenged);
    expect(isRecord(challengedBody) && challengedBody.code).toBe("challenge_required");
    expect(JSON.stringify(challengedBody)).not.toContain(EMAIL);

    const withToken = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
        turnstileToken: "turnstile-ok",
      }),
    );
    expect(withToken.status).toBe(200);
  });

  it("applies IP and device buckets to OTP requests", async () => {
    const { app } = createAuthApp({
      passwordlessLimits: {
        requestCooldownSeconds: 0,
        requestEmail: { max: 50, challengeAfter: 50 },
        requestIp: { max: 2, challengeAfter: 2 },
        requestDevice: { max: 2, challengeAfter: 2 },
      },
    });
    const ipHeaders = { "CF-Connecting-IP": "203.0.113.10" };
    expect(
      (await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }, ipHeaders))).status,
    ).toBe(202);
    expect(
      (await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: ALICE_EMAIL }, ipHeaders)))
        .status,
    ).toBe(202);
    const ipBlocked = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: BOB_EMAIL }, ipHeaders),
    );
    expect(ipBlocked.status).toBe(429);

    const deviceHeaders = {
      "CF-Connecting-IP": "198.51.100.20",
      "X-Device-Id": DEVICE_ID,
    };
    expect(
      (await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }, deviceHeaders)))
        .status,
    ).toBe(202);
    expect(
      (
        await app.fetch(
          jsonPost("/v1/auth/email-otp/request", { email: ALICE_EMAIL }, deviceHeaders),
        )
      ).status,
    ).toBe(202);
    const deviceBlocked = await app.fetch(
      jsonPost("/v1/auth/email-otp/request", { email: BOB_EMAIL }, deviceHeaders),
    );
    expect(deviceBlocked.status).toBe(429);
    expect(
      (
        await app.fetch(
          jsonPost(
            "/v1/auth/email-otp/request",
            { email: BOB_EMAIL },
            { "CF-Connecting-IP": "198.51.100.21", "X-Device-Id": DEVICE_B },
          ),
        )
      ).status,
    ).toBe(202);
  });

  it("uses lockout-only passwordless limits in production when Turnstile is unset", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const auth = createMemoryAuthService({
        jwt: LOCAL_JWT_CONFIG,
        generateOtp: () => "123456",
      });
      const app = createTestApp({
        environment: "production",
        auth,
        authenticate: (request) => auth.authenticate(request),
      });
      await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
      for (let index = 0; index < 3; index += 1) {
        const wrong = await app.fetch(
          jsonPost("/v1/auth/email-otp/verify", {
            email: EMAIL,
            code: "000000",
            deviceId: DEVICE_ID,
          }),
        );
        expect(wrong.status).toBe(401);
      }
      const fourth = await app.fetch(
        jsonPost("/v1/auth/email-otp/verify", {
          email: EMAIL,
          code: "000000",
          deviceId: DEVICE_ID,
        }),
      );
      expect(fourth.status).toBe(401);
    } finally {
      spy.mockRestore();
    }
  });

  it("warns at startup when production has no Turnstile or HMAC secret", () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      createApiAppFromEnv({ ENVIRONMENT: "production" });
      const logged = spy.mock.calls.map((call) => String(call[0])).join("\n");
      expect(logged).toContain("turnstile_secret_missing");
      expect(logged).toContain("passwordless_hmac_secret_missing");
    } finally {
      spy.mockRestore();
    }
  });

  it("warns when production can validate JWTs but cannot issue hosted sessions", () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      createApiAppFromEnv({
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_JWT_SECRET: "super-secret",
      });
      const logged = spy.mock.calls.map((call) => String(call[0])).join("\n");
      expect(logged).toContain("hosted_auth_unconfigured");
    } finally {
      spy.mockRestore();
    }
  });

  it("logs passwordless security events without raw email", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const auth = createMemoryAuthService({
        jwt: LOCAL_JWT_CONFIG,
        generateOtp: () => "123456",
      });
      const app = createTestApp({
        auth,
        authenticate: (request) => auth.authenticate(request),
      });
      await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
      const blocked = await app.fetch(
        jsonPost(
          "/v1/auth/email-otp/request",
          { email: EMAIL },
          { [REQUEST_ID_HEADER]: "otp-limit-log-1" },
        ),
      );
      expect(blocked.status).toBe(429);
      const logged = spy.mock.calls.map((call) => String(call[0])).join("\n");
      expect(logged).toContain("passwordless_rate_limited");
      expect(logged).toContain("otp-limit-log-1");
      expect(logged).toContain(await hashIdentifier(normalizeEmail(EMAIL)));
      expect(logged).not.toContain(EMAIL);
    } finally {
      spy.mockRestore();
    }
  });

  it("lets admins list blocked attempts and keeps raw email out of the payload", async () => {
    const { app, auth, passwordlessLimiter } = createAuthApp();
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    expect((await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }))).status).toBe(
      429,
    );

    const anon = await app.fetch(new Request("http://localhost/v1/admin/auth/blocked-attempts"));
    expect(anon.status).toBe(401);

    const userDenied = await createTestApp({
      auth,
      passwordlessLimiter,
      authenticate: () => createFakePrincipal({ role: "user" }),
    }).fetch(new Request("http://localhost/v1/admin/auth/blocked-attempts"));
    expect(userDenied.status).toBe(403);

    const scopedDenied = await createTestApp({
      auth,
      passwordlessLimiter,
      authenticate: () => createFakePrincipal({ role: "admin", adminRoles: ["billing_operator"] }),
    }).fetch(new Request("http://localhost/v1/admin/auth/blocked-attempts"));
    expect(scopedDenied.status).toBe(403);

    const supportAllowed = await createTestApp({
      auth,
      passwordlessLimiter,
      authenticate: () => createFakePrincipal({ role: "admin", adminRoles: ["support_readonly"] }),
    }).fetch(new Request("http://localhost/v1/admin/auth/blocked-attempts"));
    expect(supportAllowed.status).toBe(200);

    const listed = await createTestApp({
      auth,
      passwordlessLimiter,
      authenticate: () => createFakePrincipal({ role: "admin" }),
    }).fetch(new Request("http://localhost/v1/admin/auth/blocked-attempts"));
    expect(listed.status).toBe(200);
    const payload = await readJson(listed);
    expect(payload).toEqual({
      items: [
        expect.objectContaining({
          action: "email_otp_request",
          reason: "rate_limited",
          emailHash: await hashIdentifier(normalizeEmail(EMAIL)),
        }),
      ],
    });
    expect(JSON.stringify(payload)).not.toContain(EMAIL);
  });

  it("rejects access tokens with invalid issuer, audience, or signature", async () => {
    const { app } = createAuthApp();
    const validClaims = { sub: "user-1", email: EMAIL };
    const invalidIssuer = await signAccessToken(
      { ...validClaims, iss: "https://evil.example/auth/v1" },
      LOCAL_JWT_CONFIG,
    );
    const invalidAudience = await signAccessToken(
      { ...validClaims, aud: "anon" },
      LOCAL_JWT_CONFIG,
    );
    const valid = await signAccessToken(validClaims, LOCAL_JWT_CONFIG);
    const parts = valid.split(".");
    const header = parts[0];
    const payload = parts[1];
    expect(header).toBeDefined();
    expect(payload).toBeDefined();
    if (header === undefined || payload === undefined) {
      return;
    }
    const invalidSignature = `${header}.${payload}.AAAA`;

    for (const token of [invalidIssuer, invalidAudience, invalidSignature]) {
      const response = await app.fetch(
        new Request("http://localhost/v1/me", { headers: bearer(token) }),
      );
      expect(response.status).toBe(401);
      const payload = await readJson(response);
      expect(isRecord(payload) && payload.code).toBe("unauthorized");
    }
  });

  it("maps a verified session to GET /v1/me and bootstrap", async () => {
    const { app } = createAuthApp();
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    const verified = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(verified.status).toBe(200);
    const tokens = await readJson(verified);
    expect(isRecord(tokens)).toBe(true);
    if (!isRecord(tokens)) {
      return;
    }
    expect(typeof tokens.accessToken).toBe("string");
    expect(typeof tokens.refreshToken).toBe("string");
    expect(tokens.tokenType).toBe("Bearer");

    const unbound = await app.fetch(
      new Request("http://localhost/v1/me", { headers: bearer(String(tokens.accessToken)) }),
    );
    expect(unbound.status).toBe(401);

    const bootstrap = await app.fetch(
      jsonPost(
        "/v1/auth/bootstrap",
        {
          deviceId: DEVICE_ID,
          platform: "macos",
          appVersion: "1.0.0",
          deviceName: "Study Mac",
        },
        {
          ...bearer(String(tokens.accessToken)),
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-01",
        },
      ),
    );
    expect(bootstrap.status).toBe(200);
    const me = await app.fetch(
      new Request("http://localhost/v1/me", {
        headers: sessionHeaders(String(tokens.accessToken)),
      }),
    );
    expect(me.status).toBe(200);
    const profile = await readJson(me);
    expect(isRecord(profile) && profile.email).toBe(EMAIL);
    const boot = await readJson(bootstrap);
    expect(isRecord(boot)).toBe(true);
    if (!isRecord(boot)) {
      return;
    }
    expect(isRecord(boot.profile) && boot.profile.email).toBe(EMAIL);
    expect(isRecord(boot.device) && boot.device.id).toBe(DEVICE_ID);
    expect(boot.syncCursor).toBe("0");
    expect(Array.isArray(boot.featureFlags)).toBe(true);
    expect(Array.isArray(boot.quotas)).toBe(true);
    const flags = Array.isArray(boot.featureFlags) ? boot.featureFlags : [];
    const quotas = Array.isArray(boot.quotas) ? boot.quotas : [];
    expect(
      flags.some((item) => isRecord(item) && item.key === "managed_qwen" && item.enabled),
    ).toBe(true);
    expect(
      quotas.some((item) => isRecord(item) && item.key === "qwen_tasks_day" && item.limit === 50),
    ).toBe(true);
    expect(
      quotas.some((item) => isRecord(item) && item.key === "devices" && item.limit === 2),
    ).toBe(true);
  });

  it("returns requested and effective account sync state with a machine-readable pause reason", async () => {
    const { app, database } = createAuthApp({ storage: createUnavailableObjectStore() });
    await database.ops.patchFlag("account_sync", { enabled: true });
    const session = await signIn(app, EMAIL, DEVICE_ID);

    const response = await bootstrapDevice(
      app,
      session.accessToken,
      DEVICE_ID,
      "idempotency-account-sync-readiness",
    );
    const body = await readJson(response);
    const flags = isRecord(body) && Array.isArray(body.featureFlags) ? body.featureFlags : [];

    expect(response.status).toBe(200);
    expect(
      flags.some((item) => isRecord(item) && item.key === "account_sync" && item.enabled === false),
    ).toBe(true);
    expect(isRecord(body) ? body.accountSyncReadiness : null).toMatchObject({
      requested: true,
      effective: false,
      reason: "upgrade_required",
      minAppVersion: "2.0.0",
    });
  });

  it("rejects a third device when the starter device quota is two", async () => {
    const { app } = createAuthApp();
    const session = await signIn(app, EMAIL, DEVICE_ID);
    expect(
      (await bootstrapDevice(app, session.accessToken, DEVICE_ID, "idempotency-limit-a")).status,
    ).toBe(200);
    expect(
      (await bootstrapDevice(app, session.accessToken, DEVICE_B, "idempotency-limit-b")).status,
    ).toBe(200);
    const third = "3fa85f64-5717-4562-b3fc-2c963f66afa8";
    const blocked = await bootstrapDevice(app, session.accessToken, third, "idempotency-limit-c");
    expect(blocked.status).toBe(409);
    const body = await readJson(blocked);
    expect(isRecord(body) && body.code).toBe("device_limit");
  });

  it("patches the profile and replaces settings with revision checks", async () => {
    const { app } = createAuthApp();
    const session = await signIn(app, EMAIL, DEVICE_ID);
    await bootstrapDevice(app, session.accessToken, DEVICE_ID, "idempotency-key-settings-0");
    const patched = await app.fetch(
      new Request("http://localhost/v1/me", {
        method: "PATCH",
        headers: {
          ...bearer(session.accessToken),
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-profile-1",
        },
        body: JSON.stringify({ displayName: "Reader One" }),
      }),
    );
    expect(patched.status).toBe(200);
    const profile = await readJson(patched);
    expect(isRecord(profile) && profile.displayName).toBe("Reader One");

    const current = await app.fetch(
      new Request("http://localhost/v1/me/settings", {
        headers: { ...bearer(session.accessToken), "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(current.status).toBe(200);
    const settings = await readJson(current);
    expect(isRecord(settings) && settings.revision).toBe(0);
    if (!isRecord(settings)) {
      return;
    }
    const updated = await app.fetch(
      new Request("http://localhost/v1/me/settings", {
        method: "PUT",
        headers: {
          ...bearer(session.accessToken),
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-settings-1",
        },
        body: JSON.stringify({
          ...settings,
          targetLanguage: "zh",
        }),
      }),
    );
    expect(updated.status).toBe(200);
    const next = await readJson(updated);
    expect(isRecord(next) && next.revision).toBe(1);
    expect(isRecord(next) && next.targetLanguage).toBe("zh");

    const stale = await app.fetch(
      new Request("http://localhost/v1/me/settings", {
        method: "PUT",
        headers: {
          ...bearer(session.accessToken),
          "content-type": "application/json",
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-key-settings-2",
        },
        body: JSON.stringify(settings),
      }),
    );
    expect(stale.status).toBe(409);
  });

  it("rewrites local OAuth authorize URLs through a 302 onto the native callback", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "audioreader://auth/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-local-complete",
      }),
    );
    expect(authorize.status).toBe(200);
    const started = await readJson(authorize);
    expect(isRecord(started)).toBe(true);
    if (!isRecord(started)) {
      return;
    }
    const authorizationUrl = new URL(String(started.authorizationUrl));
    expect(authorizationUrl.pathname).toBe("/v1/auth/oauth/local-complete");
    expect(authorizationUrl.searchParams.get("code")).toEqual(expect.any(String));
    const complete = await app.fetch(new Request(authorizationUrl, { redirect: "manual" }));
    expect(complete.status).toBe(302);
    const location = complete.headers.get("location");
    expect(location).toMatch(/^audioreader:\/\/auth\/callback/);
    const callback = new URL(String(location));
    expect(callback.searchParams.get("code")).toBe(authorizationUrl.searchParams.get("code"));
    expect(callback.searchParams.get("state")).toBe("oauth-local-complete");
  });

  it("does not expose local OAuth completion outside issuance environments", async () => {
    const app = createApiAppFromEnv({
      ENVIRONMENT: "production",
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_JWT_SECRET: "super-secret",
    });
    const complete = await app.fetch(
      new Request(
        "http://localhost/v1/auth/oauth/local-complete?code=abc&state=oauth-prod&redirect_uri=audioreader://auth/callback",
      ),
    );
    expect(complete.status).toBe(404);
  });

  it("accepts the native audioreader OAuth callback scheme", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "audioreader://auth/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-native-callback",
      }),
    );
    expect(authorize.status).toBe(200);
    const started = await readJson(authorize);
    expect(isRecord(started)).toBe(true);
    if (!isRecord(started)) {
      return;
    }
    const exchanged = await app.fetch(
      jsonPost(
        "/v1/auth/oauth/exchange",
        {
          provider: "google",
          code: new URL(String(started.authorizationUrl)).searchParams.get("code"),
          codeVerifier: pkce.verifier,
          redirectUri: "audioreader://auth/callback",
        },
        { "X-Device-Id": DEVICE_ID },
      ),
    );
    expect(exchanged.status).toBe(200);
    const tokens = await readJson(exchanged);
    expect(isRecord(tokens) && tokens.tokenType).toBe("Bearer");
  });

  it("rejects OAuth redirect URIs that are not http(s) or audioreader", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "ftp://example.com/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-bad-redirect",
      }),
    );
    expect(authorize.status).toBe(400);
    const body = await readJson(authorize);
    expect(isRecord(body) && body.code).toBe("bad_request");
    expect(isRecord(body) && body.detail).toContain("redirectUri");
  });

  it("strips PKCE base64 padding and returns the field error in detail", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "audioreader://auth/callback",
        codeChallenge: `${pkce.challenge}==`,
        state: "oauth-padded-challenge",
      }),
    );
    expect(authorize.status).toBe(200);

    const rejected = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "audioreader://auth/callback",
        codeChallenge: "short",
        state: "oauth-short-challenge",
      }),
    );
    expect(rejected.status).toBe(400);
    const body = await readJson(rejected);
    expect(isRecord(body) && body.detail).toBe("codeChallenge must be a PKCE S256 challenge.");
    expect(isRecord(body) && Array.isArray(body.fieldErrors)).toBe(true);
  });

  it("completes Google and Microsoft OAuth PKCE and issues tokens", async () => {
    const { app } = createAuthApp();
    for (const provider of ["google", "microsoft"] as const) {
      const pkce = await pkcePair();
      const authorize = await app.fetch(
        jsonPost("/v1/auth/oauth/authorize", {
          provider,
          redirectUri: "http://localhost/callback",
          codeChallenge: pkce.challenge,
          state: `oauth-${provider}-state`,
        }),
      );
      expect(authorize.status).toBe(200);
      const started = await readJson(authorize);
      expect(isRecord(started)).toBe(true);
      if (!isRecord(started)) {
        return;
      }
      const authorizationUrl = new URL(String(started.authorizationUrl));
      const code = authorizationUrl.searchParams.get("code");
      expect(code).toEqual(expect.any(String));
      const exchanged = await app.fetch(
        jsonPost(
          "/v1/auth/oauth/exchange",
          {
            provider,
            code,
            codeVerifier: pkce.verifier,
            redirectUri: "http://localhost/callback",
          },
          { "X-Device-Id": DEVICE_ID },
        ),
      );
      expect(exchanged.status).toBe(200);
      const tokens = await readJson(exchanged);
      expect(isRecord(tokens) && tokens.tokenType).toBe("Bearer");
    }
  });

  it("refreshes tokens and treats logout as idempotent", async () => {
    const { app } = createAuthApp();
    await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    const verified = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    const tokens = await readJson(verified);
    expect(isRecord(tokens)).toBe(true);
    if (!isRecord(tokens)) {
      return;
    }
    const refreshed = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: tokens.refreshToken }),
    );
    expect(refreshed.status).toBe(200);
    const next = await readJson(refreshed);
    expect(isRecord(next)).toBe(true);
    if (!isRecord(next)) {
      return;
    }
    expect(next.accessToken).not.toBe(tokens.accessToken);
    expect(next.refreshToken).not.toBe(tokens.refreshToken);

    const logout = await app.fetch(
      jsonPost("/v1/auth/logout", { refreshToken: next.refreshToken }),
    );
    expect(logout.status).toBe(204);
    const again = await app.fetch(jsonPost("/v1/auth/logout", { refreshToken: next.refreshToken }));
    expect(again.status).toBe(204);
    const afterLogout = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: next.refreshToken }),
    );
    expect(afterLogout.status).toBe(401);
  });

  it("does not reject hosted refresh tokens shorter than 16 characters at the body gate", async () => {
    const { app } = createAuthApp();
    const rejected = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: "rt-short-token" }),
    );
    expect(rejected.status).toBe(401);
    const body = await readJson(rejected);
    expect(isRecord(body) && body.detail).not.toContain("at least 16 characters");
  });

  it("requires a session for GET /v1/me", async () => {
    const { app } = createAuthApp();
    const response = await app.fetch(new Request("http://localhost/v1/me"));
    expect(response.status).toBe(401);
  });

  it("rejects /v1/me after the account is suspended", async () => {
    const database = createFakeDatabaseClient();
    const userId = "00000000-0000-4000-8000-000000000002";
    await database.identity.ensureProfile({ userId, email: EMAIL });
    await database.identity.setAccountStatus(userId, "suspended");
    const token = await signAccessToken({ sub: userId, email: EMAIL }, LOCAL_JWT_CONFIG);
    const auth = createHostedAuthService({
      jwt: LOCAL_JWT_CONFIG,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      identity: database.identity,
      fetch: () => Promise.resolve(new Response(null, { status: 500 })),
    });
    const app = createTestApp({
      database,
      auth,
      authenticate: (request) => auth.authenticate(request),
    });
    const me = await app.fetch(new Request("http://localhost/v1/me", { headers: bearer(token) }));
    expect(me.status).toBe(401);
  });

  it("returns 503 when hosted refresh cannot reach GoTrue", async () => {
    const fetchMock = vi.fn(() => Promise.resolve(new Response("down", { status: 503 })));
    vi.stubGlobal("fetch", fetchMock);
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const app = createApiAppFromEnv({
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_JWT_SECRET: "super-secret",
        SUPABASE_ANON_KEY: "anon-key",
      });
      const response = await app.fetch(
        jsonPost("/v1/auth/token/refresh", { refreshToken: "refresh-hosted" }),
      );
      expect(response.status).toBe(503);
      const body = await readJson(response);
      expect(isRecord(body) && body.code).toBe("not_ready");
    } finally {
      spy.mockRestore();
      vi.unstubAllGlobals();
    }
  });

  it("fails closed in production without a JWT secret", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const app = createApiAppFromEnv({ ENVIRONMENT: "production" });
      const response = await app.fetch(new Request("http://localhost/v1/me"));
      expect(response.status).toBe(401);
      await expect(app.authenticate(new Request("http://localhost/v1/me"))).resolves.toBeNull();
    } finally {
      spy.mockRestore();
    }
  });

  it("validates production JWTs without minting stub OAuth or OTP sessions", async () => {
    const jwt = {
      issuer: "https://example.supabase.co/auth/v1",
      audience: "authenticated",
      secret: "super-secret",
      accessTokenTtlSeconds: 3600,
      clockSkewSeconds: 0,
    };
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const app = createApiAppFromEnv({
      ENVIRONMENT: "production",
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_JWT_SECRET: "super-secret",
      SUPABASE_JWT_AUDIENCE: "authenticated",
    });
    spy.mockRestore();
    const token = await signAccessToken({ sub: "user-prod", email: EMAIL }, jwt);
    const request = new Request("http://localhost/v1/me", { headers: bearer(token) });
    await expect(app.authenticate(request)).resolves.toMatchObject({ email: EMAIL });
    const me = await app.fetch(request);
    expect(me.status).toBe(401);

    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "http://localhost/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-prod-state",
      }),
    );
    expect(authorize.status).toBe(503);
    const authorizeBody = await readJson(authorize);
    expect(isRecord(authorizeBody) && authorizeBody.code).toBe("not_ready");

    const exchange = await app.fetch(
      jsonPost("/v1/auth/oauth/exchange", {
        provider: "google",
        code: "should-not-issue",
        codeVerifier: pkce.verifier,
        redirectUri: "http://localhost/callback",
      }),
    );
    expect(exchange.status).toBe(503);

    const otpRequest = await app.fetch(jsonPost("/v1/auth/email-otp/request", { email: EMAIL }));
    expect(otpRequest.status).toBe(503);
    const otpVerify = await app.fetch(
      jsonPost("/v1/auth/email-otp/verify", {
        email: EMAIL,
        code: "123456",
        deviceId: DEVICE_ID,
      }),
    );
    expect(otpVerify.status).toBe(503);
  });

  it("lists only the signed-in user's devices and cannot revoke another user's device", async () => {
    const { app } = createAuthApp();
    const alice = await signIn(app, ALICE_EMAIL, DEVICE_ID);
    const bob = await signIn(app, BOB_EMAIL, DEVICE_B);
    expect(
      (await bootstrapDevice(app, alice.accessToken, DEVICE_ID, "idempotency-alice-01")).status,
    ).toBe(200);
    expect(
      (await bootstrapDevice(app, bob.accessToken, DEVICE_B, "idempotency-bob-01")).status,
    ).toBe(200);

    const aliceList = await app.fetch(
      new Request("http://localhost/v1/me/devices", {
        headers: sessionHeaders(alice.accessToken),
      }),
    );
    expect(aliceList.status).toBe(200);
    const aliceDevices = await readJson(aliceList);
    expect(aliceDevices).toEqual([
      expect.objectContaining({ id: DEVICE_ID, revoked: false, platform: "macos" }),
    ]);

    const steal = await app.fetch(
      new Request(`http://localhost/v1/me/devices/${DEVICE_B}`, {
        method: "DELETE",
        headers: {
          ...bearer(alice.accessToken),
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-alice-revoke-bob",
        },
      }),
    );
    expect(steal.status).toBe(404);
    const stealBody = await readJson(steal);
    expect(isRecord(stealBody) && stealBody.code).toBe("not_found");

    const bobList = await app.fetch(
      new Request("http://localhost/v1/me/devices", {
        headers: sessionHeaders(bob.accessToken, DEVICE_B),
      }),
    );
    const bobDevices = await readJson(bobList);
    expect(bobDevices).toEqual([expect.objectContaining({ id: DEVICE_B, revoked: false })]);

    const bobRefresh = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: bob.refreshToken }),
    );
    expect(bobRefresh.status).toBe(200);
  });

  it("rejects refresh after the device is revoked", async () => {
    const { app } = createAuthApp();
    const session = await signIn(app, EMAIL, DEVICE_ID);
    expect(
      (await bootstrapDevice(app, session.accessToken, DEVICE_ID, "idempotency-boot-01")).status,
    ).toBe(200);

    const revoked = await app.fetch(
      new Request(`http://localhost/v1/me/devices/${DEVICE_ID}`, {
        method: "DELETE",
        headers: {
          ...bearer(session.accessToken),
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-revoke-self",
        },
      }),
    );
    expect(revoked.status).toBe(204);

    const listed = await app.fetch(
      new Request("http://localhost/v1/me/devices", {
        headers: sessionHeaders(session.accessToken),
      }),
    );
    expect(listed.status).toBe(401);

    const refresh = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: session.refreshToken }),
    );
    expect(refresh.status).toBe(401);
    const refreshBody = await readJson(refresh);
    expect(isRecord(refreshBody) && refreshBody.code).toBe("unauthorized");
  });

  it("requires a session to list or revoke devices", async () => {
    const { app } = createAuthApp();
    const list = await app.fetch(new Request("http://localhost/v1/me/devices"));
    expect(list.status).toBe(401);
    const revoke = await app.fetch(
      new Request(`http://localhost/v1/me/devices/${DEVICE_ID}`, {
        method: "DELETE",
        headers: {
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-anon-revoke",
        },
      }),
    );
    expect(revoke.status).toBe(401);
  });

  it("requires X-Device-Id to exchange an OAuth authorization code", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "http://localhost/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-missing-device",
      }),
    );
    const started = await readJson(authorize);
    expect(isRecord(started)).toBe(true);
    if (!isRecord(started)) {
      return;
    }
    const exchanged = await app.fetch(
      jsonPost("/v1/auth/oauth/exchange", {
        provider: "google",
        code: new URL(String(started.authorizationUrl)).searchParams.get("code"),
        codeVerifier: pkce.verifier,
        redirectUri: "http://localhost/callback",
      }),
    );
    expect(exchanged.status).toBe(400);
    const body = await readJson(exchanged);
    expect(isRecord(body) && body.code).toBe("bad_request");
  });

  it("rejects refresh after an OAuth device is revoked", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "http://localhost/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-revoke-state",
      }),
    );
    const started = await readJson(authorize);
    expect(isRecord(started)).toBe(true);
    if (!isRecord(started)) {
      return;
    }
    const exchanged = await app.fetch(
      jsonPost(
        "/v1/auth/oauth/exchange",
        {
          provider: "google",
          code: new URL(String(started.authorizationUrl)).searchParams.get("code"),
          codeVerifier: pkce.verifier,
          redirectUri: "http://localhost/callback",
        },
        { "X-Device-Id": DEVICE_ID },
      ),
    );
    expect(exchanged.status).toBe(200);
    const tokens = await readJson(exchanged);
    const session = {
      accessToken: accessToken(tokens),
      refreshToken: refreshToken(tokens),
    };
    expect(
      (await bootstrapDevice(app, session.accessToken, DEVICE_ID, "idempotency-oauth-boot")).status,
    ).toBe(200);

    const revoked = await app.fetch(
      new Request(`http://localhost/v1/me/devices/${DEVICE_ID}`, {
        method: "DELETE",
        headers: {
          ...bearer(session.accessToken),
          "X-Device-Id": DEVICE_ID,
          "Idempotency-Key": "idempotency-oauth-revoke",
        },
      }),
    );
    expect(revoked.status).toBe(204);

    const refresh = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: session.refreshToken }),
    );
    expect(refresh.status).toBe(401);
    const refreshBody = await readJson(refresh);
    expect(isRecord(refreshBody) && refreshBody.code).toBe("unauthorized");

    const rebootstrap = await bootstrapDevice(
      app,
      session.accessToken,
      DEVICE_ID,
      "idempotency-oauth-reboot",
    );
    expect(rebootstrap.status).toBe(401);
  });

  it("rebinds an OAuth login device to the bootstrap device", async () => {
    const { app } = createAuthApp();
    const pkce = await pkcePair();
    const authorize = await app.fetch(
      jsonPost("/v1/auth/oauth/authorize", {
        provider: "google",
        redirectUri: "http://localhost/callback",
        codeChallenge: pkce.challenge,
        state: "oauth-bootstrap-mismatch",
      }),
    );
    const started = await readJson(authorize);
    expect(isRecord(started)).toBe(true);
    if (!isRecord(started)) {
      return;
    }
    const exchanged = await app.fetch(
      jsonPost(
        "/v1/auth/oauth/exchange",
        {
          provider: "google",
          code: new URL(String(started.authorizationUrl)).searchParams.get("code"),
          codeVerifier: pkce.verifier,
          redirectUri: "http://localhost/callback",
        },
        { "X-Device-Id": DEVICE_ID },
      ),
    );
    expect(exchanged.status).toBe(200);
    const tokens = await readJson(exchanged);
    const session = {
      accessToken: accessToken(tokens),
      refreshToken: refreshToken(tokens),
    };
    expect(
      (await bootstrapDevice(app, session.accessToken, DEVICE_B, "idempotency-oauth-boot-b"))
        .status,
    ).toBe(200);

    const listed = await app.fetch(
      new Request("http://localhost/v1/me/devices", {
        headers: sessionHeaders(session.accessToken, DEVICE_B),
      }),
    );
    expect(listed.status).toBe(200);
    expect(await readJson(listed)).toEqual([
      expect.objectContaining({ id: DEVICE_B, revoked: false }),
    ]);

    const revoked = await app.fetch(
      new Request(`http://localhost/v1/me/devices/${DEVICE_B}`, {
        method: "DELETE",
        headers: {
          ...bearer(session.accessToken),
          "X-Device-Id": DEVICE_B,
          "Idempotency-Key": "idempotency-oauth-revoke-b",
        },
      }),
    );
    expect(revoked.status).toBe(204);

    const refresh = await app.fetch(
      jsonPost("/v1/auth/token/refresh", { refreshToken: session.refreshToken }),
    );
    expect(refresh.status).toBe(401);
    const refreshBody = await readJson(refresh);
    expect(isRecord(refreshBody) && refreshBody.code).toBe("unauthorized");
  });
});
