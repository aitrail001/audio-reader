import { describe, expect, it } from "vitest";
import { LOCAL_JWT_CONFIG, validateAccessToken } from "./jwt";
import { createMemoryAuthService } from "./service";

const EMAIL = "reader@example.com";
const UNKNOWN_EMAIL = "unknown@example.com";

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const verifier = base64Url(bytes);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64Url(new Uint8Array(digest)) };
}

describe("memory auth service", () => {
  it("returns the same public OTP request result for existing and unknown emails", async () => {
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "123456",
    });
    const firstUnknown = await auth.requestEmailOtp(UNKNOWN_EMAIL);
    const verified = await auth.verifyEmailOtp(EMAIL, "123456");
    expect(verified.ok).toBe(false);
    await auth.requestEmailOtp(EMAIL);
    const existing = await auth.verifyEmailOtp(EMAIL, "123456");
    expect(existing.ok).toBe(true);
    const secondExisting = await auth.requestEmailOtp(EMAIL);
    const secondUnknown = await auth.requestEmailOtp(UNKNOWN_EMAIL);
    expect(firstUnknown).toEqual({ ok: true, value: { accepted: true } });
    expect(secondExisting).toEqual({ ok: true, value: { accepted: true } });
    expect(secondUnknown).toEqual({ ok: true, value: { accepted: true } });
    expect(secondExisting).toEqual(secondUnknown);
  });

  it("rejects a wrong OTP and an expired OTP", async () => {
    const clock = { now: new Date("2026-01-01T00:00:00.000Z") };
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "654321",
      otpTtlSeconds: 60,
      now: () => clock.now,
    });
    await auth.requestEmailOtp(EMAIL);
    const wrong = await auth.verifyEmailOtp(EMAIL, "000000");
    expect(wrong).toEqual({ ok: false, code: "invalid_otp" });

    const expiredAuth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "654321",
      otpTtlSeconds: 60,
      now: () => clock.now,
    });
    await expiredAuth.requestEmailOtp(EMAIL);
    clock.now = new Date("2026-01-01T00:02:00.000Z");
    const expired = await expiredAuth.verifyEmailOtp(EMAIL, "654321");
    expect(expired).toEqual({ ok: false, code: "invalid_otp" });
  });

  it("issues a JWT whose subject maps to a product profile", async () => {
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "111111",
    });
    await auth.requestEmailOtp(EMAIL);
    const verified = await auth.verifyEmailOtp(EMAIL, "111111");
    expect(verified.ok).toBe(true);
    if (!verified.ok) {
      return;
    }
    expect(verified.value.tokens.tokenType).toBe("Bearer");
    const jwt = await validateAccessToken(verified.value.tokens.accessToken, LOCAL_JWT_CONFIG);
    expect(jwt.ok).toBe(true);
    if (!jwt.ok) {
      return;
    }
    expect(jwt.claims.sub).toBe(verified.value.principal.subject);
    expect(verified.value.profile.email).toBe(EMAIL);
    expect(verified.value.profile.id).toBe(verified.value.principal.profileId);
    expect(verified.value.profile.accountId).toBe(verified.value.principal.accountId);
  });

  it("does not auto-merge Google, Microsoft, and email identities that share an address", async () => {
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "222222",
    });
    await auth.requestEmailOtp(EMAIL);
    const emailSession = await auth.verifyEmailOtp(EMAIL, "222222");
    expect(emailSession.ok).toBe(true);
    if (!emailSession.ok) {
      return;
    }

    const googlePkce = await pkcePair();
    const googleAuth = await auth.authorizeOAuth({
      provider: "google",
      redirectUri: "http://localhost/callback",
      codeChallenge: googlePkce.challenge,
      state: "google-state-1",
      identity: { email: EMAIL, providerSubject: "google-user-1" },
    });
    expect(googleAuth.ok).toBe(true);
    if (!googleAuth.ok) {
      return;
    }
    const googleCode = new URL(googleAuth.value.authorizationUrl).searchParams.get("code");
    expect(googleCode).toEqual(expect.any(String));
    const googleSession = await auth.exchangeOAuth({
      provider: "google",
      code: googleCode ?? "",
      codeVerifier: googlePkce.verifier,
      redirectUri: "http://localhost/callback",
    });
    expect(googleSession.ok).toBe(true);
    if (!googleSession.ok) {
      return;
    }

    const microsoftPkce = await pkcePair();
    const microsoftAuth = await auth.authorizeOAuth({
      provider: "microsoft",
      redirectUri: "http://localhost/callback",
      codeChallenge: microsoftPkce.challenge,
      state: "ms-state-1",
      identity: { email: EMAIL, providerSubject: "ms-user-1" },
    });
    expect(microsoftAuth.ok).toBe(true);
    if (!microsoftAuth.ok) {
      return;
    }
    const microsoftCode = new URL(microsoftAuth.value.authorizationUrl).searchParams.get("code");
    const microsoftSession = await auth.exchangeOAuth({
      provider: "microsoft",
      code: microsoftCode ?? "",
      codeVerifier: microsoftPkce.verifier,
      redirectUri: "http://localhost/callback",
    });
    expect(microsoftSession.ok).toBe(true);
    if (!microsoftSession.ok) {
      return;
    }

    expect(emailSession.value.principal.accountId).not.toBe(
      googleSession.value.principal.accountId,
    );
    expect(googleSession.value.principal.accountId).not.toBe(
      microsoftSession.value.principal.accountId,
    );

    const stolen = auth.linkIdentity(emailSession.value.principal, {
      provider: "google",
      providerSubject: "google-user-1",
      email: EMAIL,
    });
    expect(stolen).toEqual({ ok: false, code: "already_linked" });

    const rebound = auth.linkIdentity(googleSession.value.principal, {
      provider: "google",
      providerSubject: "google-user-1",
      email: EMAIL,
    });
    expect(rebound.ok).toBe(true);

    const firstBind = auth.linkIdentity(emailSession.value.principal, {
      provider: "google",
      providerSubject: "google-user-unbound",
      email: EMAIL,
    });
    expect(firstBind.ok).toBe(true);

    const googleUnbound = await pkcePair();
    const googleUnboundAuth = await auth.authorizeOAuth({
      provider: "google",
      redirectUri: "http://localhost/callback",
      codeChallenge: googleUnbound.challenge,
      state: "google-state-unbound",
      identity: { email: EMAIL, providerSubject: "google-user-unbound" },
    });
    expect(googleUnboundAuth.ok).toBe(true);
    if (!googleUnboundAuth.ok) {
      return;
    }
    const unboundCode = new URL(googleUnboundAuth.value.authorizationUrl).searchParams.get("code");
    const unboundSession = await auth.exchangeOAuth({
      provider: "google",
      code: unboundCode ?? "",
      codeVerifier: googleUnbound.verifier,
      redirectUri: "http://localhost/callback",
    });
    expect(unboundSession.ok).toBe(true);
    if (!unboundSession.ok) {
      return;
    }
    expect(unboundSession.value.principal.accountId).toBe(emailSession.value.principal.accountId);

    const googleAgain = await pkcePair();
    const googleAuthAgain = await auth.authorizeOAuth({
      provider: "google",
      redirectUri: "http://localhost/callback",
      codeChallenge: googleAgain.challenge,
      state: "google-state-2",
      identity: { email: EMAIL, providerSubject: "google-user-1" },
    });
    expect(googleAuthAgain.ok).toBe(true);
    if (!googleAuthAgain.ok) {
      return;
    }
    const googleCodeAgain = new URL(googleAuthAgain.value.authorizationUrl).searchParams.get(
      "code",
    );
    const googleStillB = await auth.exchangeOAuth({
      provider: "google",
      code: googleCodeAgain ?? "",
      codeVerifier: googleAgain.verifier,
      redirectUri: "http://localhost/callback",
    });
    expect(googleStillB.ok).toBe(true);
    if (!googleStillB.ok) {
      return;
    }
    expect(googleStillB.value.principal.accountId).toBe(googleSession.value.principal.accountId);
  });

  it("does not mint stub sessions when local issuance is disabled", async () => {
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      allowLocalIssuance: false,
      generateOtp: () => "123456",
    });
    expect(auth.canIssueSessions()).toBe(false);
    expect(await auth.requestEmailOtp(EMAIL)).toEqual({ ok: false, code: "not_ready" });
    expect(await auth.verifyEmailOtp(EMAIL, "123456")).toEqual({ ok: false, code: "not_ready" });
    const pkce = await pkcePair();
    expect(
      await auth.authorizeOAuth({
        provider: "google",
        redirectUri: "http://localhost/callback",
        codeChallenge: pkce.challenge,
        state: "google-state-disabled",
      }),
    ).toEqual({ ok: false, code: "not_ready" });
    expect(
      await auth.exchangeOAuth({
        provider: "google",
        code: "not-a-real-code",
        codeVerifier: pkce.verifier,
        redirectUri: "http://localhost/callback",
      }),
    ).toEqual({ ok: false, code: "not_ready" });
  });

  it("refreshes a session and rejects the refresh token after logout", async () => {
    const auth = createMemoryAuthService({
      jwt: LOCAL_JWT_CONFIG,
      generateOtp: () => "333333",
    });
    await auth.requestEmailOtp(EMAIL);
    const verified = await auth.verifyEmailOtp(EMAIL, "333333");
    expect(verified.ok).toBe(true);
    if (!verified.ok) {
      return;
    }
    const refreshed = await auth.refresh(verified.value.tokens.refreshToken);
    expect(refreshed.ok).toBe(true);
    if (!refreshed.ok) {
      return;
    }
    expect(refreshed.value.tokens.accessToken).not.toBe(verified.value.tokens.accessToken);
    expect(refreshed.value.tokens.refreshToken).not.toBe(verified.value.tokens.refreshToken);

    const reused = await auth.refresh(verified.value.tokens.refreshToken);
    expect(reused).toEqual({ ok: false, code: "invalid_refresh" });

    await auth.logout(refreshed.value.tokens.refreshToken);
    const afterLogout = await auth.refresh(refreshed.value.tokens.refreshToken);
    expect(afterLogout).toEqual({ ok: false, code: "invalid_refresh" });
    await expect(auth.logout(refreshed.value.tokens.refreshToken)).resolves.toBeUndefined();
  });
});
