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
  listBlockedAttempts(): Promise<BlockedAttempt[]>;
};

/** Shared hit/cooldown/blocked rows. null counts mean the store is down (fail closed). */
export type PasswordlessDurableStore = {
  countHits(key: string, sinceIso: string): Promise<number | null>;
  addHit(key: string, atIso: string): Promise<boolean>;
  clearHits(key: string): Promise<void>;
  getCooldownUntilMs(emailHash: string): Promise<number | null>;
  setCooldown(emailHash: string, untilIso: string): Promise<boolean>;
  clearCooldown(emailHash: string): Promise<void>;
  appendBlocked(attempt: BlockedAttempt): Promise<void>;
  listBlocked(): Promise<BlockedAttempt[]>;
};

export type MemoryPasswordlessLimiterOptions = {
  now?: () => Date;
  verifyTurnstile?: TurnstileVerifier;
  limits?: Partial<PasswordlessLimits>;
  onSecurityEvent?: (event: PasswordlessSecurityEvent) => void;
  hmacSecret?: string;
  enableChallenge?: boolean;
};

const encoder = new TextEncoder();
const MAX_BLOCKED_ATTEMPTS = 100;
const TURNSTILE_SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export const LOCAL_PASSWORDLESS_HMAC_SECRET = "local-dev-only-passwordless-hmac";

export async function hashIdentifier(
  value: string,
  secret: string = LOCAL_PASSWORDLESS_HMAC_SECRET,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return toHex(new Uint8Array(signature));
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
  const hmacSecret = options.hmacSecret ?? LOCAL_PASSWORDLESS_HMAC_SECRET;
  const enableChallenge = options.enableChallenge ?? true;
  // Isolate-local Maps plus a mutex so concurrent awaits on this isolate cannot skip a slot.
  // Other Worker isolates do not share these buckets.
  const hits = new Map<string, number[]>();
  const requestCooldowns = new Map<string, number>();
  const blockedAttempts: BlockedAttempt[] = [];
  const withLock = createLock();

  async function identities(attempt: Pick<PasswordlessAttempt, "email" | "ip" | "deviceId">) {
    const emailHash = await hashIdentifier(normalizeEmail(attempt.email), hmacSecret);
    const ipHash = await hashIdentifier(attempt.ip, hmacSecret);
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
  ): Promise<PasswordlessDecision> {
    const ids = await identities(attempt);
    return withLock(async () => {
      const buckets = action === "email_otp_request" ? requestBuckets(ids) : verifyBuckets(ids);
      const windowMs =
        (action === "email_otp_request"
          ? limits.requestWindowSeconds
          : limits.verifyWindowSeconds) * 1000;
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

      if (enableChallenge) {
        const needsChallenge = counts.some((entry) => entry.count >= entry.limit.challengeAfter);
        if (needsChallenge) {
          const token = attempt.turnstileToken?.trim() ?? "";
          const accepted = token !== "" && (await verifyTurnstile(token, attempt.ip));
          if (!accepted) {
            return deny(action, "challenge_required", tracked);
          }
        }
      }

      for (const bucket of buckets) {
        increment(bucket.key, windowMs, nowMs);
      }
      if (action === "email_otp_request") {
        requestCooldowns.set(ids.emailHash, nowMs + limits.requestCooldownSeconds * 1000);
      }
      return { ok: true as const };
    });
  }

  return {
    hashEmail(email) {
      return hashIdentifier(normalizeEmail(email), hmacSecret);
    },

    checkRequest(attempt) {
      return decide("email_otp_request", attempt);
    },

    checkVerify(attempt) {
      return decide("email_otp_verify", attempt);
    },

    async recordVerifyFailure(attempt) {
      const ids = await identities(attempt);
      const nowMs = now().getTime();
      const windowMs = limits.verifyWindowSeconds * 1000;
      const emailCount = current(`ver:email:${ids.emailHash}`, windowMs, nowMs).length;
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
      const emailHash = await hashIdentifier(normalizeEmail(attempt.email), hmacSecret);
      hits.delete(`ver:email:${emailHash}`);
      // A successful login is a new session, not a resend of the outstanding code.
      requestCooldowns.delete(emailHash);
    },

    listBlockedAttempts() {
      return Promise.resolve(blockedAttempts.map((item) => ({ ...item })));
    },
  };
}

/**
 * Postgres-backed limiter. Isolate-local Maps cannot protect production OTP.
 * Store errors fail closed (rate_limited).
 */
export function createDurablePasswordlessLimiter(
  options: MemoryPasswordlessLimiterOptions & { store: PasswordlessDurableStore },
): PasswordlessLimiter {
  const memory = createMemoryPasswordlessLimiter(options);
  const store = options.store;
  const now = options.now ?? (() => new Date());
  const limits = { ...DEFAULT_PASSWORDLESS_LIMITS, ...options.limits };
  const verifyTurnstile = options.verifyTurnstile ?? (() => Promise.resolve(false));
  const onSecurityEvent = options.onSecurityEvent;
  const hmacSecret = options.hmacSecret ?? LOCAL_PASSWORDLESS_HMAC_SECRET;
  const enableChallenge = options.enableChallenge ?? true;

  async function identities(attempt: Pick<PasswordlessAttempt, "email" | "ip" | "deviceId">) {
    const emailHash = await hashIdentifier(normalizeEmail(attempt.email), hmacSecret);
    const ipHash = await hashIdentifier(attempt.ip, hmacSecret);
    return {
      emailHash,
      ipHash,
      deviceId: attempt.deviceId ?? null,
    };
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

  async function deny(
    action: PasswordlessAction,
    reason: "rate_limited" | "challenge_required",
    ids: {
      emailHash: string;
      ipHash: string;
      deviceId: string | null;
      requestId?: string;
    },
    retryAfterSeconds?: number,
  ): Promise<PasswordlessDecision> {
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
    await store.appendBlocked(blocked);
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
      return { ok: false, code: "rate_limited", retryAfterSeconds: retryAfterSeconds ?? 30 };
    }
    return { ok: false, code: "challenge_required" };
  }

  async function decide(
    action: PasswordlessAction,
    attempt: PasswordlessAttempt,
  ): Promise<PasswordlessDecision> {
    const ids = await identities(attempt);
    const buckets = action === "email_otp_request" ? requestBuckets(ids) : verifyBuckets(ids);
    const windowSeconds =
      action === "email_otp_request" ? limits.requestWindowSeconds : limits.verifyWindowSeconds;
    const nowMs = now().getTime();
    const sinceIso = new Date(nowMs - windowSeconds * 1000).toISOString();
    const tracked = {
      emailHash: ids.emailHash,
      ipHash: ids.ipHash,
      deviceId: ids.deviceId,
      ...(attempt.requestId === undefined ? {} : { requestId: attempt.requestId }),
    };

    if (action === "email_otp_request") {
      const cooldownUntil = await store.getCooldownUntilMs(ids.emailHash);
      if (cooldownUntil === null) {
        return deny(action, "rate_limited", tracked, 30);
      }
      if (nowMs < cooldownUntil) {
        return deny(
          action,
          "rate_limited",
          tracked,
          Math.max(1, Math.ceil((cooldownUntil - nowMs) / 1000)),
        );
      }
    }

    const counts: number[] = [];
    for (const bucket of buckets) {
      const count = await store.countHits(bucket.key, sinceIso);
      if (count === null) {
        return deny(action, "rate_limited", tracked, 30);
      }
      counts.push(count);
    }
    const overMax = buckets.filter((bucket, index) => (counts[index] ?? 0) >= bucket.limit.max);
    if (overMax.length > 0) {
      return deny(action, "rate_limited", tracked, windowSeconds);
    }
    if (enableChallenge) {
      const needsChallenge = buckets.some(
        (bucket, index) => (counts[index] ?? 0) >= bucket.limit.challengeAfter,
      );
      if (needsChallenge) {
        const token = attempt.turnstileToken?.trim() ?? "";
        const accepted = token !== "" && (await verifyTurnstile(token, attempt.ip));
        if (!accepted) {
          return deny(action, "challenge_required", tracked);
        }
      }
    }
    const atIso = now().toISOString();
    for (const bucket of buckets) {
      const wrote = await store.addHit(bucket.key, atIso);
      if (!wrote) {
        return deny(action, "rate_limited", tracked, 30);
      }
    }
    if (action === "email_otp_request") {
      const until = new Date(nowMs + limits.requestCooldownSeconds * 1000).toISOString();
      const cooled = await store.setCooldown(ids.emailHash, until);
      if (!cooled) {
        return deny(action, "rate_limited", tracked, 30);
      }
    }
    return { ok: true as const };
  }

  return {
    hashEmail(email) {
      return hashIdentifier(normalizeEmail(email), hmacSecret);
    },
    checkRequest(attempt) {
      return decide("email_otp_request", attempt);
    },
    checkVerify(attempt) {
      return decide("email_otp_verify", attempt);
    },
    async recordVerifyFailure(attempt) {
      await memory.recordVerifyFailure(attempt);
    },
    async recordVerifySuccess(attempt) {
      const emailHash = await hashIdentifier(normalizeEmail(attempt.email), hmacSecret);
      await store.clearHits(`ver:email:${emailHash}`);
      await store.clearCooldown(emailHash);
    },
    listBlockedAttempts() {
      return store.listBlocked();
    },
  };
}

function createLock(): <T>(task: () => Promise<T>) => Promise<T> {
  let chain: Promise<void> = Promise.resolve();
  return async (task) => {
    const previous = chain;
    let release = (): void => undefined;
    chain = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await task();
    } finally {
      release();
    }
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
