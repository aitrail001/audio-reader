import {
  LOCAL_JWT_CONFIG,
  LOCAL_PASSWORDLESS_HMAC_SECRET,
  createCloudflareTurnstileVerifier,
  createFakePrincipal,
  createHostedAuthService,
  createMemoryAuthService,
  createDurablePasswordlessLimiter,
  createMemoryPasswordlessLimiter,
  type AuthService,
  type HostedOtpMailer,
  type JwtSigningConfig,
  type PasswordlessLimiter,
  type Principal,
  type TurnstileVerifier,
} from "@audio-reader/auth";
import {
  createFakeDatabaseClient,
  createSupabaseDatabaseClient,
  createSupabaseRestClient,
  createUnavailableDatabaseClient,
  type DatabaseClient,
} from "@audio-reader/database";
import { createFakeQwenClient, type QwenClient } from "@audio-reader/qwen";
import { authMethodError, handleAuthRoute, isAuthPath } from "./auth-routes";
import { DEFAULT_MAX_BODY_BYTES, SYNC_PUSH_MAX_BODY_BYTES, validateRequestBody } from "./body";
import { applyCorsHeaders, resolveCorsAllowlist } from "./cors";
import {
  parseEnvironment,
  parseLocalDevOtp,
  parseOriginList,
  parsePositiveInt,
  resolveCacheHmacSecret,
  resolveHostedAuthConfig,
  resolveJwtSigningConfig,
  resolveOperatorWrappingSecret,
  resolvePasswordlessHmacSecret,
  resolveSupabaseRestConfig,
  type AppEnvironment,
  type WorkerEnv,
} from "./env";
import { buildHealth, isServiceReady } from "./health";
import { asHead, jsonResponse, problemResponse, withRequestId } from "./http";
import { logSecurityEvent, logUnhandledError, resolveRequestId } from "./observability";
import { createPostgresPasswordlessStore } from "./durable-stores";
import {
  createMemoryIdempotencyStore,
  createPostgresIdempotencyStore,
  type IdempotencyStore,
} from "./idempotency";
import { createResendOtpMailer } from "./otp-mail";
import {
  createFakeObjectStore,
  createResolvingObjectStore,
  type ObjectStore,
} from "./object-store";
import {
  createResolvingQwenClient,
  createRuntimeConfigService,
  type RuntimeConfigService,
} from "./runtime-config";
import { handleAssistantRoute, assistantMethodError, isAssistantPath } from "./assistant-routes";
import { handleSyncRoute, isSyncPath, syncMethodError } from "./sync-routes";
import { handleLibraryRoute, isLibraryPath, libraryMethodError } from "./library-routes";
import { assetMethodError, handleAssetRoute, isAssetPath, isBinaryAssetPath } from "./asset-routes";
import { handlePrivacyRoute, isPrivacyPath, privacyMethodError } from "./privacy-routes";
import { adminMethodError, handleAdminRoute, isAdminPath } from "./admin-routes";
import {
  handleProductEventRoute,
  isProductEventPath,
  productEventMethodError,
} from "./product-events";
import {
  createAccountSyncReadinessService,
  type AccountSyncReadinessService,
  type AccountSyncStorageDescriptor,
} from "./account-sync-readiness";

const HEALTH_PATHS = new Set(["/v1/health", "/healthz", "/readyz"]);

export type { WorkerEnv } from "./env";

export type AppOptions = {
  environment: AppEnvironment;
  version: string;
  maxBodyBytes?: number;
  corsOrigins: readonly string[];
  adminOrigin?: string;
  database: DatabaseClient;
  storage: ObjectStore;
  storageDescriptor?: () => Promise<AccountSyncStorageDescriptor>;
  resolveAccountSyncStorage?: () => Promise<{
    store: ObjectStore;
    descriptor: AccountSyncStorageDescriptor;
  }>;
  accountSyncReadiness?: AccountSyncReadinessService;
  qwen: QwenClient;
  runtime?: RuntimeConfigService;
  authenticate?: (request: Request) => Principal | Promise<Principal | null> | null;
  auth?: AuthService;
  idempotencyStore?: IdempotencyStore;
  passwordlessLimiter?: PasswordlessLimiter;
  verifyTurnstile?: TurnstileVerifier;
  hmacSecret?: string;
  cacheHmacSecret?: string;
  turnstileSiteKey?: string;
};

export type ApiApp = {
  fetch(request: Request): Promise<Response>;
  authenticate(request: Request): Promise<Principal | null>;
};

export function createApiApp(options: AppOptions): ApiApp {
  const allowlist = resolveCorsAllowlist(options);
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  const idempotencyStore = options.idempotencyStore ?? createMemoryIdempotencyStore();
  const passwordlessLimiter =
    options.passwordlessLimiter ??
    createDefaultPasswordlessLimiter({
      environment: options.environment,
      ...(options.verifyTurnstile === undefined
        ? {}
        : { verifyTurnstile: options.verifyTurnstile }),
      hmacSecret: options.hmacSecret ?? LOCAL_PASSWORDLESS_HMAC_SECRET,
    });
  const accountSyncReadiness =
    options.accountSyncReadiness ??
    createAccountSyncReadinessService({
      database: options.database,
      resolveStorage:
        options.resolveAccountSyncStorage ??
        (async () => ({
          store: options.storage,
          descriptor: await (
            options.storageDescriptor ??
            (() =>
              Promise.resolve({
                provider: "none" as const,
                configured: false,
                credentialsConfigured: false,
              }))
          )(),
        })),
    });

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
        passwordlessLimiter,
        accountSyncReadiness,
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
  const {
    database: databaseOverride,
    runtime: runtimeOverride,
    storage: storageOverride,
    storageDescriptor: storageDescriptorOverride,
    ...rest
  } = overrides;
  const database = databaseOverride ?? createFakeDatabaseClient();
  // Route tests opt into sync explicitly; the database factory itself retains the new-environment off default.
  if (databaseOverride === undefined) {
    void database.ops.patchFlag("account_sync", { enabled: true });
  }
  const runtime =
    runtimeOverride ??
    createRuntimeConfigService({
      env: { ENVIRONMENT: "test" },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });
  const principal = createFakePrincipal();
  const testDeviceId = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
  database.identity.seedActiveDevice?.(principal.accountId, testDeviceId);
  const storage = storageOverride ?? createFakeObjectStore();
  const storageDescriptor =
    storageDescriptorOverride ??
    (storageOverride === undefined
      ? () =>
          Promise.resolve({
            provider: "memory" as const,
            bucket: "test-private-sync",
            configured: true,
            credentialsConfigured: true,
          })
      : () =>
          Promise.resolve({
            provider: "none" as const,
            configured: false,
            credentialsConfigured: false,
          }));
  return createApiApp({
    environment: "test",
    version: "1.0.0-draft.1",
    corsOrigins: ["http://localhost:5173"],
    storage,
    storageDescriptor,
    qwen: createFakeQwenClient(),
    auth: createMemoryAuthService({ jwt: LOCAL_JWT_CONFIG }),
    authenticate: () => principal,
    ...rest,
    database,
    runtime,
  });
}

export function createApiAppFromEnv(env: WorkerEnv): ApiApp {
  const environment = parseEnvironment(env.ENVIRONMENT);
  const useFakes = environment === "local" || environment === "test";
  const adminOrigin = env.ADMIN_ORIGIN?.trim();
  const version = env.APP_VERSION?.trim();
  const jwt = resolveJwtSigningConfig(env, environment);
  const localOtp = parseLocalDevOtp(env, environment);
  const hosted = resolveHostedAuthConfig(env, environment);
  const database = resolveDatabaseClient(env, useFakes);
  const rest = resolveSupabaseRestConfig(env);
  const bootstrapEmail = env.ADMIN_BOOTSTRAP_EMAIL?.trim() ?? "";
  const resendKey = env.RESEND_API_KEY?.trim() ?? "";
  const otpFrom = env.OTP_FROM_EMAIL?.trim() ?? "";
  const auth = createAuthServiceFromEnv({
    jwt,
    useFakes,
    localOtp,
    hosted,
    ...(rest === undefined ? {} : { identity: database.identity }),
    ...(bootstrapEmail === "" ? {} : { adminBootstrapEmail: bootstrapEmail }),
    ...(rest === undefined ? {} : { serviceRoleKey: rest.serviceRoleKey }),
    ...(resendKey === ""
      ? {}
      : {
          sendOtpEmail: createResendOtpMailer({
            apiKey: resendKey,
            ...(otpFrom === "" ? {} : { from: otpFrom }),
          }),
        }),
  });
  const turnstileSecret = env.TURNSTILE_SECRET_KEY?.trim() ?? "";
  const hmac = resolvePasswordlessHmacSecret(env);
  const cacheHmac = resolveCacheHmacSecret(env);
  const wrapping = resolveOperatorWrappingSecret(env);
  const runtime = createRuntimeConfigService({
    env,
    ops: database.ops,
    wrappingSecret: wrapping.secret,
    wrappingSource: wrapping.source,
  });
  if (!useFakes) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "operator_runtime_boot",
        wrappingSource: wrapping.source,
        wrappingConfigured: wrapping.secret.trim() !== "",
        qwenEnvKeyConfigured: (env.QWEN_API_KEY?.trim() ?? "") !== "",
        qwenEnvModel: env.QWEN_MODEL?.trim() ?? "",
        qwenEnvBaseUrlConfigured: (env.QWEN_BASE_URL?.trim() ?? "") !== "",
        operatorConfigKeyConfigured: (env.OPERATOR_CONFIG_KEY?.trim() ?? "") !== "",
        cacheHmacConfigured: (env.CACHE_HMAC_SECRET?.trim() ?? "") !== "",
      }),
    );
  }
  if (!useFakes && !hmac.fromEnv) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "passwordless_hmac_secret_missing",
        detail:
          "PASSWORDLESS_HMAC_SECRET (or CACHE_HMAC_SECRET) is unset; hashes use the local-dev pepper.",
      }),
    );
  }
  if (!useFakes && jwt !== undefined && hosted === undefined) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "hosted_auth_unconfigured",
        detail:
          "OTP and OAuth issuance require SUPABASE_ANON_KEY with SUPABASE_URL and SUPABASE_JWT_SECRET. JWT validation still works; login returns 503 until the anon key is set.",
      }),
    );
  }
  if (!useFakes && rest === undefined) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "supabase_service_role_missing",
        detail:
          "SUPABASE_SERVICE_ROLE_KEY is unset; profiles, devices, settings, and sync stay isolate-local. Set it with wrangler secret put SUPABASE_SERVICE_ROLE_KEY.",
      }),
    );
  }
  if (!useFakes && turnstileSecret === "") {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "turnstile_secret_missing",
        detail:
          "Passwordless Turnstile challenge is disabled; lockout-only. Set TURNSTILE_SECRET_KEY with wrangler secret put TURNSTILE_SECRET_KEY.",
      }),
    );
  }
  const verifyTurnstile: TurnstileVerifier = async (token, ip) => {
    const secret = (await runtime.resolveTurnstileSecret()) ?? turnstileSecret;
    if (secret === "") {
      return useFakes ? token === "turnstile-ok" : false;
    }
    return createCloudflareTurnstileVerifier({ secretKey: secret })(token, ip);
  };
  return createApiApp({
    environment,
    version: version === undefined || version === "" ? "1.0.0-draft.1" : version,
    maxBodyBytes: parsePositiveInt(env.MAX_BODY_BYTES, DEFAULT_MAX_BODY_BYTES),
    corsOrigins: parseOriginList(env.CORS_ALLOWED_ORIGINS),
    ...(adminOrigin !== undefined && adminOrigin !== "" ? { adminOrigin } : {}),
    database,
    storage: createResolvingObjectStore(
      async () => (await runtime.resolveStorage({ useFakes })).store,
    ),
    resolveAccountSyncStorage: () => runtime.resolveStorage({ useFakes }),
    qwen: createResolvingQwenClient(() => runtime.resolveQwenClient({ useFakes })),
    runtime,
    ...(auth === undefined ? {} : { auth }),
    authenticate: auth === undefined ? () => null : (request) => auth.authenticate(request),
    hmacSecret: hmac.secret,
    cacheHmacSecret: cacheHmac.secret,
    verifyTurnstile,
    ...(env.TURNSTILE_SITE_KEY?.trim() ? { turnstileSiteKey: env.TURNSTILE_SITE_KEY.trim() } : {}),
    ...(rest === undefined || useFakes
      ? {}
      : {
          idempotencyStore: createPostgresIdempotencyStore(createSupabaseRestClient(rest)),
          passwordlessLimiter: createDurablePasswordlessLimiter({
            store: createPostgresPasswordlessStore(createSupabaseRestClient(rest)),
            verifyTurnstile,
            hmacSecret: hmac.secret,
            enableChallenge: true,
            onSecurityEvent: (event) => {
              logSecurityEvent({
                message: event.type,
                requestId: event.requestId ?? "unspecified",
                action: event.action,
                emailHash: event.emailHash,
                ipHash: event.ipHash,
                reason: event.reason,
                ...(event.deviceId === null ? {} : { deviceId: event.deviceId }),
              });
            },
          }),
        }),
  });
}

function resolveDatabaseClient(env: WorkerEnv, useFakes: boolean): DatabaseClient {
  if (useFakes) {
    return createFakeDatabaseClient();
  }
  const rest = resolveSupabaseRestConfig(env);
  if (rest !== undefined) {
    return createSupabaseDatabaseClient(rest);
  }
  return createUnavailableDatabaseClient();
}

function createAuthServiceFromEnv(input: {
  jwt: JwtSigningConfig | undefined;
  useFakes: boolean;
  localOtp: string | undefined;
  hosted: { url: string; anonKey: string } | undefined;
  identity?: DatabaseClient["identity"];
  adminBootstrapEmail?: string;
  serviceRoleKey?: string;
  sendOtpEmail?: HostedOtpMailer;
}): AuthService | undefined {
  if (input.jwt === undefined) {
    return undefined;
  }
  if (input.useFakes) {
    const otp = input.localOtp;
    return createMemoryAuthService({
      jwt: input.jwt,
      allowLocalIssuance: true,
      ...(otp === undefined ? {} : { generateOtp: () => otp }),
    });
  }
  if (input.hosted !== undefined) {
    return createHostedAuthService({
      jwt: input.jwt,
      supabaseUrl: input.hosted.url,
      supabaseAnonKey: input.hosted.anonKey,
      ...(input.identity === undefined ? {} : { identity: input.identity }),
      ...(input.adminBootstrapEmail === undefined || input.adminBootstrapEmail === ""
        ? {}
        : { adminBootstrapEmail: input.adminBootstrapEmail }),
      ...(input.serviceRoleKey === undefined || input.serviceRoleKey === ""
        ? {}
        : { serviceRoleKey: input.serviceRoleKey }),
      ...(input.sendOtpEmail === undefined ? {} : { sendOtpEmail: input.sendOtpEmail }),
    });
  }
  return createMemoryAuthService({
    jwt: input.jwt,
    allowLocalIssuance: false,
  });
}

function createDefaultPasswordlessLimiter(input: {
  environment: AppEnvironment;
  verifyTurnstile?: TurnstileVerifier;
  hmacSecret: string;
}): PasswordlessLimiter {
  // Local/test only. Staging and production pass a Postgres limiter from createApiAppFromEnv.
  const local = input.environment === "local" || input.environment === "test";
  const enableChallenge = local || input.verifyTurnstile !== undefined;
  const verifier: TurnstileVerifier =
    input.verifyTurnstile ??
    (local ? (token) => Promise.resolve(token === "turnstile-ok") : () => Promise.resolve(false));
  return createMemoryPasswordlessLimiter({
    verifyTurnstile: verifier,
    hmacSecret: input.hmacSecret,
    enableChallenge,
    onSecurityEvent: (event) => {
      logSecurityEvent({
        message: event.type,
        requestId: event.requestId ?? "unspecified",
        action: event.action,
        emailHash: event.emailHash,
        ipHash: event.ipHash,
        reason: event.reason,
        ...(event.deviceId === null ? {} : { deviceId: event.deviceId }),
      });
    },
  });
}

async function handleRequest(
  request: Request,
  requestId: string,
  options: AppOptions,
  maxBodyBytes: number,
  authenticate: (request: Request) => Promise<Principal | null>,
  idempotencyStore: IdempotencyStore,
  passwordlessLimiter: PasswordlessLimiter,
  accountSyncReadiness: AccountSyncReadinessService,
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
      storage: options.storage,
      qwen: options.qwen,
    });
    if (path === "/readyz" && !isServiceReady(health.dependencies)) {
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

  const methodError =
    authMethodError(path, request.method, requestId) ??
    syncMethodError(path, request.method, requestId) ??
    assistantMethodError(path, request.method, requestId) ??
    libraryMethodError(path, request.method, requestId) ??
    assetMethodError(path, request.method, requestId) ??
    privacyMethodError(path, request.method, requestId) ??
    productEventMethodError(path, request.method, requestId) ??
    adminMethodError(path, request.method, requestId);
  if (methodError !== undefined) {
    return methodError;
  }

  if (!isBinaryAssetPath(path)) {
    // Base transcripts can exceed the generic JSON limit; only sync push gets the larger,
    // still-bounded allowance used by the native byte-aware batcher.
    const bodyLimit =
      path === "/v1/sync/push" || path === "/v2/sync/push"
        ? Math.max(maxBodyBytes, SYNC_PUSH_MAX_BODY_BYTES)
        : maxBodyBytes;
    const bodyError = await validateRequestBody(request, bodyLimit, requestId);
    if (bodyError !== undefined) {
      return bodyError;
    }
  }

  if (isAuthPath(path)) {
    const routed = await handleAuthRoute({
      request,
      requestId,
      ...(options.auth === undefined ? {} : { auth: options.auth }),
      authenticate,
      idempotencyStore,
      passwordlessLimiter,
      localOAuthComplete: options.environment === "local" || options.environment === "test",
      ops: options.database.ops,
      accountSyncReadiness,
      ...(options.turnstileSiteKey === undefined || options.turnstileSiteKey === ""
        ? {}
        : { turnstileSiteKey: options.turnstileSiteKey }),
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isSyncPath(path)) {
    const routed = await handleSyncRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      sync: path.startsWith("/v2/") ? options.database.syncV2 : options.database.sync,
      identity: options.database.identity,
      ops: options.database.ops,
      objects: options.storage,
      accountSyncReadiness,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isAssistantPath(path)) {
    const routed = await handleAssistantRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      qwen: options.qwen,
      ops: options.database.ops,
      identity: options.database.identity,
      cacheHmacSecret:
        options.cacheHmacSecret ?? options.hmacSecret ?? LOCAL_PASSWORDLESS_HMAC_SECRET,
      ...(options.runtime === undefined ? {} : { runtime: options.runtime }),
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isLibraryPath(path)) {
    const routed = await handleLibraryRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      catalog: options.database.catalog,
      identity: options.database.identity,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isAssetPath(path)) {
    const routed = await handleAssetRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      ops: options.database.ops,
      identity: options.database.identity,
      objects: options.storage,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isPrivacyPath(path)) {
    const routed = await handlePrivacyRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      ops: options.database.ops,
      identity: options.database.identity,
      catalog: options.database.catalog,
      objects: options.storage,
      sync: options.database.syncV2,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isProductEventPath(path)) {
    const routed = await handleProductEventRoute({
      request,
      requestId,
      authenticate,
      ops: options.database.ops,
      identity: options.database.identity,
    });
    if (routed !== undefined) {
      return routed;
    }
  }

  if (isAdminPath(path)) {
    const routed = await handleAdminRoute({
      request,
      requestId,
      authenticate,
      idempotencyStore,
      ops: options.database.ops,
      identity: options.database.identity,
      catalog: options.database.catalog,
      ...(options.runtime === undefined ? {} : { runtime: options.runtime }),
      accountSyncReadiness,
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
