import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { IdentityStore, OpsStore } from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, jsonResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import {
  UUID_PATTERN,
  fieldError,
  methodNotAllowed,
  notFound,
  pageCursor,
  parseLimit,
  requireAdmin,
  requireDeviceId,
} from "./route-helpers";
import { buildOperatorDiagnostics } from "./diagnostics";
import { listOperatorEvents, operatorEventFromAudit, recordOperatorEvent } from "./operator-events";
import type { RuntimeConfigPut, RuntimeConfigService } from "./runtime-config";

type AdminUser = components["schemas"]["AdminUser"];
type LlmPolicy = components["schemas"]["LlmPolicy"];
type CacheEntry = components["schemas"]["CacheEntry"];
type Job = components["schemas"]["Job"];
type AuditEvent = components["schemas"]["AuditEvent"];
type MetricsSnapshot = components["schemas"]["MetricsSnapshot"];
type FeatureFlag = components["schemas"]["FeatureFlag"];
type Quota = components["schemas"]["Quota"];
type PrivacyRequest = components["schemas"]["PrivacyRequest"];

const USER_ITEM = /^\/v1\/admin\/users\/([^/]+)$/;
const USER_SUSPEND = /^\/v1\/admin\/users\/([^/]+)\/suspend$/;
const USER_UNSUSPEND = /^\/v1\/admin\/users\/([^/]+)\/unsuspend$/;
const USER_REVOKE = /^\/v1\/admin\/users\/([^/]+)\/revoke-sessions$/;
const USER_GRANT_ADMIN = /^\/v1\/admin\/users\/([^/]+)\/grant-admin$/;
const POLICY_ITEM = /^\/v1\/admin\/llm\/policies\/([^/]+)$/;
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
  runtime?: RuntimeConfigService;
};

export function isAdminPath(path: string): boolean {
  return (
    path === "/v1/admin/users" ||
    path === "/v1/admin/llm/policies" ||
    path === "/v1/admin/cache" ||
    path === "/v1/admin/jobs" ||
    path === "/v1/admin/metrics" ||
    path === "/v1/admin/audit-events" ||
    path === "/v1/admin/runtime-config" ||
    path === "/v1/admin/diagnostics" ||
    path === "/v1/admin/events" ||
    path === "/v1/admin/feature-flags" ||
    path === "/v1/admin/quotas" ||
    path === "/v1/admin/privacy-requests" ||
    USER_ITEM.test(path) ||
    USER_SUSPEND.test(path) ||
    USER_UNSUSPEND.test(path) ||
    USER_REVOKE.test(path) ||
    USER_GRANT_ADMIN.test(path) ||
    POLICY_ITEM.test(path) ||
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
      path === "/v1/admin/llm/policies" ||
      path === "/v1/admin/cache" ||
      path === "/v1/admin/jobs" ||
      path === "/v1/admin/metrics" ||
      path === "/v1/admin/audit-events" ||
      path === "/v1/admin/feature-flags" ||
      path === "/v1/admin/quotas" ||
      path === "/v1/admin/privacy-requests" ||
      path === "/v1/admin/diagnostics" ||
      path === "/v1/admin/events" ||
      USER_ITEM.test(path) ||
      CACHE_ITEM.test(path)) &&
    upper !== "GET" &&
    upper !== "HEAD"
  ) {
    return methodNotAllowed(["GET", "HEAD"], requestId);
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
  const ops = context.ops;
  if (ops === undefined) {
    return notFound(context.requestId, "Admin services are not configured.");
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
  const userItem = USER_ITEM.exec(path);
  if (userItem?.[1] !== undefined) {
    const users = await ops.adminUsers();
    const user = users.find((item) => item.accountId === userItem[1] || item.id === userItem[1]);
    if (user === undefined) {
      return notFound(context.requestId);
    }
    const quotas = await ops.quotasFor(user.accountId);
    return asHead(context.request, jsonResponse(toAdminUser(user, quotas.map(toQuota))));
  }
  const suspend = USER_SUSPEND.exec(path);
  if (suspend?.[1] !== undefined) {
    return mutateUser(context, principal, ops, suspend[1], "suspended", "suspend_user");
  }
  const unsuspend = USER_UNSUSPEND.exec(path);
  if (unsuspend?.[1] !== undefined) {
    return mutateUser(context, principal, ops, unsuspend[1], "active", "unsuspend_user");
  }
  const revoke = USER_REVOKE.exec(path);
  if (revoke?.[1] !== undefined) {
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
  if (path === "/v1/admin/cache") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const task = url.searchParams.get("task");
    const state = url.searchParams.get("state");
    const items = await ops.listCache({
      ...(task === null || task === "" ? {} : { task }),
      ...(state === null || state === "" ? {} : { state }),
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
    };
    return asHead(context.request, jsonResponse(snapshot));
  }
  if (path === "/v1/admin/audit-events") {
    const limit = parseLimit(url, context.requestId);
    if (limit instanceof Response) {
      return limit;
    }
    const actorId = url.searchParams.get("actorId") ?? "";
    const action = url.searchParams.get("action") ?? "";
    const requestId = url.searchParams.get("requestId") ?? "";
    const resourceType = url.searchParams.get("resourceType") ?? "";
    const events = await ops.listAudit({
      ...(actorId.trim() === "" ? {} : { actorId: actorId.trim() }),
      ...(action.trim() === "" ? {} : { action: action.trim() }),
      ...(requestId.trim() === "" ? {} : { requestId: requestId.trim() }),
      ...(resourceType.trim() === "" ? {} : { resourceType: resourceType.trim() }),
    });
    return asHead(
      context.request,
      jsonResponse(pageCursor(events.map(toAudit), url.searchParams.get("cursor"), limit)),
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
    return asHead(
      context.request,
      jsonResponse(
        persisted
          .filter(
            (event) =>
              event.action.startsWith("managed_qwen") || event.action.startsWith("operator_"),
          )
          .map(operatorEventFromAudit)
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
    });
    return asHead(context.request, jsonResponse(snapshot));
  }
  if (path === "/v1/admin/feature-flags") {
    const flags = await ops.listFlags();
    return asHead(context.request, jsonResponse(flags.map(toFeatureFlag)));
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
      const view = await runtime.put(patch, principal.accountId);
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
      const before = await ops.getPolicy(policyId);
      const patched = await ops.patchPolicy(policyId, {
        ...(typeof body.value.enabled === "boolean" ? { enabled: body.value.enabled } : {}),
        ...(typeof body.value.model === "string" ? { model: body.value.model } : {}),
        ...(typeof body.value.promptVersion === "string"
          ? { promptVersion: body.value.promptVersion }
          : {}),
        ...(typeof body.value.systemPrompt === "string"
          ? { systemPrompt: body.value.systemPrompt }
          : {}),
        ...(typeof body.value.canaryPercent === "number"
          ? { canaryPercent: body.value.canaryPercent }
          : {}),
      });
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
          before:
            before === undefined
              ? {}
              : {
                  model: before.model,
                  promptVersion: before.promptVersion,
                  enabled: before.enabled,
                  systemPromptChars: before.systemPrompt.length,
                  canaryPercent: before.canaryPercent,
                },
          after: {
            model: patched.model,
            promptVersion: patched.promptVersion,
            enabled: patched.enabled,
            systemPromptChars: patched.systemPrompt.length,
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
      const updated = await ops.patchFlag(key, patch);
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
      const updated = await ops.patchQuota(key, body.value.limit);
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
  quotas?: Quota[],
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
    ...(quotas === undefined || quotas.length === 0 ? {} : { quotas }),
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
