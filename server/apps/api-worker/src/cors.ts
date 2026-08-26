import type { AppEnvironment } from "./env";

const LOCAL_ORIGINS = [
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:8787",
  "http://127.0.0.1:8787",
] as const;

const ALLOW_HEADERS = [
  "Authorization",
  "Content-Type",
  "X-Request-Id",
  "X-Device-Id",
  "Idempotency-Key",
] as const;

const ALLOW_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"] as const;

export function resolveCorsAllowlist(options: {
  environment: AppEnvironment;
  corsOrigins: readonly string[];
  adminOrigin?: string;
}): string[] {
  const origins = [...options.corsOrigins];
  if (options.adminOrigin !== undefined && options.adminOrigin !== "") {
    origins.push(options.adminOrigin);
  }
  if (options.environment === "local") {
    origins.push(...LOCAL_ORIGINS);
  }
  return [...new Set(origins.filter((origin) => origin !== ""))];
}

export function applyCorsHeaders(
  request: Request,
  response: Response,
  allowlist: readonly string[],
): Response {
  const origin = request.headers.get("origin");
  if (origin === null || !allowlist.includes(origin)) {
    return response;
  }
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", origin);
  headers.set("access-control-allow-credentials", "true");
  headers.set("access-control-allow-methods", ALLOW_METHODS.join(", "));
  headers.set("access-control-allow-headers", ALLOW_HEADERS.join(", "));
  headers.set("access-control-expose-headers", "X-Request-Id");
  headers.append("vary", "Origin");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
