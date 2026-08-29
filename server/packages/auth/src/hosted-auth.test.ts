import { createMemoryIdentityStore } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { createHostedAuthService, type HostedAuthFetch } from "./hosted-auth";
import { signAccessToken, type JwtSigningConfig } from "./jwt";

const EMAIL = "reader@example.com";
const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const JWT: JwtSigningConfig = {
  issuer: "https://example.supabase.co/auth/v1",
  audience: "authenticated",
  secret: "hosted-test-secret",
  accessTokenTtlSeconds: 3600,
  clockSkewSeconds: 0,
};

type RecordedCall = {
  url: string;
  method: string;
  body: unknown;
  authorization: string | undefined;
};

function jsonResponse(status: number, body: unknown): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function createFetch(handler: (call: RecordedCall) => Response | Promise<Response>): {
  fetch: HostedAuthFetch;
  calls: RecordedCall[];
} {
  const calls: RecordedCall[] = [];
  const fetchImpl: HostedAuthFetch = async (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const method = init?.method ?? "GET";
    let body: unknown = null;
    if (typeof init?.body === "string" && init.body !== "") {
      body = JSON.parse(init.body) as unknown;
    }
    const headers = new Headers(init?.headers);
    const call: RecordedCall = {
      url,
      method,
      body,
      authorization: headers.get("authorization") ?? undefined,
    };
    calls.push(call);
    return handler(call);
  };
  return { fetch: fetchImpl, calls };
}

async function sessionBody(email = EMAIL) {
  const accessToken = await signAccessToken({ sub: "user-hosted", email }, JWT);
  return {
    access_token: accessToken,
    refresh_token: "refresh-token-hosted",
    expires_in: 3600,
    token_type: "bearer",
    user: { id: "user-hosted", email },
  };
}

describe("hosted GoTrue auth service", () => {
  it("requests an email OTP without enumerating unknown addresses", async () => {
    const { fetch, calls } = createFetch(() => jsonResponse(200, null));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    expect(auth.canIssueSessions()).toBe(true);
    expect(await auth.requestEmailOtp(EMAIL)).toEqual({ ok: true, value: { accepted: true } });
    expect(await auth.requestEmailOtp("unknown@example.com")).toEqual({
      ok: true,
      value: { accepted: true },
    });
    expect(calls).toHaveLength(2);
    expect(calls[0]?.url).toBe("https://example.supabase.co/auth/v1/otp");
    expect(calls[0]?.body).toEqual({ email: EMAIL, create_user: true });
  });

  it("emails a six-digit code from generate_link instead of a magic-link OTP mail", async () => {
    const sent: { to: string; code: string }[] = [];
    const { fetch, calls } = createFetch((call) => {
      if (call.url.endsWith("/admin/generate_link")) {
        return jsonResponse(200, { email_otp: "42424201", hashed_token: "hash" });
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      serviceRoleKey: "service-role",
      sendOtpEmail: (input) => {
        sent.push(input);
        return Promise.resolve(true);
      },
      fetch,
    });
    expect(await auth.requestEmailOtp(EMAIL)).toEqual({ ok: true, value: { accepted: true } });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("https://example.supabase.co/auth/v1/admin/generate_link");
    expect(calls[0]?.body).toEqual({ type: "magiclink", email: EMAIL });
    expect(calls[0]?.authorization).toBe("Bearer service-role");
    expect(sent).toEqual([{ to: EMAIL, code: "42424201" }]);
  });

  it("falls back to GoTrue /otp when Resend cannot send the generated code", async () => {
    const { fetch, calls } = createFetch((call) => {
      if (call.url.endsWith("/admin/generate_link")) {
        return jsonResponse(200, { email_otp: "42424201", hashed_token: "hash" });
      }
      if (call.url.endsWith("/otp")) {
        return jsonResponse(200, null);
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      serviceRoleKey: "service-role",
      sendOtpEmail: () => Promise.resolve(false),
      fetch,
    });
    expect(await auth.requestEmailOtp(EMAIL)).toEqual({ ok: true, value: { accepted: true } });
    expect(calls.map((call) => call.url)).toEqual([
      "https://example.supabase.co/auth/v1/admin/generate_link",
      "https://example.supabase.co/auth/v1/otp",
    ]);
  });

  it("returns not_ready when GoTrue OTP is unreachable", async () => {
    const { fetch } = createFetch(() => jsonResponse(503, { message: "down" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    expect(await auth.requestEmailOtp(EMAIL)).toEqual({ ok: false, code: "not_ready" });
  });

  it("verifies an email OTP against GoTrue and hydrates a product session", async () => {
    const tokens = await sessionBody();
    const { fetch, calls } = createFetch((call) => {
      if (call.url.endsWith("/verify")) {
        return jsonResponse(200, tokens);
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const verified = await auth.verifyEmailOtp(EMAIL, "424242", DEVICE_ID);
    expect(verified.ok).toBe(true);
    if (!verified.ok) {
      return;
    }
    expect(verified.value.tokens.refreshToken).toBe("refresh-token-hosted");
    expect(verified.value.tokens.tokenType).toBe("Bearer");
    expect(verified.value.principal.email).toBe(EMAIL);
    expect(verified.value.profile.email).toBe(EMAIL);
    expect(calls[0]?.body).toEqual({ type: "email", email: EMAIL, token: "424242" });

    const request = new Request("https://example.invalid/v1/me", {
      headers: { authorization: `Bearer ${verified.value.tokens.accessToken}` },
    });
    await expect(auth.authenticate(request)).resolves.toMatchObject({ email: EMAIL });
  });

  it("maps a rejected OTP to invalid_otp", async () => {
    const { fetch } = createFetch(() => jsonResponse(400, { error: "invalid" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    expect(await auth.verifyEmailOtp(EMAIL, "000000")).toEqual({ ok: false, code: "invalid_otp" });
  });

  it("verifies a generate_link code as a magiclink OTP after email verify fails", async () => {
    const tokens = await sessionBody();
    const { fetch, calls } = createFetch((call) => {
      const body = call.body as { type?: string };
      if (call.url.endsWith("/verify") && body.type === "magiclink") {
        return jsonResponse(200, tokens);
      }
      if (call.url.endsWith("/verify")) {
        return jsonResponse(400, { error: "invalid" });
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const verified = await auth.verifyEmailOtp(EMAIL, "424242", DEVICE_ID);
    expect(verified.ok).toBe(true);
    expect(calls.map((call) => (call.body as { type?: string }).type)).toEqual([
      "email",
      "magiclink",
    ]);
  });

  it("returns a GoTrue authorize URL for Google and Azure without local-complete", async () => {
    const { fetch, calls } = createFetch(() => jsonResponse(500, { message: "should not fetch" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co/",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const google = await auth.authorizeOAuth({
      provider: "google",
      redirectUri: "audioreader://auth/callback",
      codeChallenge: "a".repeat(43),
      state: "oauth-state-google",
    });
    expect(google.ok).toBe(true);
    if (!google.ok) {
      return;
    }
    const googleUrl = new URL(google.value.authorizationUrl);
    expect(googleUrl.origin).toBe("https://example.supabase.co");
    expect(googleUrl.pathname).toBe("/auth/v1/authorize");
    expect(googleUrl.searchParams.get("provider")).toBe("google");
    expect(googleUrl.searchParams.get("code_challenge_method")).toBe("S256");
    expect(googleUrl.searchParams.get("redirect_to")).toBe("audioreader://auth/callback");
    expect(google.value.state).toBe("oauth-state-google");
    expect(google.value.authorizationUrl).not.toContain("local-complete");

    const microsoft = await auth.authorizeOAuth({
      provider: "microsoft",
      redirectUri: "audioreader://auth/callback",
      codeChallenge: "b".repeat(43),
      state: "oauth-state-ms",
    });
    expect(microsoft.ok).toBe(true);
    if (!microsoft.ok) {
      return;
    }
    const microsoftUrl = new URL(microsoft.value.authorizationUrl);
    expect(microsoftUrl.searchParams.get("provider")).toBe("azure");
    expect(microsoftUrl.searchParams.get("scopes")).toBe("email");
    expect(calls).toHaveLength(0);
  });

  it("reads GoTrue tokens from a nested session envelope", async () => {
    const inner = await sessionBody();
    const { fetch } = createFetch(() =>
      jsonResponse(200, {
        session: {
          access_token: inner.access_token,
          refresh_token: "rt-nested-1",
          expires_in: 3600,
        },
        user: inner.user,
      }),
    );
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const exchanged = await auth.exchangeOAuth({
      provider: "google",
      code: "auth-code-nested",
      codeVerifier: "c".repeat(43),
      redirectUri: "audioreader://auth/callback",
      deviceId: DEVICE_ID,
    });
    expect(exchanged.ok).toBe(true);
    if (!exchanged.ok) {
      return;
    }
    expect(exchanged.value.tokens.refreshToken).toBe("rt-nested-1");
  });

  it("exchanges a PKCE authorization code with GoTrue", async () => {
    const tokens = await sessionBody();
    const { fetch, calls } = createFetch((call) => {
      if (call.url.includes("grant_type=pkce")) {
        return jsonResponse(200, tokens);
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const exchanged = await auth.exchangeOAuth({
      provider: "google",
      code: "auth-code-1",
      codeVerifier: "c".repeat(43),
      redirectUri: "audioreader://auth/callback",
      deviceId: DEVICE_ID,
    });
    expect(exchanged.ok).toBe(true);
    if (!exchanged.ok) {
      return;
    }
    expect(exchanged.value.principal.email).toBe(EMAIL);
    expect(calls[0]?.url).toBe("https://example.supabase.co/auth/v1/token?grant_type=pkce");
    expect(calls[0]?.body).toEqual({
      auth_code: "auth-code-1",
      code: "auth-code-1",
      code_verifier: "c".repeat(43),
    });
  });

  it("refreshes and logs out through GoTrue", async () => {
    const tokens = await sessionBody();
    const nextTokens = {
      ...tokens,
      access_token: await signAccessToken({ sub: "user-hosted", email: EMAIL }, JWT),
      refresh_token: "refresh-token-next",
    };
    const { fetch, calls } = createFetch((call) => {
      if (call.url.includes("grant_type=refresh_token")) {
        return jsonResponse(200, nextTokens);
      }
      if (call.url.includes("/logout")) {
        return new Response(null, { status: 204 });
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const refreshed = await auth.refresh("refresh-token-hosted");
    expect(refreshed.ok).toBe(true);
    if (!refreshed.ok) {
      return;
    }
    expect(refreshed.value.tokens.refreshToken).toBe("refresh-token-next");
    const withDevice = await auth.refresh("refresh-token-hosted", DEVICE_ID);
    expect(withDevice.ok).toBe(true);
    await auth.logout("refresh-token-next");
    expect(calls.some((call) => call.url.includes("/logout"))).toBe(true);
    const logout = calls.find((call) => call.url.includes("/logout"));
    expect(logout?.authorization).toMatch(/^Bearer ey/);
  });

  it("bootstraps a device against the hydrated principal", async () => {
    const tokens = await sessionBody();
    const { fetch } = createFetch(() => jsonResponse(200, tokens));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    const verified = await auth.verifyEmailOtp(EMAIL, "424242", DEVICE_ID);
    expect(verified.ok).toBe(true);
    if (!verified.ok) {
      return;
    }
    const bootstrapped = await auth.bootstrap(verified.value.principal, {
      deviceId: DEVICE_ID,
      platform: "macos",
      appVersion: "1.0.0",
      deviceName: "Study Mac",
    });
    expect(bootstrapped.ok).toBe(true);
    if (!bootstrapped.ok) {
      return;
    }
    expect(bootstrapped.value.device.id).toBe(DEVICE_ID);
    expect(await auth.listDevices(verified.value.principal)).toHaveLength(1);
  });

  it("persists profiles and devices through an identity store across service instances", async () => {
    const userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const identity = createMemoryIdentityStore();
    const tokens = {
      access_token: await signAccessToken({ sub: userId, email: EMAIL }, JWT),
      refresh_token: "refresh-token-hosted",
      expires_in: 3600,
      token_type: "bearer",
      user: { id: userId, email: EMAIL },
    };
    const { fetch } = createFetch(() => jsonResponse(200, tokens));
    const first = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    const verified = await first.verifyEmailOtp(EMAIL, "424242", DEVICE_ID);
    expect(verified.ok).toBe(true);
    if (!verified.ok) {
      return;
    }
    expect(verified.value.principal.accountId).toBe(userId);
    expect(
      (
        await first.bootstrap(verified.value.principal, {
          deviceId: DEVICE_ID,
          platform: "macos",
          appVersion: "1.0.0",
        })
      ).ok,
    ).toBe(true);

    const second = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    const restored = await second.authenticate(
      new Request("https://audio-reader.local/session", {
        headers: {
          authorization: `Bearer ${tokens.access_token}`,
          "X-Device-Id": DEVICE_ID,
        },
      }),
    );
    expect(restored?.accountId).toBe(userId);
    if (restored === null) {
      return;
    }
    expect(await second.listDevices(restored)).toEqual(
      expect.arrayContaining([expect.objectContaining({ id: DEVICE_ID, revoked: false })]),
    );
  });

  it("refuses suspended accounts even with a valid access token", async () => {
    const userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId, email: EMAIL });
    await identity.setAccountStatus(userId, "suspended");
    const token = await signAccessToken({ sub: userId, email: EMAIL }, JWT);
    const { fetch } = createFetch(() => jsonResponse(500, { message: "unused" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    await expect(
      auth.authenticate(
        new Request("https://audio-reader.local/session", {
          headers: { authorization: `Bearer ${token}` },
        }),
      ),
    ).resolves.toBeNull();
  });

  it("grants bootstrap admin only when no operator exists yet", async () => {
    const bootstrapId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const otherId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const { fetch } = createFetch(() => jsonResponse(500, { message: "unused" }));
    const empty = createMemoryIdentityStore();
    const firstAuth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity: empty,
      adminBootstrapEmail: EMAIL,
    });
    const token = await signAccessToken({ sub: bootstrapId, email: EMAIL }, JWT);
    const headers = { authorization: `Bearer ${token}` };
    const first = await firstAuth.authenticate(
      new Request("https://audio-reader.local/session", { headers }),
    );
    expect(first?.role).toBe("admin");
    expect(await empty.hasAdminRole(bootstrapId)).toBe(true);
    const again = await firstAuth.authenticate(
      new Request("https://audio-reader.local/session", { headers }),
    );
    expect(again?.role).toBe("admin");

    const occupied = createMemoryIdentityStore();
    await occupied.ensureProfile({ userId: otherId, email: "ops@example.com" });
    await occupied.grantAdminRole(otherId);
    const blocked = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity: occupied,
      adminBootstrapEmail: EMAIL,
    });
    const second = await blocked.authenticate(
      new Request("https://audio-reader.local/session", { headers }),
    );
    expect(second?.role).toBe("user");
    expect(await occupied.hasAdminRole(bootstrapId)).toBe(false);
  });

  it("maps GoTrue refresh outages to not_ready instead of invalid_refresh", async () => {
    const { fetch } = createFetch(() => jsonResponse(503, { message: "down" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });
    await expect(auth.refresh("refresh-token-hosted")).resolves.toEqual({
      ok: false,
      code: "not_ready",
    });
  });

  it("refuses refresh when the presented device has been revoked", async () => {
    const userId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId, email: EMAIL });
    await identity.bootstrapDevice(userId, {
      deviceId: DEVICE_ID,
      platform: "macos",
      appVersion: "1.0.0",
    });
    await identity.revokeDevice(userId, DEVICE_ID);
    const accessToken = await signAccessToken({ sub: userId, email: EMAIL }, JWT);
    const { fetch } = createFetch((call) => {
      if (call.url.includes("grant_type=refresh_token")) {
        return jsonResponse(200, {
          access_token: accessToken,
          refresh_token: "refresh-token-next",
          expires_in: 3600,
        });
      }
      return jsonResponse(500, { message: "unexpected" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    await expect(auth.refresh("refresh-token-hosted", DEVICE_ID)).resolves.toEqual({
      ok: false,
      code: "invalid_token",
    });
  });
});
