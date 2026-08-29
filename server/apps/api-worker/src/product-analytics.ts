import type { OpsProductEvent } from "@audio-reader/database";

export type AnalyticsInterval = "hour" | "day" | "week";

export type AnalyticsFilters = Partial<{
  country: string;
  language: string;
  readerLevel: string;
  platform: string;
  contentCategory: string;
  feature: string;
  outcome: OpsProductEvent["outcome"];
}>;

export type AnalyticsPoint = {
  start: string;
  events: number;
  activeUsers: number;
  failed: number;
};

export type AnalyticsDistributionItem = {
  key: string;
  count: number;
  share: number;
};

export type ProductAnalytics = {
  from: string;
  to: string;
  interval: AnalyticsInterval;
  filters: AnalyticsFilters;
  summary: {
    events: number;
    activeUsers: number;
    activeDevices: number;
    failed: number;
    cancelled: number;
    started: number;
    successRate: number;
  };
  series: AnalyticsPoint[];
  distributions: {
    country: AnalyticsDistributionItem[];
    region: AnalyticsDistributionItem[];
    sourceLanguage: AnalyticsDistributionItem[];
    targetLanguage: AnalyticsDistributionItem[];
    readerLevel: AnalyticsDistributionItem[];
    platform: AnalyticsDistributionItem[];
    appVersion: AnalyticsDistributionItem[];
    content: AnalyticsDistributionItem[];
    contentCategory: AnalyticsDistributionItem[];
    feature: AnalyticsDistributionItem[];
    outcome: AnalyticsDistributionItem[];
  };
  anomalies: Array<{
    kind: "failure_rate" | "volume_spike";
    severity: "warning" | "critical";
    observed: number;
    baseline: number;
    message: string;
  }>;
  privacy: {
    minimumBucketSize: number;
    preciseLocationCollected: false;
    rawContentReturned: false;
    identifiersReturned: "pseudonymous";
    durableOwnershipKeysStored: true;
    profileDeletionCascadesEvents: true;
    completedDeletionRequestPurgesEvents: false;
    automaticRetentionDays: null;
  };
  sampled: boolean;
};

const MINIMUM_PRIVATE_BUCKET = 3;
const MAX_SOURCE_EVENTS = 5000;

type Dimensions = {
  country: string;
  region: string;
  sourceLanguage: string;
  targetLanguage: string;
  readerLevel: string;
  platform: string;
  appVersion: string;
  content: string;
  contentCategory: string;
  feature: string;
  outcome: string;
};

/** Aggregate only normalized dimensions. Event payloads and raw content identifiers never leave this boundary. */
export function buildProductAnalytics(
  source: OpsProductEvent[],
  input: {
    from: string;
    to: string;
    interval: AnalyticsInterval;
    filters: AnalyticsFilters;
  },
): ProductAnalytics {
  const fromMs = Date.parse(input.from);
  const toMs = Date.parse(input.to);
  const selected = source.filter((event) => {
    const at = Date.parse(event.createdAt);
    if (!Number.isFinite(at) || at < fromMs || at >= toMs) return false;
    return matchesFilters(dimensions(event), input.filters);
  });
  const userIds = new Set(selected.map((event) => event.accountId));
  const deviceIds = new Set(
    selected.flatMap((event) => (event.deviceId === null ? [] : [event.deviceId])),
  );
  const failed = selected.filter((event) => event.outcome === "failed").length;
  const cancelled = selected.filter((event) => event.outcome === "cancelled").length;
  const started = selected.filter((event) => event.outcome === "started").length;
  const ok = selected.filter((event) => event.outcome === "ok").length;
  const terminal = ok + failed + cancelled;
  const series = buildSeries(selected, fromMs, toMs, input.interval);
  const entries = selected.map((event) => ({ event, dimensions: dimensions(event) }));
  const learnerDistribution = (key: keyof Dimensions) =>
    uniqueDistribution(entries, key, (event) => event.accountId, userIds.size, true);
  const deviceDistribution = (key: keyof Dimensions) =>
    uniqueDistribution(entries, key, (event) => event.deviceId, deviceIds.size, false);
  const eventDistribution = (key: keyof Dimensions) =>
    distribution(
      entries.map((item) => item.dimensions[key]),
      selected.length,
      false,
    );

  return {
    from: new Date(fromMs).toISOString(),
    to: new Date(toMs).toISOString(),
    interval: input.interval,
    filters: { ...input.filters },
    summary: {
      events: selected.length,
      activeUsers: userIds.size,
      activeDevices: deviceIds.size,
      failed,
      cancelled,
      started,
      successRate: terminal === 0 ? 0 : ok / terminal,
    },
    series,
    distributions: {
      country: learnerDistribution("country"),
      region: learnerDistribution("region"),
      sourceLanguage: learnerDistribution("sourceLanguage"),
      targetLanguage: learnerDistribution("targetLanguage"),
      readerLevel: learnerDistribution("readerLevel"),
      platform: deviceDistribution("platform"),
      appVersion: deviceDistribution("appVersion"),
      content: learnerDistribution("content"),
      contentCategory: learnerDistribution("contentCategory"),
      feature: eventDistribution("feature"),
      outcome: eventDistribution("outcome"),
    },
    anomalies: anomalies(terminal, failed, series),
    privacy: {
      minimumBucketSize: MINIMUM_PRIVATE_BUCKET,
      preciseLocationCollected: false,
      rawContentReturned: false,
      identifiersReturned: "pseudonymous",
      durableOwnershipKeysStored: true,
      profileDeletionCascadesEvents: true,
      completedDeletionRequestPurgesEvents: false,
      automaticRetentionDays: null,
    },
    sampled: source.length >= MAX_SOURCE_EVENTS,
  };
}

function dimensions(event: OpsProductEvent): Dimensions {
  const string = (key: string): string => {
    const value = event.properties[key];
    return typeof value === "string" && value.trim() !== "" ? value.trim() : "Unknown";
  };
  const sourceLanguage = string("sourceLanguage");
  const targetLanguage = string("targetLanguage");
  const opaqueContentId = string("contentId");
  const contentId = opaqueContentId === "Unknown" ? string("chapterId") : opaqueContentId;
  return {
    country: string("country"),
    region: string("region"),
    sourceLanguage,
    targetLanguage,
    readerLevel: string("readerLevel"),
    platform: string("platform"),
    appVersion: string("appVersion"),
    content: contentId === "Unknown" ? contentId : `content-${stableHash(contentId)}`,
    contentCategory: string("contentCategory"),
    feature:
      string("feature") === "Unknown" ? (event.name.split(".")[0] ?? "Unknown") : string("feature"),
    outcome: event.outcome,
  };
}

function matchesFilters(item: Dimensions, filters: AnalyticsFilters): boolean {
  return (
    match(item.country, filters.country) &&
    matchLanguage(item, filters.language) &&
    match(item.readerLevel, filters.readerLevel) &&
    match(item.platform, filters.platform) &&
    match(item.contentCategory, filters.contentCategory) &&
    match(item.feature, filters.feature) &&
    match(item.outcome, filters.outcome)
  );
}

function match(actual: string, expected: string | undefined): boolean {
  return (
    expected === undefined || expected === "" || actual.toLowerCase() === expected.toLowerCase()
  );
}

function matchLanguage(item: Dimensions, expected: string | undefined): boolean {
  return match(item.sourceLanguage, expected) || match(item.targetLanguage, expected);
}

function distribution(
  values: string[],
  total: number,
  suppressSmall: boolean,
): AnalyticsDistributionItem[] {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  if (suppressSmall) {
    let other = 0;
    for (const [key, count] of counts) {
      if (key !== "Unknown" && count < MINIMUM_PRIVATE_BUCKET) {
        counts.delete(key);
        other += count;
      }
    }
    if (other > 0) counts.set("Other", (counts.get("Other") ?? 0) + other);
  }
  return [...counts.entries()]
    .sort(([leftKey, left], [rightKey, right]) => right - left || leftKey.localeCompare(rightKey))
    .map(([key, count]) => ({ key, count, share: total === 0 ? 0 : count / total }));
}

function uniqueDistribution(
  entries: Array<{ event: OpsProductEvent; dimensions: Dimensions }>,
  key: keyof Dimensions,
  subject: (event: OpsProductEvent) => string | null,
  total: number,
  suppressSmall: boolean,
): AnalyticsDistributionItem[] {
  const subjectsByValue = new Map<string, Set<string>>();
  for (const entry of entries) {
    const subjectId = subject(entry.event);
    if (subjectId === null) continue;
    const value = entry.dimensions[key];
    const subjects = subjectsByValue.get(value) ?? new Set<string>();
    subjects.add(subjectId);
    subjectsByValue.set(value, subjects);
  }
  if (suppressSmall) {
    // Merge subject identities, not bucket counts: one learner may touch several suppressed books.
    const otherSubjects = new Set(subjectsByValue.get("Other") ?? []);
    for (const [value, subjects] of subjectsByValue) {
      if (value !== "Unknown" && value !== "Other" && subjects.size < MINIMUM_PRIVATE_BUCKET) {
        subjectsByValue.delete(value);
        for (const subjectId of subjects) otherSubjects.add(subjectId);
      }
    }
    if (otherSubjects.size > 0) subjectsByValue.set("Other", otherSubjects);
  }
  return [...subjectsByValue.entries()]
    .sort(
      ([leftKey, left], [rightKey, right]) =>
        right.size - left.size || leftKey.localeCompare(rightKey),
    )
    .map(([key, subjects]) => ({
      key,
      count: subjects.size,
      share: total === 0 ? 0 : subjects.size / total,
    }));
}

function buildSeries(
  events: OpsProductEvent[],
  fromMs: number,
  toMs: number,
  interval: AnalyticsInterval,
): AnalyticsPoint[] {
  const duration = interval === "hour" ? 3_600_000 : interval === "day" ? 86_400_000 : 604_800_000;
  const buckets = new Map<number, OpsProductEvent[]>();
  for (const event of events) {
    const at = Date.parse(event.createdAt);
    const start = fromMs + Math.floor((at - fromMs) / duration) * duration;
    const bucket = buckets.get(start) ?? [];
    bucket.push(event);
    buckets.set(start, bucket);
  }
  const points: AnalyticsPoint[] = [];
  for (let start = fromMs; start < toMs; start += duration) {
    const bucket = buckets.get(start) ?? [];
    points.push({
      start: new Date(start).toISOString(),
      events: bucket.length,
      activeUsers: new Set(bucket.map((event) => event.accountId)).size,
      failed: bucket.filter((event) => event.outcome === "failed").length,
    });
  }
  return points;
}

function anomalies(
  total: number,
  failed: number,
  series: AnalyticsPoint[],
): ProductAnalytics["anomalies"] {
  const result: ProductAnalytics["anomalies"] = [];
  const failureRate = total === 0 ? 0 : failed / total;
  if (total >= 10 && failureRate >= 0.25) {
    result.push({
      kind: "failure_rate",
      severity: failureRate >= 0.5 ? "critical" : "warning",
      observed: failureRate,
      baseline: 0.1,
      message: `${String(Math.round(failureRate * 100))}% of events failed in this window.`,
    });
  }
  if (series.length >= 3) {
    const previous = series.slice(0, -1);
    const baseline = previous.reduce((sum, point) => sum + point.events, 0) / previous.length;
    const latest = series.at(-1)?.events ?? 0;
    if (latest >= 10 && latest >= Math.max(2 * baseline, baseline + 5)) {
      result.push({
        kind: "volume_spike",
        severity: latest >= 3 * Math.max(1, baseline) ? "critical" : "warning",
        observed: latest,
        baseline,
        message: `Latest event volume is ${String(latest)}; the earlier-bucket average is ${baseline.toFixed(1)}.`,
      });
    }
  }
  return result;
}

function stableHash(value: string): string {
  let hash = 2_166_136_261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
