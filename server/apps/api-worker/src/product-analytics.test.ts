import type { OpsProductEvent } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { buildProductAnalytics } from "./product-analytics";

function event(
  id: string,
  at: string,
  properties: Record<string, unknown>,
  outcome: OpsProductEvent["outcome"] = "ok",
  accountId = `account-${id}`,
): OpsProductEvent {
  return {
    id,
    accountId,
    deviceId: `device-${id}`,
    name: "reading.session.completed",
    outcome,
    requestId: `request-${id}`,
    properties,
    createdAt: at,
  };
}

describe("product analytics", () => {
  it("builds time series and privacy-bucketed distributions", () => {
    const events = [
      event("1", "2026-08-29T09:00:00.000Z", {
        country: "AU",
        region: "AU-VIC",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        readerLevel: "intermediate",
        platform: "macos",
        appVersion: "1.3.0",
        contentId: "book-1",
        contentCategory: "fiction",
        feature: "reader",
      }),
      event("2", "2026-08-29T10:00:00.000Z", {
        country: "AU",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        readerLevel: "intermediate",
        platform: "ipados",
        contentId: "book-1",
        contentCategory: "fiction",
        feature: "review",
      }),
      event("3", "2026-08-30T10:00:00.000Z", {
        country: "NZ",
        sourceLanguage: "en",
        targetLanguage: "ja",
        readerLevel: "beginner",
        platform: "macos",
        contentId: "book-2",
        contentCategory: "nonfiction",
        feature: "sync",
      }),
    ];

    const analytics = buildProductAnalytics(events, {
      from: "2026-08-29T00:00:00.000Z",
      to: "2026-08-31T00:00:00.000Z",
      interval: "day",
      filters: {},
    });

    expect(analytics.summary).toMatchObject({ events: 3, activeUsers: 3, activeDevices: 3 });
    expect(analytics.series.map((point) => point.events)).toEqual([2, 1]);
    expect(analytics.distributions.country).toEqual([{ key: "Other", count: 3, share: 1 }]);
    expect(analytics.distributions.platform).toEqual([
      { key: "macos", count: 2, share: 2 / 3 },
      { key: "ipados", count: 1, share: 1 / 3 },
    ]);
    expect(analytics.privacy).toMatchObject({
      minimumBucketSize: 3,
      preciseLocationCollected: false,
      rawContentReturned: false,
      identifiersReturned: "pseudonymous",
      durableOwnershipKeysStored: true,
      profileDeletionCascadesEvents: true,
      completedDeletionRequestPurgesEvents: false,
      automaticRetentionDays: null,
    });
  });

  it("applies dimension filters before aggregation", () => {
    const events = [
      event("1", "2026-08-30T09:00:00.000Z", { country: "AU", platform: "macos" }),
      event("2", "2026-08-30T10:00:00.000Z", { country: "NZ", platform: "ipados" }),
    ];
    const analytics = buildProductAnalytics(events, {
      from: "2026-08-30T00:00:00.000Z",
      to: "2026-08-31T00:00:00.000Z",
      interval: "hour",
      filters: { platform: "macos" },
    });
    expect(analytics.summary.events).toBe(1);
    expect(analytics.filters.platform).toBe("macos");
  });

  it("excludes missing devices from platform shares and counts only ok terminal outcomes as successful", () => {
    const events: OpsProductEvent[] = [
      event("1", "2026-08-30T09:00:00.000Z", { platform: "macos" }, "ok", "account-a"),
      event("2", "2026-08-30T09:10:00.000Z", { platform: "macos" }, "started", "account-a"),
      {
        ...event("3", "2026-08-30T09:20:00.000Z", { platform: "ipados" }, "cancelled", "account-b"),
        deviceId: null,
      },
      {
        ...event("4", "2026-08-30T09:30:00.000Z", { platform: "ipados" }, "failed", "account-c"),
        deviceId: null,
      },
    ];
    const analytics = buildProductAnalytics(events, {
      from: "2026-08-30T00:00:00.000Z",
      to: "2026-08-31T00:00:00.000Z",
      interval: "day",
      filters: {},
    });
    expect(analytics.summary).toMatchObject({
      events: 4,
      activeDevices: 2,
      failed: 1,
      cancelled: 1,
      started: 1,
      successRate: 1 / 3,
    });
    expect(analytics.distributions.platform).toEqual([{ key: "macos", count: 2, share: 1 }]);
    expect(analytics.distributions.platform.every((item) => item.share <= 1)).toBe(true);
  });

  it("flags an unusual failure rate without exposing event payloads", () => {
    const events = Array.from({ length: 12 }, (_, index) =>
      event(
        String(index),
        `2026-08-30T${String(10 + Math.floor(index / 6)).padStart(2, "0")}:${String(index % 6).padStart(2, "0")}:00.000Z`,
        { feature: "sync", contentId: `book-${String(index)}` },
        index < 8 ? "failed" : "ok",
        "same-account",
      ),
    );
    const analytics = buildProductAnalytics(events, {
      from: "2026-08-30T10:00:00.000Z",
      to: "2026-08-30T12:00:00.000Z",
      interval: "hour",
      filters: {},
    });
    expect(analytics.anomalies.some((item) => item.kind === "failure_rate")).toBe(true);
    expect(JSON.stringify(analytics)).not.toContain("book-0");
  });
});
