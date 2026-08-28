import type { Principal } from "@audio-reader/auth";
import { problemResponse } from "./http";

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function requirePrincipal(input: {
  authenticate: (request: Request) => Promise<Principal | null>;
  request: Request;
  requestId: string;
}): Promise<Principal | Response> {
  const principal = await input.authenticate(input.request);
  if (principal === null) {
    return problemResponse({
      status: 401,
      code: "unauthorized",
      title: "Unauthorized",
      detail: "Authentication required.",
      traceId: input.requestId,
    });
  }
  return principal;
}

export async function requireAdmin(input: {
  authenticate: (request: Request) => Promise<Principal | null>;
  request: Request;
  requestId: string;
}): Promise<Principal | Response> {
  const principal = await requirePrincipal(input);
  if (principal instanceof Response) {
    return principal;
  }
  if (principal.role !== "admin") {
    return problemResponse({
      status: 403,
      code: "forbidden",
      title: "Forbidden",
      detail: "This endpoint requires an admin capability.",
      traceId: input.requestId,
    });
  }
  return principal;
}

export function requireDeviceId(request: Request, requestId: string): string | Response {
  const deviceId = request.headers.get("X-Device-Id")?.trim() ?? "";
  if (!UUID_PATTERN.test(deviceId)) {
    return problemResponse({
      status: 400,
      code: "bad_request",
      title: "Bad request",
      detail: "X-Device-Id must be a UUID.",
      traceId: requestId,
    });
  }
  return deviceId;
}

export function fieldError(requestId: string, field: string, message: string): Response {
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: message,
    traceId: requestId,
    fieldErrors: [{ field, message }],
  });
}

export function notFound(
  requestId: string,
  detail = "The requested resource does not exist.",
): Response {
  return problemResponse({
    status: 404,
    code: "not_found",
    title: "Not found",
    detail,
    traceId: requestId,
  });
}

export function conflict(
  requestId: string,
  detail = "The resource revision does not match.",
): Response {
  return problemResponse({
    status: 409,
    code: "conflict",
    title: "Conflict",
    detail,
    traceId: requestId,
  });
}

export function requiredString(
  value: unknown,
  field: string,
  requestId: string,
): string | Response {
  if (typeof value !== "string" || value.trim() === "") {
    return fieldError(requestId, field, `${field} is required.`);
  }
  return value.trim();
}

export function requiredUuid(value: unknown, field: string, requestId: string): string | Response {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    return fieldError(requestId, field, `${field} must be a UUID.`);
  }
  return value;
}

export function parseLimit(url: URL, requestId: string, fallback = 100): number | Response {
  const raw = url.searchParams.get("limit");
  const limit = raw === null || raw.trim() === "" ? fallback : Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
    return fieldError(requestId, "limit", "limit must be an integer between 1 and 500.");
  }
  return limit;
}

export function pageCursor<T>(
  items: T[],
  cursor: string | null,
  limit: number,
): { items: T[]; nextCursor: string | null } {
  const start = cursor === null || cursor.trim() === "" ? 0 : Number(cursor);
  const offset = Number.isInteger(start) && start >= 0 ? start : 0;
  const sliced = items.slice(offset, offset + limit);
  const next = offset + sliced.length;
  return {
    items: sliced,
    nextCursor: next < items.length ? String(next) : null,
  };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function methodNotAllowed(allowed: readonly string[], requestId: string): Response {
  return problemResponse({
    status: 405,
    code: "method_not_allowed",
    title: "Method not allowed",
    detail: `This endpoint accepts ${allowed.join(", ")}.`,
    traceId: requestId,
    headers: { Allow: allowed.join(", ") },
  });
}
