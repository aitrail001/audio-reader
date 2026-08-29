export type HealthPayload = {
  status?: string;
  version?: string;
  time?: string;
  dependencies?: Record<string, string>;
};

export type AdminUserDevice = {
  id: string;
  platform: string;
  name?: string | null;
  appVersion?: string;
  lastSeenAt: string;
  revoked: boolean;
};

export type AdminUserBook = {
  id: string;
  title: string;
  chapterCount?: number;
};

export type AdminUser = {
  id: string;
  accountId: string;
  email: string;
  displayName?: string | null;
  status: string;
  deviceCount: number;
  bookCount: number;
  storageBytes: number;
  createdAt: string;
  lastSeenAt?: string | null;
  quotas?: Quota[];
  devices?: AdminUserDevice[];
  books?: AdminUserBook[];
};

export type Job = {
  id: string;
  accountId?: string | null;
  kind: string;
  status: string;
  attempts?: number;
  maxAttempts?: number;
  lastError?: string | null;
  createdAt: string;
  updatedAt: string;
  startedAt?: string | null;
  finishedAt?: string | null;
};

export type Policy = {
  id: string;
  task: string;
  region: string;
  model: string;
  promptVersion: string;
  systemPrompt?: string;
  userPrompt?: string;
  schemaVersion?: string;
  policyVersion?: string;
  enabled: boolean;
  canaryPercent?: number;
  maxInputTokens?: number;
  maxOutputTokens?: number;
  timeoutMs?: number;
  createdAt?: string;
  updatedAt?: string;
};

export type CacheEntry = {
  id: string;
  task: string;
  state: string;
  sourceLanguage: string;
  targetLanguage: string;
  editionFingerprint?: string;
  policyVersion?: string;
  hitCount: number;
  acceptCount?: number;
  rejectCount?: number;
  createdAt: string;
  lastHitAt?: string | null;
  cacheKey?: string;
  payload?: Record<string, unknown>;
};

export type AuditEvent = {
  id: string;
  actorId: string;
  action: string;
  resourceType: string;
  resourceId: string;
  reason: string;
  metadata?: Record<string, unknown>;
  traceId?: string;
  createdAt: string;
};

export type MetricsSnapshot = {
  from: string;
  to: string;
  users?: { count?: number; [key: string]: unknown };
  sync?: { jobs?: number; [key: string]: unknown };
  llm?: {
    cacheEntries?: number;
    qwenOk?: number;
    qwenFailed?: number;
    qwenRequests?: number;
    [key: string]: unknown;
  };
  storage?: { bytes?: number; [key: string]: unknown };
  flags?: { enabled?: number; disabled?: number; [key: string]: unknown };
  quotas?: { count?: number; [key: string]: unknown };
  usage?: { events?: number; failed?: number; [key: string]: unknown };
};

export type RuntimeConfig = {
  qwen: {
    apiKeyConfigured: boolean;
    apiKeyLast4?: string;
    baseUrl: string;
    model: string;
    source: string;
    ciphertextPresent?: boolean;
    secretsDecryptable?: boolean;
    wrappingSecretConfigured?: boolean;
    wrappingSecretSource?: string;
  };
  storage: {
    provider: string;
    bucket?: string;
    serviceAccountConfigured: boolean;
    clientEmail?: string;
    source: string;
  };
  turnstile: { configured: boolean; source: string };
  bootstrap: {
    supabaseUrlConfigured: boolean;
    supabaseAnonKeyConfigured: boolean;
    supabaseServiceRoleConfigured: boolean;
    cacheHmacConfigured: boolean;
    operatorConfigKeyConfigured: boolean;
    adminBootstrapEmailConfigured: boolean;
    resendConfigured?: boolean;
    otpFromConfigured?: boolean;
    qwenEnvKeyConfigured?: boolean;
  };
  assistant: {
    sentenceContextCount: number;
  };
  updatedAt?: string;
};

export type QwenCompleteProbe = {
  status: string;
  httpStatus?: number;
  model?: string;
  detail?: string;
};

export type OperatorEvent = {
  id: string;
  at: string;
  kind: string;
  requestId: string;
  task?: string;
  status?: string;
  summary: string;
  detail?: string;
  metadata?: Record<string, unknown>;
};

export type OperatorDiagnostics = {
  requestId: string;
  runtime: RuntimeConfig;
  flags: FeatureFlag[];
  quotas: Quota[];
  policies: Policy[];
  qwenProbe: string;
  notes: string[];
  qwenComplete?: QwenCompleteProbe;
  recentEvents?: OperatorEvent[];
};

export type BlockedAttempt = {
  id: string;
  action: string;
  reason: string;
  emailHash: string;
  ipHash: string;
  deviceId: string | null;
  at: string;
  requestId?: string;
};

export type CursorPage<T> = {
  items: T[];
  nextCursor: string | null;
};

export type AuthConfig = {
  providers?: string[];
  turnstileSiteKey?: string;
};

export type CacheAction = "quarantine" | "activate" | "expire" | "purge" | "regenerate";

export type FeatureFlag = {
  key: string;
  enabled: boolean;
  variant?: string | null;
  rolloutPercent?: number;
  minAppVersion?: string | null;
  platforms?: string[];
};

export type Quota = {
  key: string;
  used: number;
  limit: number;
  periodEndsAt: string;
};

export type PrivacyRequest = {
  id: string;
  accountId: string;
  kind: string;
  status: string;
  format?: string | null;
  assetId?: string | null;
  error?: string | null;
  reason?: string | null;
  createdAt: string;
  completedAt?: string | null;
};

export type Section =
  | "overview"
  | "users"
  | "policies"
  | "jobs"
  | "cache"
  | "access"
  | "metrics"
  | "audit"
  | "flags"
  | "quotas"
  | "privacy"
  | "trace"
  | "usage";

export type PolicyDraft = {
  model: string;
  promptVersion: string;
  schemaVersion: string;
  systemPrompt: string;
  userPrompt: string;
  canaryPercent: string;
  maxInputTokens: string;
  maxOutputTokens: string;
  timeoutMs: string;
};

export type ProductEvent = {
  id: string;
  accountId: string;
  deviceId?: string;
  name: string;
  outcome: string;
  requestId?: string;
  properties?: Record<string, unknown>;
  createdAt: string;
};
