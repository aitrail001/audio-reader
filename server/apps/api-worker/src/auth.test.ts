import { LOCAL_JWT_CONFIG, createMemoryAuthService, signAccessToken } from "@audio-reader/auth";
import { REQUEST_ID_HEADER } from "@audio-reader/observability";
import { describe, expect, it } from "vitest";
import { createApiAppFromEnv, createTestApp } from "./app";

const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const EMAIL = "reader@example.com";
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

function createAuthApp(options: { now?: () => Date; generateOtp?: () => string } = {}) {
  const auth = createMemoryAuthService({
    jwt: LOCAL_JWT_CONFIG,
    ...(options.now === undefined ? {} : { now: options.now }),
    generateOtp: options.generateOtp ?? (() => "123456"),
  });
  return {
    auth,
    app: createTestApp({
      auth,
      authenticate: (request) => auth.authenticate(request),
    }),
  };
}

function bearer(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
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

    const me = await app.fetch(
      new Request("http://localhost/v1/me", { headers: bearer(String(tokens.accessToken)) }),
    );
    expect(me.status).toBe(200);
    const profile = await readJson(me);
    expect(isRecord(profile) && profile.email).toBe(EMAIL);

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
        jsonPost("/v1/auth/oauth/exchange", {
          provider,
          code,
          codeVerifier: pkce.verifier,
          redirectUri: "http://localhost/callback",
        }),
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

  it("requires a session for GET /v1/me", async () => {
    const { app } = createAuthApp();
    const response = await app.fetch(new Request("http://localhost/v1/me"));
    expect(response.status).toBe(401);
  });

  it("fails closed in production without a JWT secret", async () => {
    const app = createApiAppFromEnv({ ENVIRONMENT: "production" });
    const response = await app.fetch(new Request("http://localhost/v1/me"));
    expect(response.status).toBe(401);
    await expect(app.authenticate(new Request("http://localhost/v1/me"))).resolves.toBeNull();
  });
});
