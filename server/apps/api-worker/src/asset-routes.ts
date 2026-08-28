import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { OpsStore } from "@audio-reader/database";
import { readJsonObject } from "./body";
import { jsonResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import type { ObjectStore } from "./object-store";
import {
  UUID_PATTERN,
  fieldError,
  methodNotAllowed,
  notFound,
  requireDeviceId,
  requirePrincipal,
  requiredString,
} from "./route-helpers";

type UploadTicket = components["schemas"]["UploadTicket"];
type Asset = components["schemas"]["Asset"];
type SignedDownload = components["schemas"]["SignedDownload"];

const COMPLETE = /^\/v1\/uploads\/([^/]+)\/complete$/;
const BODY = /^\/v1\/uploads\/([^/]+)\/body$/;
const DOWNLOAD = /^\/v1\/assets\/([^/]+)\/download$/;
const CONTENT = /^\/v1\/assets\/([^/]+)\/content$/;

export function isBinaryAssetPath(path: string): boolean {
  return BODY.test(path) || CONTENT.test(path);
}

export type AssetRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  ops?: OpsStore;
  objects?: ObjectStore;
};

export function isAssetPath(path: string): boolean {
  return (
    path === "/v1/uploads" ||
    COMPLETE.test(path) ||
    BODY.test(path) ||
    DOWNLOAD.test(path) ||
    CONTENT.test(path)
  );
}

export function assetMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const upper = method.toUpperCase();
  if (path === "/v1/uploads" && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (COMPLETE.test(path) && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (BODY.test(path) && upper !== "PUT") {
    return methodNotAllowed(["PUT"], requestId);
  }
  if (DOWNLOAD.test(path) && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if (CONTENT.test(path) && upper !== "GET" && upper !== "HEAD") {
    return methodNotAllowed(["GET", "HEAD"], requestId);
  }
  return undefined;
}

export async function handleAssetRoute(context: AssetRouteContext): Promise<Response | undefined> {
  const url = new URL(context.request.url);
  const path = url.pathname;
  if (!isAssetPath(path)) {
    return undefined;
  }
  const methodError = assetMethodError(path, context.request.method, context.requestId);
  if (methodError !== undefined) {
    return methodError;
  }
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const ops = context.ops;
  const objects = context.objects;
  if (ops === undefined || objects === undefined) {
    return notFound(context.requestId, "Object storage is not configured.");
  }
  if (path === "/v1/uploads") {
    return createUpload(context, principal, ops, url.origin);
  }
  const complete = COMPLETE.exec(path);
  if (complete?.[1] !== undefined) {
    return completeUpload(context, principal, ops, objects, complete[1]);
  }
  const body = BODY.exec(path);
  if (body?.[1] !== undefined) {
    return putUploadBody(context, principal, ops, objects, body[1]);
  }
  const download = DOWNLOAD.exec(path);
  if (download?.[1] !== undefined) {
    return createDownload(context, principal, ops, download[1], url.origin);
  }
  const content = CONTENT.exec(path);
  if (content?.[1] !== undefined) {
    return getContent(context, principal, ops, objects, content[1]);
  }
  return undefined;
}

async function createUpload(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  origin: string,
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
      const kind = body.value.kind;
      if (kind !== "audio" && kind !== "ebook" && kind !== "cover") {
        return fieldError(context.requestId, "kind", "kind must be audio, ebook, or cover.");
      }
      const contentType = requiredString(body.value.contentType, "contentType", context.requestId);
      if (contentType instanceof Response) {
        return contentType;
      }
      const sha256 = requiredString(body.value.sha256, "sha256", context.requestId);
      if (sha256 instanceof Response) {
        return sha256;
      }
      const fileName = requiredString(body.value.fileName, "fileName", context.requestId);
      if (fileName instanceof Response) {
        return fileName;
      }
      if (typeof body.value.sizeBytes !== "number" || body.value.sizeBytes < 1) {
        return fieldError(context.requestId, "sizeBytes", "sizeBytes must be >= 1.");
      }
      const asset = await ops.createAsset(principal.accountId, {
        kind,
        contentType,
        sizeBytes: body.value.sizeBytes,
        sha256,
        fileName,
      });
      const expiresAt = new Date(Date.now() + 15 * 60_000).toISOString();
      const ticket: UploadTicket = {
        uploadId: asset.uploadId,
        assetId: asset.id,
        method: "PUT",
        url: `${origin}/v1/uploads/${asset.uploadId}/body`,
        expiresAt,
        headers: { "content-type": contentType },
        multipart: false,
      };
      return jsonResponse(ticket, 201);
    },
    context.requestId,
    principal,
  );
}

async function putUploadBody(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  objects: ObjectStore,
  uploadId: string,
): Promise<Response> {
  if (!UUID_PATTERN.test(uploadId)) {
    return fieldError(context.requestId, "uploadId", "uploadId must be a UUID.");
  }
  const asset = await ops.getAssetByUpload(principal.accountId, uploadId);
  if (asset === undefined) {
    return notFound(context.requestId);
  }
  const bytes = new Uint8Array(await context.request.arrayBuffer());
  await objects.put(asset.objectKey, bytes);
  return jsonResponse({ ok: true });
}

async function completeUpload(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  objects: ObjectStore,
  uploadId: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (!UUID_PATTERN.test(uploadId)) {
    return fieldError(context.requestId, "uploadId", "uploadId must be a UUID.");
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const stored = await ops.getAssetByUpload(principal.accountId, uploadId);
      if (stored === undefined) {
        return notFound(context.requestId);
      }
      const object = await objects.get(stored.objectKey);
      if (object === undefined) {
        return fieldError(context.requestId, "uploadId", "Upload body is missing.");
      }
      const completed = await ops.completeAsset(principal.accountId, uploadId);
      if (completed === undefined) {
        return notFound(context.requestId);
      }
      const payload: Asset = {
        id: completed.id,
        kind: completed.kind,
        contentType: completed.contentType,
        sizeBytes: completed.sizeBytes,
        sha256: completed.sha256,
        status: completed.status,
        createdAt: completed.createdAt,
        deletedAt: completed.deletedAt,
      };
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
  );
}

async function createDownload(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  assetId: string,
  origin: string,
): Promise<Response> {
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (!UUID_PATTERN.test(assetId)) {
    return fieldError(context.requestId, "assetId", "assetId must be a UUID.");
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const asset = await ops.getAsset(principal.accountId, assetId);
      if (asset === undefined || asset.status !== "ready") {
        return notFound(context.requestId);
      }
      const expiresSeconds = 15 * 60;
      const signed = await context.objects?.signedDownloadUrl?.(asset.objectKey, expiresSeconds);
      const payload: SignedDownload = {
        url: signed ?? `${origin}/v1/assets/${asset.id}/content`,
        expiresAt: new Date(Date.now() + expiresSeconds * 1000).toISOString(),
      };
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
  );
}

async function getContent(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  objects: ObjectStore,
  assetId: string,
): Promise<Response> {
  const asset = await ops.getAsset(principal.accountId, assetId);
  if (asset === undefined || asset.status !== "ready") {
    return notFound(context.requestId);
  }
  const bytes = await objects.get(asset.objectKey);
  if (bytes === undefined) {
    return notFound(context.requestId);
  }
  return new Response(bytes, {
    status: 200,
    headers: { "content-type": asset.contentType },
  });
}
