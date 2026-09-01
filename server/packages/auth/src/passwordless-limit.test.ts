import { describe, expect, it } from "vitest";
import { normalizeEmail } from "./service";
import {
  createCloudflareTurnstileVerifier,
  createDurablePasswordlessLimiter,
  createMemoryPasswordlessLimiter,
  hashIdentifier,
  type PasswordlessAttempt,
  type PasswordlessDurableStore,
  type PasswordlessLimiter,
  type PasswordlessSecurityEvent,
} from "./passwordless-limit";

const EMAIL = "reader@example.com";
const OTHER_EMAIL = "other@example.com";
const THIRD_EMAIL = "third@example.com";
const IP = "203.0.113.10";
const OTHER_IP = "198.51.100.20";
const DEVICE = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const OTHER_DEVICE = "3fa85f64-5717-4562-b3fc-2c963f66afa7";

function createLimiter(overrides: Parameters<typeof createMemoryPasswordlessLimiter>[0] = {}): {
  limiter: PasswordlessLimiter;
  events: PasswordlessSecurityEvent[];
} {
  const events: PasswordlessSecurityEvent[] = [];
  const limiter = createMemoryPasswordlessLimiter({
    ...overrides,
    onSecurityEvent: (event) => {
      events.push(event);
      overrides.onSecurityEvent?.(event);
    },
  });
  return { limiter, events };
}

function attempt(
  overrides: Partial<PasswordlessAttempt> & Pick<PasswordlessAttempt, "email">,
): PasswordlessAttempt {
  return {
    ip: IP,
    ...overrides,
  };
}

describe("passwordless rate limits", () => {
  it("hashes emails after normalization and never stores the raw address", async () => {
    const expected = await hashIdentifier(normalizeEmail("Reader@Example.com"));
    expect(await hashIdentifier(normalizeEmail(EMAIL))).toBe(expected);
    expect(expected).toMatch(/^[0-9a-f]{64}$/);
    expect(expected).not.toContain("reader");
    expect(expected).not.toContain("@");
  });

  it("HMACs identifiers so unsalted SHA-256 of the email is not stored", async () => {
    const hmac = await hashIdentifier(normalizeEmail(EMAIL), "pepper-a");
    const otherPepper = await hashIdentifier(normalizeEmail(EMAIL), "pepper-b");
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(normalizeEmail(EMAIL)),
    );
    let unsalted = "";
    for (const byte of new Uint8Array(digest)) {
      unsalted += byte.toString(16).padStart(2, "0");
    }
    expect(hmac).not.toBe(otherPepper);
    expect(hmac).not.toBe(unsalted);
    const { limiter } = createLimiter({
      hmacSecret: "pepper-a",
      limits: { requestCooldownSeconds: 30 },
    });
    await limiter.checkRequest(attempt({ email: EMAIL }));
    await limiter.checkRequest(attempt({ email: EMAIL }));
    expect((await limiter.listBlockedAttempts())[0]?.emailHash).toBe(hmac);
    expect(JSON.stringify(await limiter.listBlockedAttempts())).not.toContain(EMAIL);
  });

  it("enforces a resend cooldown per email hash", async () => {
    const clock = { now: new Date("2026-01-01T00:00:00.000Z") };
    const { limiter, events } = createLimiter({
      now: () => clock.now,
      limits: { requestCooldownSeconds: 60 },
    });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });
    const blocked = await limiter.checkRequest(attempt({ email: "Reader@example.com" }));
    expect(blocked).toEqual({ ok: false, code: "rate_limited", retryAfterSeconds: 60 });
    expect(await limiter.checkRequest(attempt({ email: OTHER_EMAIL }))).toEqual({ ok: true });

    clock.now = new Date("2026-01-01T00:01:00.000Z");
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });

    expect(events).toEqual([
      expect.objectContaining({
        type: "passwordless_rate_limited",
        action: "email_otp_request",
        emailHash: await hashIdentifier(normalizeEmail(EMAIL)),
      }),
    ]);
    expect(JSON.stringify(events)).not.toContain(EMAIL);
  });

  it("clears the resend cooldown after a successful verification", async () => {
    const { limiter } = createLimiter({ limits: { requestCooldownSeconds: 60 } });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });
    await limiter.recordVerifySuccess({ email: EMAIL });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });
  });

  it("reserves verify slots atomically so a parallel burst cannot exceed max", async () => {
    const { limiter } = createLimiter({
      limits: {
        verifyEmail: { max: 3, challengeAfter: 3 },
      },
    });
    const results = await Promise.all(
      Array.from({ length: 8 }, () => limiter.checkVerify(attempt({ email: EMAIL }))),
    );
    expect(results.filter((result) => result.ok)).toHaveLength(3);
    expect(results.filter((result) => !result.ok && result.code === "rate_limited")).toHaveLength(
      5,
    );
  });

  it("skips Turnstile and only lockouts when challenge is disabled", async () => {
    const { limiter, events } = createLimiter({
      enableChallenge: false,
      limits: {
        verifyEmail: { max: 3, challengeAfter: 1 },
      },
    });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toMatchObject({
      ok: false,
      code: "rate_limited",
    });
    expect(events.map((event) => event.type)).not.toContain("passwordless_challenge_required");
  });

  it("rate limits brute-force OTP verification even when the code is later correct", async () => {
    const { limiter } = createLimiter({
      limits: {
        verifyEmail: { max: 3, challengeAfter: 3 },
      },
      verifyTurnstile: () => Promise.resolve(false),
    });
    for (let index = 0; index < 3; index += 1) {
      expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
      await limiter.recordVerifyFailure(attempt({ email: EMAIL }));
    }
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({
      ok: false,
      code: "rate_limited",
      retryAfterSeconds: expect.any(Number) as number,
    });
  });

  it("requires a Turnstile token after the verify abuse threshold", async () => {
    const { limiter, events } = createLimiter({
      limits: {
        verifyEmail: { max: 5, challengeAfter: 2 },
      },
      verifyTurnstile: (token) => Promise.resolve(token === "turnstile-ok"),
    });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
    await limiter.recordVerifyFailure(attempt({ email: EMAIL }));
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
    await limiter.recordVerifyFailure(attempt({ email: EMAIL }));

    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({
      ok: false,
      code: "challenge_required",
    });
    expect(await limiter.checkVerify(attempt({ email: EMAIL, turnstileToken: "nope" }))).toEqual({
      ok: false,
      code: "challenge_required",
    });
    expect(
      await limiter.checkVerify(attempt({ email: EMAIL, turnstileToken: "turnstile-ok" })),
    ).toEqual({ ok: true });

    expect(events.map((event) => event.type)).toContain("passwordless_challenge_required");
    expect(JSON.stringify(events)).not.toContain(EMAIL);
    expect(JSON.stringify(events)).not.toContain("turnstile-ok");
  });

  it("requires Turnstile on OTP request after the email-hash abuse threshold", async () => {
    const { limiter } = createLimiter({
      limits: {
        requestCooldownSeconds: 0,
        requestEmail: { max: 4, challengeAfter: 2 },
      },
      verifyTurnstile: (token) => Promise.resolve(token === "turnstile-ok"),
    });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({ ok: true });
    expect(await limiter.checkRequest(attempt({ email: EMAIL }))).toEqual({
      ok: false,
      code: "challenge_required",
    });
    expect(
      await limiter.checkRequest(attempt({ email: EMAIL, turnstileToken: "turnstile-ok" })),
    ).toEqual({ ok: true });
    expect(
      await limiter.checkRequest(attempt({ email: EMAIL, turnstileToken: "turnstile-ok" })),
    ).toEqual({ ok: true });
    expect(
      await limiter.checkRequest(attempt({ email: EMAIL, turnstileToken: "turnstile-ok" })),
    ).toEqual({
      ok: false,
      code: "rate_limited",
      retryAfterSeconds: expect.any(Number) as number,
    });
  });

  it("applies independent IP and device buckets", async () => {
    const { limiter } = createLimiter({
      limits: {
        requestCooldownSeconds: 0,
        requestEmail: { max: 50, challengeAfter: 50 },
        requestIp: { max: 2, challengeAfter: 2 },
        requestDevice: { max: 2, challengeAfter: 2 },
      },
    });
    expect(await limiter.checkRequest(attempt({ email: EMAIL, ip: IP }))).toEqual({ ok: true });
    expect(await limiter.checkRequest(attempt({ email: OTHER_EMAIL, ip: IP }))).toEqual({
      ok: true,
    });
    expect(await limiter.checkRequest(attempt({ email: THIRD_EMAIL, ip: IP }))).toEqual({
      ok: false,
      code: "rate_limited",
      retryAfterSeconds: expect.any(Number) as number,
    });
    expect(await limiter.checkRequest(attempt({ email: THIRD_EMAIL, ip: OTHER_IP }))).toEqual({
      ok: true,
    });

    const deviceIpA = "192.0.2.1";
    const deviceIpB = "192.0.2.2";
    const deviceIpC = "192.0.2.3";
    expect(
      await limiter.checkRequest(attempt({ email: EMAIL, ip: deviceIpA, deviceId: DEVICE })),
    ).toEqual({ ok: true });
    expect(
      await limiter.checkRequest(attempt({ email: OTHER_EMAIL, ip: deviceIpB, deviceId: DEVICE })),
    ).toEqual({ ok: true });
    expect(
      await limiter.checkRequest(attempt({ email: THIRD_EMAIL, ip: deviceIpC, deviceId: DEVICE })),
    ).toEqual({
      ok: false,
      code: "rate_limited",
      retryAfterSeconds: expect.any(Number) as number,
    });
    expect(
      await limiter.checkRequest(
        attempt({ email: THIRD_EMAIL, ip: deviceIpC, deviceId: OTHER_DEVICE }),
      ),
    ).toEqual({ ok: true });
  });

  it("lists blocked attempts with hashes instead of raw email or IP", async () => {
    const { limiter } = createLimiter({
      limits: { requestCooldownSeconds: 30 },
    });
    await limiter.checkRequest(attempt({ email: EMAIL, ip: IP, deviceId: DEVICE }));
    await limiter.checkRequest(
      attempt({ email: EMAIL, ip: IP, deviceId: DEVICE, requestId: "req-blocked-1" }),
    );
    const blocked = await limiter.listBlockedAttempts();
    expect(blocked).toEqual([
      expect.objectContaining({
        action: "email_otp_request",
        reason: "rate_limited",
        emailHash: await hashIdentifier(normalizeEmail(EMAIL)),
        ipHash: await hashIdentifier(IP),
        deviceId: DEVICE,
      }),
    ]);
    expect(JSON.stringify(blocked)).not.toContain(EMAIL);
    expect(JSON.stringify(blocked)).not.toContain(IP);
  });

  it("emits a repeated-failure security event without raw email", async () => {
    const { limiter, events } = createLimiter({
      limits: {
        verifyEmail: { max: 5, challengeAfter: 2 },
      },
    });
    await limiter.checkVerify(attempt({ email: EMAIL }));
    await limiter.recordVerifyFailure(attempt({ email: EMAIL, requestId: "req-fail-1" }));
    await limiter.checkVerify(attempt({ email: EMAIL }));
    await limiter.recordVerifyFailure(attempt({ email: EMAIL, requestId: "req-fail-2" }));
    expect(events).toEqual([
      expect.objectContaining({
        type: "passwordless_repeated_failure",
        action: "email_otp_verify",
        emailHash: await hashIdentifier(normalizeEmail(EMAIL)),
        requestId: "req-fail-2",
      }),
    ]);
    expect(JSON.stringify(events)).not.toContain(EMAIL);
  });

  it("clears per-email verify failures after success so a later login is not locked", async () => {
    const { limiter } = createLimiter({
      limits: {
        verifyEmail: { max: 2, challengeAfter: 2 },
      },
    });
    await limiter.checkVerify(attempt({ email: EMAIL }));
    await limiter.recordVerifyFailure(attempt({ email: EMAIL }));
    await limiter.recordVerifySuccess({ email: EMAIL });
    expect(await limiter.checkVerify(attempt({ email: EMAIL }))).toEqual({ ok: true });
  });

  it("fails closed when the durable store cannot count hits", async () => {
    const store: PasswordlessDurableStore = {
      countHits: () => Promise.resolve(null),
      addHit: () => Promise.resolve(true),
      clearHits: () => Promise.resolve(undefined),
      getCooldownUntilMs: () => Promise.resolve(0),
      setCooldown: () => Promise.resolve(true),
      clearCooldown: () => Promise.resolve(undefined),
      appendBlocked: () => Promise.resolve(undefined),
      listBlocked: () => Promise.resolve([]),
    };
    const limiter = createDurablePasswordlessLimiter({ store });
    const denied = await limiter.checkRequest(attempt({ email: EMAIL }));
    expect(denied.ok).toBe(false);
    if (!denied.ok) {
      expect(denied.code).toBe("rate_limited");
    }
  });
});

describe("Cloudflare Turnstile verifier", () => {
  it("accepts siteverify success and rejects failures without echoing the secret", async () => {
    const seen: string[] = [];
    const verify = createCloudflareTurnstileVerifier({
      secretKey: "turnstile-secret",
      fetchImpl: (url, init) => {
        const body = init?.body;
        const encoded =
          typeof body === "string" ? body : body instanceof URLSearchParams ? body.toString() : "";
        seen.push(`${url} ${encoded}`);
        return Promise.resolve(new Response(JSON.stringify({ success: true }), { status: 200 }));
      },
    });
    await expect(verify("token-1", IP)).resolves.toBe(true);

    const reject = createCloudflareTurnstileVerifier({
      secretKey: "turnstile-secret",
      fetchImpl: () =>
        Promise.resolve(new Response(JSON.stringify({ success: false }), { status: 200 })),
    });
    await expect(reject("token-2", IP)).resolves.toBe(false);
    expect(seen.join("\n")).toContain("siteverify");
    expect(seen.join("\n")).toContain("remoteip");
  });

  it("fails closed when siteverify is unavailable", async () => {
    const verify = createCloudflareTurnstileVerifier({
      secretKey: "turnstile-secret",
      fetchImpl: () => Promise.reject(new Error("network")),
    });
    await expect(verify("token", IP)).resolves.toBe(false);
  });
});
