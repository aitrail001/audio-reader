import { createMemoryIdentityStore, type IdentityStore } from "@audio-reader/database";
import { describe, expect, it, vi } from "vitest";
import { createHostedAuthService, type HostedAuthFetch } from "./hosted-auth";
import { signAccessToken, type JwtSigningConfig } from "./jwt";

const EMAIL = "reader@example.com";
const DEVICE_ID = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const BOOTSTRAP_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
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

async function authenticateBootstrap(identity: IdentityStore) {
  const { fetch } = createFetch(() => jsonResponse(500, { message: "unused" }));
  const auth = createHostedAuthService({
    jwt: JWT,
    supabaseUrl: "https://example.supabase.co",
    supabaseAnonKey: "anon-key",
    fetch,
    identity,
    adminBootstrapEmail: EMAIL,
  });
  const token = await signAccessToken({ sub: BOOTSTRAP_ID, email: EMAIL }, JWT);
  return auth.authenticate(
    new Request("https://audio-reader.local/session", {
      headers: { authorization: `Bearer ${token}` },
    }),
  );
}

describe("hosted GoTrue auth service", () => {
  it("reports only OAuth providers enabled by GoTrue", async () => {
    const { fetch, calls } = createFetch(() =>
      jsonResponse(200, { external: { email: true, google: false, azure: true } }),
    );
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });

    await expect(auth.authConfig()).resolves.toEqual({
      providers: [{ id: "microsoft" }, { id: "email_otp" }],
    });
    expect(calls.map((call) => call.url)).toEqual(["https://example.supabase.co/auth/v1/settings"]);
  });

  it("rejects an OAuth provider disabled by GoTrue before opening a browser", async () => {
    const { fetch, calls } = createFetch(() =>
      jsonResponse(200, { external: { email: true, google: false, azure: true } }),
    );
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
    });

    await expect(
      auth.authorizeOAuth({
        provider: "google",
        redirectUri: "audioreader://auth/callback",
        codeChallenge: "a".repeat(43),
        state: "oauth-state-google",
      }),
    ).resolves.toEqual({ ok: false, code: "provider_disabled" });
    expect(calls).toHaveLength(1);
  });

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
    const { fetch, calls } = createFetch(() =>
      jsonResponse(200, { external: { email: true, google: true, azure: true } }),
    );
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
    expect(googleUrl.searchParams.get("prompt")).toBe("select_account");
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
    expect(microsoftUrl.searchParams.get("prompt")).toBe("select_account");
    expect(microsoftUrl.searchParams.get("scopes")).toBe("email");
    expect(calls.map((call) => call.url)).toEqual([
      "https://example.supabase.co/auth/v1/settings",
      "https://example.supabase.co/auth/v1/settings",
    ]);
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
      code_verifier: "c".repeat(43),
    });
  });

  it("reports a PKCE verifier mismatch without logging the code or verifier", async () => {
    const spy = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    try {
      const { fetch } = createFetch(() =>
        jsonResponse(400, {
          error_code: "bad_code_verifier",
          msg: "code challenge does not match previously saved code verifier",
        }),
      );
      const auth = createHostedAuthService({
        jwt: JWT,
        supabaseUrl: "https://example.supabase.co",
        supabaseAnonKey: "anon-key",
        fetch,
      });

      await expect(
        auth.exchangeOAuth({
          provider: "google",
          code: "sensitive-auth-code",
          codeVerifier: "v".repeat(43),
          redirectUri: "audioreader://auth/callback",
          deviceId: DEVICE_ID,
        }),
      ).resolves.toEqual({ ok: false, code: "pkce_mismatch" });
      const logs = spy.mock.calls.flat().join("\n");
      expect(logs).toContain("bad_code_verifier");
      expect(logs).not.toContain("sensitive-auth-code");
      expect(logs).not.toContain("v".repeat(43));
    } finally {
      spy.mockRestore();
    }
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

  it("moves one install UUID to a newly signed-in account", async () => {
    const aliceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    const bobId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const identity = createMemoryIdentityStore();
    const aliceToken = await signAccessToken({ sub: aliceId, email: "alice@example.com" }, JWT);
    const bobToken = await signAccessToken({ sub: bobId, email: "bob@example.com" }, JWT);
    const { fetch } = createFetch((call) => {
      if (call.url.includes("/token") || call.url.includes("/user")) {
        return jsonResponse(200, { access_token: aliceToken });
      }
      return jsonResponse(500, { message: "unused" });
    });
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    const alice = await auth.authenticate(
      new Request("https://audio-reader.local/session", {
        headers: { authorization: `Bearer ${aliceToken}`, "X-Device-Id": DEVICE_ID },
      }),
    );
    const bob = await auth.authenticate(
      new Request("https://audio-reader.local/session", {
        headers: { authorization: `Bearer ${bobToken}`, "X-Device-Id": DEVICE_ID },
      }),
    );
    expect(alice?.accountId).toBe(aliceId);
    expect(bob?.accountId).toBe(bobId);
    if (alice === null || bob === null) {
      return;
    }
    expect(
      (
        await auth.bootstrap(alice, {
          deviceId: DEVICE_ID,
          platform: "macos",
          appVersion: "1.0.0",
        })
      ).ok,
    ).toBe(true);
    expect(
      (
        await auth.bootstrap(bob, {
          deviceId: DEVICE_ID,
          platform: "macos",
          appVersion: "2.6.1",
        })
      ).ok,
    ).toBe(true);
    expect((await auth.listDevices(alice)).map((device) => device.id)).toEqual([]);
    expect((await auth.listDevices(bob)).map((device) => device.id)).toEqual([DEVICE_ID]);
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

  it("grants the configured bootstrap identity a superadmin role when no admin exists", async () => {
    const otherId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const empty = createMemoryIdentityStore();
    const first = await authenticateBootstrap(empty);
    expect(first?.role).toBe("admin");
    expect(first?.adminRoles).toEqual(["superadmin"]);
    expect(await empty.hasAdminRole(BOOTSTRAP_ID)).toBe(true);
    const again = await authenticateBootstrap(empty);
    expect(again?.role).toBe("admin");

    const occupied = createMemoryIdentityStore();
    await occupied.ensureProfile({ userId: otherId, email: "ops@example.com" });
    await occupied.grantAdminRole(otherId);
    const second = await authenticateBootstrap(occupied);
    expect(second?.role).toBe("user");
    expect(await occupied.hasAdminRole(BOOTSTRAP_ID)).toBe(false);
  });

  it("promotes the configured legacy bootstrap operator when no superadmin exists", async () => {
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId: BOOTSTRAP_ID, email: EMAIL });
    await identity.grantAdminRole(BOOTSTRAP_ID);
    const principal = await authenticateBootstrap(identity);

    expect(principal?.adminRoles).toEqual(["operator", "superadmin"]);
    expect(await identity.hasAnyAdminRole("superadmin")).toBe(true);
  });

  it("does not promote a scoped bootstrap admin without the legacy operator role", async () => {
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId: BOOTSTRAP_ID, email: EMAIL });
    await identity.grantAdminRole(BOOTSTRAP_ID, "privacy_officer");
    const principal = await authenticateBootstrap(identity);

    expect(principal?.adminRoles).toEqual(["privacy_officer"]);
    expect(await identity.hasAnyAdminRole("superadmin")).toBe(false);
  });

  it("does not restore a revoked bootstrap superadmin grant", async () => {
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId: BOOTSTRAP_ID, email: EMAIL });
    let grantAttempted = false;
    Object.assign(identity, {
      hasAdminRole: () => Promise.resolve(false),
      adminRoles: () => Promise.resolve([]),
      hasAnyAdminRole: () => Promise.resolve(false),
      hasAdminRoleHistory: () => Promise.resolve(true),
      grantAdminRole: () => {
        grantAttempted = true;
        return Promise.resolve();
      },
    });
    const principal = await authenticateBootstrap(identity);

    expect(principal?.role).toBe("user");
    expect(grantAttempted).toBe(false);
  });

  it("does not elevate when persistence reports success without an active grant", async () => {
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId: BOOTSTRAP_ID, email: EMAIL });
    Object.assign(identity, { grantAdminRole: () => Promise.resolve() });
    const principal = await authenticateBootstrap(identity);

    expect(principal?.role).toBe("user");
    expect(principal?.adminRoles).toEqual([]);
  });

  it("preserves scoped admin roles instead of collapsing them into generic admin", async () => {
    const userId = "abababab-abab-4bab-8bab-abababababab";
    const identity = createMemoryIdentityStore();
    await identity.ensureProfile({ userId, email: EMAIL });
    Object.assign(identity, {
      adminRoles: () => Promise.resolve(["privacy_officer" as const]),
    });
    const { fetch } = createFetch(() => jsonResponse(500, { message: "unused" }));
    const auth = createHostedAuthService({
      jwt: JWT,
      supabaseUrl: "https://example.supabase.co",
      supabaseAnonKey: "anon-key",
      fetch,
      identity,
    });
    const token = await signAccessToken({ sub: userId, email: EMAIL }, JWT);

    const principal = await auth.authenticate(
      new Request("https://audio-reader.local/session", {
        headers: { authorization: `Bearer ${token}` },
      }),
    );

    expect(principal).toMatchObject({ role: "admin", adminRoles: ["privacy_officer"] });
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
