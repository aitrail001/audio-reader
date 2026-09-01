import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import {
  AssetReservationError,
  type IdentityStore,
  type OpsAsset,
  type OpsStore,
} from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import type { ObjectStore } from "./object-store";
import {
  contentAddressedObjectKey,
  isAssetManifestKind,
  pendingUploadObjectKey,
  validateAssetManifestDraft,
  verifyAssetStream,
} from "./asset-manifest-policy";
import {
  UUID_PATTERN,
  conflict,
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
const V2_COMPLETE = /^\/v2\/assets\/uploads\/([^/]+)\/complete$/;
const V2_BODY = /^\/v2\/assets\/uploads\/([^/]+)\/body$/;
const V2_DOWNLOAD = /^\/v2\/assets\/([^/]+)\/download$/;
const V2_CONTENT = /^\/v2\/assets\/([^/]+)\/content$/;
const V2_ASSET = /^\/v2\/assets\/(?!uploads$)([^/]+)$/;
const MAX_WORKER_UPLOAD_BYTES = 8 * 1024 * 1024;

export function isBinaryAssetPath(path: string): boolean {
  return BODY.test(path) || CONTENT.test(path) || V2_BODY.test(path) || V2_CONTENT.test(path);
}

export type AssetRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  ops?: OpsStore;
  identity?: IdentityStore;
  objects?: ObjectStore;
};

export function isAssetPath(path: string): boolean {
  return (
    path === "/v2/assets" ||
    path === "/v1/uploads" ||
    path === "/v2/assets/uploads" ||
    COMPLETE.test(path) ||
    V2_COMPLETE.test(path) ||
    BODY.test(path) ||
    V2_BODY.test(path) ||
    DOWNLOAD.test(path) ||
    V2_DOWNLOAD.test(path) ||
    CONTENT.test(path) ||
    V2_CONTENT.test(path) ||
    V2_ASSET.test(path)
  );
}

export function assetMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const upper = method.toUpperCase();
  if (path === "/v2/assets" && upper !== "GET") {
    return methodNotAllowed(["GET"], requestId);
  }
  if (V2_ASSET.test(path) && upper !== "GET") {
    return methodNotAllowed(["GET"], requestId);
  }
  if ((path === "/v1/uploads" || path === "/v2/assets/uploads") && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if ((COMPLETE.test(path) || V2_COMPLETE.test(path)) && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if ((BODY.test(path) || V2_BODY.test(path)) && upper !== "PUT") {
    return methodNotAllowed(["PUT"], requestId);
  }
  if ((DOWNLOAD.test(path) || V2_DOWNLOAD.test(path)) && upper !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  if ((CONTENT.test(path) || V2_CONTENT.test(path)) && upper !== "GET" && upper !== "HEAD") {
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
  if (path.startsWith("/v1/")) {
    return asHead(
      context.request,
      problemResponse({
        status: 426,
        code: "upgrade_required",
        title: "Upgrade required",
        detail: "The v1 asset adapter is retired. Upgrade to the private v2 asset protocol.",
        traceId: context.requestId,
        headers: { "X-Min-App-Version": "2.0.0" },
      }),
    );
  }
  const ops = context.ops;
  const objects = context.objects;
  if (ops === undefined || objects === undefined) {
    return notFound(context.requestId, "Object storage is not configured.");
  }
  if (path === "/v2/assets") {
    const kind = url.searchParams.get("kind") ?? undefined;
    const bookId = url.searchParams.get("bookId") ?? undefined;
    const chapterId = url.searchParams.get("chapterId") ?? undefined;
    if (kind !== undefined && !isAssetManifestKind(kind)) {
      return fieldError(context.requestId, "kind", "kind is unsupported.");
    }
    if (bookId !== undefined && !UUID_PATTERN.test(bookId)) {
      return fieldError(context.requestId, "bookId", "bookId must be a UUID.");
    }
    if (chapterId !== undefined && !UUID_PATTERN.test(chapterId)) {
      return fieldError(context.requestId, "chapterId", "chapterId must be a UUID.");
    }
    const assets = await ops.listAssets(principal.accountId, {
      ...(kind === undefined ? {} : { kind }),
      ...(bookId === undefined ? {} : { bookId }),
      ...(chapterId === undefined ? {} : { chapterId }),
    });
    return jsonResponse({ assets: assets.map(assetResponse) });
  }
  const direct = V2_ASSET.exec(path);
  if (direct?.[1] !== undefined) {
    if (!UUID_PATTERN.test(direct[1])) {
      return fieldError(context.requestId, "assetId", "assetId must be a UUID.");
    }
    const asset = await ops.getAsset(principal.accountId, direct[1]);
    if (asset === undefined || asset.status !== "ready") {
      return notFound(context.requestId);
    }
    return jsonResponse(assetResponse(asset));
  }
  if (path === "/v1/uploads" || path === "/v2/assets/uploads") {
    return createUpload(context, principal, ops, objects, url.origin);
  }
  const complete = COMPLETE.exec(path) ?? V2_COMPLETE.exec(path);
  if (complete?.[1] !== undefined) {
    return completeUpload(context, principal, ops, objects, complete[1]);
  }
  const body = BODY.exec(path) ?? V2_BODY.exec(path);
  if (body?.[1] !== undefined) {
    return putUploadBody(context, principal, ops, objects, body[1]);
  }
  const download = DOWNLOAD.exec(path) ?? V2_DOWNLOAD.exec(path);
  if (download?.[1] !== undefined) {
    return createDownload(
      context,
      principal,
      ops,
      download[1],
      url.origin,
      path.startsWith("/v2/"),
    );
  }
  const content = CONTENT.exec(path) ?? V2_CONTENT.exec(path);
  if (content?.[1] !== undefined) {
    return getContent(context, principal, ops, objects, content[1]);
  }
  return undefined;
}

async function createUpload(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  objects: ObjectStore,
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
      const validated = validateAssetManifestDraft(body.value);
      if (!validated.ok) {
        return fieldError(context.requestId, validated.field, validated.message);
      }
      const fileName = requiredString(body.value.fileName, "fileName", context.requestId);
      if (fileName instanceof Response) {
        return fileName;
      }
      const manifest = validated.value;
      const existing = await ops.getAssetByContent(
        principal.accountId,
        manifest.kind,
        manifest.sha256,
      );
      if (existing !== undefined) {
        if (
          existing.revisionId !== manifest.revisionId ||
          existing.chapterId !== manifest.chapterId ||
          existing.compressedBytes !== manifest.compressedBytes
        ) {
          return conflict(
            context.requestId,
            "Content digest is already bound to different metadata.",
          );
        }
        if (existing.status !== "pending" && existing.status !== "ready") {
          return conflict(context.requestId, "Asset upload is no longer writable.");
        }
        const upload =
          existing.status === "ready"
            ? workerUploadTarget(
                existing.uploadId,
                existing.compressedBytes,
                existing.contentType,
                origin,
              )
            : await authorizedUploadTarget(ops, objects, principal.accountId, existing, origin);
        if (upload === undefined) {
          return directUploadUnavailable(context.requestId);
        }
        const ticket: UploadTicket = {
          uploadId: existing.uploadId,
          assetId: existing.id,
          method: "PUT",
          url: upload.url,
          expiresAt: upload.expiresAt,
          headers: upload.headers,
          multipart: false,
          ready: existing.status === "ready",
        };
        return jsonResponse(ticket, existing.status === "ready" ? 200 : 201);
      }
      const uploadId = crypto.randomUUID();
      const uploadObjectKey = pendingUploadObjectKey(principal.accountId, uploadId);
      let asset: OpsAsset;
      try {
        asset = await ops.createAsset(principal.accountId, {
          ...manifest,
          fileName,
          objectKey: contentAddressedObjectKey(principal.accountId, manifest.kind, manifest.sha256),
          uploadObjectKey,
          uploadId,
        });
      } catch (error) {
        if (error instanceof AssetReservationError) {
          if (error.code === "asset_book_deleted") {
            return conflict(context.requestId, "Asset book is already deleted.");
          }
          return problemResponse({
            status: 429,
            code: error.code,
            title: "Asset reservation rejected",
            detail:
              error.code === "pending_asset_count_exceeded"
                ? "Too many private uploads are pending."
                : "Private object quota would be exceeded.",
            traceId: context.requestId,
          });
        }
        throw error;
      }
      const upload = await authorizedUploadTarget(ops, objects, principal.accountId, asset, origin);
      if (upload === undefined) {
        return directUploadUnavailable(context.requestId);
      }
      const ticket: UploadTicket = {
        uploadId: asset.uploadId,
        assetId: asset.id,
        method: "PUT",
        url: upload.url,
        expiresAt: upload.expiresAt,
        headers: upload.headers,
        multipart: false,
        ready: false,
      };
      return jsonResponse(ticket, 201);
    },
    context.requestId,
    principal,
  );
}

/** Persists a conservative capability deadline before any irrevocable direct-upload URL is issued. */
async function authorizedUploadTarget(
  ops: OpsStore,
  objects: ObjectStore,
  accountId: string,
  asset: OpsAsset,
  origin: string,
): Promise<{ url: string; headers: Record<string, string>; expiresAt: string } | undefined> {
  if (asset.compressedBytes <= MAX_WORKER_UPLOAD_BYTES) {
    return workerUploadTarget(asset.uploadId, asset.compressedBytes, asset.contentType, origin);
  }
  const durableUntil = new Date(Date.now() + 16 * 60_000).toISOString();
  const authorized = await ops.authorizeAssetUpload(accountId, asset.uploadId, durableUntil);
  if (authorized === undefined) return undefined;
  return uploadTarget(
    objects,
    asset.uploadObjectKey,
    asset.uploadId,
    asset.compressedBytes,
    asset.contentType,
    asset.sha256,
    origin,
  );
}

function workerUploadTarget(
  uploadId: string,
  compressedBytes: number,
  contentType: string,
  origin: string,
): { url: string; headers: Record<string, string>; expiresAt: string } {
  return {
    url: `${origin}/v2/assets/uploads/${uploadId}/body`,
    expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(),
    headers: { "content-type": contentType, "content-length": String(compressedBytes) },
  };
}

async function uploadTarget(
  objects: ObjectStore,
  uploadObjectKey: string,
  uploadId: string,
  compressedBytes: number,
  contentType: string,
  sha256: string,
  origin: string,
): Promise<{ url: string; headers: Record<string, string>; expiresAt: string } | undefined> {
  if (compressedBytes <= MAX_WORKER_UPLOAD_BYTES) {
    return workerUploadTarget(uploadId, compressedBytes, contentType, origin);
  }
  return objects.createBoundUpload?.(uploadObjectKey, {
    expiresSeconds: 15 * 60,
    contentType,
    contentLength: compressedBytes,
    sha256,
  });
}

function directUploadUnavailable(requestId: string): Response {
  return problemResponse({
    status: 503,
    code: "direct_upload_unavailable",
    title: "Direct upload unavailable",
    detail: "Large private objects require a short-lived direct upload URL.",
    traceId: requestId,
  });
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
  if (asset === undefined || asset.status !== "pending") {
    return notFound(context.requestId);
  }
  if (asset.compressedBytes > MAX_WORKER_UPLOAD_BYTES) {
    return fieldError(context.requestId, "body", "Large objects must use direct upload.");
  }
  const declaredLength = context.request.headers.get("content-length");
  if (declaredLength === null) {
    return problemResponse({
      status: 411,
      code: "content_length_required",
      title: "Content-Length required",
      detail: "Bounded upload fallback requires an exact Content-Length header.",
      traceId: context.requestId,
    });
  }
  if (Number(declaredLength) !== asset.compressedBytes) {
    return fieldError(
      context.requestId,
      "content-length",
      "Upload size does not match its manifest.",
    );
  }
  const bytes = await readBoundedUpload(context.request, asset.compressedBytes);
  if (bytes === undefined) {
    return fieldError(context.requestId, "body", "Upload size does not match its manifest.");
  }
  if (bytes.byteLength !== asset.compressedBytes) {
    return fieldError(context.requestId, "body", "Upload size does not match its manifest.");
  }
  if (!(await objectWriteIsAllowed(context.identity, principal.accountId))) {
    return conflict(context.requestId, "Account deletion is already in progress.");
  }
  const lease = await ops.beginAssetObjectWrite(
    principal.accountId,
    asset.id,
    asset.uploadObjectKey,
  );
  if (lease === undefined) {
    return conflict(context.requestId, "Asset upload is no longer writable.");
  }
  await objects.put(asset.uploadObjectKey, bytes);
  // Account deletion and storage writes are separate systems. Re-check after the write and
  // compensate so a request that raced the deletion sweep cannot recreate private media.
  const current = await ops.getAssetByUpload(principal.accountId, uploadId);
  if (
    !(await objectWriteIsAllowed(context.identity, principal.accountId)) ||
    current?.status !== "pending"
  ) {
    await objects.delete(asset.uploadObjectKey);
    await ops.finishObjectWrite(lease.id);
    return conflict(context.requestId, "Asset deletion began while the upload was in progress.");
  }
  await ops.finishObjectWrite(lease.id);
  return jsonResponse({ ok: true });
}

/** Reads the Worker fallback stream without ever buffering beyond the reserved manifest size. */
async function readBoundedUpload(
  request: Request,
  expectedBytes: number,
): Promise<Uint8Array | undefined> {
  const reader = request.body?.getReader();
  if (reader === undefined) return expectedBytes === 0 ? new Uint8Array() : undefined;
  const chunks: Uint8Array[] = [];
  let total = 0;
  let next = (await reader.read()) as ReadableStreamReadResult<Uint8Array>;
  while (!next.done) {
    total += next.value.byteLength;
    if (total > expectedBytes || total > MAX_WORKER_UPLOAD_BYTES) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(next.value);
    next = await reader.read();
  }
  if (total !== expectedBytes) return undefined;
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
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
      if (stored.status === "ready") {
        if (uploadCapabilityActive(stored)) return jsonResponse(assetResponse(stored));
        try {
          await objects.delete(stored.uploadObjectKey);
          await ops.finishReadyAssetUploadCleanup([stored.id]);
        } catch {
          return problemResponse({
            status: 503,
            code: "upload_cleanup_pending",
            title: "Upload cleanup pending",
            detail: "The immutable object is ready but temporary upload cleanup will be retried.",
            traceId: context.requestId,
          });
        }
        return jsonResponse(assetResponse(stored));
      }
      if (stored.status !== "pending") {
        return conflict(context.requestId, "Asset upload is no longer writable.");
      }
      const object = await objects.open(stored.uploadObjectKey);
      if (object === undefined) {
        return fieldError(context.requestId, "uploadId", "Upload body is missing.");
      }
      if (
        !(await verifyAssetStream(
          {
            compressedBytes: stored.compressedBytes,
            sha256: stored.sha256,
            kind: stored.kind,
            encoding: stored.encoding,
            originalBytes: stored.originalBytes,
            segmentCount: stored.segmentCount,
          },
          object,
        ))
      ) {
        console.warn(
          JSON.stringify({
            level: "warn",
            message: "asset_upload_verification_failed",
            requestId: context.requestId,
            component: "assets",
            outcome: "rejected",
            assetId: stored.id,
          }),
        );
        return fieldError(
          context.requestId,
          "uploadId",
          "Upload size or checksum does not match the manifest.",
        );
      }
      if (!(await objectWriteIsAllowed(context.identity, principal.accountId))) {
        return conflict(context.requestId, "Account deletion is already in progress.");
      }
      const lease = await ops.beginAssetObjectWrite(
        principal.accountId,
        stored.id,
        stored.objectKey,
      );
      if (lease === undefined) {
        return conflict(context.requestId, "Asset upload is no longer writable.");
      }
      const existing = await objects.open(stored.objectKey);
      if (
        existing !== undefined &&
        !(await verifyAssetStream(
          {
            compressedBytes: stored.compressedBytes,
            sha256: stored.sha256,
            kind: stored.kind,
            encoding: stored.encoding,
            originalBytes: stored.originalBytes,
            segmentCount: stored.segmentCount,
          },
          existing,
        ))
      ) {
        await ops.finishObjectWrite(lease.id);
        return fieldError(
          context.requestId,
          "uploadId",
          "Immutable object key already contains different bytes.",
        );
      }
      if (existing === undefined) await objects.copy(stored.uploadObjectKey, stored.objectKey);
      const current = await ops.getAssetByUpload(principal.accountId, uploadId);
      if (
        !(await objectWriteIsAllowed(context.identity, principal.accountId)) ||
        current?.status !== "pending"
      ) {
        await objects.delete(stored.objectKey);
        await ops.finishObjectWrite(lease.id);
        return conflict(context.requestId, "Asset deletion began while the upload was completing.");
      }
      const completed = await ops.completeAsset(principal.accountId, uploadId);
      if (completed === undefined) {
        await objects.delete(stored.objectKey);
        await ops.finishObjectWrite(lease.id);
        return notFound(context.requestId);
      }
      if (uploadCapabilityActive(completed)) {
        await ops.finishObjectWrite(lease.id);
        return jsonResponse(assetResponse(completed));
      }
      try {
        await objects.delete(stored.uploadObjectKey);
        await ops.finishReadyAssetUploadCleanup([completed.id]);
      } catch {
        await ops.finishObjectWrite(lease.id);
        return problemResponse({
          status: 503,
          code: "upload_cleanup_pending",
          title: "Upload cleanup pending",
          detail: "The immutable object is ready but temporary upload cleanup will be retried.",
          traceId: context.requestId,
        });
      }
      await ops.finishObjectWrite(lease.id);
      return jsonResponse(assetResponse(completed));
    },
    context.requestId,
    principal,
  );
}

function uploadCapabilityActive(asset: OpsAsset): boolean {
  return (
    asset.uploadAuthorizedUntil !== null && Date.parse(asset.uploadAuthorizedUntil) > Date.now()
  );
}

function assetResponse(asset: OpsAsset): Asset {
  return {
    id: asset.id,
    kind: asset.kind,
    contentType: asset.contentType,
    sizeBytes: asset.compressedBytes,
    compressedBytes: asset.compressedBytes,
    originalBytes: asset.originalBytes,
    sha256: asset.sha256,
    encoding: asset.encoding,
    revisionId: asset.revisionId,
    bookId: asset.bookId,
    chapterId: asset.chapterId,
    segmentCount: asset.segmentCount,
    status: asset.status,
    createdAt: asset.createdAt,
    deletedAt: asset.deletedAt,
  };
}

async function createDownload(
  context: AssetRouteContext,
  principal: Principal,
  ops: OpsStore,
  assetId: string,
  origin: string,
  v2: boolean,
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
        url: signed ?? `${origin}/${v2 ? "v2" : "v1"}/assets/${asset.id}/content`,
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
    headers: {
      "content-type": asset.contentType,
      "content-length": String(asset.compressedBytes),
    },
  });
}
