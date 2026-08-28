export const FEATURE_FLAG_KEYS = [
  "managed_qwen",
  "account_sync",
  "cloud_media",
  "maintenance_mode",
] as const;

export type FeatureFlagKey = (typeof FEATURE_FLAG_KEYS)[number];

export const QUOTA_KEYS = [
  "qwen_tasks_day",
  "cloud_media_bytes",
  "cloud_books",
  "devices",
] as const;

export type QuotaKey = (typeof QUOTA_KEYS)[number];

export type ProductFeatureFlag = {
  key: string;
  enabled: boolean;
  variant: string | null;
  rolloutPercent: number;
  minAppVersion: string | null;
  platforms: string[];
};

export type ProductQuotaLimit = {
  key: QuotaKey;
  limit: number;
};

/** Plan 18.2 starter quotas and kill switches. */
export const DEFAULT_FEATURE_FLAGS: readonly ProductFeatureFlag[] = [
  {
    key: "managed_qwen",
    enabled: true,
    variant: null,
    rolloutPercent: 100,
    minAppVersion: null,
    platforms: [],
  },
  {
    key: "account_sync",
    enabled: true,
    variant: null,
    rolloutPercent: 100,
    minAppVersion: null,
    platforms: [],
  },
  {
    key: "cloud_media",
    enabled: true,
    variant: null,
    rolloutPercent: 100,
    minAppVersion: null,
    platforms: [],
  },
  {
    key: "maintenance_mode",
    enabled: false,
    variant: null,
    rolloutPercent: 100,
    minAppVersion: null,
    platforms: [],
  },
];

export const DEFAULT_QUOTA_LIMITS: readonly ProductQuotaLimit[] = [
  { key: "qwen_tasks_day", limit: 50 },
  { key: "cloud_media_bytes", limit: 250 * 1024 * 1024 },
  { key: "cloud_books", limit: 3 },
  { key: "devices", limit: 2 },
];

export function utcDay(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

export function endOfUtcDay(now = new Date()): string {
  return `${utcDay(now)}T23:59:59.000Z`;
}

export function isQuotaKey(value: string): value is QuotaKey {
  return (QUOTA_KEYS as readonly string[]).includes(value);
}
