import type { BlockedAttempt, PasswordlessDurableStore } from "@audio-reader/auth";
import type { RestClient } from "@audio-reader/database";

/** Maps limiter buckets onto Postgres so every Worker isolate shares OTP limits. */
export function createPostgresPasswordlessStore(rest: RestClient): PasswordlessDurableStore {
  return {
    async countHits(key, sinceIso) {
      const response = await rest.request({
        method: "GET",
        path: "/passwordless_hits",
        query: {
          select: "hit_at",
          bucket_key: `eq.${key}`,
          hit_at: `gte.${sinceIso}`,
        },
      });
      if (response.status < 200 || response.status >= 300 || !Array.isArray(response.body)) {
        return null;
      }
      return response.body.length;
    },
    async addHit(key, atIso) {
      const response = await rest.request({
        method: "POST",
        path: "/passwordless_hits",
        prefer: "return=minimal",
        body: { bucket_key: key, hit_at: atIso },
      });
      return response.status >= 200 && response.status < 300;
    },
    async clearHits(key) {
      await rest.request({
        method: "DELETE",
        path: "/passwordless_hits",
        query: { bucket_key: `eq.${key}` },
      });
    },
    async getCooldownUntilMs(emailHash) {
      const response = await rest.request({
        method: "GET",
        path: "/passwordless_cooldowns",
        query: { select: "until_at", email_hash: `eq.${emailHash}`, limit: "1" },
      });
      if (response.status < 200 || response.status >= 300) {
        return null;
      }
      const row = Array.isArray(response.body) ? response.body[0] : response.body;
      if (typeof row !== "object" || row === null || !("until_at" in row)) {
        return 0;
      }
      const until = (row as { until_at?: unknown }).until_at;
      if (typeof until !== "string") {
        return 0;
      }
      const ms = Date.parse(until);
      return Number.isFinite(ms) ? ms : 0;
    },
    async setCooldown(emailHash, untilIso) {
      const response = await rest.request({
        method: "POST",
        path: "/passwordless_cooldowns",
        query: { on_conflict: "email_hash" },
        prefer: "resolution=merge-duplicates,return=minimal",
        body: { email_hash: emailHash, until_at: untilIso },
      });
      return response.status >= 200 && response.status < 300;
    },
    async clearCooldown(emailHash) {
      await rest.request({
        method: "DELETE",
        path: "/passwordless_cooldowns",
        query: { email_hash: `eq.${emailHash}` },
      });
    },
    async appendBlocked(attempt) {
      await rest.request({
        method: "POST",
        path: "/passwordless_blocked_attempts",
        prefer: "return=minimal",
        body: {
          id: attempt.id,
          action: attempt.action,
          reason: attempt.reason,
          email_hash: attempt.emailHash,
          ip_hash: attempt.ipHash,
          device_id: attempt.deviceId,
          request_id: attempt.requestId ?? null,
          created_at: attempt.at,
        },
      });
    },
    async listBlocked() {
      const response = await rest.request({
        method: "GET",
        path: "/passwordless_blocked_attempts",
        query: { select: "*", order: "created_at.desc", limit: "100" },
      });
      if (response.status < 200 || response.status >= 300 || !Array.isArray(response.body)) {
        return [];
      }
      return response.body.flatMap((row) => {
        const mapped = mapBlocked(row);
        return mapped === undefined ? [] : [mapped];
      });
    },
  };
}

function mapBlocked(row: unknown): BlockedAttempt | undefined {
  if (typeof row !== "object" || row === null) {
    return undefined;
  }
  const record = row as Record<string, unknown>;
  if (
    typeof record.id !== "string" ||
    (record.action !== "email_otp_request" && record.action !== "email_otp_verify") ||
    (record.reason !== "rate_limited" && record.reason !== "challenge_required") ||
    typeof record.email_hash !== "string" ||
    typeof record.ip_hash !== "string"
  ) {
    return undefined;
  }
  return {
    id: record.id,
    action: record.action,
    reason: record.reason,
    emailHash: record.email_hash,
    ipHash: record.ip_hash,
    deviceId: typeof record.device_id === "string" ? record.device_id : null,
    at: typeof record.created_at === "string" ? record.created_at : new Date().toISOString(),
    ...(typeof record.request_id === "string" ? { requestId: record.request_id } : {}),
  };
}
