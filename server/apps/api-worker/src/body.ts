import { problemResponse } from "./http";

export const DEFAULT_MAX_BODY_BYTES = 1_048_576;

const WRITE_METHODS = new Set(["POST", "PUT", "PATCH"]);

export async function validateRequestBody(
  request: Request,
  maxBodyBytes: number,
  requestId: string,
): Promise<Response | undefined> {
  const method = request.method.toUpperCase();
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") {
    return undefined;
  }

  const contentLengthHeader = request.headers.get("content-length");
  if (contentLengthHeader !== null) {
    const contentLength = Number(contentLengthHeader);
    if (!Number.isFinite(contentLength) || contentLength < 0) {
      return problemResponse({
        status: 400,
        code: "bad_request",
        title: "Bad request",
        detail: "Content-Length is invalid.",
        traceId: requestId,
      });
    }
    if (contentLength > maxBodyBytes) {
      return payloadTooLarge(requestId);
    }
  } else if (request.body !== null) {
    const bytes = await request.clone().arrayBuffer();
    if (bytes.byteLength > maxBodyBytes) {
      return payloadTooLarge(requestId);
    }
  }

  if (!WRITE_METHODS.has(method)) {
    return undefined;
  }

  const raw = request.headers.get("content-type");
  const mediaType = raw?.split(";")[0]?.trim().toLowerCase() ?? "";
  if (mediaType !== "application/json") {
    return problemResponse({
      status: 415,
      code: "unsupported_media_type",
      title: "Unsupported media type",
      detail: "Write requests must use Content-Type: application/json.",
      traceId: requestId,
    });
  }
  return undefined;
}

function payloadTooLarge(requestId: string): Response {
  return problemResponse({
    status: 413,
    code: "payload_too_large",
    title: "Payload too large",
    detail: "The request body exceeds the allowed size.",
    traceId: requestId,
  });
}
