import { normalizeEmail } from "./service";

export type PasswordlessAction = "email_otp_request" | "email_otp_verify";

export type BucketLimit = {
  max: number;
  challengeAfter: number;
};

export type PasswordlessLimits = {
  requestCooldownSeconds: number;
  requestWindowSeconds: number;
  verifyWindowSeconds: number;
  requestEmail: BucketLimit;
  requestIp: BucketLimit;
  requestDevice: BucketLimit;
  verifyEmail: BucketLimit;
  verifyIp: BucketLimit;
  verifyDevice: BucketLimit;
};

export const DEFAULT_PASSWORDLESS_LIMITS: PasswordlessLimits = {
  requestCooldownSeconds: 60,
  requestWindowSeconds: 15 * 60,
  verifyWindowSeconds: 15 * 60,
  requestEmail: { max: 5, challengeAfter: 3 },
  requestIp: { max: 20, challengeAfter: 10 },
  requestDevice: { max: 10, challengeAfter: 5 },
  verifyEmail: { max: 5, challengeAfter: 3 },
  verifyIp: { max: 30, challengeAfter: 10 },
  verifyDevice: { max: 10, challengeAfter: 5 },
};

export type PasswordlessAttempt = {
  email: string;
  ip: string;
  deviceId?: string;
  turnstileToken?: string;
  requestId?: string;
};

export type PasswordlessDecision =
  | { ok: true }
  | { ok: false; code: "rate_limited"; retryAfterSeconds: number }
  | { ok: false; code: "challenge_required" };

export type BlockedAttempt = {
  id: string;
  action: PasswordlessAction;
  reason: "rate_limited" | "challenge_required";
  emailHash: string;
  ipHash: string;
  deviceId: string | null;
  at: string;
  requestId?: string;
};

export type PasswordlessSecurityEvent = {
  type:
    | "passwordless_rate_limited"
    | "passwordless_challenge_required"
    | "passwordless_repeated_failure";
  action: PasswordlessAction;
  reason: "rate_limited" | "challenge_required" | "repeated_failure";
  emailHash: string;
  ipHash: string;
  deviceId: string | null;
  at: string;
  requestId?: string;
  retryAfterSeconds?: number;
};

export type TurnstileVerifier = (token: string, ip: string) => Promise<boolean>;

export type TurnstileFetch = (input: string, init?: RequestInit) => Promise<Response>;

export type PasswordlessLimiter = {
  hashEmail(email: string): Promise<string>;
  checkRequest(attempt: PasswordlessAttempt): Promise<PasswordlessDecision>;
  checkVerify(attempt: PasswordlessAttempt): Promise<PasswordlessDecision>;
  recordVerifyFailure(
    attempt: Pick<PasswordlessAttempt, "email" | "ip" | "deviceId" | "requestId">,
  ): Promise<void>;
  recordVerifySuccess(attempt: Pick<PasswordlessAttempt, "email">): Promise<void>;
  listBlockedAttempts(): BlockedAttempt[];
};

export type MemoryPasswordlessLimiterOptions = {
  now?: () => Date;
  verifyTurnstile?: TurnstileVerifier;
  limits?: Partial<PasswordlessLimits>;
  onSecurityEvent?: (event: PasswordlessSecurityEvent) => void;
};

const encoder = new TextEncoder();
const MAX_BLOCKED_ATTEMPTS = 100;
const TURNSTILE_SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export async function hashIdentifier(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return toHex(new Uint8Array(digest));
}

export function createCloudflareTurnstileVerifier(options: {
  secretKey: string;
  fetchImpl?: TurnstileFetch;
}): TurnstileVerifier {
  const fetchImpl = options.fetchImpl ?? fetch;
  return async (token, ip) => {
    if (token.trim() === "") {
      return false;
    }
    try {
      const body = new URLSearchParams();
      body.set("secret", options.secretKey);
      body.set("response", token);
      if (ip !== "unknown") {
        body.set("remoteip", ip);
      }
      const response = await fetchImpl(TURNSTILE_SITEVERIFY, {
        method: "POST",
        body,
      });
      if (!response.ok) {
        return false;
      }
      const payload: unknown = await response.json();
      return isRecord(payload) && payload.success === true;
    } catch {
      return false;
    }
  };
}

export function createMemoryPasswordlessLimiter(
  options: MemoryPasswordlessLimiterOptions = {},
): PasswordlessLimiter {
  const now = options.now ?? (() => new Date());
  const limits = { ...DEFAULT_PASSWORDLESS_LIMITS, ...options.limits };
  const verifyTurnstile = options.verifyTurnstile ?? (() => Promise.resolve(false));
  const onSecurityEvent = options.onSecurityEvent;
  const hits = new Map<string, number[]>();
  const requestCooldowns = new Map<string, number>();
  const blockedAttempts: BlockedAttempt[] = [];

  async function identities(attempt: Pick<PasswordlessAttempt, "email" | "ip" | "deviceId">) {
    const emailHash = await hashIdentifier(normalizeEmail(attempt.email));
    const ipHash = await hashIdentifier(attempt.ip);
    return {
      emailHash,
      ipHash,
      deviceId: attempt.deviceId ?? null,
    };
  }

  function current(key: string, windowMs: number, nowMs: number): number[] {
    const next = (hits.get(key) ?? []).filter((stamp) => nowMs - stamp < windowMs);
    hits.set(key, next);
    return next;
  }

  function increment(key: string, windowMs: number, nowMs: number): number[] {
    const next = current(key, windowMs, nowMs);
    next.push(nowMs);
    hits.set(key, next);
    return next;
  }

  function requestBuckets(ids: {
    emailHash: string;
    ipHash: string;
    deviceId: string | null;
  }): Array<{ key: string; limit: BucketLimit }> {
    const buckets = [
      { key: `req:email:${ids.emailHash}`, limit: limits.requestEmail },
      { key: `req:ip:${ids.ipHash}`, limit: limits.requestIp },
    ];
    if (ids.deviceId !== null) {
      buckets.push({ key: `req:device:${ids.deviceId}`, limit: limits.requestDevice });
    }
    return buckets;
  }

  function verifyBuckets(ids: {
    emailHash: string;
    ipHash: string;
    deviceId: string | null;
  }): Array<{ key: string; limit: BucketLimit }> {
    const buckets = [
      { key: `ver:email:${ids.emailHash}`, limit: limits.verifyEmail },
      { key: `ver:ip:${ids.ipHash}`, limit: limits.verifyIp },
    ];
    if (ids.deviceId !== null) {
      buckets.push({ key: `ver:device:${ids.deviceId}`, limit: limits.verifyDevice });
    }
    return buckets;
  }

  function snapshot(
    buckets: Array<{ key: string; limit: BucketLimit }>,
    windowMs: number,
    nowMs: number,
  ): Array<{ count: number; limit: BucketLimit; timestamps: number[] }> {
    return buckets.map((bucket) => {
      const timestamps = current(bucket.key, windowMs, nowMs);
      return { count: timestamps.length, limit: bucket.limit, timestamps };
    });
  }

  function retryAfter(timestamps: number[], windowMs: number, nowMs: number): number {
    const oldest = timestamps[0];
    if (oldest === undefined) {
      return 1;
    }
    return Math.max(1, Math.ceil((oldest + windowMs - nowMs) / 1000));
  }

  function deny(
    action: PasswordlessAction,
    reason: "rate_limited" | "challenge_required",
    ids: {
      emailHash: string;
      ipHash: string;
      deviceId: string | null;
      requestId?: string;
    },
    retryAfterSeconds?: number,
  ): PasswordlessDecision {
    const at = now().toISOString();
    const blocked: BlockedAttempt = {
      id: crypto.randomUUID(),
      action,
      reason,
      emailHash: ids.emailHash,
      ipHash: ids.ipHash,
      deviceId: ids.deviceId,
      at,
      ...(ids.requestId === undefined ? {} : { requestId: ids.requestId }),
    };
    blockedAttempts.unshift(blocked);
    if (blockedAttempts.length > MAX_BLOCKED_ATTEMPTS) {
      blockedAttempts.length = MAX_BLOCKED_ATTEMPTS;
    }
    onSecurityEvent?.({
      type:
        reason === "rate_limited" ? "passwordless_rate_limited" : "passwordless_challenge_required",
      action,
      reason,
      emailHash: ids.emailHash,
      ipHash: ids.ipHash,
      deviceId: ids.deviceId,
      at,
      ...(ids.requestId === undefined ? {} : { requestId: ids.requestId }),
      ...(retryAfterSeconds === undefined ? {} : { retryAfterSeconds }),
    });
    if (reason === "rate_limited") {
      return { ok: false, code: "rate_limited", retryAfterSeconds: retryAfterSeconds ?? 1 };
    }
    return { ok: false, code: "challenge_required" };
  }

  async function decide(
    action: PasswordlessAction,
    attempt: PasswordlessAttempt,
    recordOnAllow: boolean,
  ): Promise<PasswordlessDecision> {
    const ids = await identities(attempt);
    const buckets = action === "email_otp_request" ? requestBuckets(ids) : verifyBuckets(ids);
    const windowMs =
      (action === "email_otp_request" ? limits.requestWindowSeconds : limits.verifyWindowSeconds) *
      1000;
    const nowMs = now().getTime();
    const tracked = {
      emailHash: ids.emailHash,
      ipHash: ids.ipHash,
      deviceId: ids.deviceId,
      ...(attempt.requestId === undefined ? {} : { requestId: attempt.requestId }),
    };

    if (action === "email_otp_request") {
      const cooldownUntil = requestCooldowns.get(ids.emailHash) ?? 0;
      if (nowMs < cooldownUntil) {
        return deny(
          action,
          "rate_limited",
          tracked,
          Math.max(1, Math.ceil((cooldownUntil - nowMs) / 1000)),
        );
      }
    }

    const counts = snapshot(buckets, windowMs, nowMs);
    const overMax = counts.filter((entry) => entry.count >= entry.limit.max);
    if (overMax.length > 0) {
      const seconds = Math.max(
        ...overMax.map((entry) => retryAfter(entry.timestamps, windowMs, nowMs)),
      );
      return deny(action, "rate_limited", tracked, seconds);
    }

    const needsChallenge = counts.some((entry) => entry.count >= entry.limit.challengeAfter);
    if (needsChallenge) {
      const token = attempt.turnstileToken?.trim() ?? "";
      const accepted = token !== "" && (await verifyTurnstile(token, attempt.ip));
      if (!accepted) {
        return deny(action, "challenge_required", tracked);
      }
    }

    if (recordOnAllow) {
      for (const bucket of buckets) {
        increment(bucket.key, windowMs, nowMs);
      }
      requestCooldowns.set(ids.emailHash, nowMs + limits.requestCooldownSeconds * 1000);
    }
    return { ok: true };
  }

  return {
    hashEmail(email) {
      return hashIdentifier(normalizeEmail(email));
    },

    checkRequest(attempt) {
      return decide("email_otp_request", attempt, true);
    },

    checkVerify(attempt) {
      return decide("email_otp_verify", attempt, false);
    },

    async recordVerifyFailure(attempt) {
      const ids = await identities(attempt);
      const nowMs = now().getTime();
      const windowMs = limits.verifyWindowSeconds * 1000;
      const buckets = verifyBuckets(ids);
      let emailCount = 0;
      for (const bucket of buckets) {
        const next = increment(bucket.key, windowMs, nowMs);
        if (bucket.key === `ver:email:${ids.emailHash}`) {
          emailCount = next.length;
        }
      }
      if (emailCount >= limits.verifyEmail.challengeAfter) {
        onSecurityEvent?.({
          type: "passwordless_repeated_failure",
          action: "email_otp_verify",
          reason: "repeated_failure",
          emailHash: ids.emailHash,
          ipHash: ids.ipHash,
          deviceId: ids.deviceId,
          at: now().toISOString(),
          ...(attempt.requestId === undefined ? {} : { requestId: attempt.requestId }),
        });
      }
    },

    async recordVerifySuccess(attempt) {
      const emailHash = await hashIdentifier(normalizeEmail(attempt.email));
      hits.delete(`ver:email:${emailHash}`);
      // A successful login is a new session, not a resend of the outstanding code.
      requestCooldowns.delete(emailHash);
    },

    listBlockedAttempts() {
      return blockedAttempts.map((item) => ({ ...item }));
    },
  };
}

function toHex(bytes: Uint8Array): string {
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
