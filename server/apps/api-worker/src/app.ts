import {
  LOCAL_JWT_CONFIG,
  createFakePrincipal,
  createMemoryAuthService,
  type AuthService,
  type Principal,
} from "@audio-reader/auth";
import { createFakeDatabaseClient } from "@audio-reader/database";
import { logUnhandledError, resolveRequestId } from "@audio-reader/observability";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { authMethodError, handleAuthRoute, isAuthPath } from "./auth-routes";
import { DEFAULT_MAX_BODY_BYTES, validateRequestBody } from "./body";
import { applyCorsHeaders, resolveCorsAllowlist } from "./cors";
import {
  parseEnvironment,
  parseOriginList,
  parsePositiveInt,
  resolveJwtSigningConfig,
  type AppEnvironment,
  type WorkerEnv,
} from "./env";
import { buildHealth, unavailableProbe, type DependencyProbe } from "./health";
import { asHead, jsonResponse, problemResponse, withRequestId } from "./http";
import { createMemoryIdempotencyStore, type IdempotencyStore } from "./idempotency";
import { createFakeObjectStore } from "./object-store";

const HEALTH_PATHS = new Set(["/v1/health", "/healthz", "/readyz"]);

export type { WorkerEnv } from "./env";

export type AppOptions = {
  environment: AppEnvironment;
  version: string;
  maxBodyBytes?: number;
  corsOrigins: readonly string[];
  adminOrigin?: string;
  database: DependencyProbe;
  r2: DependencyProbe;
  qwen: DependencyProbe;
  authenticate?: (request: Request) => Principal | Promise<Principal | null> | null;
  auth?: AuthService;
  idempotencyStore?: IdempotencyStore;
};

export type ApiApp = {
  fetch(request: Request): Promise<Response>;
  authenticate(request: Request): Promise<Principal | null>;
};

export function createApiApp(options: AppOptions): ApiApp {
  const allowlist = resolveCorsAllowlist(options);
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  const idempotencyStore = options.idempotencyStore ?? createMemoryIdempotencyStore();

  async function authenticate(request: Request): Promise<Principal | null> {
    const principal = await options.authenticate?.(request);
    return principal ?? null;
  }

  async function handleFetch(request: Request): Promise<Response> {
    const requestId = resolveRequestId(request.headers.get("X-Request-Id"));
    try {
      const response = await handleRequest(
        request,
        requestId,
        options,
        maxBodyBytes,
        authenticate,
        idempotencyStore,
      );
      return applyCorsHeaders(request, withRequestId(response, requestId), allowlist);
    } catch (error: unknown) {
      logUnhandledError(requestId, error);
      const response = problemResponse({
        status: 500,
        code: "internal_error",
        title: "Internal server error",
        detail: "An unexpected error occurred.",
        traceId: requestId,
      });
      return applyCorsHeaders(request, withRequestId(response, requestId), allowlist);
    }
  }

  return { fetch: handleFetch, authenticate };
}

export function createTestApp(overrides: Partial<AppOptions> = {}): ApiApp {
  return createApiApp({
    environment: "test",
    version: "1.0.0-draft.1",
    corsOrigins: ["http://localhost:5173"],
    database: createFakeDatabaseClient(),
    r2: createFakeObjectStore(),
    qwen: createFakeQwenClient(),
    auth: createMemoryAuthService({ jwt: LOCAL_JWT_CONFIG }),
    authenticate: () => createFakePrincipal(),
    ...overrides,
  });
}

export function createApiAppFromEnv(env: WorkerEnv): ApiApp {
  const environment = parseEnvironment(env.ENVIRONMENT);
  const useFakes = environment === "local" || environment === "test";
  const adminOrigin = env.ADMIN_ORIGIN?.trim();
  const version = env.APP_VERSION?.trim();
  const jwt = resolveJwtSigningConfig(env, environment);
  const auth = jwt === undefined ? undefined : createMemoryAuthService({ jwt });
  return createApiApp({
    environment,
    version: version === undefined || version === "" ? "1.0.0-draft.1" : version,
    maxBodyBytes: parsePositiveInt(env.MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES),
    corsOrigins: parseOriginList(env.CORS_ALLOWED_ORIGINS),
    ...(adminOrigin !== undefined && adminOrigin !== "" ? { adminOrigin } : {}),
    database: useFakes ? createFakeDatabaseClient() : unavailableProbe(),
    r2: useFakes ? createFakeObjectStore() : unavailableProbe(),
    qwen: useFakes ? createFakeQwenClient() : unavailableProbe(),
    ...(auth === undefined ? {} : { auth }),
    authenticate: auth === undefined ? () => null : (request) => auth.authenticate(request),
  });
}

async function handleRequest(
  request: Request,
  requestId: string,
  options: AppOptions,
  maxBodyBytes: number,
  authenticate: (request: Request) => Promise<Principal | null>,
  idempotencyStore: IdempotencyStore,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  const path = new URL(request.url).pathname;
  if (HEALTH_PATHS.has(path)) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return problemResponse({
        status: 405,
        code: "method_not_allowed",
        title: "Method not allowed",
        detail: "Health endpoints accept GET or HEAD.",
        traceId: requestId,
        headers: { Allow: "GET, HEAD" },
      });
    }
    const includeDependencies = path !== "/healthz";
    const health = await buildHealth({
      version: options.version,
      includeDependencies,
      database: options.database,
      r2: options.r2,
      qwen: options.qwen,
    });
    if (path === "/readyz" && health.status !== "ok") {
      return asHead(
        request,
        problemResponse({
          status: 503,
          code: "not_ready",
          title: "Service unavailable",
          detail: "One or more dependencies are unavailable.",
          traceId: requestId,
        }),
      );
    }
    return asHead(request, jsonResponse(health));
  }

  const methodError = authMethodError(path, request.method, requestId);
  if (methodError !== undefined) {
    return methodError;
  }

  const bodyError = await validateRequestBody(request, maxBodyBytes, requestId);
  if (bodyError !== undefined) {
    return bodyError;
  }

  if (isAuthPath(path)) {
    const routed = await handleAuthRoute({
      request,
      requestId,
      ...(options.auth === undefined ? {} : { auth: options.auth }),
      authenticate,
      idempotencyStore,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  return problemResponse({
    status: 404,
    code: "not_found",
    title: "Not found",
    detail: "The requested path does not exist.",
    traceId: requestId,
  });
}
