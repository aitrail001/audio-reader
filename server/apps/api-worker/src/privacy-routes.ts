import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { CatalogStore, IdentityStore, OpsStore, SyncStore } from "@audio-reader/database";
import { sha256Hex } from "@audio-reader/qwen";
import { buildAccountExportPayload } from "./account-export";
import { readJsonObject } from "./body";
import { asHead, jsonResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import type { ObjectStore } from "./object-store";
import { contentAddressedObjectKey, pendingUploadObjectKey } from "./asset-manifest-policy";
import { captureProductEvent } from "./product-events";
import {
  UUID_PATTERN,
  conflict,
  fieldError,
  methodNotAllowed,
  notFound,
  requireBoundDevice,
  requireDeviceId,
  requirePrincipal,
} from "./route-helpers";

type ExportJob = components["schemas"]["ExportJob"];
type Job = components["schemas"]["Job"];
type AnalyticsPreference = components["schemas"]["AnalyticsPreference"];

const EXPORT_ITEM = /^\/v1\/exports\/([^/]+)$/;

export type PrivacyRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  ops?: OpsStore;
  identity?: IdentityStore;
  catalog?: CatalogStore;
  objects?: ObjectStore;
  sync?: SyncStore;
};

export function isPrivacyPath(path: string): boolean {
  return (
    path === "/v1/exports" ||
    path === "/v1/me/deletion" ||
    path === "/v1/me/analytics-preferences" ||
    EXPORT_ITEM.test(path)
  );
}

export function privacyMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const upper = method.toUpperCase();
  if (path === "/v1/exports" && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (path === "/v1/me/deletion" && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (
    path === "/v1/me/analytics-preferences" &&
    upper !== "GET" &&
    upper !== "HEAD" &&
    upper !== "PUT"
  ) {
    return methodNotAllowed(["GET", "HEAD", "PUT"], requestId);
  }
  if (EXPORT_ITEM.test(path) && upper !== "GET" && upper !== "HEAD") {
    return methodNotAllowed(["GET", "HEAD"], requestId);
  }
  return undefined;
}

export async function handlePrivacyRoute(
  context: PrivacyRouteContext,
): Promise<Response | undefined> {
  const url = new URL(context.request.url);
  const path = url.pathname;
  if (!isPrivacyPath(path)) {
    return undefined;
  }
  const methodError = privacyMethodError(path, context.request.method, context.requestId);
  if (methodError !== undefined) {
    return methodError;
  }
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const ops = context.ops;
  if (ops === undefined) {
    return notFound(context.requestId, "Privacy services are not configured.");
  }
  if (path === "/v1/exports") {
    return createExport(context, principal, ops);
  }
  if (path === "/v1/me/analytics-preferences") {
    if (
      context.request.method.toUpperCase() === "GET" ||
      context.request.method.toUpperCase() === "HEAD"
    ) {
      return asHead(
        context.request,
        jsonResponse(await ops.analyticsPreference(principal.accountId)),
      );
    }
    return putAnalyticsPreference(context, principal, ops);
  }
  const item = EXPORT_ITEM.exec(path);
  if (item?.[1] !== undefined) {
    if (!UUID_PATTERN.test(item[1])) {
      return fieldError(context.requestId, "exportId", "exportId must be a UUID.");
    }
    const job = await ops.getExport(principal.accountId, item[1]);
    return job === undefined
      ? notFound(context.requestId)
      : asHead(context.request, jsonResponse(toExport(job)));
  }
  if (path === "/v1/me/deletion") {
    return requestDeletion(context, principal, ops);
  }
  return undefined;
}

async function putAnalyticsPreference(
  context: PrivacyRouteContext,
  principal: Principal,
  ops: OpsStore,
): Promise<Response> {
  const deviceId = await requireBoundDevice({
    request: context.request,
    requestId: context.requestId,
    accountId: principal.accountId,
    hasActiveDevice: (accountId, candidateDeviceId) =>
      context.identity?.hasActiveDevice(accountId, candidateDeviceId) ?? Promise.resolve(false),
  });
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
      if (typeof body.value.operatorLearningAnalyticsEnabled !== "boolean") {
        return fieldError(
          context.requestId,
          "operatorLearningAnalyticsEnabled",
          "operatorLearningAnalyticsEnabled must be a boolean.",
        );
      }
      const preference = await ops.putAnalyticsPreference(
        principal.accountId,
        body.value.operatorLearningAnalyticsEnabled,
      );
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "analytics_preference_changed",
        resourceType: "analytics_preference",
        resourceId: principal.accountId,
        reason: preference.operatorLearningAnalyticsEnabled
          ? "User enabled Operator learning analytics."
          : "User disabled Operator learning analytics.",
        traceId: context.requestId,
        metadata: { enabled: preference.operatorLearningAnalyticsEnabled, deviceId },
      });
      console.warn(
        JSON.stringify({
          level: "info",
          message: "analytics_preference_changed",
          component: "privacy",
          requestId: context.requestId,
          accountId: principal.accountId,
          deviceId,
          enabled: preference.operatorLearningAnalyticsEnabled,
          outcome: "ok",
        }),
      );
      const payload: AnalyticsPreference = preference;
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
  );
}

async function createExport(
  context: PrivacyRouteContext,
  principal: Principal,
  ops: OpsStore,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      if (!(await objectWriteIsAllowed(context.identity, principal.accountId))) {
        return conflict(context.requestId, "Account deletion is already in progress.");
      }
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const rawFormat = typeof body.value.format === "string" ? body.value.format : "zip_json";
      const format = rawFormat === "csv" || rawFormat === "anki_package" ? rawFormat : "zip_json";
      const created = await ops.createExport(principal.accountId, format);
      const payload = await buildAccountExportPayload({
        accountId: principal.accountId,
        ops,
        ...(context.identity === undefined ? {} : { identity: context.identity }),
        ...(context.catalog === undefined ? {} : { catalog: context.catalog }),
        ...(context.sync === undefined ? {} : { sync: context.sync }),
      });
      const json = JSON.stringify(payload, null, 2);
      const bytes = new TextEncoder().encode(json);
      const digest = await sha256Hex(json);
      const fileName = `audioreader-account-${created.id.slice(0, 8)}.json`;
      const uploadId = crypto.randomUUID();
      const objectKey = contentAddressedObjectKey(principal.accountId, "accountExport", digest);
      const uploadObjectKey = pendingUploadObjectKey(principal.accountId, uploadId);
      const asset = await ops.createAsset(principal.accountId, {
        kind: "accountExport",
        contentType: "application/json",
        compressedBytes: bytes.byteLength,
        originalBytes: bytes.byteLength,
        sha256: digest,
        encoding: "identity",
        revisionId: null,
        bookId: null,
        chapterId: null,
        segmentCount: null,
        fileName,
        objectKey,
        uploadObjectKey,
        uploadId,
      });
      if (context.objects !== undefined) {
        const lease = await ops.beginObjectWrite(principal.accountId, asset.uploadObjectKey);
        await context.objects.put(asset.uploadObjectKey, bytes);
        // The post-write check closes the cross-system deletion race; a late export must remove
        // itself rather than recreate private data after the deletion worker's final sweep.
        if (!(await objectWriteIsAllowed(context.identity, principal.accountId))) {
          await context.objects.delete(asset.uploadObjectKey);
          await ops.finishObjectWrite(lease.id);
          return conflict(
            context.requestId,
            "Account deletion began while the export was being created.",
          );
        }
        await context.objects.put(asset.objectKey, bytes);
        await context.objects.delete(asset.uploadObjectKey);
        await ops.finishObjectWrite(lease.id);
        await ops.completeAsset(principal.accountId, asset.uploadId);
      }
      await ops.createPrivacyRequest({
        accountId: principal.accountId,
        kind: "export",
        status: "ready",
        format,
        assetId: asset.id,
      });
      const ready = await ops.completeExport(principal.accountId, created.id, asset.id);
      const job = await ops.createJob({
        accountId: principal.accountId,
        kind: "account_export",
        payload: { exportId: created.id, assetId: asset.id, fileName },
      });
      await ops.updateJob(job.id, { status: "succeeded", finishedAt: new Date().toISOString() });
      await captureProductEvent(ops, {
        accountId: principal.accountId,
        deviceId,
        name: "account.export.created",
        purpose: "operational",
        requestId: context.requestId,
        properties: { format, bytes: bytes.byteLength },
      });
      console.warn(
        JSON.stringify({
          level: "info",
          message: "account_export_ready",
          requestId: context.requestId,
          accountId: principal.accountId,
          exportId: created.id,
          assetId: asset.id,
          bytes: bytes.byteLength,
        }),
      );
      return jsonResponse(toExport(ready ?? created), 202);
    },
    context.requestId,
    principal,
  );
}

async function objectWriteIsAllowed(
  identity: IdentityStore | undefined,
  accountId: string,
): Promise<boolean> {
  if (identity === undefined) {
    return true;
  }
  const profile = await identity.getProfileByUserId(accountId);
  return (
    profile !== undefined && profile.status !== "deletion_pending" && profile.status !== "deleted"
  );
}

async function requestDeletion(
  context: PrivacyRouteContext,
  principal: Principal,
  ops: OpsStore,
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
      if (body.value.confirmation !== "DELETE MY ACCOUNT") {
        return fieldError(
          context.requestId,
          "confirmation",
          'confirmation must be "DELETE MY ACCOUNT".',
        );
      }
      if (typeof body.value.reason !== "string" || body.value.reason.trim() === "") {
        return fieldError(context.requestId, "reason", "reason is required.");
      }
      // Status, the cascading request, the durable job, and the minimized audit event commit or
      // roll back together; a partial request must never strand the account in deletion_pending.
      const { job } = await ops.requestAccountDeletion(
        principal.accountId,
        body.value.reason,
        context.requestId,
      );
      const payload: Job = {
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
      return jsonResponse(payload, 202);
    },
    context.requestId,
    principal,
  );
}

function toExport(job: NonNullable<Awaited<ReturnType<OpsStore["getExport"]>>>): ExportJob {
  return {
    id: job.id,
    status: job.status,
    format: job.format,
    assetId: job.assetId,
    error: job.error,
    createdAt: job.createdAt,
    completedAt: job.completedAt,
    expiresAt: job.expiresAt,
  };
}
