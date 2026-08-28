import { useCallback, useEffect, useRef, useState } from "react";
import {
  API_BASE,
  TOKEN_STORAGE_KEY,
  fetchAuthConfig,
  getJson,
  getJsonOrNull,
  requestOtp,
  sendJson,
  verifyOtp,
} from "./api";
import {
  extractAccessToken,
  formatBytes,
  formatWhen,
  nextCursorOf,
  pageItems,
  pipClass,
  reasonReady,
  statusTone,
} from "./format";
import {
  PREVIEW_AUDIT,
  PREVIEW_BLOCKED,
  PREVIEW_CACHE,
  PREVIEW_DIAGNOSTICS,
  PREVIEW_EVENTS,
  PREVIEW_FLAGS,
  PREVIEW_JOBS,
  PREVIEW_METRICS,
  PREVIEW_POLICIES,
  PREVIEW_PRIVACY,
  PREVIEW_QUOTAS,
  PREVIEW_RUNTIME,
  PREVIEW_USERS,
  isPreviewMode,
} from "./preview-data";
import type {
  AdminUser,
  AuditEvent,
  BlockedAttempt,
  CacheAction,
  CacheEntry,
  FeatureFlag,
  HealthPayload,
  Job,
  MetricsSnapshot,
  OperatorDiagnostics,
  OperatorEvent,
  Policy,
  PolicyDraft,
  PrivacyRequest,
  Quota,
  RuntimeConfig,
  Section,
} from "./types";

const RAIL: ({ type: "label"; label: string } | { type: "item"; id: Section; label: string })[] = [
  { type: "item", id: "overview", label: "Desk" },
  { type: "item", id: "users", label: "Users" },
  { type: "label", label: "Product" },
  { type: "item", id: "flags", label: "Flags" },
  { type: "item", id: "quotas", label: "Quotas" },
  { type: "item", id: "policies", label: "Policies" },
  { type: "label", label: "Operations" },
  { type: "item", id: "jobs", label: "Jobs" },
  { type: "item", id: "cache", label: "Cache" },
  { type: "item", id: "access", label: "Access" },
  { type: "item", id: "metrics", label: "Metrics" },
  { type: "item", id: "trace", label: "Trace" },
  { type: "item", id: "audit", label: "Audit" },
  { type: "item", id: "privacy", label: "Privacy" },
];

const BOOTSTRAP_LABELS: Record<string, string> = {
  supabaseUrlConfigured: "Supabase URL",
  supabaseAnonKeyConfigured: "Supabase anon key",
  supabaseServiceRoleConfigured: "Supabase service role",
  cacheHmacConfigured: "Cache HMAC",
  operatorConfigKeyConfigured: "Operator wrapping key",
  adminBootstrapEmailConfigured: "Bootstrap admin email",
  resendConfigured: "Resend mail",
  otpFromConfigured: "OTP from address",
  qwenEnvKeyConfigured: "Worker QWEN_API_KEY",
};

function cacheActionsFor(state: string): CacheAction[] {
  switch (state) {
    case "active":
      return ["quarantine", "expire", "purge", "regenerate"];
    case "quarantined":
      return ["activate", "expire", "purge", "regenerate"];
    case "expired":
    case "superseded":
      return ["activate", "purge", "regenerate"];
    case "purged":
      return ["regenerate"];
    default:
      return ["quarantine", "activate", "expire", "purge", "regenerate"];
  }
}

function draftsFrom(policies: Policy[]): Record<string, PolicyDraft> {
  const next: Record<string, PolicyDraft> = {};
  for (const policy of policies) {
    next[policy.id] = {
      model: policy.model,
      promptVersion: policy.promptVersion,
      systemPrompt: policy.systemPrompt ?? "",
      canaryPercent: String(policy.canaryPercent ?? 0),
    };
  }
  return next;
}

export function App() {
  const preview = isPreviewMode();
  const [section, setSection] = useState<Section>("overview");
  const [health, setHealth] = useState<HealthPayload | null>(null);
  const [healthError, setHealthError] = useState<string | null>(null);
  const [token, setToken] = useState(() =>
    preview ? "preview" : (sessionStorage.getItem(TOKEN_STORAGE_KEY) ?? ""),
  );
  const [email, setEmail] = useState("audio.reader.service@gmail.com");
  const [code, setCode] = useState("");
  const [tokenDraft, setTokenDraft] = useState("");
  const [turnstileSiteKey, setTurnstileSiteKey] = useState("");
  const [turnstileToken, setTurnstileToken] = useState("");
  const [showChallenge, setShowChallenge] = useState(false);
  const [reason, setReason] = useState("operator update");
  const [busy, setBusy] = useState(false);
  const [adminError, setAdminError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [userQuery, setUserQuery] = useState("");
  const [jobs, setJobs] = useState<Job[]>([]);
  const [jobStatus, setJobStatus] = useState("");
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [drafts, setDrafts] = useState<Record<string, PolicyDraft>>({});
  const [cache, setCache] = useState<CacheEntry[]>([]);
  const [cacheState, setCacheState] = useState("");
  const [cacheTask, setCacheTask] = useState("");
  const [cacheFingerprint, setCacheFingerprint] = useState("");
  const [metrics, setMetrics] = useState<MetricsSnapshot | null>(null);
  const [audit, setAudit] = useState<AuditEvent[]>([]);
  const [auditActor, setAuditActor] = useState("");
  const [auditAction, setAuditAction] = useState("");
  const [auditRequestId, setAuditRequestId] = useState("");
  const [openAuditId, setOpenAuditId] = useState<string | null>(null);
  const [events, setEvents] = useState<OperatorEvent[]>([]);
  const [eventRequestId, setEventRequestId] = useState("");
  const [eventKind, setEventKind] = useState("");
  const [blocked, setBlocked] = useState<BlockedAttempt[]>([]);
  const [runtime, setRuntime] = useState<RuntimeConfig | null>(null);
  const [flags, setFlags] = useState<FeatureFlag[]>([]);
  const [quotas, setQuotas] = useState<Quota[]>([]);
  const [privacy, setPrivacy] = useState<PrivacyRequest[]>([]);
  const [quotaDrafts, setQuotaDrafts] = useState<Record<string, string>>({});
  const [diagnostics, setDiagnostics] = useState<OperatorDiagnostics | null>(null);
  const [qwenKey, setQwenKey] = useState("");
  const [qwenBaseUrl, setQwenBaseUrl] = useState("");
  const [qwenModel, setQwenModel] = useState("");
  const [gcsBucket, setGcsBucket] = useState("");
  const [gcsJson, setGcsJson] = useState("");
  const [turnstileSecret, setTurnstileSecret] = useState("");
  const [openUserId, setOpenUserId] = useState<string | null>(null);
  const [openCacheId, setOpenCacheId] = useState<string | null>(null);
  const [userDetail, setUserDetail] = useState<AdminUser | null>(null);
  const [cacheDetail, setCacheDetail] = useState<CacheEntry | null>(null);
  const [armed, setArmed] = useState<string | null>(null);
  const [cursors, setCursors] = useState<{
    users: string | null;
    jobs: string | null;
    cache: string | null;
    audit: string | null;
  }>({ users: null, jobs: null, cache: null, audit: null });
  const [metricsFrom, setMetricsFrom] = useState(() =>
    new Date(Date.now() - 86_400_000).toISOString().slice(0, 16),
  );
  const [metricsTo, setMetricsTo] = useState(() => new Date().toISOString().slice(0, 16));

  useEffect(() => {
    let cancelled = false;
    const loadHealth = () => {
      void fetch(`${API_BASE}/v1/health`)
        .then(async (response) => {
          const payload = (await response.json()) as HealthPayload;
          if (!cancelled) {
            setHealth(payload);
            setHealthError(null);
          }
        })
        .catch((cause: unknown) => {
          if (!cancelled) {
            setHealthError(cause instanceof Error ? cause.message : "health request failed");
          }
        });
    };
    loadHealth();
    const timer = window.setInterval(loadHealth, 30_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    void fetchAuthConfig()
      .then((config) => {
        if (!cancelled && typeof config.turnstileSiteKey === "string") {
          setTurnstileSiteKey(config.turnstileSiteKey);
        }
      })
      .catch(() => {
        /* Gate still works with a pasted token. */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const rememberToken = (value: string) => {
    setToken(value);
    if (value === "" || preview) {
      sessionStorage.removeItem(TOKEN_STORAGE_KEY);
    } else {
      sessionStorage.setItem(TOKEN_STORAGE_KEY, value);
    }
  };

  const applyRuntime = (config: RuntimeConfig) => {
    setRuntime(config);
    setQwenBaseUrl(config.qwen.baseUrl);
    setQwenModel(config.qwen.model);
    setGcsBucket(config.storage.bucket ?? "");
  };

  const loadAdmin = useCallback(
    async (access = token) => {
      if (preview) {
        setUsers(PREVIEW_USERS);
        setJobs(PREVIEW_JOBS);
        setPolicies(PREVIEW_POLICIES);
        setDrafts(draftsFrom(PREVIEW_POLICIES));
        setCache(PREVIEW_CACHE);
        applyRuntime(PREVIEW_RUNTIME);
        setMetrics(PREVIEW_METRICS);
        setAudit(PREVIEW_AUDIT);
        setBlocked(PREVIEW_BLOCKED);
        setFlags(PREVIEW_FLAGS);
        setQuotas(PREVIEW_QUOTAS);
        setQuotaDrafts(
          Object.fromEntries(PREVIEW_QUOTAS.map((item) => [item.key, String(item.limit)])),
        );
        setPrivacy(PREVIEW_PRIVACY);
        setDiagnostics(PREVIEW_DIAGNOSTICS);
        setEvents(PREVIEW_EVENTS);
        setAdminError(null);
        setStatus(null);
        return;
      }
      if (access.trim() === "") {
        setAdminError("Sign in or paste an admin access token.");
        return;
      }
      setBusy(true);
      try {
        const from = new Date(metricsFrom).toISOString();
        const to = new Date(metricsTo).toISOString();
        const usersQuery = new URLSearchParams();
        if (userQuery.trim() !== "") {
          usersQuery.set("query", userQuery.trim());
        }
        const jobQuery = new URLSearchParams();
        if (jobStatus !== "") {
          jobQuery.set("status", jobStatus);
        }
        const cacheQuery = new URLSearchParams();
        if (cacheState !== "") {
          cacheQuery.set("state", cacheState);
        }
        if (cacheTask.trim() !== "") {
          cacheQuery.set("task", cacheTask.trim());
        }
        if (cacheFingerprint.trim() !== "") {
          cacheQuery.set("editionFingerprint", cacheFingerprint.trim());
        }
        const auditQuery = new URLSearchParams();
        if (auditActor.trim() !== "") {
          auditQuery.set("actorId", auditActor.trim());
        }
        if (auditAction.trim() !== "") {
          auditQuery.set("action", auditAction.trim());
        }
        if (auditRequestId.trim() !== "") {
          auditQuery.set("requestId", auditRequestId.trim());
        }
        const eventsQuery = new URLSearchParams();
        if (eventRequestId.trim() !== "") {
          eventsQuery.set("requestId", eventRequestId.trim());
        }
        if (eventKind.trim() !== "") {
          eventsQuery.set("kind", eventKind.trim());
        }
        const [
          usersPayload,
          jobsPayload,
          policiesPayload,
          cachePayload,
          runtimePayload,
          metricsPayload,
          auditPayload,
          blockedPayload,
          flagsPayload,
          quotasPayload,
          privacyPayload,
          diagnosticsPayload,
          eventsPayload,
        ] = await Promise.all([
          getJson<unknown>(`/v1/admin/users?${usersQuery.toString()}`, access),
          getJson<unknown>(`/v1/admin/jobs?${jobQuery.toString()}`, access),
          getJson<Policy[] | { items?: Policy[] }>("/v1/admin/llm/policies", access),
          getJson<unknown>(`/v1/admin/cache?${cacheQuery.toString()}`, access),
          getJson<RuntimeConfig>("/v1/admin/runtime-config", access),
          getJson<MetricsSnapshot>(
            `/v1/admin/metrics?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
            access,
          ),
          getJson<unknown>(`/v1/admin/audit-events?${auditQuery.toString()}`, access),
          getJson<unknown>("/v1/admin/auth/blocked-attempts", access),
          getJsonOrNull<FeatureFlag[]>("/v1/admin/feature-flags", access),
          getJsonOrNull<Quota[]>("/v1/admin/quotas", access),
          getJsonOrNull<unknown>("/v1/admin/privacy-requests", access),
          getJsonOrNull<OperatorDiagnostics>("/v1/admin/diagnostics", access),
          getJsonOrNull<OperatorEvent[]>(
            `/v1/admin/events${eventsQuery.toString() === "" ? "" : `?${eventsQuery.toString()}`}`,
            access,
          ),
        ]);
        const nextPolicies = pageItems<Policy>(policiesPayload);
        setUsers(pageItems<AdminUser>(usersPayload));
        setJobs(pageItems<Job>(jobsPayload));
        setPolicies(nextPolicies);
        setDrafts(draftsFrom(nextPolicies));
        setCache(pageItems<CacheEntry>(cachePayload));
        applyRuntime(runtimePayload);
        setMetrics(metricsPayload);
        setAudit(pageItems<AuditEvent>(auditPayload));
        setBlocked(pageItems<BlockedAttempt>(blockedPayload));
        const nextFlags = Array.isArray(flagsPayload) ? flagsPayload : [];
        const nextQuotas = Array.isArray(quotasPayload) ? quotasPayload : [];
        setFlags(nextFlags);
        setQuotas(nextQuotas);
        setQuotaDrafts(
          Object.fromEntries(nextQuotas.map((item) => [item.key, String(item.limit)])),
        );
        setPrivacy(pageItems<PrivacyRequest>(privacyPayload ?? { items: [] }));
        setDiagnostics(diagnosticsPayload);
        setEvents(
          Array.isArray(eventsPayload) ? eventsPayload : (diagnosticsPayload?.recentEvents ?? []),
        );
        setCursors({
          users: nextCursorOf(usersPayload),
          jobs: nextCursorOf(jobsPayload),
          cache: nextCursorOf(cachePayload),
          audit: nextCursorOf(auditPayload),
        });
        setAdminError(null);
        setStatus("Operator data loaded.");
      } catch (cause: unknown) {
        setAdminError(cause instanceof Error ? cause.message : "admin request failed");
      } finally {
        setBusy(false);
      }
    },
    [
      auditAction,
      auditActor,
      auditRequestId,
      cacheFingerprint,
      cacheState,
      cacheTask,
      eventKind,
      eventRequestId,
      jobStatus,
      metricsFrom,
      metricsTo,
      preview,
      token,
      userQuery,
    ],
  );

  useEffect(() => {
    const fromLink = extractAccessToken(window.location.href);
    if (fromLink !== "") {
      const next = `${window.location.pathname}${window.location.search}`;
      window.history.replaceState({}, document.title, next);
      rememberToken(fromLink);
      void loadAdmin(fromLink);
      return;
    }
    if (token.trim() !== "") {
      void loadAdmin(token);
    }
  }, []);

  async function onRequestCode(): Promise<void> {
    setBusy(true);
    try {
      await requestOtp(email.trim(), turnstileToken === "" ? undefined : turnstileToken);
      setAdminError(null);
      setStatus("A sign-in code was sent if that mailbox is known.");
    } catch (cause: unknown) {
      const message = cause instanceof Error ? cause.message : "could not request a code";
      if (
        message.toLowerCase().includes("turnstile") ||
        message.toLowerCase().includes("challenge")
      ) {
        setShowChallenge(true);
      }
      setAdminError(message);
    } finally {
      setBusy(false);
    }
  }

  async function onVerifyCode(): Promise<void> {
    setBusy(true);
    try {
      const access = await verifyOtp(
        email.trim(),
        code.trim(),
        turnstileToken === "" ? undefined : turnstileToken,
      );
      rememberToken(access);
      await loadAdmin(access);
    } catch (cause: unknown) {
      const message = cause instanceof Error ? cause.message : "sign-in failed";
      if (
        message.toLowerCase().includes("turnstile") ||
        message.toLowerCase().includes("challenge")
      ) {
        setShowChallenge(true);
      }
      setAdminError(message);
    } finally {
      setBusy(false);
    }
  }

  async function saveRuntime(extra: Record<string, unknown> = {}): Promise<void> {
    if (preview) {
      setStatus("Synthetic sample cannot change live configuration.");
      return;
    }
    if (!reasonReady(reason)) {
      setAdminError("Change reason must be at least 5 characters.");
      return;
    }
    setBusy(true);
    try {
      const payload: Record<string, unknown> = {
        reason: reason.trim(),
        qwen: {
          baseUrl: qwenBaseUrl,
          model: qwenModel,
          ...(qwenKey.trim() === "" ? {} : { apiKey: qwenKey.trim() }),
        },
        storage: {
          bucket: gcsBucket,
          ...(gcsJson.trim() === "" ? {} : { serviceAccountJson: gcsJson.trim() }),
        },
        ...(turnstileSecret.trim() === ""
          ? {}
          : { turnstile: { secretKey: turnstileSecret.trim() } }),
        ...extra,
      };
      const config = await sendJson<RuntimeConfig>(
        "/v1/admin/runtime-config",
        token,
        "PUT",
        payload,
      );
      applyRuntime(config);
      setQwenKey("");
      setGcsJson("");
      setTurnstileSecret("");
      setAdminError(null);
      setStatus("Runtime configuration saved. Workers pick it up without a redeploy.");
      await loadAdmin();
    } catch (cause: unknown) {
      setAdminError(cause instanceof Error ? cause.message : "save failed");
    } finally {
      setBusy(false);
    }
  }

  async function probeQwen(): Promise<void> {
    if (preview) {
      setStatus("Synthetic sample cannot probe live Qwen.");
      return;
    }
    if (token.trim() === "") {
      setAdminError("Sign in or paste an admin access token.");
      return;
    }
    setBusy(true);
    try {
      const snapshot = await getJson<OperatorDiagnostics>(
        "/v1/admin/diagnostics?probe=complete",
        token,
      );
      setDiagnostics(snapshot);
      applyRuntime(snapshot.runtime);
      setAdminError(null);
      setStatus(
        snapshot.qwenComplete?.status === "ok"
          ? `Qwen completion probe succeeded with ${snapshot.qwenComplete.model ?? "the configured model"}.`
          : `Qwen completion probe: ${snapshot.qwenComplete?.status ?? "unknown"}. See Diagnostics.`,
      );
    } catch (cause: unknown) {
      setAdminError(cause instanceof Error ? cause.message : "Qwen probe failed");
    } finally {
      setBusy(false);
    }
  }

  async function mutate(
    path: string,
    method: string,
    body: unknown,
    okMessage: string,
  ): Promise<void> {
    if (preview) {
      setStatus("Synthetic sample cannot change live configuration.");
      return;
    }
    if (!reasonReady(reason)) {
      setAdminError("Change reason must be at least 5 characters.");
      return;
    }
    setBusy(true);
    try {
      await sendJson(path, token, method, body);
      setArmed(null);
      setStatus(okMessage);
      await loadAdmin();
    } catch (cause: unknown) {
      setAdminError(cause instanceof Error ? cause.message : "request failed");
    } finally {
      setBusy(false);
    }
  }

  async function loadMore(kind: "users" | "jobs" | "cache" | "audit"): Promise<void> {
    const cursor = cursors[kind];
    if (cursor === null || preview) {
      return;
    }
    setBusy(true);
    try {
      const params = new URLSearchParams({ cursor });
      let path = `/v1/admin/${kind}`;
      if (kind === "users" && userQuery.trim() !== "") {
        params.set("query", userQuery.trim());
      }
      if (kind === "jobs" && jobStatus !== "") {
        params.set("status", jobStatus);
      }
      if (kind === "cache") {
        path = "/v1/admin/cache";
        if (cacheState !== "") {
          params.set("state", cacheState);
        }
        if (cacheTask.trim() !== "") {
          params.set("task", cacheTask.trim());
        }
        if (cacheFingerprint.trim() !== "") {
          params.set("editionFingerprint", cacheFingerprint.trim());
        }
      }
      if (kind === "audit") {
        path = "/v1/admin/audit-events";
        if (auditActor.trim() !== "") {
          params.set("actorId", auditActor.trim());
        }
      }
      const payload = await getJson<unknown>(`${path}?${params.toString()}`, token);
      const extraUsers = pageItems<AdminUser>(payload);
      if (kind === "users") {
        setUsers((current) => [...current, ...extraUsers]);
      }
      if (kind === "jobs") {
        setJobs((current) => [...current, ...pageItems<Job>(payload)]);
      }
      if (kind === "cache") {
        setCache((current) => [...current, ...pageItems<CacheEntry>(payload)]);
      }
      if (kind === "audit") {
        setAudit((current) => [...current, ...pageItems<AuditEvent>(payload)]);
      }
      setCursors((current) => ({ ...current, [kind]: nextCursorOf(payload) }));
    } catch (cause: unknown) {
      setAdminError(cause instanceof Error ? cause.message : "could not load more");
    } finally {
      setBusy(false);
    }
  }

  async function toggleUser(user: AdminUser): Promise<void> {
    if (openUserId === user.accountId) {
      setOpenUserId(null);
      setUserDetail(null);
      return;
    }
    setOpenUserId(user.accountId);
    if (preview) {
      setUserDetail(user);
      return;
    }
    try {
      setUserDetail(await getJson<AdminUser>(`/v1/admin/users/${user.accountId}`, token));
    } catch (cause: unknown) {
      setUserDetail(user);
      setAdminError(cause instanceof Error ? cause.message : "could not load user");
    }
  }

  async function toggleCache(entry: CacheEntry): Promise<void> {
    if (openCacheId === entry.id) {
      setOpenCacheId(null);
      setCacheDetail(null);
      return;
    }
    setOpenCacheId(entry.id);
    if (preview) {
      setCacheDetail(entry);
      return;
    }
    try {
      setCacheDetail(await getJson<CacheEntry>(`/v1/admin/cache/${entry.id}`, token));
    } catch (cause: unknown) {
      setCacheDetail(entry);
      setAdminError(cause instanceof Error ? cause.message : "could not load cache entry");
    }
  }

  const canMutate = reasonReady(reason) && !busy;
  const signedIn = token.trim() !== "";

  if (!signedIn) {
    return (
      <div className="shell">
        <TopBar
          health={health}
          busy={busy}
          signedIn={false}
          onRefresh={() => undefined}
          onSignOut={() => undefined}
        />
        <main className="gate">
          <h1>Sign in to operate</h1>
          <p className="lede">
            Use the product account that holds the operator role. You should get a numeric sign-in
            code. If the mail is still a link, paste that URL below.
          </p>
          <label>
            Email
            <input
              type="email"
              autoComplete="username"
              value={email}
              onChange={(event) => {
                setEmail(event.target.value);
              }}
            />
          </label>
          {showChallenge && turnstileSiteKey !== "" ? (
            <Turnstile siteKey={turnstileSiteKey} onToken={setTurnstileToken} />
          ) : null}
          <div className="actions">
            <button
              type="button"
              className="primary"
              disabled={busy}
              onClick={() => void onRequestCode()}
            >
              Send sign-in code
            </button>
          </div>
          <label>
            Sign-in code
            <input
              inputMode="numeric"
              autoComplete="one-time-code"
              value={code}
              onChange={(event) => {
                setCode(event.target.value);
              }}
            />
          </label>
          <div className="actions">
            <button
              type="button"
              className="primary"
              disabled={busy}
              onClick={() => void onVerifyCode()}
            >
              Sign in
            </button>
          </div>
          <label>
            Or paste a magic link or access token
            <input
              type="password"
              autoComplete="off"
              value={tokenDraft}
              onChange={(event) => {
                setTokenDraft(event.target.value);
              }}
            />
          </label>
          <div className="actions">
            <button
              type="button"
              className="ghost"
              disabled={busy || extractAccessToken(tokenDraft) === ""}
              onClick={() => {
                const access = extractAccessToken(tokenDraft);
                rememberToken(access);
                void loadAdmin(access);
              }}
            >
              Use token
            </button>
          </div>
          {adminError !== null ? <p role="alert">{adminError}</p> : null}
          {status !== null ? <p className="status-line">{status}</p> : null}
        </main>
      </div>
    );
  }

  return (
    <div className="shell">
      <TopBar
        health={health}
        busy={busy}
        signedIn
        onRefresh={() => {
          void loadAdmin();
        }}
        onSignOut={() => {
          rememberToken("");
          setStatus(null);
        }}
      />
      <div className="layout">
        <nav className="rail" aria-label="Operator sections">
          {RAIL.map((item) =>
            item.type === "label" ? (
              <p key={item.label} className="rail-label">
                {item.label}
              </p>
            ) : (
              <button
                key={item.id}
                type="button"
                className="dest"
                aria-current={section === item.id ? "page" : undefined}
                onClick={() => {
                  setSection(item.id);
                }}
              >
                {item.label}
              </button>
            ),
          )}
          <div className="reason-dock">
            <label>
              Change reason
              <input
                value={reason}
                aria-invalid={!reasonReady(reason)}
                onChange={(event) => {
                  setReason(event.target.value);
                }}
              />
            </label>
          </div>
        </nav>
        <main className="stage" aria-busy={busy}>
          {preview ? (
            <p className="banner">
              Synthetic operator sample — labeled for layout review, not live data.
            </p>
          ) : null}
          {healthError !== null ? <p role="alert">{healthError}</p> : null}
          {adminError !== null ? <p role="alert">{adminError}</p> : null}
          {status !== null ? <p className="status-line">{status}</p> : null}
          {busy && users.length === 0 && runtime === null ? (
            <div className="skeleton" aria-hidden="true">
              <i />
              <i />
              <i />
            </div>
          ) : null}

          {section === "overview" ? (
            <DeskPanel
              health={health}
              runtime={runtime}
              diagnostics={diagnostics}
              reasonReady={canMutate}
              busy={busy}
              onProbe={() => {
                void probeQwen();
              }}
              qwenBaseUrl={qwenBaseUrl}
              qwenModel={qwenModel}
              qwenKey={qwenKey}
              gcsBucket={gcsBucket}
              gcsJson={gcsJson}
              turnstileSecret={turnstileSecret}
              onQwenBaseUrl={setQwenBaseUrl}
              onQwenModel={setQwenModel}
              onQwenKey={setQwenKey}
              onGcsBucket={setGcsBucket}
              onGcsJson={setGcsJson}
              onTurnstileSecret={setTurnstileSecret}
              onSave={() => {
                void saveRuntime();
              }}
              onClearQwen={() => {
                void saveRuntime({
                  qwen: { apiKey: null, baseUrl: qwenBaseUrl, model: qwenModel },
                });
              }}
              onClearStorage={() => {
                void saveRuntime({ storage: { bucket: gcsBucket, serviceAccountJson: null } });
              }}
              onClearTurnstile={() => {
                void saveRuntime({ turnstile: { secretKey: null } });
              }}
            />
          ) : null}

          {section === "users" ? (
            <UsersPanel
              users={users}
              userQuery={userQuery}
              busy={busy}
              canMutate={canMutate}
              armed={armed}
              openUserId={openUserId}
              userDetail={userDetail}
              nextCursor={cursors.users}
              onQuery={setUserQuery}
              onApply={() => {
                void loadAdmin();
              }}
              onLoadMore={() => {
                void loadMore("users");
              }}
              onToggle={(user) => {
                void toggleUser(user);
              }}
              onArm={setArmed}
              onMutate={(path, message) => {
                void mutate(path, "POST", { reason: reason.trim() }, message);
              }}
            />
          ) : null}

          {section === "policies" ? (
            <PoliciesPanel
              policies={policies}
              drafts={drafts}
              busy={busy}
              canMutate={canMutate}
              onDraft={(id, patch) => {
                setDrafts((current) => {
                  const existing = current[id];
                  if (existing === undefined) {
                    return current;
                  }
                  return { ...current, [id]: { ...existing, ...patch } };
                });
              }}
              onToggle={(policy) => {
                void mutate(
                  `/v1/admin/llm/policies/${policy.id}`,
                  "PATCH",
                  { reason: reason.trim(), enabled: !policy.enabled },
                  `${policy.task} ${policy.enabled ? "disabled" : "enabled"}.`,
                );
              }}
              onSave={(policy) => {
                const draft = drafts[policy.id];
                if (draft === undefined) {
                  return;
                }
                const canary = Number(draft.canaryPercent);
                void mutate(
                  `/v1/admin/llm/policies/${policy.id}`,
                  "PATCH",
                  {
                    reason: reason.trim(),
                    model: draft.model.trim(),
                    promptVersion: draft.promptVersion.trim(),
                    systemPrompt: draft.systemPrompt,
                    ...(Number.isFinite(canary) ? { canaryPercent: canary } : {}),
                  },
                  `${policy.task} policy saved.`,
                );
              }}
            />
          ) : null}

          {section === "jobs" ? (
            <JobsPanel
              jobs={jobs}
              jobStatus={jobStatus}
              busy={busy}
              canMutate={canMutate}
              armed={armed}
              nextCursor={cursors.jobs}
              onStatus={setJobStatus}
              onApply={() => {
                void loadAdmin();
              }}
              onLoadMore={() => {
                void loadMore("jobs");
              }}
              onArm={setArmed}
              onMutate={(path, message) => {
                void mutate(path, "POST", { reason: reason.trim() }, message);
              }}
            />
          ) : null}

          {section === "cache" ? (
            <CachePanel
              entries={cache}
              cacheState={cacheState}
              cacheTask={cacheTask}
              cacheFingerprint={cacheFingerprint}
              busy={busy}
              canMutate={canMutate}
              armed={armed}
              openCacheId={openCacheId}
              cacheDetail={cacheDetail}
              nextCursor={cursors.cache}
              onState={setCacheState}
              onTask={setCacheTask}
              onFingerprint={setCacheFingerprint}
              onApply={() => {
                void loadAdmin();
              }}
              onLoadMore={() => {
                void loadMore("cache");
              }}
              onToggle={(entry) => {
                void toggleCache(entry);
              }}
              onArm={setArmed}
              onAction={(entry, action) => {
                void mutate(
                  `/v1/admin/cache/${entry.id}/actions`,
                  "POST",
                  { action, reason: reason.trim() },
                  `Cache ${action} queued.`,
                );
              }}
            />
          ) : null}

          {section === "access" ? <AccessPanel attempts={blocked} /> : null}

          {section === "metrics" ? (
            <MetricsPanel
              metrics={metrics}
              from={metricsFrom}
              to={metricsTo}
              busy={busy}
              onFrom={setMetricsFrom}
              onTo={setMetricsTo}
              onApply={() => {
                void loadAdmin();
              }}
            />
          ) : null}

          {section === "trace" ? (
            <TracePanel
              events={events}
              requestId={eventRequestId}
              kind={eventKind}
              busy={busy}
              onRequestId={setEventRequestId}
              onKind={setEventKind}
              onApply={() => {
                void loadAdmin();
              }}
            />
          ) : null}

          {section === "audit" ? (
            <AuditPanel
              events={audit}
              actor={auditActor}
              action={auditAction}
              requestId={auditRequestId}
              openId={openAuditId}
              busy={busy}
              nextCursor={cursors.audit}
              onActor={setAuditActor}
              onAction={setAuditAction}
              onRequestId={setAuditRequestId}
              onOpen={setOpenAuditId}
              onApply={() => {
                void loadAdmin();
              }}
              onLoadMore={() => {
                void loadMore("audit");
              }}
            />
          ) : null}

          {section === "flags" ? (
            <FlagsPanel
              flags={flags}
              busy={busy}
              canMutate={canMutate}
              onToggle={(flag) => {
                void mutate(
                  `/v1/admin/feature-flags/${flag.key}`,
                  "PATCH",
                  { reason: reason.trim(), enabled: !flag.enabled },
                  `${flag.key} ${flag.enabled ? "disabled" : "enabled"}.`,
                );
              }}
              onSave={(flag, rollout) => {
                void mutate(
                  `/v1/admin/feature-flags/${flag.key}`,
                  "PATCH",
                  { reason: reason.trim(), rolloutPercent: rollout },
                  `${flag.key} rollout set to ${String(rollout)}%.`,
                );
              }}
            />
          ) : null}

          {section === "quotas" ? (
            <QuotasPanel
              quotas={quotas}
              drafts={quotaDrafts}
              busy={busy}
              canMutate={canMutate}
              onDraft={(key, value) => {
                setQuotaDrafts((current) => ({ ...current, [key]: value }));
              }}
              onSave={(quota) => {
                const draft = Number(quotaDrafts[quota.key]);
                if (!Number.isFinite(draft)) {
                  return;
                }
                void mutate(
                  `/v1/admin/quotas/${quota.key}`,
                  "PATCH",
                  { reason: reason.trim(), limit: draft },
                  `${quota.key} limit saved.`,
                );
              }}
            />
          ) : null}

          {section === "privacy" ? (
            <PrivacyPanel
              requests={privacy}
              busy={busy}
              canMutate={canMutate}
              armed={armed}
              onArm={setArmed}
              onMutate={(path, action, message) => {
                void mutate(path, "POST", { reason: reason.trim(), action }, message);
              }}
            />
          ) : null}
        </main>
      </div>
    </div>
  );
}

function TopBar(props: {
  health: HealthPayload | null;
  busy: boolean;
  signedIn: boolean;
  onRefresh: () => void;
  onSignOut: () => void;
}) {
  return (
    <header className="topbar">
      <h1 className="brand">
        AudioReader
        <span>Operator console</span>
      </h1>
      <div className="health-pips" aria-label="API health">
        <span className={`pip ${pipClass(props.health?.status)}`}>
          <i />
          {props.health?.status ?? "loading"}
        </span>
        {props.health?.dependencies !== undefined
          ? Object.entries(props.health.dependencies).map(([name, value]) => (
              <span key={name} className={`pip ${pipClass(value)}`}>
                <i />
                {name} {value}
              </span>
            ))
          : null}
      </div>
      {props.signedIn ? (
        <div className="session">
          <button type="button" className="ghost" disabled={props.busy} onClick={props.onRefresh}>
            Refresh
          </button>
          <button type="button" className="signout" onClick={props.onSignOut}>
            Sign out
          </button>
        </div>
      ) : null}
    </header>
  );
}

function Turnstile(props: { siteKey: string; onToken: (token: string) => void }) {
  const host = useRef<HTMLDivElement | null>(null);
  const widgetId = useRef<string | null>(null);
  const onToken = useRef(props.onToken);
  onToken.current = props.onToken;

  useEffect(() => {
    let cancelled = false;
    const render = () => {
      if (cancelled || window.turnstile === undefined || host.current === null) {
        return;
      }
      if (widgetId.current !== null) {
        window.turnstile.reset(widgetId.current);
        return;
      }
      widgetId.current = window.turnstile.render(host.current, {
        sitekey: props.siteKey,
        theme: "auto",
        callback: (token) => {
          onToken.current(token);
        },
        "expired-callback": () => {
          onToken.current("");
        },
        "error-callback": () => {
          onToken.current("");
        },
      });
    };
    if (window.turnstile !== undefined) {
      render();
    } else {
      const existing = document.querySelector("script[data-turnstile]");
      if (existing === null) {
        const script = document.createElement("script");
        script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
        script.async = true;
        script.dataset.turnstile = "true";
        script.addEventListener("load", render);
        document.head.append(script);
      } else {
        existing.addEventListener("load", render);
      }
    }
    return () => {
      cancelled = true;
    };
  }, [props.siteKey]);

  return <div className="turnstile-slot" ref={host} />;
}

function DeskPanel(props: {
  health: HealthPayload | null;
  runtime: RuntimeConfig | null;
  diagnostics: OperatorDiagnostics | null;
  reasonReady: boolean;
  busy: boolean;
  onProbe: () => void;
  qwenBaseUrl: string;
  qwenModel: string;
  qwenKey: string;
  gcsBucket: string;
  gcsJson: string;
  turnstileSecret: string;
  onQwenBaseUrl: (value: string) => void;
  onQwenModel: (value: string) => void;
  onQwenKey: (value: string) => void;
  onGcsBucket: (value: string) => void;
  onGcsJson: (value: string) => void;
  onTurnstileSecret: (value: string) => void;
  onSave: () => void;
  onClearQwen: () => void;
  onClearStorage: () => void;
  onClearTurnstile: () => void;
}) {
  const dependencies = props.health?.dependencies;
  return (
    <>
      <h2>Desk</h2>
      <p className="lede">Live health and the configuration that used to live in Worker secrets.</p>
      {props.diagnostics !== null ? (
        <section className="ledger">
          <h3>Diagnostics</h3>
          <p className="lede tight">
            What the Worker currently uses for Managed Qwen, without secrets. Probe completion to
            exercise the same path the app uses.
          </p>
          {props.diagnostics.notes.length > 0 ? (
            <ul className="diag-notes">
              {props.diagnostics.notes.map((note) => (
                <li key={note} role="alert">
                  {note}
                </li>
              ))}
            </ul>
          ) : (
            <p className="status-line">No configuration warnings from this snapshot.</p>
          )}
          <table className="service-table">
            <caption>Live Worker snapshot</caption>
            <tbody>
              <tr>
                <td>Qwen key</td>
                <td>
                  {props.diagnostics.runtime.qwen.apiKeyConfigured
                    ? `yes (${props.diagnostics.runtime.qwen.source}${props.diagnostics.runtime.qwen.apiKeyLast4 !== undefined ? ` · …${props.diagnostics.runtime.qwen.apiKeyLast4}` : ""})`
                    : "no"}
                </td>
              </tr>
              <tr>
                <td>Qwen model (Desk)</td>
                <td>{props.diagnostics.runtime.qwen.model || "(empty)"}</td>
              </tr>
              <tr>
                <td>Qwen base URL</td>
                <td className="mono">
                  {props.diagnostics.runtime.qwen.baseUrl || "(package default)"}
                </td>
              </tr>
              <tr>
                <td>Qwen /models probe</td>
                <td>{props.diagnostics.qwenProbe}</td>
              </tr>
              <tr>
                <td>Qwen completion probe</td>
                <td>
                  {props.diagnostics.qwenComplete === undefined
                    ? "not run"
                    : `${props.diagnostics.qwenComplete.status}${props.diagnostics.qwenComplete.model !== undefined ? ` · ${props.diagnostics.qwenComplete.model}` : ""}${props.diagnostics.qwenComplete.httpStatus !== undefined ? ` · HTTP ${String(props.diagnostics.qwenComplete.httpStatus)}` : ""}${props.diagnostics.qwenComplete.detail !== undefined && props.diagnostics.qwenComplete.detail !== "" ? ` · ${props.diagnostics.qwenComplete.detail}` : ""}`}
                </td>
              </tr>
              <tr>
                <td>Secrets decryptable</td>
                <td>
                  {props.diagnostics.runtime.qwen.secretsDecryptable === false ? "no" : "yes"}
                  {props.diagnostics.runtime.qwen.ciphertextPresent === true
                    ? " · ciphertext present"
                    : ""}
                </td>
              </tr>
              <tr>
                <td>Operator wrapping key</td>
                <td>
                  {props.diagnostics.runtime.qwen.wrappingSecretSource ??
                    (props.diagnostics.runtime.bootstrap.operatorConfigKeyConfigured
                      ? "operator_config_key"
                      : "unknown")}
                  {props.diagnostics.runtime.qwen.wrappingSecretConfigured === false
                    ? " · missing"
                    : ""}
                </td>
              </tr>
              <tr>
                <td>Flags</td>
                <td>
                  {props.diagnostics.flags
                    .map((flag) => `${flag.key}:${flag.enabled ? "on" : "off"}`)
                    .join(" · ") || "none"}
                </td>
              </tr>
              <tr>
                <td>Quotas</td>
                <td>
                  {props.diagnostics.quotas
                    .map((quota) => `${quota.key} ${String(quota.used)}/${String(quota.limit)}`)
                    .join(" · ") || "none"}
                </td>
              </tr>
              <tr>
                <td>Policies</td>
                <td>
                  {props.diagnostics.policies
                    .map(
                      (policy) =>
                        `${policy.task}:${policy.enabled ? "on" : "off"}:${policy.model}:${policy.promptVersion}`,
                    )
                    .join(" · ") || "none"}
                </td>
              </tr>
            </tbody>
          </table>
          <div className="actions">
            <button type="button" className="ghost" disabled={props.busy} onClick={props.onProbe}>
              Probe Qwen completion
            </button>
          </div>
          {(props.diagnostics.recentEvents ?? []).length > 0 ? (
            <table className="service-table">
              <caption>Recent Worker events</caption>
              <tbody>
                {(props.diagnostics.recentEvents ?? []).slice(0, 8).map((event) => (
                  <tr key={event.id}>
                    <td>
                      <span className={`pill ${statusTone(event.status ?? event.kind)}`}>
                        {event.kind}
                      </span>
                    </td>
                    <td>
                      {event.summary}
                      <div className="mono">{formatWhen(event.at)}</div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
        </section>
      ) : null}
      <p className="lede tight">
        Endpoint <code className="mono">{API_BASE === "" ? window.location.origin : API_BASE}</code>
      </p>
      <section className="ledger">
        <h3>Service</h3>
        {dependencies === undefined ? (
          <p className="empty">Waiting for health from the API.</p>
        ) : (
          <table className="service-table">
            <thead>
              <tr>
                <th>Dependency</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(dependencies).map(([name, value]) => (
                <tr key={name}>
                  <td>{name}</td>
                  <td>
                    <span className={`pill ${statusTone(value)}`}>{value}</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="lede tight">
          Version {props.health?.version ?? "unknown"}
          {props.health?.time !== undefined ? ` · ${formatWhen(props.health.time)}` : ""}
        </p>
      </section>
      <section className="ledger">
        <h3>Runtime configuration</h3>
        {props.runtime !== null ? (
          <p className="lede">
            Qwen {props.runtime.qwen.source}
            {props.runtime.qwen.apiKeyConfigured
              ? ` · …${props.runtime.qwen.apiKeyLast4 ?? ""}`
              : " · no key"}
            . Storage {props.runtime.storage.provider} ({props.runtime.storage.source}
            {props.runtime.storage.bucket !== undefined ? ` · ${props.runtime.storage.bucket}` : ""}
            {props.runtime.storage.clientEmail !== undefined
              ? ` · ${props.runtime.storage.clientEmail}`
              : ""}
            ). Turnstile {props.runtime.turnstile.configured ? "configured" : "not configured"} (
            {props.runtime.turnstile.source}).
            {props.runtime.updatedAt !== undefined
              ? ` Updated ${formatWhen(props.runtime.updatedAt)}.`
              : ""}
          </p>
        ) : (
          <p className="empty">Load operator data to edit live config.</p>
        )}
        <div className="grid-2">
          <label>
            Qwen base URL
            <input
              value={props.qwenBaseUrl}
              onChange={(event) => {
                props.onQwenBaseUrl(event.target.value);
              }}
            />
          </label>
          <label>
            Qwen model
            <input
              value={props.qwenModel}
              onChange={(event) => {
                props.onQwenModel(event.target.value);
              }}
            />
          </label>
        </div>
        <label>
          Qwen API key (leave blank to keep)
          <input
            type="password"
            autoComplete="off"
            value={props.qwenKey}
            onChange={(event) => {
              props.onQwenKey(event.target.value);
            }}
          />
        </label>
        <label>
          Object-store bucket
          <input
            value={props.gcsBucket}
            onChange={(event) => {
              props.onGcsBucket(event.target.value);
            }}
          />
        </label>
        <label>
          GCS service account JSON (leave blank to keep)
          <textarea
            value={props.gcsJson}
            spellCheck={false}
            onChange={(event) => {
              props.onGcsJson(event.target.value);
            }}
          />
        </label>
        <label>
          Turnstile secret (leave blank to keep)
          <input
            type="password"
            autoComplete="off"
            value={props.turnstileSecret}
            onChange={(event) => {
              props.onTurnstileSecret(event.target.value);
            }}
          />
        </label>
        <div className="actions">
          <button
            type="button"
            className="primary"
            disabled={!props.reasonReady}
            onClick={props.onSave}
          >
            Save runtime config
          </button>
          <button
            type="button"
            className="ghost"
            disabled={!props.reasonReady}
            onClick={props.onClearQwen}
          >
            Clear stored Qwen key
          </button>
          <button
            type="button"
            className="ghost"
            disabled={!props.reasonReady}
            onClick={props.onClearStorage}
          >
            Clear stored GCS key
          </button>
          <button
            type="button"
            className="ghost"
            disabled={!props.reasonReady}
            onClick={props.onClearTurnstile}
          >
            Clear stored Turnstile secret
          </button>
        </div>
        {props.runtime !== null ? (
          <table className="service-table follow">
            <thead>
              <tr>
                <th>Bootstrap secret</th>
                <th>Worker env</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(props.runtime.bootstrap).map(([name, on]) => (
                <tr key={name}>
                  <td>{BOOTSTRAP_LABELS[name] ?? name}</td>
                  <td>
                    <span className={`pill ${on ? "ok" : "warn"}`}>{on ? "set" : "missing"}</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
      </section>
    </>
  );
}

function ConfirmButton(props: {
  id: string;
  armed: string | null;
  disabled: boolean;
  kind?: "danger" | "ghost";
  label: string;
  confirm: string;
  onArm: (id: string | null) => void;
  onConfirm: () => void;
}) {
  const isArmed = props.armed === props.id;
  return (
    <button
      type="button"
      className={isArmed ? "danger" : (props.kind ?? "ghost")}
      disabled={props.disabled}
      onClick={() => {
        if (isArmed) {
          props.onConfirm();
        } else {
          props.onArm(props.id);
        }
      }}
    >
      {isArmed ? props.confirm : props.label}
    </button>
  );
}

function UsersPanel(props: {
  users: AdminUser[];
  userQuery: string;
  busy: boolean;
  canMutate: boolean;
  armed: string | null;
  openUserId: string | null;
  userDetail: AdminUser | null;
  nextCursor: string | null;
  onQuery: (value: string) => void;
  onApply: () => void;
  onLoadMore: () => void;
  onToggle: (user: AdminUser) => void;
  onArm: (id: string | null) => void;
  onMutate: (path: string, message: string) => void;
}) {
  return (
    <>
      <h2>Users</h2>
      <p className="lede">Search, inspect, suspend, restore, revoke devices, or grant operator.</p>
      <div className="toolbar">
        <label>
          Search
          <input
            value={props.userQuery}
            onChange={(event) => {
              props.onQuery(event.target.value);
            }}
          />
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.users.length === 0 ? (
        <p className="empty">No users match this view. Try a different search or refresh.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Support-safe account metadata</caption>
            <thead>
              <tr>
                <th>Email</th>
                <th>Status</th>
                <th>Devices</th>
                <th>Books</th>
                <th>Storage</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.users.map((user) => (
                <UserRows
                  key={user.accountId}
                  user={user}
                  open={props.openUserId === user.accountId}
                  detail={props.openUserId === user.accountId ? props.userDetail : null}
                  canMutate={props.canMutate}
                  armed={props.armed}
                  onToggle={() => {
                    props.onToggle(user);
                  }}
                  onArm={props.onArm}
                  onMutate={props.onMutate}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
      {props.nextCursor !== null ? (
        <div className="actions">
          <button type="button" className="ghost" disabled={props.busy} onClick={props.onLoadMore}>
            Load more
          </button>
        </div>
      ) : null}
    </>
  );
}

function UserRows(props: {
  user: AdminUser;
  open: boolean;
  detail: AdminUser | null;
  canMutate: boolean;
  armed: string | null;
  onToggle: () => void;
  onArm: (id: string | null) => void;
  onMutate: (path: string, message: string) => void;
}) {
  const user = props.detail ?? props.user;
  return (
    <>
      <tr className={props.open ? "selected" : undefined}>
        <td>
          <button type="button" className="ghost" onClick={props.onToggle}>
            {props.open ? "Hide" : "Open"} {user.email}
          </button>
          <div className="mono">{user.accountId}</div>
        </td>
        <td>
          <span className={`pill ${statusTone(user.status)}`}>{user.status}</span>
        </td>
        <td>{user.deviceCount}</td>
        <td>{user.bookCount}</td>
        <td>{formatBytes(user.storageBytes)}</td>
        <td className="row-actions">
          {user.status === "active" ? (
            <ConfirmButton
              id={`suspend:${user.accountId}`}
              armed={props.armed}
              disabled={!props.canMutate}
              kind="danger"
              label="Suspend"
              confirm="Confirm suspend"
              onArm={props.onArm}
              onConfirm={() => {
                props.onMutate(
                  `/v1/admin/users/${user.accountId}/suspend`,
                  `Suspended ${user.email}.`,
                );
              }}
            />
          ) : null}
          {user.status === "suspended" ? (
            <button
              type="button"
              className="ghost"
              disabled={!props.canMutate}
              onClick={() => {
                props.onMutate(
                  `/v1/admin/users/${user.accountId}/unsuspend`,
                  `Restored ${user.email}.`,
                );
              }}
            >
              Restore
            </button>
          ) : null}
          <ConfirmButton
            id={`revoke:${user.accountId}`}
            armed={props.armed}
            disabled={!props.canMutate}
            label="Revoke sessions"
            confirm="Confirm revoke"
            onArm={props.onArm}
            onConfirm={() => {
              props.onMutate(
                `/v1/admin/users/${user.accountId}/revoke-sessions`,
                `Revoked sessions for ${user.email}.`,
              );
            }}
          />
          <ConfirmButton
            id={`grant:${user.accountId}`}
            armed={props.armed}
            disabled={!props.canMutate}
            label="Grant admin"
            confirm="Confirm grant"
            onArm={props.onArm}
            onConfirm={() => {
              props.onMutate(
                `/v1/admin/users/${user.accountId}/grant-admin`,
                `Granted operator to ${user.email}.`,
              );
            }}
          />
        </td>
      </tr>
      {props.open ? (
        <tr className="expand">
          <td colSpan={6}>
            <dl className="detail-grid">
              <dt>Display name</dt>
              <dd>{user.displayName ?? "—"}</dd>
              <dt>Created</dt>
              <dd>{formatWhen(user.createdAt)}</dd>
              <dt>Last seen</dt>
              <dd>{formatWhen(user.lastSeenAt)}</dd>
              <dt>User id</dt>
              <dd className="mono">{user.id}</dd>
              <dt>Quotas</dt>
              <dd>
                {(user.quotas ?? []).length === 0
                  ? "Open this row to load live usage, or apply quota_limits SQL."
                  : user.quotas
                      ?.map((quota) =>
                        quota.key === "cloud_media_bytes"
                          ? `${quota.key} ${formatBytes(quota.used)}/${formatBytes(quota.limit)}`
                          : `${quota.key} ${String(quota.used)}/${String(quota.limit)}`,
                      )
                      .join(" · ")}
              </dd>
            </dl>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function PoliciesPanel(props: {
  policies: Policy[];
  drafts: Record<string, PolicyDraft>;
  busy: boolean;
  canMutate: boolean;
  onDraft: (id: string, patch: Partial<PolicyDraft>) => void;
  onToggle: (policy: Policy) => void;
  onSave: (policy: Policy) => void;
}) {
  return (
    <>
      <h2>Policies</h2>
      <p className="lede">
        Each Managed Qwen task has its own model and system prompt. Translation and chapter summary
        must still return the JSON shape the app parses. Prompt version is a cache label; editing
        the system prompt also busts shared cache.
      </p>
      {props.policies.length === 0 ? (
        <p className="empty">No Qwen policies loaded.</p>
      ) : (
        props.policies.map((policy) => {
          const draft = props.drafts[policy.id];
          return (
            <section className="ledger" key={policy.id}>
              <h3>
                {policy.task.replaceAll("_", " ")}
                <span className={`pill ${policy.enabled ? "ok" : "warn"}`}>
                  {policy.enabled ? "enabled" : "disabled"}
                </span>
              </h3>
              <p className="lede tight mono">
                {policy.region} · policy {policy.policyVersion ?? "v?"}
              </p>
              <div className="grid-2">
                <label>
                  Model
                  <input
                    value={draft?.model ?? policy.model}
                    onChange={(event) => {
                      props.onDraft(policy.id, { model: event.target.value });
                    }}
                  />
                </label>
                <label>
                  Prompt version
                  <input
                    value={draft?.promptVersion ?? policy.promptVersion}
                    onChange={(event) => {
                      props.onDraft(policy.id, { promptVersion: event.target.value });
                    }}
                  />
                </label>
              </div>
              <label>
                Canary percent
                <input
                  inputMode="numeric"
                  value={draft?.canaryPercent ?? String(policy.canaryPercent ?? 0)}
                  onChange={(event) => {
                    props.onDraft(policy.id, { canaryPercent: event.target.value });
                  }}
                />
              </label>
              <label>
                System prompt
                <textarea
                  className="prompt-editor"
                  spellCheck={false}
                  value={draft?.systemPrompt ?? policy.systemPrompt ?? ""}
                  onChange={(event) => {
                    props.onDraft(policy.id, { systemPrompt: event.target.value });
                  }}
                />
              </label>
              <div className="actions">
                <button
                  type="button"
                  className="ghost"
                  disabled={!props.canMutate || props.busy}
                  onClick={() => {
                    props.onToggle(policy);
                  }}
                >
                  {policy.enabled ? "Disable" : "Enable"}
                </button>
                <button
                  type="button"
                  className="primary"
                  disabled={!props.canMutate || props.busy}
                  onClick={() => {
                    props.onSave(policy);
                  }}
                >
                  Save policy
                </button>
              </div>
            </section>
          );
        })
      )}
    </>
  );
}

function JobsPanel(props: {
  jobs: Job[];
  jobStatus: string;
  busy: boolean;
  canMutate: boolean;
  armed: string | null;
  nextCursor: string | null;
  onStatus: (value: string) => void;
  onApply: () => void;
  onLoadMore: () => void;
  onArm: (id: string | null) => void;
  onMutate: (path: string, message: string) => void;
}) {
  return (
    <>
      <h2>Jobs</h2>
      <p className="lede">Retry a failed run or cancel work still in the queue.</p>
      <div className="toolbar">
        <label>
          Status
          <select
            value={props.jobStatus}
            onChange={(event) => {
              props.onStatus(event.target.value);
            }}
          >
            <option value="">Any</option>
            <option value="queued">queued</option>
            <option value="running">running</option>
            <option value="failed">failed</option>
            <option value="succeeded">succeeded</option>
            <option value="cancelled">cancelled</option>
            <option value="dead_letter">dead_letter</option>
          </select>
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.jobs.length === 0 ? (
        <p className="empty">No jobs in this filter.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Background jobs</caption>
            <thead>
              <tr>
                <th>Kind</th>
                <th>Status</th>
                <th>Attempts</th>
                <th>Error</th>
                <th>Updated</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.jobs.map((job) => (
                <tr key={job.id}>
                  <td>
                    {job.kind}
                    <div className="mono">{job.id}</div>
                  </td>
                  <td>
                    <span className={`pill ${statusTone(job.status)}`}>{job.status}</span>
                  </td>
                  <td>
                    {job.attempts ?? 0}/{job.maxAttempts ?? "—"}
                  </td>
                  <td>{job.lastError ?? "—"}</td>
                  <td>{formatWhen(job.updatedAt)}</td>
                  <td className="row-actions">
                    {job.status === "failed" || job.status === "dead_letter" ? (
                      <button
                        type="button"
                        className="ghost"
                        disabled={!props.canMutate}
                        onClick={() => {
                          props.onMutate(`/v1/admin/jobs/${job.id}/retry`, "Job queued again.");
                        }}
                      >
                        Retry
                      </button>
                    ) : null}
                    {job.status === "queued" || job.status === "running" ? (
                      <ConfirmButton
                        id={`cancel:${job.id}`}
                        armed={props.armed}
                        disabled={!props.canMutate}
                        kind="danger"
                        label="Cancel"
                        confirm="Confirm cancel"
                        onArm={props.onArm}
                        onConfirm={() => {
                          props.onMutate(`/v1/admin/jobs/${job.id}/cancel`, "Job cancelled.");
                        }}
                      />
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {props.nextCursor !== null ? (
        <div className="actions">
          <button type="button" className="ghost" disabled={props.busy} onClick={props.onLoadMore}>
            Load more
          </button>
        </div>
      ) : null}
    </>
  );
}

function CachePanel(props: {
  entries: CacheEntry[];
  cacheState: string;
  cacheTask: string;
  cacheFingerprint: string;
  busy: boolean;
  canMutate: boolean;
  armed: string | null;
  openCacheId: string | null;
  cacheDetail: CacheEntry | null;
  nextCursor: string | null;
  onState: (value: string) => void;
  onTask: (value: string) => void;
  onFingerprint: (value: string) => void;
  onApply: () => void;
  onLoadMore: () => void;
  onToggle: (entry: CacheEntry) => void;
  onArm: (id: string | null) => void;
  onAction: (entry: CacheEntry, action: CacheAction) => void;
}) {
  return (
    <>
      <h2>Cache</h2>
      <p className="lede">
        Quarantine, restore, expire, purge, or regenerate an exact-content entry.
      </p>
      <div className="toolbar">
        <label>
          State
          <select
            value={props.cacheState}
            onChange={(event) => {
              props.onState(event.target.value);
            }}
          >
            <option value="">Any</option>
            <option value="active">active</option>
            <option value="quarantined">quarantined</option>
            <option value="expired">expired</option>
            <option value="superseded">superseded</option>
            <option value="purged">purged</option>
          </select>
        </label>
        <label>
          Task
          <input
            value={props.cacheTask}
            onChange={(event) => {
              props.onTask(event.target.value);
            }}
          />
        </label>
        <label>
          Edition fingerprint
          <input
            value={props.cacheFingerprint}
            onChange={(event) => {
              props.onFingerprint(event.target.value);
            }}
          />
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.entries.length === 0 ? (
        <p className="empty">No cache entries in this filter.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Shared derived cache</caption>
            <thead>
              <tr>
                <th>Task</th>
                <th>State</th>
                <th>Hits</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.entries.map((entry) => {
                const detail =
                  props.openCacheId === entry.id ? (props.cacheDetail ?? entry) : entry;
                return (
                  <CacheRows
                    key={entry.id}
                    entry={detail}
                    open={props.openCacheId === entry.id}
                    canMutate={props.canMutate}
                    armed={props.armed}
                    onToggle={() => {
                      props.onToggle(entry);
                    }}
                    onArm={props.onArm}
                    onAction={props.onAction}
                  />
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {props.nextCursor !== null ? (
        <div className="actions">
          <button type="button" className="ghost" disabled={props.busy} onClick={props.onLoadMore}>
            Load more
          </button>
        </div>
      ) : null}
    </>
  );
}

function CacheRows(props: {
  entry: CacheEntry;
  open: boolean;
  canMutate: boolean;
  armed: string | null;
  onToggle: () => void;
  onArm: (id: string | null) => void;
  onAction: (entry: CacheEntry, action: CacheAction) => void;
}) {
  const entry = props.entry;
  return (
    <>
      <tr className={props.open ? "selected" : undefined}>
        <td>
          <button type="button" className="ghost" onClick={props.onToggle}>
            {props.open ? "Hide" : "Open"} {entry.task}
          </button>
          <div className="mono">
            {entry.sourceLanguage} → {entry.targetLanguage}
          </div>
        </td>
        <td>
          <span className={`pill ${statusTone(entry.state)}`}>{entry.state}</span>
        </td>
        <td>{entry.hitCount}</td>
        <td className="row-actions">
          {cacheActionsFor(entry.state).map((action) =>
            action === "purge" ? (
              <ConfirmButton
                key={action}
                id={`purge:${entry.id}`}
                armed={props.armed}
                disabled={!props.canMutate}
                kind="danger"
                label="purge"
                confirm="Confirm purge"
                onArm={props.onArm}
                onConfirm={() => {
                  props.onAction(entry, action);
                }}
              />
            ) : (
              <button
                key={action}
                type="button"
                className="ghost"
                disabled={!props.canMutate}
                onClick={() => {
                  props.onAction(entry, action);
                }}
              >
                {action}
              </button>
            ),
          )}
        </td>
      </tr>
      {props.open ? (
        <tr className="expand">
          <td colSpan={4}>
            <dl className="detail-grid">
              <dt>Fingerprint</dt>
              <dd className="mono">{entry.editionFingerprint ?? "—"}</dd>
              <dt>Policy</dt>
              <dd>{entry.policyVersion ?? "—"}</dd>
              <dt>Accept / reject</dt>
              <dd>
                {entry.acceptCount ?? 0} / {entry.rejectCount ?? 0}
              </dd>
              <dt>Created</dt>
              <dd>{formatWhen(entry.createdAt)}</dd>
              <dt>Last hit</dt>
              <dd>{formatWhen(entry.lastHitAt)}</dd>
              <dt>Id</dt>
              <dd className="mono">{entry.id}</dd>
            </dl>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function AccessPanel(props: { attempts: BlockedAttempt[] }) {
  return (
    <>
      <h2>Access</h2>
      <p className="lede">
        Passwordless attempts this Worker process blocked for rate or a missing Turnstile challenge.
        Hashed identifiers only.
      </p>
      {props.attempts.length === 0 ? (
        <p className="empty">No blocked attempts in this Worker isolate.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Blocked passwordless attempts</caption>
            <thead>
              <tr>
                <th>When</th>
                <th>Action</th>
                <th>Reason</th>
                <th>Email hash</th>
                <th>IP hash</th>
              </tr>
            </thead>
            <tbody>
              {props.attempts.map((attempt) => (
                <tr key={attempt.id}>
                  <td>{formatWhen(attempt.at)}</td>
                  <td>{attempt.action}</td>
                  <td>
                    <span className={`pill ${statusTone(attempt.reason)}`}>{attempt.reason}</span>
                  </td>
                  <td className="mono">{attempt.emailHash}</td>
                  <td className="mono">{attempt.ipHash}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function metricNumber(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) ? String(value) : "—";
}

function MetricsPanel(props: {
  metrics: MetricsSnapshot | null;
  from: string;
  to: string;
  busy: boolean;
  onFrom: (value: string) => void;
  onTo: (value: string) => void;
  onApply: () => void;
}) {
  const rows =
    props.metrics === null
      ? []
      : [
          ["Users", String(props.metrics.users?.count ?? 0)],
          ["Jobs", String(props.metrics.sync?.jobs ?? 0)],
          ["Jobs queued", metricNumber(props.metrics.sync?.queued)],
          ["Jobs failed", metricNumber(props.metrics.sync?.failed)],
          ["Cache entries", String(props.metrics.llm?.cacheEntries ?? 0)],
          ["Qwen requests", String(props.metrics.llm?.qwenRequests ?? 0)],
          ["Qwen ok", String(props.metrics.llm?.qwenOk ?? 0)],
          ["Qwen failed", String(props.metrics.llm?.qwenFailed ?? 0)],
          ["Flags on", String(props.metrics.flags?.enabled ?? "—")],
          ["Quota keys", String(props.metrics.quotas?.count ?? "—")],
          ["Stored bytes", formatBytes(props.metrics.storage?.bytes)],
        ];
  return (
    <>
      <h2>Metrics</h2>
      <p className="lede">
        Live totals plus Qwen success/fail counts from this Worker isolate for the selected window.
        Search Trace by request id for the matching rows.
      </p>
      <div className="toolbar">
        <label>
          From
          <input
            type="datetime-local"
            value={props.from}
            onChange={(event) => {
              props.onFrom(event.target.value);
            }}
          />
        </label>
        <label>
          To
          <input
            type="datetime-local"
            value={props.to}
            onChange={(event) => {
              props.onTo(event.target.value);
            }}
          />
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.metrics === null ? (
        <p className="empty">No snapshot yet.</p>
      ) : (
        <section className="ledger">
          <h3>
            {formatWhen(props.metrics.from)} – {formatWhen(props.metrics.to)}
          </h3>
          <table className="service-table">
            <thead>
              <tr>
                <th>Measure</th>
                <th>Value</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(([label, value]) => (
                <tr key={label}>
                  <td>{label}</td>
                  <td>{value}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}

function AuditPanel(props: {
  events: AuditEvent[];
  actor: string;
  action: string;
  requestId: string;
  openId: string | null;
  busy: boolean;
  nextCursor: string | null;
  onActor: (value: string) => void;
  onAction: (value: string) => void;
  onRequestId: (value: string) => void;
  onOpen: (id: string | null) => void;
  onApply: () => void;
  onLoadMore: () => void;
}) {
  return (
    <>
      <h2>Audit</h2>
      <p className="lede">
        Immutable operator actions and persisted Qwen failures. Open a row for before/after metadata
        and the request id.
      </p>
      <div className="toolbar">
        <label>
          Actor id
          <input
            value={props.actor}
            onChange={(event) => {
              props.onActor(event.target.value);
            }}
          />
        </label>
        <label>
          Action
          <input
            value={props.action}
            onChange={(event) => {
              props.onAction(event.target.value);
            }}
          />
        </label>
        <label>
          Request id
          <input
            value={props.requestId}
            onChange={(event) => {
              props.onRequestId(event.target.value);
            }}
          />
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.events.length === 0 ? (
        <p className="empty">No audit events loaded.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Operator audit log</caption>
            <thead>
              <tr>
                <th>When</th>
                <th>Action</th>
                <th>Resource</th>
                <th>Reason</th>
              </tr>
            </thead>
            <tbody>
              {props.events.map((event) => (
                <AuditRows
                  key={event.id}
                  event={event}
                  open={props.openId === event.id}
                  onToggle={() => {
                    props.onOpen(props.openId === event.id ? null : event.id);
                  }}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
      {props.nextCursor !== null ? (
        <div className="actions">
          <button type="button" className="ghost" disabled={props.busy} onClick={props.onLoadMore}>
            Load more
          </button>
        </div>
      ) : null}
    </>
  );
}

function AuditRows(props: { event: AuditEvent; open: boolean; onToggle: () => void }) {
  const event = props.event;
  return (
    <>
      <tr className={props.open ? "selected" : undefined}>
        <td>
          <button type="button" className="ghost" onClick={props.onToggle}>
            {formatWhen(event.createdAt)}
          </button>
        </td>
        <td>{event.action}</td>
        <td>
          {event.resourceType}
          <div className="mono">{event.resourceId}</div>
        </td>
        <td>{event.reason}</td>
      </tr>
      {props.open ? (
        <tr className="expand">
          <td colSpan={4}>
            <dl className="detail-grid">
              <dt>Actor</dt>
              <dd className="mono">{event.actorId}</dd>
              <dt>Request id</dt>
              <dd className="mono">{event.traceId ?? "—"}</dd>
              <dt>Metadata</dt>
              <dd className="mono">{JSON.stringify(event.metadata ?? {}, null, 2)}</dd>
            </dl>
          </td>
        </tr>
      ) : null}
    </>
  );
}

function TracePanel(props: {
  events: OperatorEvent[];
  requestId: string;
  kind: string;
  busy: boolean;
  onRequestId: (value: string) => void;
  onKind: (value: string) => void;
  onApply: () => void;
}) {
  return (
    <>
      <h2>Trace</h2>
      <p className="lede">
        Live Worker events for Managed Qwen and operator changes. Paste an app request id to see
        what that call did. Failures are also written to Audit so they survive a new isolate.
      </p>
      <div className="toolbar">
        <label>
          Request id
          <input
            value={props.requestId}
            onChange={(event) => {
              props.onRequestId(event.target.value);
            }}
          />
        </label>
        <label>
          Kind
          <input
            value={props.kind}
            onChange={(event) => {
              props.onKind(event.target.value);
            }}
          />
        </label>
        <button type="button" className="ghost" disabled={props.busy} onClick={props.onApply}>
          Apply
        </button>
      </div>
      {props.events.length === 0 ? (
        <p className="empty">No events in this isolate yet. Probe Qwen on Desk or use the app.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Operator event log</caption>
            <thead>
              <tr>
                <th>When</th>
                <th>Kind</th>
                <th>Task</th>
                <th>Summary</th>
              </tr>
            </thead>
            <tbody>
              {props.events.map((event) => (
                <tr key={event.id}>
                  <td className="mono">{formatWhen(event.at)}</td>
                  <td>
                    <span className={`pill ${statusTone(event.status ?? event.kind)}`}>
                      {event.kind}
                    </span>
                  </td>
                  <td>{event.task ?? "—"}</td>
                  <td>
                    {event.summary}
                    <div className="mono">{event.requestId}</div>
                    {event.detail !== undefined && event.detail !== "" ? (
                      <div>{event.detail}</div>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function FlagRollout(props: {
  value: number;
  disabled: boolean;
  onSave: (rollout: number) => void;
}) {
  const [draft, setDraft] = useState(String(props.value));
  return (
    <span className="row-actions">
      <input
        inputMode="numeric"
        value={draft}
        disabled={props.disabled}
        onChange={(event) => {
          setDraft(event.target.value);
        }}
      />
      <button
        type="button"
        className="ghost"
        disabled={props.disabled}
        onClick={() => {
          const next = Number(draft);
          if (Number.isFinite(next) && next >= 0 && next <= 100) {
            props.onSave(next);
          }
        }}
      >
        Save
      </button>
    </span>
  );
}

function FlagsPanel(props: {
  flags: FeatureFlag[];
  busy: boolean;
  canMutate: boolean;
  onToggle: (flag: FeatureFlag) => void;
  onSave: (flag: FeatureFlag, rollout: number) => void;
}) {
  return (
    <>
      <h2>Flags</h2>
      <p className="lede">
        Kill switches for managed Qwen, account sync, optional cloud media, and maintenance. Rollout
        is the percent of signed-in sessions that should see the flag.
      </p>
      {props.flags.length === 0 ? (
        <p className="empty">No flags loaded.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Product feature flags</caption>
            <thead>
              <tr>
                <th>Key</th>
                <th>State</th>
                <th>Rollout</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.flags.map((flag) => (
                <tr key={flag.key}>
                  <td>
                    <div>{flag.key.replaceAll("_", " ")}</div>
                    <div className="mono">{flag.key}</div>
                  </td>
                  <td>
                    <span className={`pill ${flag.enabled ? "ok" : "warn"}`}>
                      {flag.enabled ? "on" : "off"}
                    </span>
                  </td>
                  <td>
                    <FlagRollout
                      value={flag.rolloutPercent ?? 100}
                      disabled={!props.canMutate || props.busy}
                      onSave={(rollout) => {
                        props.onSave(flag, rollout);
                      }}
                    />
                  </td>
                  <td className="row-actions">
                    <button
                      type="button"
                      className="ghost"
                      disabled={!props.canMutate || props.busy}
                      onClick={() => {
                        props.onToggle(flag);
                      }}
                    >
                      {flag.enabled ? "Disable" : "Enable"}
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function QuotasPanel(props: {
  quotas: Quota[];
  drafts: Record<string, string>;
  busy: boolean;
  canMutate: boolean;
  onDraft: (key: string, value: string) => void;
  onSave: (quota: Quota) => void;
}) {
  return (
    <>
      <h2>Quotas</h2>
      <p className="lede">
        Starter limits from the product plan: 50 managed Qwen tasks a day, 250 MB cloud media, three
        cloud books, and two devices.
      </p>
      {props.quotas.length === 0 ? (
        <p className="empty">No quotas loaded.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Account starter quotas</caption>
            <thead>
              <tr>
                <th>Key</th>
                <th>Used</th>
                <th>Limit</th>
                <th>Period</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.quotas.map((quota) => (
                <tr key={quota.key}>
                  <td>
                    <div>{quota.key.replaceAll("_", " ")}</div>
                    <div className="mono">{quota.key}</div>
                  </td>
                  <td>
                    {quota.key === "cloud_media_bytes" ? formatBytes(quota.used) : quota.used}
                  </td>
                  <td>
                    <input
                      value={props.drafts[quota.key] ?? String(quota.limit)}
                      inputMode="decimal"
                      disabled={!props.canMutate}
                      onChange={(event) => {
                        props.onDraft(quota.key, event.target.value);
                      }}
                    />
                  </td>
                  <td>{formatWhen(quota.periodEndsAt)}</td>
                  <td className="row-actions">
                    <button
                      type="button"
                      className="ghost"
                      disabled={!props.canMutate || props.busy}
                      onClick={() => {
                        props.onSave(quota);
                      }}
                    >
                      Save limit
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function PrivacyPanel(props: {
  requests: PrivacyRequest[];
  busy: boolean;
  canMutate: boolean;
  armed: string | null;
  onArm: (id: string | null) => void;
  onMutate: (path: string, action: "complete" | "cancel", message: string) => void;
}) {
  return (
    <>
      <h2>Privacy</h2>
      <p className="lede">Export and deletion requests. Completing a deletion revokes sessions.</p>
      {props.requests.length === 0 ? (
        <p className="empty">No privacy requests in this window.</p>
      ) : (
        <div className="scroll-table">
          <table className="data">
            <caption>Privacy requests</caption>
            <thead>
              <tr>
                <th>Account</th>
                <th>Kind</th>
                <th>Status</th>
                <th>Opened</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {props.requests.map((request) => (
                <tr key={request.id}>
                  <td>
                    <div className="mono">{request.accountId}</div>
                  </td>
                  <td>{request.kind}</td>
                  <td>
                    <span className={`pill ${statusTone(request.status)}`}>{request.status}</span>
                  </td>
                  <td>{formatWhen(request.createdAt)}</td>
                  <td className="row-actions">
                    {request.status === "queued" || request.status === "running" ? (
                      <>
                        <ConfirmButton
                          id={`privacy-complete:${request.id}`}
                          armed={props.armed}
                          disabled={!props.canMutate || props.busy}
                          label="Complete"
                          confirm="Confirm complete"
                          onArm={props.onArm}
                          onConfirm={() => {
                            props.onMutate(
                              `/v1/admin/privacy-requests/${request.id}/actions`,
                              "complete",
                              "Privacy request completed.",
                            );
                          }}
                        />
                        <ConfirmButton
                          id={`privacy-cancel:${request.id}`}
                          armed={props.armed}
                          disabled={!props.canMutate || props.busy}
                          kind="danger"
                          label="Cancel"
                          confirm="Confirm cancel"
                          onArm={props.onArm}
                          onConfirm={() => {
                            props.onMutate(
                              `/v1/admin/privacy-requests/${request.id}/actions`,
                              "cancel",
                              "Privacy request cancelled.",
                            );
                          }}
                        />
                      </>
                    ) : (
                      <span className="mute">No action</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
