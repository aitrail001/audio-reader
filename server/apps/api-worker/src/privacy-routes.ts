import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { CatalogStore, IdentityStore, OpsStore, SyncStore } from "@audio-reader/database";
import { sha256Hex } from "@audio-reader/qwen";
import { buildAccountExportPayload } from "./account-export";
import { readJsonObject } from "./body";
import { asHead, jsonResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import type { ObjectStore } from "./object-store";
import { captureProductEvent } from "./product-events";
import {
  UUID_PATTERN,
  fieldError,
  methodNotAllowed,
  notFound,
  requireDeviceId,
  requirePrincipal,
} from "./route-helpers";

type ExportJob = components["schemas"]["ExportJob"];
type Job = components["schemas"]["Job"];

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
  return path === "/v1/exports" || path === "/v1/me/deletion" || EXPORT_ITEM.test(path);
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
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const rawFormat = typeof body.value.format === "string" ? body.value.format : "zip_json";
      const format = rawFormat === "csv" || rawFormat === "anki_package" ? rawFormat : "zip_json";
      const created = await ops.createExport(principal.accountId, format);
      const payload = await buildAccountExportPayload({
        accountId: principal.accountId,
        ...(context.identity === undefined ? {} : { identity: context.identity }),
        ...(context.catalog === undefined ? {} : { catalog: context.catalog }),
        ...(context.sync === undefined ? {} : { sync: context.sync }),
      });
      const json = JSON.stringify(payload, null, 2);
      const bytes = new TextEncoder().encode(json);
      const digest = await sha256Hex(json);
      const fileName = `audioreader-account-${created.id.slice(0, 8)}.json`;
      const asset = await ops.createAsset(principal.accountId, {
        kind: "account_export",
        contentType: "application/json",
        sizeBytes: bytes.byteLength,
        sha256: digest,
        fileName,
      });
      if (context.objects !== undefined) {
        await context.objects.put(asset.objectKey, bytes);
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
      await context.identity?.setAccountStatus(principal.accountId, "deletion_pending");
      await ops.createPrivacyRequest({
        accountId: principal.accountId,
        kind: "deletion",
        status: "queued",
        reason: body.value.reason,
      });
      const job = await ops.createJob({
        accountId: principal.accountId,
        kind: "account_deletion",
        payload: { reason: body.value.reason },
      });
      await ops.appendAudit({
        actorId: principal.accountId,
        action: "request_deletion",
        resourceType: "account",
        resourceId: principal.accountId,
        reason: body.value.reason,
        traceId: context.requestId,
        metadata: {},
      });
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
