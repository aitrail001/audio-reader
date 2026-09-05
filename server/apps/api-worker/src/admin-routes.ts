import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import {
  assembleManagedPrompt,
  RestPersistenceError,
  validateAssistantPromptDraft,
  validateManagedPromptOutput,
  type CatalogStore,
  type IdentityStore,
  type ManagedPromptSubtask,
  type OpsProductEvent,
  type OpsStore,
} from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import {
  UUID_PATTERN,
  decodeTimeIdCursor,
  fieldError,
  methodNotAllowed,
  notFound,
  pageCursor,
  parseLimit,
  requireAdmin,
  requireDeviceId,
  timeIdCursorPage,
} from "./route-helpers";
import { buildOperatorDiagnostics } from "./diagnostics";
import { listOperatorEvents, operatorEventFromAudit, recordOperatorEvent } from "./operator-events";
import { captureProductEvent, toProductEvent } from "./product-events";
import {
  buildProductAnalytics,
  type AnalyticsFilters,
  type AnalyticsInterval,
} from "./product-analytics";
import {
  OperatorWrappingNotConfiguredError,
  type RuntimeConfigPut,
  type RuntimeConfigService,
} from "./runtime-config";
import type { AccountSyncReadinessService } from "./account-sync-readiness";

type AdminUser = components["schemas"]["AdminUser"];
type AdminUserProgress = components["schemas"]["AdminUserProgress"];
type LlmPolicy = components["schemas"]["LlmPolicy"];
type CacheEntry = components["schemas"]["CacheEntry"];
type Job = components["schemas"]["Job"];
type AuditEvent = components["schemas"]["AuditEvent"];
type MetricsSnapshot = components["schemas"]["MetricsSnapshot"];
type FeatureFlag = components["schemas"]["FeatureFlag"];
type Quota = components["schemas"]["Quota"];
type PrivacyRequest = components["schemas"]["PrivacyRequest"];
type ProductAnalytics = components["schemas"]["ProductAnalytics"];

type AdminRole =
  "support_readonly" | "operator" | "privacy_officer" | "billing_operator" | "superadmin";

type AdminCapability =
  | "users.read"
  | "users.manage"
  | "roles.manage"
  | "policies.read"
  | "policies.manage"
  | "ai.probe"
  | "runtime.read"
  | "runtime.manage"
  | "cache.read"
  | "cache.manage"
  | "jobs.read"
  | "jobs.manage"
  | "flags.read"
  | "flags.manage"
  | "quotas.read"
  | "quotas.manage"
  | "privacy.read"
  | "privacy.manage"
  | "metrics.read"
  | "activity.read"
  | "access.read"
  | "diagnostics.read"
  | "admin.full";

const ROLE_CAPABILITIES: Readonly<Record<AdminRole, readonly AdminCapability[]>> = {
  support_readonly: ["users.read", "activity.read", "access.read"],
  operator: [
    "users.read",
    "users.manage",
    "jobs.read",
    "jobs.manage",
    "flags.read",
    "flags.manage",
    "metrics.read",
    "activity.read",
    "access.read",
  ],
  privacy_officer: ["users.read", "privacy.read", "privacy.manage", "activity.read"],
  billing_operator: ["quotas.read", "quotas.manage", "metrics.read"],
  superadmin: [
    "users.read",
    "users.manage",
    "roles.manage",
    "policies.read",
    "policies.manage",
    "ai.probe",
    "runtime.read",
    "runtime.manage",
    "cache.read",
    "cache.manage",
    "jobs.read",
    "jobs.manage",
    "flags.read",
    "flags.manage",
    "quotas.read",
    "quotas.manage",
    "privacy.read",
    "privacy.manage",
    "metrics.read",
    "activity.read",
    "access.read",
    "diagnostics.read",
    "admin.full",
  ],
};

const USER_ITEM = /^\/v1\/admin\/users\/([^/]+)$/;
const USER_PROGRESS = /^\/v1\/admin\/users\/([^/]+)\/progress$/;
const USER_SUSPEND = /^\/v1\/admin\/users\/([^/]+)\/suspend$/;
const USER_UNSUSPEND = /^\/v1\/admin\/users\/([^/]+)\/unsuspend$/;
const USER_REVOKE = /^\/v1\/admin\/users\/([^/]+)\/revoke-sessions$/;
const USER_GRANT_ADMIN = /^\/v1\/admin\/users\/([^/]+)\/grant-admin$/;
const POLICY_ITEM = /^\/v1\/admin\/llm\/policies\/([^/]+)$/;
const POLICY_PREVIEW = /^\/v1\/admin\/llm\/policies\/([^/]+)\/preview$/;
const POLICY_PROBE = /^\/v1\/admin\/llm\/policies\/([^/]+)\/probe$/;
const CACHE_ITEM = /^\/v1\/admin\/cache\/([^/]+)$/;
const CACHE_ACTION = /^\/v1\/admin\/cache\/([^/]+)\/actions$/;
const JOB_RETRY = /^\/v1\/admin\/jobs\/([^/]+)\/retry$/;
const JOB_CANCEL = /^\/v1\/admin\/jobs\/([^/]+)\/cancel$/;
const FLAG_ITEM = /^\/v1\/admin\/feature-flags\/([^/]+)$/;
const QUOTA_ITEM = /^\/v1\/admin\/quotas\/([^/]+)$/;
const PRIVACY_ACTION = /^\/v1\/admin\/privacy-requests\/([^/]+)\/actions$/;

export type AdminRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  ops?: OpsStore;
  identity?: IdentityStore;
  catalog?: CatalogStore;
  runtime?: RuntimeConfigService;
  accountSyncReadiness: AccountSyncReadinessService;
};

export function isAdminPath(path: string): boolean {
  return (
    path === "/v1/admin/users" ||
    path === "/v1/admin/legacy-cleanup" ||
    path === "/v1/admin/capabilities" ||
    path === "/v1/admin/llm/policies" ||
    path === "/v1/admin/cache" ||
    path === "/v1/admin/jobs" ||
    path === "/v1/admin/metrics" ||
    path === "/v1/admin/product-analytics" ||
    path === "/v1/admin/audit-events" ||
    path === "/v1/admin/runtime-config" ||
    path === "/v1/admin/diagnostics" ||
    path === "/v1/admin/events" ||
    path === "/v1/admin/feature-flags" ||
    path === "/v1/admin/account-sync-readiness" ||
    path === "/v1/admin/quotas" ||
    path === "/v1/admin/privacy-requests" ||
    path === "/v1/admin/product-events" ||
    USER_ITEM.test(path) ||
    USER_PROGRESS.test(path) ||
    USER_SUSPEND.test(path) ||
    USER_UNSUSPEND.test(path) ||
    USER_REVOKE.test(path) ||
    USER_GRANT_ADMIN.test(path) ||
    POLICY_ITEM.test(path) ||
    POLICY_PREVIEW.test(path) ||
    POLICY_PROBE.test(path) ||
    CACHE_ITEM.test(path) ||
    CACHE_ACTION.test(path) ||
    JOB_RETRY.test(path) ||
    JOB_CANCEL.test(path) ||
    FLAG_ITEM.test(path) ||
    QUOTA_ITEM.test(path) ||
    PRIVACY_ACTION.test(path)
  );
}

export function adminMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const upper = method.toUpperCase();
  if (
    (path === "/v1/admin/users" ||
      path === "/v1/admin/capabilities" ||
      path === "/v1/admin/llm/policies" ||
      path === "/v1/admin/cache" ||
      path === "/v1/admin/jobs" ||
      path === "/v1/admin/metrics" ||
      path === "/v1/admin/product-analytics" ||
      path === "/v1/admin/audit-events" ||
      path === "/v1/admin/feature-flags" ||
      path === "/v1/admin/account-sync-readiness" ||
      path === "/v1/admin/quotas" ||
      path === "/v1/admin/privacy-requests" ||
      path === "/v1/admin/diagnostics" ||
      path === "/v1/admin/events" ||
      path === "/v1/admin/product-events" ||
      USER_ITEM.test(path) ||
      USER_PROGRESS.test(path) ||
      CACHE_ITEM.test(path)) &&
    upper !== "GET" &&
    upper !== "HEAD"
  ) {
    return methodNotAllowed(["GET", "HEAD"], requestId);
  }
  if ((POLICY_PREVIEW.test(path) || POLICY_PROBE.test(path)) && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (path === "/v1/admin/legacy-cleanup" && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (path === "/v1/admin/runtime-config") {
    if (upper !== "GET" && upper !== "HEAD" && upper !== "PUT") {
      return methodNotAllowed(["GET", "HEAD", "PUT"], requestId);
    }
    return undefined;
  }
  if (
    (POLICY_ITEM.test(path) || FLAG_ITEM.test(path) || QUOTA_ITEM.test(path)) &&
    upper !== "PATCH"
  ) {
    return methodNotAllowed(["PATCH"], requestId);
  }
  if (
    (USER_SUSPEND.test(path) ||
      USER_UNSUSPEND.test(path) ||
      USER_REVOKE.test(path) ||
      USER_GRANT_ADMIN.test(path) ||
      CACHE_ACTION.test(path) ||
      JOB_RETRY.test(path) ||
      JOB_CANCEL.test(path) ||
      PRIVACY_ACTION.test(path)) &&
    upper !== "POST"
  ) {
    return methodNotAllowed(["POST"], requestId);
  }
  return undefined;
}

function isAdminRole(value: string): value is AdminRole {
  return value in ROLE_CAPABILITIES;
}

function capabilitiesFor(roles: readonly AdminRole[]): Set<AdminCapability> {
  return new Set(roles.flatMap((role) => ROLE_CAPABILITIES[role]));
}

/**
 * A scoped operator may manage ordinary users, but only a superadmin may change another
 * superadmin's account or sessions. Resolve this at the route boundary before parsing the body or
 * entering idempotency so denied requests cannot perform or record a partial mutation.
 */
async function protectSuperadminTarget(
  context: AdminRouteContext,
  actorRoles: readonly AdminRole[],
  targetId: string,
): Promise<Response | undefined> {
  if (actorRoles.includes("superadmin")) {
    return undefined;
  }
  const targetRoles = await context.identity?.adminRoles(targetId);
  if (targetRoles !== undefined && !targetRoles.includes("superadmin")) {
    return undefined;
  }
  console.warn(
    JSON.stringify({
      level: "warn",
      component: "admin-authorization",
      message: "admin_target_protected",
      requestId: context.requestId,
      targetId,
      outcome: "denied",
    }),
  );
  return problemResponse({
    status: 403,
    code: "forbidden",
    title: "Forbidden",
    detail: "This account cannot be changed with the current administrative role.",
    traceId: context.requestId,
  });
}

/**
 * Resolve authorization before any admin handler reads data or parses a mutation body. This keeps
 * scoped roles from inheriting the historical generic-admin access by reaching a later branch.
 */
function capabilityFor(path: string, method: string, url: URL): AdminCapability | undefined {
  const write = method.toUpperCase() !== "GET" && method.toUpperCase() !== "HEAD";
  if (path === "/v1/admin/capabilities") return undefined;
  if (path === "/v1/admin/users" || USER_ITEM.test(path) || USER_PROGRESS.test(path)) {
    return "users.read";
  }
  if (USER_SUSPEND.test(path) || USER_UNSUSPEND.test(path) || USER_REVOKE.test(path)) {
    return "users.manage";
  }
  if (path === "/v1/admin/legacy-cleanup") return "users.manage";
  if (USER_GRANT_ADMIN.test(path)) return "roles.manage";
  if (path === "/v1/admin/runtime-config") {
    return write ? "runtime.manage" : "runtime.read";
  }
  if (path === "/v1/admin/llm/policies") return "policies.read";
  if (POLICY_ITEM.test(path) || POLICY_PREVIEW.test(path) || POLICY_PROBE.test(path)) {
    return "policies.manage";
  }
  if (path === "/v1/admin/cache" || CACHE_ITEM.test(path) || path === "/v1/admin/jobs") {
    return path === "/v1/admin/jobs" ? "jobs.read" : "cache.read";
  }
  if (CACHE_ACTION.test(path)) return "cache.manage";
  if (JOB_RETRY.test(path) || JOB_CANCEL.test(path)) return "jobs.manage";
  if (path === "/v1/admin/feature-flags") return "flags.read";
  if (path === "/v1/admin/account-sync-readiness") return "flags.read";
  if (FLAG_ITEM.test(path)) return "flags.manage";
  if (path === "/v1/admin/quotas") return "quotas.read";
  if (QUOTA_ITEM.test(path)) return "quotas.manage";
  if (path === "/v1/admin/privacy-requests") return "privacy.read";
  if (PRIVACY_ACTION.test(path)) return "privacy.manage";
  if (path === "/v1/admin/diagnostics" && url.searchParams.get("probe") === "complete") {
    return "ai.probe";
  }
  if (path === "/v1/admin/diagnostics") return "diagnostics.read";
  if (path === "/v1/admin/metrics" || path === "/v1/admin/product-analytics") {
    return "metrics.read";
  }
  if (
    path === "/v1/admin/audit-events" ||
    path === "/v1/admin/events" ||
    path === "/v1/admin/product-events"
  ) {
    return "activity.read";
  }
  return "admin.full";
}

export async function handleAdminRoute(context: AdminRouteContext): Promise<Response | undefined> {
  const url = new URL(context.request.url);
  const path = url.pathname;
  if (!isAdminPath(path)) {
    return undefined;
  }
  const methodError = adminMethodError(path, context.request.method, context.requestId);
  if (methodError !== undefined) {
    return methodError;
  }
  const principal = await requireAdmin(context);
  if (principal instanceof Response) {
    return principal;
  }
  const storedRoles = (await context.identity?.adminRoles(principal.accountId)) ?? [];
  const roles = (principal.adminRoles.length > 0 ? principal.adminRoles : storedRoles).filter(
    isAdminRole,
  );
  const capabilities = capabilitiesFor(roles);
  const requiredCapability = capabilityFor(path, context.request.method, url);
  if (requiredCapability !== undefined && !capabilities.has(requiredCapability)) {
    console.warn(
      JSON.stringify({
        level: "warn",
        component: "admin-authorization",
        message: "admin_capability_denied",
        requestId: context.requestId,
        actorId: principal.accountId,
        capability: requiredCapability,
        outcome: "denied",
      }),
    );
    return problemResponse({
      status: 403,
      code: "forbidden",
      title: "Forbidden",
      detail: `This action requires the ${requiredCapability} capability.`,
      traceId: context.requestId,
    });
  }
  if (path === "/v1/admin/capabilities") {
    return asHead(context.request, jsonResponse({ roles, capabilities: [...capabilities].sort() }));
  }
  const ops = context.ops;
  if (ops === undefined) {
    return notFound(context.requestId, "Admin services are not configured.");
  }
  if (path === "/v1/admin/legacy-cleanup") {
    // Execution fingerprints the untouched request body inside the idempotency boundary.
    const body = await readJsonObject(context.request.clone(), context.requestId);
    if (!body.ok) return body.response;
    const userId = body.value.userId;
    if (typeof userId !== "string" || !UUID_PATTERN.test(userId)) {
      return fieldError(context.requestId, "userId", "userId must be a UUID.");
    }
    if (typeof body.value.dryRun !== "boolean") {
      return fieldError(context.requestId, "dryRun", "dryRun must be explicit.");
    }
    const inspected = await ops.cleanupObsoleteV1Data(userId, false);
    if (body.value.dryRun) {
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "legacy_cleanup_dry_run",
        resourceType: "account",
        resourceId: userId,
        reason: "Explicit obsolete v1 data cleanup dry-run.",
        traceId: context.requestId,
        metadata: { ...inspected, objectKeys: inspected.objectKeys.length },
      });
      return jsonResponse(inspected);
    }
    return withIdempotency(
      context.idempotencyStore,
      context.request,
      async () => {
        const job = await ops.createJob({
          accountId: userId,
          kind: "legacy_cleanup",
          payload: { requestedBy: principal.accountId, requestId: context.requestId },
        });
        await ops.appendAudit({
          actorId: principal.accountId,
          action: "legacy_cleanup_execute_requested",
          resourceType: "account",
          resourceId: userId,
          reason: "Explicit obsolete v1 data cleanup execution.",
          traceId: context.requestId,
          metadata: { jobId: job.id, ...inspected, objectKeys: inspected.objectKeys.length },
        });
        return jsonResponse({ jobId: job.id, status: job.status, inspected }, 202);
      },
      context.requestId,
      principal,
    );
  }
  if (path === "/v1/admin/users") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const query = (url.searchParams.get("query") ?? "").toLowerCase();
    const users = (await ops.adminUsers()).filter((user) =>
      query === ""
        ? true
        : user.email.toLowerCase().includes(query) || user.accountId.includes(query),
    );
    return asHead(
      context.request,
      jsonResponse(
        pageCursor(
          users.map((user) => toAdminUser(user)),
          url.searchParams.get("cursor"),
          limit,
        ),
      ),
    );
  }
  const userProgress = USER_PROGRESS.exec(path);
  if (userProgress?.[1] !== undefined) {
    return readUserProgress(context, principal, ops, userProgress[1]);
  }
  const userItem = USER_ITEM.exec(path);
  if (userItem?.[1] !== undefined) {
    const users = await ops.adminUsers();
    const user = users.find((item) => item.accountId === userItem[1] || item.id === userItem[1]);
    if (user === undefined) {
      return notFound(context.requestId);
    }
    const quotas = await ops.quotasFor(user.accountId);
    const devices = (await context.identity?.listDevices(user.accountId)) ?? [];
    const books = (await context.catalog?.listBooks(user.accountId)) ?? [];
    return asHead(
      context.request,
      jsonResponse(
        toAdminUser(user, {
          quotas: quotas.map(toQuota),
          devices: devices.map((device) => ({
            id: device.id,
            platform: device.platform,
            name: device.name,
            appVersion: device.appVersion,
            lastSeenAt: device.lastSeenAt,
            revoked: device.revoked,
          })),
          books: books.map((book) => ({
            id: book.id,
            title: book.title,
            chapterCount: book.chapterCount,
          })),
        }),
      ),
    );
  }
  const suspend = USER_SUSPEND.exec(path);
  if (suspend?.[1] !== undefined) {
    const protectedTarget = await protectSuperadminTarget(context, roles, suspend[1]);
    if (protectedTarget !== undefined) return protectedTarget;
    return mutateUser(context, principal, ops, suspend[1], "suspended", "suspend_user");
  }
  const unsuspend = USER_UNSUSPEND.exec(path);
  if (unsuspend?.[1] !== undefined) {
    const protectedTarget = await protectSuperadminTarget(context, roles, unsuspend[1]);
    if (protectedTarget !== undefined) return protectedTarget;
    return mutateUser(context, principal, ops, unsuspend[1], "active", "unsuspend_user");
  }
  const revoke = USER_REVOKE.exec(path);
  if (revoke?.[1] !== undefined) {
    const protectedTarget = await protectSuperadminTarget(context, roles, revoke[1]);
    if (protectedTarget !== undefined) return protectedTarget;
    return revokeSessions(context, principal, ops, revoke[1]);
  }
  const grantAdmin = USER_GRANT_ADMIN.exec(path);
  if (grantAdmin?.[1] !== undefined) {
    return grantAdminRole(context, principal, ops, grantAdmin[1]);
  }
  if (path === "/v1/admin/runtime-config") {
    if (context.request.method.toUpperCase() === "PUT") {
      return putRuntimeConfig(context, principal);
    }
    if (context.runtime === undefined) {
      return notFound(context.requestId, "Runtime configuration is not available.");
    }
    return asHead(context.request, jsonResponse(await context.runtime.view()));
  }
  if (path === "/v1/admin/llm/policies") {
    const policies = await ops.listPolicies();
    return asHead(context.request, jsonResponse(policies.map(toPolicy)));
  }
  const policyItem = POLICY_ITEM.exec(path);
  if (policyItem?.[1] !== undefined) {
    return patchPolicy(context, principal, ops, policyItem[1]);
  }
  const policyPreview = POLICY_PREVIEW.exec(path);
  if (policyPreview?.[1] !== undefined) {
    return previewPolicy(context, ops, policyPreview[1], false, principal);
  }
  const policyProbe = POLICY_PROBE.exec(path);
  if (policyProbe?.[1] !== undefined) {
    return previewPolicy(context, ops, policyProbe[1], true, principal);
  }
  if (path === "/v1/admin/cache") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const task = url.searchParams.get("task");
    const state = url.searchParams.get("state");
    const editionFingerprint = url.searchParams.get("editionFingerprint");
    const items = await ops.listCache({
      ...(task === null || task === "" ? {} : { task }),
      ...(state === null || state === "" ? {} : { state }),
      ...(editionFingerprint === null || editionFingerprint === "" ? {} : { editionFingerprint }),
    });
    return asHead(
      context.request,
      jsonResponse(pageCursor(items.map(toCache), url.searchParams.get("cursor"), limit)),
    );
  }
  const cacheItem = CACHE_ITEM.exec(path);
  if (cacheItem?.[1] !== undefined) {
    const entry = await ops.getCache(cacheItem[1]);
    return entry === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toCache(entry)));
  }
  const cacheAction = CACHE_ACTION.exec(path);
  if (cacheAction?.[1] !== undefined) {
    return actOnCache(context, principal, ops, cacheAction[1]);
  }
  if (path === "/v1/admin/jobs") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const status = url.searchParams.get("status");
    const items = await ops.listJobs({
      ...(status === null || status === "" ? {} : { status }),
    });
    return asHead(
      context.request,
      jsonResponse(pageCursor(items.map(toJob), url.searchParams.get("cursor"), limit)),
    );
  }
  const retry = JOB_RETRY.exec(path);
  if (retry?.[1] !== undefined) {
    return jobAction(context, principal, ops, retry[1], "queued", "retry_job");
  }
  const cancel = JOB_CANCEL.exec(path);
  if (cancel?.[1] !== undefined) {
    return jobAction(context, principal, ops, cancel[1], "cancelled", "cancel_job");
  }
  if (path === "/v1/admin/metrics") {
    const fromParam = url.searchParams.get("from");
    const toParam = url.searchParams.get("to");
    const from =
      fromParam === null || fromParam === ""
        ? new Date(Date.now() - 86_400_000)
        : new Date(fromParam);
    const to = toParam === null || toParam === "" ? new Date() : new Date(toParam);
    const users = await ops.adminUsers();
    const jobs = await ops.listJobs();
    const cache = await ops.listCache();
    const flags = await ops.listFlags();
    const quotas = await ops.quotasFor("");
    const live = listOperatorEvents({ limit: 250 });
    const inWindow = live.filter((event) => {
      const at = Date.parse(event.at);
      return at >= from.getTime() && at <= to.getTime();
    });
    const jobsByStatus: Record<string, number> = {};
    for (const job of jobs) {
      jobsByStatus[job.status] = (jobsByStatus[job.status] ?? 0) + 1;
    }
    const usageEvents = await ops.listProductEvents({
      from: from.toISOString(),
      to: to.toISOString(),
      limit: 500,
    });
    const byName: Record<string, number> = {};
    for (const event of usageEvents) {
      byName[event.name] = (byName[event.name] ?? 0) + 1;
    }
    const snapshot: MetricsSnapshot = {
      from: from.toISOString(),
      to: to.toISOString(),
      users: { count: users.length },
      sync: { jobs: jobs.length, ...jobsByStatus },
      llm: {
        cacheEntries: cache.length,
        qwenOk: inWindow.filter((event) => event.kind === "managed_qwen_ok").length,
        qwenFailed: inWindow.filter((event) => event.kind === "managed_qwen_failed").length,
        qwenRequests: inWindow.filter((event) => event.kind === "managed_qwen_request").length,
      },
      storage: { bytes: users.reduce((sum, user) => sum + user.storageBytes, 0) },
      flags: {
        enabled: flags.filter((flag) => flag.enabled).length,
        disabled: flags.filter((flag) => !flag.enabled).length,
      },
      quotas: { count: quotas.length },
      usage: {
        events: usageEvents.length,
        failed: usageEvents.filter((event) => event.outcome === "failed").length,
        ...byName,
      },
    };
    return asHead(context.request, jsonResponse(snapshot));
  }
  if (path === "/v1/admin/product-analytics") {
    const from = analyticsDate(url.searchParams.get("from"), Date.now() - 7 * 86_400_000);
    const to = analyticsDate(url.searchParams.get("to"), Date.now());
    if (from === null || to === null || from.getTime() >= to.getTime()) {
      return fieldError(
        context.requestId,
        "from",
        "from and to must be valid date-times and from must be before to.",
      );
    }
    const intervalParam = url.searchParams.get("interval") ?? "day";
    if (intervalParam !== "hour" && intervalParam !== "day" && intervalParam !== "week") {
      return fieldError(context.requestId, "interval", "interval must be hour, day, or week.");
    }
    const filters = analyticsFilters(url);
    const events = await listCompleteProductAnalyticsWindow(ops, {
      from: from.toISOString(),
      to: to.toISOString(),
    });
    const analytics: ProductAnalytics = buildProductAnalytics(events, {
      from: from.toISOString(),
      to: to.toISOString(),
      interval: intervalParam satisfies AnalyticsInterval,
      filters,
    });
    return asHead(context.request, jsonResponse(analytics));
  }
  if (path === "/v1/admin/audit-events") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const decodedCursor = decodeTimeIdCursor(url.searchParams.get("cursor"));
    if (!decodedCursor.ok) {
      return fieldError(context.requestId, "cursor", "cursor must be a valid continuation token.");
    }
    const actorId = url.searchParams.get("actorId") ?? "";
    const action = url.searchParams.get("action") ?? "";
    const requestId = url.searchParams.get("requestId") ?? "";
    const resourceType = url.searchParams.get("resourceType") ?? "";
    const resourceId = url.searchParams.get("resourceId") ?? "";
    const events = await ops.listAudit({
      ...(actorId.trim() === "" ? {} : { actorId: actorId.trim() }),
      ...(action.trim() === "" ? {} : { action: action.trim() }),
      ...(requestId.trim() === "" ? {} : { requestId: requestId.trim() }),
      ...(resourceType.trim() === "" ? {} : { resourceType: resourceType.trim() }),
      ...(resourceId.trim() === "" ? {} : { resourceId: resourceId.trim() }),
      ...(decodedCursor.cursor === null ? {} : { cursor: decodedCursor.cursor }),
      limit: limit + 1,
    });
    const page = timeIdCursorPage(events, limit);
    return asHead(
      context.request,
      jsonResponse({ items: page.items.map(toAudit), nextCursor: page.nextCursor }),
    );
  }
  if (path === "/v1/admin/product-events") {
    const limit = parseLimit(url, context.requestId, 500);
    if (limit instanceof Response) {
      return limit;
    }
    const decodedCursor = decodeTimeIdCursor(url.searchParams.get("cursor"));
    if (!decodedCursor.ok) {
      return fieldError(context.requestId, "cursor", "cursor must be a valid continuation token.");
    }
    const name = url.searchParams.get("name") ?? "";
    const accountId = url.searchParams.get("accountId") ?? "";
    const normalizedAccountId = accountId.trim();
    const productRequestId = url.searchParams.get("requestId") ?? "";
    const from = url.searchParams.get("from") ?? "";
    const to = url.searchParams.get("to") ?? "";
    if (normalizedAccountId !== "") {
      const consented = (await ops.analyticsPreference(normalizedAccountId))
        .operatorLearningAnalyticsEnabled;
      // Individual behavior is more sensitive than aggregate activity, so every attempted read is durable.
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "admin_user_activity_read",
        resourceType: "user_activity",
        resourceId: normalizedAccountId,
        reason: "Account-scoped product activity viewed.",
        traceId: context.requestId,
        metadata: { consented },
      });
      console.warn(
        JSON.stringify({
          level: "info",
          message: "admin_user_activity_read",
          component: "admin-activity",
          requestId: context.requestId,
          actorId: principal.accountId,
          accountId: normalizedAccountId,
          consented,
          outcome: consented ? "ok" : "withheld",
        }),
      );
      if (!consented) {
        return asHead(
          context.request,
          jsonResponse(pageCursor([], url.searchParams.get("cursor"), limit)),
        );
      }
    }
    const events = await ops.listProductEvents({
      ...(normalizedAccountId === "" ? {} : { accountId: normalizedAccountId }),
      ...(name.trim() === "" ? {} : { name: name.trim() }),
      ...(productRequestId.trim() === "" ? {} : { requestId: productRequestId.trim() }),
      ...(from.trim() === "" ? {} : { from: from.trim() }),
      ...(to.trim() === "" ? {} : { to: to.trim() }),
      ...(decodedCursor.cursor === null ? {} : { cursor: decodedCursor.cursor }),
      limit: limit + 1,
    });
    const page = timeIdCursorPage(events, limit);
    const productEvents = await Promise.all(page.items.map(toProductEvent));
    return asHead(
      context.request,
      jsonResponse({ items: productEvents, nextCursor: page.nextCursor }),
    );
  }
  if (path === "/v1/admin/events") {
    const live = listOperatorEvents({
      ...(url.searchParams.get("requestId")?.trim()
        ? { requestId: url.searchParams.get("requestId") ?? "" }
        : {}),
      ...(url.searchParams.get("kind")?.trim() ? { kind: url.searchParams.get("kind") ?? "" } : {}),
      ...(url.searchParams.get("task")?.trim() ? { task: url.searchParams.get("task") ?? "" } : {}),
      limit: 100,
    });
    if (live.length > 0) {
      return asHead(context.request, jsonResponse(live));
    }
    const persisted = await ops.listAudit({
      ...(url.searchParams.get("requestId")?.trim()
        ? { requestId: url.searchParams.get("requestId") ?? "" }
        : {}),
    });
    const kind = url.searchParams.get("kind")?.trim() ?? "";
    const task = url.searchParams.get("task")?.trim() ?? "";
    return asHead(
      context.request,
      jsonResponse(
        persisted
          .filter(
            (event) =>
              event.action.startsWith("managed_qwen") || event.action.startsWith("operator_"),
          )
          .map(operatorEventFromAudit)
          .filter((event) => (kind === "" ? true : event.kind === kind))
          .filter((event) => (task === "" ? true : event.task === task))
          .slice(0, 100),
      ),
    );
  }
  if (path === "/v1/admin/diagnostics") {
    if (context.runtime === undefined) {
      return notFound(context.requestId, "Runtime configuration is not available.");
    }
    const runtimeView = await context.runtime.view();
    const flags = await ops.listFlags();
    const quotas = await ops.quotasFor("");
    const policies = await ops.listPolicies();
    const client = await context.runtime.resolveQwenClient({ useFakes: false });
    const probe = url.searchParams.get("probe");
    const snapshot = await buildOperatorDiagnostics({
      runtime: runtimeView,
      flags: flags.map(toFeatureFlag),
      quotas: quotas.map(toQuota),
      policies: policies.map(toPolicy),
      qwen: client,
      probeComplete: probe === "complete",
      requestId: context.requestId,
      ops,
    });
    if (probe === "complete") {
      const status = snapshot.qwenComplete?.status ?? "unavailable";
      const outcome = status === "ok" ? "ok" : "failed";
      const model = snapshot.qwenComplete?.model ?? runtimeView.qwen.model;
      await captureProductEvent(ops, {
        accountId: principal.accountId,
        name: "operator.qwen_probe",
        purpose: "operational",
        outcome,
        requestId: context.requestId,
        properties: { model, status },
      });
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "operator_qwen_probe",
        resourceType: "managed_qwen",
        resourceId: model || "default",
        reason: "Operator completion probe",
        traceId: context.requestId,
        metadata: { model, status },
      });
      recordOperatorEvent({
        kind: "operator_qwen_probe",
        requestId: context.requestId,
        task: "translation",
        status: outcome,
        summary:
          status === "ok"
            ? `Operator Qwen probe succeeded with ${model || "the configured model"}.`
            : `Operator Qwen probe returned ${status} with ${model || "the configured model"}.`,
        metadata: { model, status },
      });
    }
    return asHead(context.request, jsonResponse(snapshot));
  }
  if (path === "/v1/admin/feature-flags") {
    const flags = await ops.listFlags();
    return asHead(context.request, jsonResponse(flags.map(toFeatureFlag)));
  }
  if (path === "/v1/admin/account-sync-readiness") {
    const requested =
      (await ops.listFlags()).find((flag) => flag.key === "account_sync")?.enabled === true;
    return asHead(
      context.request,
      jsonResponse(
        await context.accountSyncReadiness.read(requested, {
          force: url.searchParams.get("probe") === "true",
        }),
      ),
    );
  }
  const flagItem = FLAG_ITEM.exec(path);
  if (flagItem?.[1] !== undefined) {
    return patchFlag(context, principal, ops, decodeURIComponent(flagItem[1]));
  }
  if (path === "/v1/admin/quotas") {
    const quotas = await ops.quotasFor("");
    return asHead(context.request, jsonResponse(quotas.map(toQuota)));
  }
  const quotaItem = QUOTA_ITEM.exec(path);
  if (quotaItem?.[1] !== undefined) {
    return patchQuota(context, principal, ops, decodeURIComponent(quotaItem[1]));
  }
  if (path === "/v1/admin/privacy-requests") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const status = url.searchParams.get("status");
    const items = await ops.listPrivacyRequests({
      ...(status === null || status === "" ? {} : { status }),
    });
    return asHead(
      context.request,
      jsonResponse(pageCursor(items.map(toPrivacy), url.searchParams.get("cursor"), limit)),
    );
  }
  const privacyAction = PRIVACY_ACTION.exec(path);
  if (privacyAction?.[1] !== undefined) {
    return actOnPrivacy(context, principal, ops, privacyAction[1]);
  }
  return undefined;
}

/** Read the requested retained window with stable keyset pages so filters never see a truncated prefix. */
async function listCompleteProductAnalyticsWindow(
  ops: OpsStore,
  range: { from: string; to: string },
): Promise<OpsProductEvent[]> {
  const pageSize = 1_000;
  const events: OpsProductEvent[] = [];
  let cursor: { createdAt: string; id: string } | undefined;
  const seenCursors = new Set<string>();
  for (;;) {
    const page = await ops.listProductEvents({
      ...range,
      ...(cursor === undefined ? {} : { cursor }),
      limit: pageSize,
    });
    events.push(...page);
    if (page.length < pageSize) return events;
    const last = page.at(-1);
    if (last === undefined) return events;
    const cursorKey = `${last.createdAt}\u0000${last.id}`;
    if (seenCursors.has(cursorKey)) {
      throw new Error("Product analytics pagination did not advance.");
    }
    seenCursors.add(cursorKey);
    cursor = { createdAt: last.createdAt, id: last.id };
  }
}

/**
 * This endpoint returns only bounded counts and timestamps. Raw sync payloads can contain book
 * text, transcript content, definitions, translations, and notes, so the Worker must never fetch
 * or log them while serving Operator.
 */
async function readUserProgress(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  userId: string,
): Promise<Response> {
  if (!UUID_PATTERN.test(userId)) {
    return fieldError(context.requestId, "userId", "userId must be a UUID.");
  }
  const users = await ops.adminUsers();
  const user = users.find((item) => item.accountId === userId || item.id === userId);
  if (user === undefined || user.status === "deleted" || user.status === "deletion_pending") {
    return notFound(context.requestId);
  }
  const preference = await ops.analyticsPreference(user.accountId);
  let summary;
  try {
    summary = await ops.userProgressSummary(user.accountId);
  } catch (error) {
    if (error instanceof RestPersistenceError) {
      return persistenceFailed(context.requestId, "Could not load user progress", error);
    }
    throw error;
  }
  const sync = summary?.sync ?? {
    lastSuccessfulAt: null,
    lastDevice: null,
    entityCounts: [],
    pendingCount: null,
    conflictCount: 0,
  };
  const consented = preference.operatorLearningAnalyticsEnabled;
  await ops.appendAudit({
    actorId: principal.accountId,
    action: "admin_user_progress_read",
    resourceType: "user_progress",
    resourceId: user.accountId,
    reason: "Support-safe user progress summary viewed.",
    traceId: context.requestId,
    metadata: {
      consented,
      sectionsReturned: consented ? ["sync", "reading", "review", "learning"] : ["sync"],
    },
  });
  console.warn(
    JSON.stringify({
      level: "info",
      message: "admin_user_progress_read",
      component: "admin-users",
      requestId: context.requestId,
      actorId: principal.accountId,
      accountId: user.accountId,
      consented,
      outcome: "ok",
    }),
  );
  const payload: AdminUserProgress = {
    accountId: user.accountId,
    generatedAt: summary?.generatedAt ?? new Date().toISOString(),
    expiresAt: summary?.expiresAt ?? null,
    consent: preference,
    sync,
    reading: consented ? (summary?.reading ?? null) : null,
    review: consented ? (summary?.review ?? null) : null,
    learning: consented ? (summary?.learning ?? null) : null,
    activity: {
      eventsPath: `/v1/admin/product-events?accountId=${encodeURIComponent(user.accountId)}`,
      auditPath: `/v1/admin/audit-events?resourceId=${encodeURIComponent(user.accountId)}`,
    },
  };
  return asHead(context.request, jsonResponse(payload));
}

async function mutateUser(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  userId: string,
  status: "active" | "suspended",
  action: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const updated = await context.identity?.setAccountStatus(userId, status);
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action,
        resourceType: "user",
        resourceId: userId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: { status },
      });
      const users = await ops.adminUsers();
      const user = users.find((item) => item.accountId === userId) ?? {
        id: updated.id,
        accountId: updated.accountId,
        email: updated.email,
        displayName: updated.displayName,
        status: updated.status,
        deviceCount: 0,
        bookCount: 0,
        storageBytes: 0,
        createdAt: updated.createdAt,
        lastSeenAt: null,
      };
      return jsonResponse(toAdminUser(user));
    },
    context.requestId,
    principal,
  );
}

async function revokeSessions(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  userId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      await context.identity?.revokeAllDevices(userId);
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "revoke_sessions",
        resourceType: "user",
        resourceId: userId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {},
      });
      const users = await ops.adminUsers();
      const user = users.find((item) => item.accountId === userId);
      return user === undefined ? notFound(context.requestId) : jsonResponse(toAdminUser(user));
    },
    context.requestId,
    principal,
  );
}

async function grantAdminRole(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  userId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const profile = await context.identity?.getProfileByUserId(userId);
      if (profile === undefined) {
        return notFound(context.requestId);
      }
      await context.identity?.grantAdminRole(userId);
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "grant_admin",
        resourceType: "user",
        resourceId: userId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {},
      });
      const users = await ops.adminUsers();
      const user = users.find((item) => item.accountId === userId);
      return user === undefined ? notFound(context.requestId) : jsonResponse(toAdminUser(user));
    },
    context.requestId,
    principal,
  );
}

async function putRuntimeConfig(
  context: AdminRouteContext,
  principal: Principal,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  const runtime = context.runtime;
  if (runtime === undefined) {
    return notFound(context.requestId, "Runtime configuration is not available.");
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      let patch: RuntimeConfigPut;
      try {
        patch = parseRuntimeConfigPut(body.value);
      } catch (error: unknown) {
        const message = error instanceof Error ? error.message : "runtime config is invalid.";
        return fieldError(context.requestId, "runtimeConfig", message);
      }
      let view: Awaited<ReturnType<RuntimeConfigService["put"]>>;
      try {
        view = await runtime.put(patch, principal.accountId);
        context.accountSyncReadiness.invalidate();
      } catch (error: unknown) {
        if (error instanceof RestPersistenceError) {
          return persistenceFailed(context.requestId, "Runtime config update failed", error);
        }
        if (error instanceof OperatorWrappingNotConfiguredError) {
          console.warn(
            JSON.stringify({
              level: "warn",
              message: "operator_wrapping_not_configured",
              requestId: context.requestId,
            }),
          );
          return problemResponse({
            status: 503,
            code: "dependency_failed",
            title: "Runtime config update failed",
            detail:
              "Operator wrapping key is not configured. Set OPERATOR_CONFIG_KEY before saving secrets.",
            traceId: context.requestId,
          });
        }
        throw error;
      }
      await context.ops?.appendAudit({
        actorId: principal.accountId,
        action: "put_runtime_config",
        resourceType: "operator_settings",
        resourceId: "default",
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {
          qwen: patch.qwen !== undefined,
          storage: patch.storage !== undefined,
          turnstile: patch.turnstile !== undefined,
          after: {
            qwenModel: view.qwen.model,
            qwenSource: view.qwen.source,
            qwenKeyConfigured: view.qwen.apiKeyConfigured,
            storageProvider: view.storage.provider,
            turnstileConfigured: view.turnstile.configured,
          },
        },
      });
      return jsonResponse(view);
    },
    context.requestId,
    principal,
  );
}

function parseRuntimeConfigPut(value: Record<string, unknown>): RuntimeConfigPut {
  const patch: RuntimeConfigPut = {};
  if (value.qwen !== undefined) {
    if (!isRecord(value.qwen)) {
      throw new Error("qwen must be an object.");
    }
    patch.qwen = {
      ...(value.qwen.apiKey === null || typeof value.qwen.apiKey === "string"
        ? { apiKey: value.qwen.apiKey }
        : {}),
      ...(typeof value.qwen.baseUrl === "string" ? { baseUrl: value.qwen.baseUrl } : {}),
      ...(typeof value.qwen.model === "string" ? { model: value.qwen.model } : {}),
    };
  }
  if (value.storage !== undefined) {
    if (!isRecord(value.storage)) {
      throw new Error("storage must be an object.");
    }
    if (typeof value.storage.serviceAccountJson === "string") {
      parseServiceAccountOrThrow(value.storage.serviceAccountJson);
    }
    patch.storage = {
      ...(typeof value.storage.bucket === "string" ? { bucket: value.storage.bucket } : {}),
      ...(value.storage.serviceAccountJson === null ||
      typeof value.storage.serviceAccountJson === "string"
        ? { serviceAccountJson: value.storage.serviceAccountJson }
        : {}),
    };
  }
  if (value.turnstile !== undefined) {
    if (!isRecord(value.turnstile)) {
      throw new Error("turnstile must be an object.");
    }
    patch.turnstile = {
      ...(value.turnstile.secretKey === null || typeof value.turnstile.secretKey === "string"
        ? { secretKey: value.turnstile.secretKey }
        : {}),
    };
  }
  if (value.assistant !== undefined) {
    if (!isRecord(value.assistant)) {
      throw new Error("assistant must be an object.");
    }
    const count = value.assistant.sentenceTranslationBatchSize;
    if (count !== undefined && (typeof count !== "number" || !Number.isFinite(count))) {
      throw new Error("assistant.sentenceTranslationBatchSize must be a number.");
    }
    patch.assistant = {
      ...(typeof count === "number" ? { sentenceTranslationBatchSize: count } : {}),
    };
  }
  return patch;
}

function parseServiceAccountOrThrow(raw: string): void {
  if (raw.trim() === "") {
    return;
  }
  const parsed: unknown = JSON.parse(raw);
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    typeof (parsed as { client_email?: unknown }).client_email !== "string" ||
    typeof (parsed as { private_key?: unknown }).private_key !== "string"
  ) {
    throw new Error("storage.serviceAccountJson must be a GCP service account JSON key.");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function persistenceFailed(
  requestId: string,
  title: string,
  error: RestPersistenceError,
): Response {
  console.warn(
    JSON.stringify({
      level: "warn",
      message: "admin_persistence_failed",
      requestId,
      title,
      status: error.status,
      detail: error.message,
    }),
  );
  return problemResponse({
    status: 502,
    code: "dependency_failed",
    title,
    detail:
      "The persistence dependency could not complete this request. Use the trace ID to investigate.",
    traceId: requestId,
  });
}

const PROMPT_SUBTASKS = new Set<ManagedPromptSubtask>([
  "sentence",
  "word",
  "chapter_batch",
  "chapter_summary",
  "chat",
  "heard_quiz",
]);

/** Builds the runtime-owned prompt layers without persisting an unsaved draft. */
async function previewPolicy(
  context: AdminRouteContext,
  ops: OpsStore,
  policyId: string,
  probe: boolean,
  principal: Principal,
): Promise<Response> {
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) return body.response;
  const stored = await ops.getPolicy(policyId);
  if (stored === undefined) return notFound(context.requestId);
  const requested = body.value.subtask;
  if (typeof requested !== "string" || !PROMPT_SUBTASKS.has(requested as ManagedPromptSubtask)) {
    return fieldError(
      context.requestId,
      "subtask",
      "subtask must name a supported Managed Qwen task.",
    );
  }
  const subtask = requested as ManagedPromptSubtask;
  const expectedTask =
    subtask === "chapter_summary"
      ? "chapter_summary"
      : subtask === "chat" || subtask === "heard_quiz"
        ? "chat"
        : "translation";
  if (stored.task !== expectedTask) {
    return fieldError(
      context.requestId,
      "subtask",
      `Subtask ${subtask} does not belong to ${stored.task}.`,
    );
  }
  const draft = isRecord(body.value.draft) ? body.value.draft : {};
  const assembled = assembleManagedPrompt({
    subtask,
    policySystemPrompt:
      typeof draft.systemPrompt === "string" ? draft.systemPrompt : stored.systemPrompt,
    policyUserPrompt: typeof draft.userPrompt === "string" ? draft.userPrompt : stored.userPrompt,
    schemaVersion:
      typeof draft.schemaVersion === "string" ? draft.schemaVersion : stored.schemaVersion,
    fields: promptPreviewFields(subtask),
  });
  if (!assembled.validation.valid) {
    return promptValidationProblem(context.requestId, assembled.validation.fieldErrors);
  }
  if (!probe) return jsonResponse(assembled);
  if (context.runtime === undefined) {
    return notFound(context.requestId, "Runtime configuration is not available.");
  }
  const qwen = await context.runtime.resolveQwenClient({ useFakes: false });
  const completed = await qwen.complete({
    jsonObject: true,
    ...(stored.model.trim() === "" ? {} : { model: stored.model }),
    messages: [
      { role: "system", content: assembled.effective.system },
      { role: "user", content: assembled.effective.user },
    ],
  });
  const allowedSegmentIDs =
    subtask === "heard_quiz"
      ? new Set(HEARD_QUIZ_PREVIEW_SEGMENTS.map((segment) => segment.id))
      : undefined;
  const expectedTargetIDs = subtask === "chapter_batch" ? new Set(["s1"]) : undefined;
  const output = completed.ok
    ? validateManagedPromptOutput(subtask, completed.text, {
        ...(allowedSegmentIDs === undefined ? {} : { allowedSegmentIDs }),
        ...(expectedTargetIDs === undefined ? {} : { expectedTargetIDs }),
      })
    : { valid: false, parsed: null, errors: [completed.detail] };
  const parsedResult = output.parsed;
  const status = completed.ok && output.valid ? "valid" : "invalid";
  const model = completed.ok ? completed.model : completed.usedModel;
  await captureProductEvent(ops, {
    accountId: principal.accountId,
    name: "operator.prompt_probe",
    purpose: "operational",
    outcome: status === "valid" ? "ok" : "failed",
    requestId: context.requestId,
    properties: { model, subtask, status },
  });
  await ops.appendAudit({
    actorId: principal.accountId,
    action: "operator_prompt_probe",
    resourceType: "llm_policy",
    resourceId: policyId,
    reason: `Validate ${subtask} effective prompt`,
    traceId: context.requestId,
    metadata: { subtask, status, contractFingerprint: assembled.contractFingerprint },
  });
  recordOperatorEvent({
    kind: "operator_prompt_probe",
    requestId: context.requestId,
    task: subtask,
    status,
    summary: `Managed Qwen ${subtask} prompt probe ${status}.`,
    metadata: { contractFingerprint: assembled.contractFingerprint },
  });
  return jsonResponse({
    ...assembled,
    requestId: context.requestId,
    model,
    providerStatus: completed.ok ? "ok" : completed.code,
    parsedResult,
    outputValidation: { valid: status === "valid", errors: output.errors },
  });
}

const HEARD_QUIZ_PREVIEW_SEGMENTS = [
  { id: "s1", text: "The room was quiet." },
  { id: "s2", text: "She broke the ice." },
] as const;

function promptPreviewFields(subtask: ManagedPromptSubtask): Record<string, string> {
  return {
    task: subtask,
    source: subtask === "word" ? "break the ice" : "She broke the ice and everyone relaxed.",
    context: "PREVIOUS: The room was quiet.\nTARGET: She broke the ice.\nNEXT: Everyone relaxed.",
    segments: HEARD_QUIZ_PREVIEW_SEGMENTS.map(
      (segment) => `HEARD id=${segment.id}: ${segment.text}`,
    ).join("\n"),
    question: "What does this moment reveal?",
    chapterId: "chapter-7",
    bookTitle: "The Example Book",
    author: "Ada Author",
    chapterTitle: "An Arrival",
    sourceLanguage: "English",
    targetLanguage: "Simplified Chinese",
    learnerLevel: "B1",
    targetIds: "s1",
  };
}

function promptValidationProblem(requestId: string, errors: Record<string, string>): Response {
  return problemResponse({
    status: 422,
    code: "invalid_prompt_contract",
    title: "Invalid prompt contract",
    detail: "Fix the prompt contract errors before previewing or saving.",
    traceId: requestId,
    fieldErrors: Object.entries(errors).map(([field, message]) => ({ field, message })),
  });
}

async function patchPolicy(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  policyId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const policyFieldProblem = validatePolicyPatch(body.value, context.requestId);
      if (policyFieldProblem !== undefined) {
        return policyFieldProblem;
      }
      const before = await ops.getPolicy(policyId);
      if (before === undefined) {
        return notFound(context.requestId);
      }
      const promptValidation = validateAssistantPromptDraft({
        task: before.task,
        userPrompt:
          typeof body.value.userPrompt === "string" ? body.value.userPrompt : before.userPrompt,
        schemaVersion:
          typeof body.value.schemaVersion === "string"
            ? body.value.schemaVersion
            : before.schemaVersion,
      });
      if (!promptValidation.valid) {
        return promptValidationProblem(context.requestId, promptValidation.fieldErrors);
      }
      let patched: Awaited<ReturnType<OpsStore["patchPolicy"]>>;
      try {
        patched = await ops.patchPolicy(policyId, {
          ...(typeof body.value.enabled === "boolean" ? { enabled: body.value.enabled } : {}),
          ...(typeof body.value.model === "string" ? { model: body.value.model } : {}),
          ...(typeof body.value.promptVersion === "string"
            ? { promptVersion: body.value.promptVersion }
            : {}),
          ...(typeof body.value.systemPrompt === "string"
            ? { systemPrompt: body.value.systemPrompt }
            : {}),
          ...(typeof body.value.userPrompt === "string"
            ? { userPrompt: body.value.userPrompt }
            : {}),
          ...(typeof body.value.canaryPercent === "number"
            ? { canaryPercent: body.value.canaryPercent }
            : {}),
          ...(typeof body.value.schemaVersion === "string"
            ? { schemaVersion: body.value.schemaVersion }
            : {}),
          ...(typeof body.value.maxInputTokens === "number"
            ? { maxInputTokens: body.value.maxInputTokens }
            : {}),
          ...(typeof body.value.maxOutputTokens === "number"
            ? { maxOutputTokens: body.value.maxOutputTokens }
            : {}),
          ...(typeof body.value.timeoutMs === "number" ? { timeoutMs: body.value.timeoutMs } : {}),
        });
      } catch (error: unknown) {
        if (error instanceof RestPersistenceError) {
          return persistenceFailed(context.requestId, "Policy update failed", error);
        }
        throw error;
      }
      if (patched === undefined) {
        return notFound(context.requestId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "patch_policy",
        resourceType: "llm_policy",
        resourceId: policyId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {
          before: {
            model: before.model,
            promptVersion: before.promptVersion,
            enabled: before.enabled,
            systemPromptChars: before.systemPrompt.length,
            userPromptChars: before.userPrompt.length,
            canaryPercent: before.canaryPercent,
          },
          after: {
            model: patched.model,
            promptVersion: patched.promptVersion,
            enabled: patched.enabled,
            systemPromptChars: patched.systemPrompt.length,
            userPromptChars: patched.userPrompt.length,
            canaryPercent: patched.canaryPercent,
          },
        },
      });
      recordOperatorEvent({
        kind: "patch_policy",
        requestId: context.requestId,
        task: patched.task,
        status: patched.enabled ? "enabled" : "disabled",
        summary: `Policy ${patched.task} saved (${patched.model}, ${patched.promptVersion}).`,
        metadata: { model: patched.model, promptVersion: patched.promptVersion },
      });
      return jsonResponse(toPolicy(patched));
    },
    context.requestId,
    principal,
  );
}

function validatePolicyPatch(
  value: Record<string, unknown>,
  requestId: string,
): Response | undefined {
  const requiredStrings = ["model", "promptVersion", "schemaVersion"] as const;
  for (const field of requiredStrings) {
    if (field in value && (typeof value[field] !== "string" || value[field].trim() === "")) {
      return fieldError(requestId, field, `${field} must not be blank.`);
    }
  }
  const bounds: ReadonlyArray<readonly [string, number, number]> = [
    ["canaryPercent", 0, 100],
    ["maxInputTokens", 1, 1_000_000],
    ["maxOutputTokens", 1, 1_000_000],
    ["timeoutMs", 1_000, 300_000],
  ];
  for (const [field, minimum, maximum] of bounds) {
    if (field in value) {
      const number = value[field];
      if (
        typeof number !== "number" ||
        !Number.isInteger(number) ||
        number < minimum ||
        number > maximum
      ) {
        return fieldError(
          requestId,
          field,
          `${field} must be a whole number from ${String(minimum)} to ${String(maximum)}.`,
        );
      }
    }
  }
  return undefined;
}

async function actOnCache(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  cacheId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const action = body.value.action;
      if (
        action !== "quarantine" &&
        action !== "activate" &&
        action !== "expire" &&
        action !== "purge" &&
        action !== "regenerate"
      ) {
        return fieldError(context.requestId, "action", "action is invalid.");
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      if (action !== "regenerate") {
        const updated = await ops.actOnCache(cacheId, action);
        if (updated === undefined) {
          return notFound(context.requestId);
        }
      } else if ((await ops.getCache(cacheId)) === undefined) {
        return notFound(context.requestId);
      }
      const job = await ops.createJob({
        accountId: principal.accountId,
        kind: `cache_${action}`,
        payload: { cacheId },
      });
      await ops.appendAudit({
        actorId: principal.accountId,
        action: `cache_${action}`,
        resourceType: "cache",
        resourceId: cacheId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {},
      });
      return jsonResponse(toJob(job), 202);
    },
    context.requestId,
    principal,
  );
}

async function jobAction(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  jobId: string,
  status: "queued" | "cancelled",
  action: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (!UUID_PATTERN.test(jobId)) {
    return fieldError(context.requestId, "jobId", "jobId must be a UUID.");
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const updated = await ops.updateJob(jobId, { status });
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action,
        resourceType: "job",
        resourceId: jobId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {},
      });
      return jsonResponse(toJob(updated), 202);
    },
    context.requestId,
    principal,
  );
}

async function patchFlag(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  key: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const patch: Parameters<OpsStore["patchFlag"]>[1] = {};
      if (typeof body.value.enabled === "boolean") {
        patch.enabled = body.value.enabled;
      }
      if (body.value.variant === null || typeof body.value.variant === "string") {
        patch.variant = body.value.variant;
      }
      if (typeof body.value.rolloutPercent === "number") {
        patch.rolloutPercent = body.value.rolloutPercent;
      }
      if (body.value.minAppVersion === null || typeof body.value.minAppVersion === "string") {
        patch.minAppVersion = body.value.minAppVersion;
      }
      if (Array.isArray(body.value.platforms)) {
        patch.platforms = body.value.platforms.filter(
          (item): item is string => typeof item === "string",
        );
      }
      if (key === "account_sync" && patch.enabled === true) {
        // Enabling is a state transition and must never trust a cached successful canary.
        const readiness = await context.accountSyncReadiness.read(true, { force: true });
        if (!readiness.ready) {
          console.warn(
            JSON.stringify({
              level: "warn",
              component: "account-sync-readiness",
              message: "account_sync_enable_rejected",
              requestId: context.requestId,
              outcome: "unavailable",
              reason: readiness.reason,
              provider: readiness.provider,
            }),
          );
          return problemResponse({
            status: 503,
            code: "account_sync_unavailable",
            title: "Account sync unavailable",
            detail: readiness.lastFailureDetail ?? "Account sync dependencies are unavailable.",
            traceId: context.requestId,
          });
        }
      }
      let updated: Awaited<ReturnType<OpsStore["patchFlag"]>>;
      try {
        updated = await ops.patchFlag(key, patch);
      } catch (error: unknown) {
        if (error instanceof RestPersistenceError) {
          return persistenceFailed(context.requestId, "Feature flag update failed", error);
        }
        throw error;
      }
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "patch_feature_flag",
        resourceType: "feature_flag",
        resourceId: key,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: { enabled: updated.enabled, rolloutPercent: updated.rolloutPercent },
      });
      recordOperatorEvent({
        kind: "patch_feature_flag",
        requestId: context.requestId,
        status: updated.enabled ? "on" : "off",
        summary: `Flag ${key} ${updated.enabled ? "enabled" : "disabled"}.`,
        metadata: { key, enabled: updated.enabled },
      });
      return jsonResponse(toFeatureFlag(updated));
    },
    context.requestId,
    principal,
  );
}

async function patchQuota(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  key: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      if (typeof body.value.limit !== "number" || body.value.limit < 0) {
        return fieldError(context.requestId, "limit", "limit must be a non-negative number.");
      }
      let updated: Awaited<ReturnType<OpsStore["patchQuota"]>>;
      try {
        updated = await ops.patchQuota(key, body.value.limit);
      } catch (error: unknown) {
        if (error instanceof RestPersistenceError) {
          return persistenceFailed(context.requestId, "Quota update failed", error);
        }
        throw error;
      }
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "patch_quota",
        resourceType: "quota",
        resourceId: key,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: { limit: updated.limit, used: updated.used },
      });
      recordOperatorEvent({
        kind: "patch_quota",
        requestId: context.requestId,
        status: "ok",
        summary: `Quota ${key} limit set to ${String(updated.limit)}.`,
        metadata: { key, limit: updated.limit },
      });
      return jsonResponse(toQuota(updated));
    },
    context.requestId,
    principal,
  );
}

async function actOnPrivacy(
  context: AdminRouteContext,
  principal: Principal,
  ops: OpsStore,
  requestId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (!UUID_PATTERN.test(requestId)) {
    return fieldError(context.requestId, "requestId", "requestId must be a UUID.");
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim().length < 5) {
        return fieldError(context.requestId, "reason", "reason must be at least 5 characters.");
      }
      const action = body.value.action;
      if (action !== "complete" && action !== "cancel") {
        return fieldError(context.requestId, "action", "action must be complete or cancel.");
      }
      const existing = await ops.getPrivacyRequest(requestId);
      if (existing === undefined) {
        return notFound(context.requestId);
      }
      const status = action === "cancel" ? "cancelled" : "ready";
      const updated = await ops.patchPrivacyRequest(requestId, {
        status,
        completedAt: new Date().toISOString(),
      });
      if (updated === undefined) {
        return notFound(context.requestId);
      }
      if (action === "complete" && existing.kind === "deletion") {
        await context.identity?.setAccountStatus(existing.accountId, "deleted");
        await context.identity?.revokeAllDevices(existing.accountId);
      }
      await ops.appendAudit({
        actorId: principal.accountId,
        action: `${action}_privacy_request`,
        resourceType: "privacy_request",
        resourceId: requestId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: { kind: existing.kind, status },
      });
      return jsonResponse(toPrivacy(updated));
    },
    context.requestId,
    principal,
  );
}

function toFeatureFlag(flag: Awaited<ReturnType<OpsStore["listFlags"]>>[number]): FeatureFlag {
  return {
    key: flag.key,
    enabled: flag.enabled,
    variant: flag.variant,
    rolloutPercent: flag.rolloutPercent,
    minAppVersion: flag.minAppVersion,
    platforms: flag.platforms.filter(
      (item): item is "macos" | "ios" | "ipados" =>
        item === "macos" || item === "ios" || item === "ipados",
    ),
  };
}

function toQuota(quota: Awaited<ReturnType<OpsStore["quotasFor"]>>[number]): Quota {
  return {
    key: quota.key,
    used: quota.used,
    limit: quota.limit,
    periodEndsAt: quota.periodEndsAt,
  };
}

function toPrivacy(
  request: NonNullable<Awaited<ReturnType<OpsStore["getPrivacyRequest"]>>>,
): PrivacyRequest {
  return {
    id: request.id,
    accountId: request.accountId,
    kind: request.kind,
    status: request.status,
    format: request.format,
    assetId: request.assetId,
    error: request.error,
    reason: request.reason,
    createdAt: request.createdAt,
    completedAt: request.completedAt,
  };
}

function toAdminUser(
  user: Awaited<ReturnType<OpsStore["adminUsers"]>>[number],
  extras?: {
    quotas?: Quota[];
    devices?: NonNullable<AdminUser["devices"]>;
    books?: NonNullable<AdminUser["books"]>;
  },
): AdminUser {
  return {
    id: user.id,
    accountId: user.accountId,
    email: user.email,
    displayName: user.displayName,
    status: user.status,
    deviceCount: user.deviceCount,
    bookCount: user.bookCount,
    storageBytes: user.storageBytes,
    createdAt: user.createdAt,
    lastSeenAt: user.lastSeenAt,
    ...(extras?.quotas === undefined ? {} : { quotas: extras.quotas }),
    ...(extras?.devices === undefined ? {} : { devices: extras.devices }),
    ...(extras?.books === undefined ? {} : { books: extras.books }),
  };
}

function toPolicy(policy: NonNullable<Awaited<ReturnType<OpsStore["getPolicy"]>>>): LlmPolicy {
  return {
    id: policy.id,
    task: policy.task,
    region: policy.region,
    model: policy.model,
    promptVersion: policy.promptVersion,
    systemPrompt: policy.systemPrompt,
    userPrompt: policy.userPrompt,
    schemaVersion: policy.schemaVersion,
    policyVersion: policy.policyVersion,
    enabled: policy.enabled,
    canaryPercent: policy.canaryPercent,
    createdAt: policy.createdAt,
    updatedAt: policy.updatedAt,
    ...(policy.maxInputTokens === null ? {} : { maxInputTokens: policy.maxInputTokens }),
    ...(policy.maxOutputTokens === null ? {} : { maxOutputTokens: policy.maxOutputTokens }),
    ...(policy.timeoutMs === null ? {} : { timeoutMs: policy.timeoutMs }),
  };
}

function toCache(entry: NonNullable<Awaited<ReturnType<OpsStore["getCache"]>>>): CacheEntry {
  return {
    id: entry.id,
    task: entry.task,
    state: entry.state,
    sourceLanguage: entry.sourceLanguage,
    targetLanguage: entry.targetLanguage,
    editionFingerprint: entry.editionFingerprint,
    policyVersion: entry.policyVersion,
    hitCount: entry.hitCount,
    acceptCount: entry.acceptCount,
    rejectCount: entry.rejectCount,
    createdAt: entry.createdAt,
    lastHitAt: entry.lastHitAt,
    cacheKey: entry.cacheKey,
    payload: entry.payload,
  };
}

function toJob(job: NonNullable<Awaited<ReturnType<OpsStore["getJob"]>>>): Job {
  return {
    id: job.id,
    accountId: job.accountId,
    kind: job.kind,
    status: job.status,
    attempts: job.attempts,
    maxAttempts: job.maxAttempts,
    lastError: job.lastError,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    startedAt: job.startedAt,
    finishedAt: job.finishedAt,
  };
}

function toAudit(event: Awaited<ReturnType<OpsStore["listAudit"]>>[number]): AuditEvent {
  return {
    id: event.id,
    actorId: event.actorId,
    action: event.action,
    resourceType: event.resourceType,
    resourceId: event.resourceId,
    reason: event.reason,
    metadata: event.metadata,
    createdAt: event.createdAt,
    ...(event.traceId === null ? {} : { traceId: event.traceId }),
  };
}

function analyticsDate(value: string | null, fallback: number): Date | null {
  if (value === null || value.trim() === "") return new Date(fallback);
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date : null;
}

function analyticsFilters(url: URL): AnalyticsFilters {
  const filters: AnalyticsFilters = {};
  const values: Array<[keyof AnalyticsFilters, string]> = [
    ["country", "country"],
    ["language", "language"],
    ["readerLevel", "readerLevel"],
    ["platform", "platform"],
    ["contentCategory", "contentCategory"],
    ["feature", "feature"],
  ];
  for (const [key, queryKey] of values) {
    const value = url.searchParams.get(queryKey)?.trim() ?? "";
    if (value !== "") Object.assign(filters, { [key]: value });
  }
  const outcome = url.searchParams.get("outcome")?.trim() ?? "";
  if (
    outcome === "ok" ||
    outcome === "failed" ||
    outcome === "cancelled" ||
    outcome === "started"
  ) {
    filters.outcome = outcome;
  }
  return filters;
}
