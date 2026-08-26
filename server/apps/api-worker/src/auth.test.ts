import { LOCAL_JWT_CONFIG, createMemoryAuthService, signAccessToken } from "@audio-reader/auth";
import { REQUEST_ID_HEADER } from "@audio-reader/observability";
import { describe, expect, it } from "vitest";
import { createApiAppFromEnv, createTestApp } from "./app";

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

  it("validates production JWTs without minting stub OAuth or OTP sessions", async () => {
    const jwt = {
      issuer: "https://example.supabase.co/auth/v1",
      audience: "authenticated",
      secret: "super-secret",
      accessTokenTtlSeconds: 3600,
      clockSkewSeconds: 0,
    };
    const app = createApiAppFromEnv({
      ENVIRONMENT: "production",
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_JWT_SECRET: "super-secret",
      SUPABASE_JWT_AUDIENCE: "authenticated",
    });
    const token = await signAccessToken({ sub: "user-prod", email: EMAIL }, jwt);
    const me = await app.fetch(new Request("http://localhost/v1/me", { headers: bearer(token) }));
    expect(me.status).toBe(200);
    const profile = await readJson(me);
    expect(isRecord(profile) && profile.email).toBe(EMAIL);

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
      new Request("http://localhost/v1/me/devices", { headers: bearer(alice.accessToken) }),
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
      new Request("http://localhost/v1/me/devices", { headers: bearer(bob.accessToken) }),
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
      new Request("http://localhost/v1/me/devices", { headers: bearer(session.accessToken) }),
    );
    const devices = await readJson(listed);
    expect(devices).toEqual([expect.objectContaining({ id: DEVICE_ID, revoked: true })]);

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
      new Request("http://localhost/v1/me/devices", { headers: bearer(session.accessToken) }),
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
