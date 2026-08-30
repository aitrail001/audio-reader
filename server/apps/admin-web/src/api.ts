import { extractAccessToken } from "./format";
import type { AuthConfig } from "./types";

export const API_BASE = (import.meta.env.VITE_API_BASE_URL ?? "").replace(/\/$/, "");
export const DEVICE_STORAGE_KEY = "audio-reader-admin-device-id";
export const TOKEN_STORAGE_KEY = "audio-reader-admin-token";
export const SESSION_STORAGE_KEY = "audio-reader-admin-session";

export type StoredSession = {
  accessToken: string;
  refreshToken?: string;
};

export type RefreshResult =
  { status: "refreshed"; accessToken: string } | { status: "invalid" } | { status: "unavailable" };

export class AdminSessionError extends Error {
  readonly outcome: "invalid" | "unavailable";

  constructor(outcome: "invalid" | "unavailable", message: string) {
    super(message);
    this.name = "AdminSessionError";
    this.outcome = outcome;
  }
}

export type AdminFieldError = { field: string; message: string };

/** Typed operator failure. Keep problem metadata intact so every panel can offer recovery and support. */
export class AdminApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly traceId: string;
  readonly retryAfterSeconds: number | null;
  readonly fieldErrors: AdminFieldError[];

  constructor(input: {
    status: number;
    code: string;
    message: string;
    traceId?: string;
    retryAfterSeconds?: number | null;
    fieldErrors?: AdminFieldError[];
  }) {
    super(input.message);
    this.name = "AdminApiError";
    this.status = input.status;
    this.code = input.code;
    this.traceId = input.traceId ?? "";
    this.retryAfterSeconds = input.retryAfterSeconds ?? null;
    this.fieldErrors = input.fieldErrors ?? [];
  }
}

export function deviceId(): string {
  const existing = localStorage.getItem(DEVICE_STORAGE_KEY);
  if (existing !== null && existing !== "") {
    return existing;
  }
  const created = crypto.randomUUID();
  localStorage.setItem(DEVICE_STORAGE_KEY, created);
  return created;
}

const sessionListeners = new Set<(session: StoredSession | null) => void>();

/** React must follow storage: after refresh or wipe, in-memory JWT is stale. */
export function subscribeSession(listener: (session: StoredSession | null) => void): () => void {
  sessionListeners.add(listener);
  return () => {
    sessionListeners.delete(listener);
  };
}

function emitSession(session: StoredSession | null): void {
  for (const listener of sessionListeners) {
    listener(session);
  }
}

function logAuth(
  message: string,
  outcome: string,
  extra: Record<string, string | number | boolean> = {},
): void {
  console.warn(
    JSON.stringify({
      level: "warn",
      message,
      component: "admin-web",
      outcome,
      ...extra,
    }),
  );
}

/**
 * localStorage JSON is the session source of truth. Access values must look like
 * JWTs so a portal URL cannot clobber a token.
 */
export function loadStoredSession(): StoredSession | null {
  const raw =
    window.localStorage.getItem(SESSION_STORAGE_KEY) ??
    window.sessionStorage.getItem(SESSION_STORAGE_KEY);
  if (raw !== null && raw !== "") {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (isRecord(parsed)) {
        const access = extractAccessToken(
          typeof parsed.accessToken === "string" ? parsed.accessToken : "",
        );
        if (access !== "") {
          const refresh = typeof parsed.refreshToken === "string" ? parsed.refreshToken.trim() : "";
          return refresh === ""
            ? { accessToken: access }
            : { accessToken: access, refreshToken: refresh };
        }
      }
    } catch {
      /* migrate the legacy string token below */
    }
  }
  const legacy =
    window.localStorage.getItem(TOKEN_STORAGE_KEY) ??
    window.sessionStorage.getItem(TOKEN_STORAGE_KEY) ??
    "";
  const access = extractAccessToken(legacy);
  return access === "" ? null : { accessToken: access };
}

/** Persist a verified session. null is the only client-side stored-token wipe. */
export function storeSession(session: StoredSession | null): void {
  window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
  window.localStorage.removeItem(TOKEN_STORAGE_KEY);
  window.sessionStorage.removeItem(SESSION_STORAGE_KEY);
  if (session === null || session.accessToken.trim() === "") {
    window.localStorage.removeItem(SESSION_STORAGE_KEY);
    logAuth("admin_session_store", "cleared");
    emitSession(null);
    return;
  }
  window.localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(session));
  logAuth("admin_session_store", "ok", {
    hasRefresh: typeof session.refreshToken === "string" && session.refreshToken !== "",
  });
  emitSession(session);
}

export function adminHeaders(token: string, mutating = false): HeadersInit {
  const headers: Record<string, string> = {
    authorization: `Bearer ${token.trim()}`,
    "X-Device-Id": deviceId(),
  };
  if (mutating) {
    headers["content-type"] = "application/json";
    headers["Idempotency-Key"] = `admin-${crypto.randomUUID()}`;
  }
  return headers;
}

export async function readError(response: Response): Promise<AdminApiError> {
  const responseTraceId = response.headers.get("X-Request-Id") ?? "";
  const headerRetry = Number.parseInt(response.headers.get("Retry-After") ?? "", 10);
  try {
    const payload = (await response.json()) as Record<string, unknown>;
    const fieldErrors = Array.isArray(payload.fieldErrors)
      ? payload.fieldErrors.flatMap((item): AdminFieldError[] => {
          if (
            !isRecord(item) ||
            typeof item.field !== "string" ||
            typeof item.message !== "string"
          ) {
            return [];
          }
          return [{ field: item.field, message: item.message }];
        })
      : [];
    const bodyRetry =
      typeof payload.retryAfterSeconds === "number" ? payload.retryAfterSeconds : null;
    return new AdminApiError({
      status: response.status,
      code: typeof payload.code === "string" ? payload.code : `http_${String(response.status)}`,
      message:
        typeof payload.detail === "string"
          ? payload.detail
          : typeof payload.title === "string"
            ? payload.title
            : `Request failed (${String(response.status)}).`,
      traceId: typeof payload.traceId === "string" ? payload.traceId : responseTraceId,
      retryAfterSeconds: bodyRetry ?? (Number.isFinite(headerRetry) ? headerRetry : null),
      fieldErrors,
    });
  } catch {
    return new AdminApiError({
      status: response.status,
      code: `http_${String(response.status)}`,
      message: `Request failed (${String(response.status)}).`,
      traceId: responseTraceId,
      retryAfterSeconds: Number.isFinite(headerRetry) ? headerRetry : null,
    });
  }
}

export async function getJson<T>(path: string, token: string): Promise<T> {
  const response = await authorizedFetch(path, token, {});
  if (!response.ok) {
    throw await readError(response);
  }
  return (await response.json()) as T;
}

export async function getJsonOrNull<T>(path: string, token: string): Promise<T | null> {
  try {
    return await getJson<T>(path, token);
  } catch (cause: unknown) {
    if (cause instanceof AdminSessionError) {
      throw cause;
    }
    if (cause instanceof AdminApiError && cause.status === 404) {
      return null;
    }
    throw cause;
  }
}

export async function sendJson<T>(
  path: string,
  token: string,
  method: string,
  body: unknown,
): Promise<T> {
  const response = await authorizedFetch(path, token, {
    method,
    mutating: true,
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw await readError(response);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

export async function fetchAuthConfig(): Promise<AuthConfig> {
  const response = await fetch(`${API_BASE}/v1/auth/config`);
  if (!response.ok) {
    throw await readError(response);
  }
  return (await response.json()) as AuthConfig;
}

export async function requestOtp(email: string, turnstileToken: string | undefined): Promise<void> {
  const payload: Record<string, string> = { email };
  if (turnstileToken !== undefined && turnstileToken.trim() !== "") {
    payload.turnstileToken = turnstileToken.trim();
  }
  const response = await fetch(`${API_BASE}/v1/auth/email-otp/request`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Device-Id": deviceId(),
      "Idempotency-Key": `admin-${crypto.randomUUID()}`,
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw await readError(response);
  }
}

export async function verifyOtp(
  email: string,
  code: string,
  turnstileToken: string | undefined,
): Promise<StoredSession> {
  const payload: Record<string, string> = { email, code, deviceId: deviceId() };
  if (turnstileToken !== undefined && turnstileToken.trim() !== "") {
    payload.turnstileToken = turnstileToken.trim();
  }
  const response = await fetch(`${API_BASE}/v1/auth/email-otp/verify`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Device-Id": deviceId(),
      "Idempotency-Key": `admin-${crypto.randomUUID()}`,
    },
    body: JSON.stringify(payload),
  });
  const requestId = response.headers.get("X-Request-Id") ?? "";
  if (!response.ok) {
    logAuth("admin_session_verify_otp", "failed", requestIdExtra(requestId));
    throw await readError(response);
  }
  const session = sessionFromTokenResponse(
    await response.json(),
    "Sign-in did not return an access token.",
  );
  logAuth("admin_session_verify_otp", "ok", {
    ...requestIdExtra(requestId),
    hasRefresh: typeof session.refreshToken === "string" && session.refreshToken !== "",
  });
  return session;
}

/** Drop local authority synchronously, then make the best-effort server-side refresh-token revoke. */
export async function logoutSession(): Promise<void> {
  const refreshToken = loadStoredSession()?.refreshToken?.trim() ?? "";
  storeSession(null);
  try {
    if (refreshToken !== "") {
      const response = await fetch(`${API_BASE}/v1/auth/logout`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Device-Id": deviceId(),
          "Idempotency-Key": `admin-${crypto.randomUUID()}`,
        },
        body: JSON.stringify({ refreshToken }),
      });
      logAuth(
        "admin_session_logout",
        response.ok ? "ok" : "failed",
        requestIdExtra(response.headers.get("X-Request-Id") ?? ""),
      );
    }
  } catch {
    logAuth("admin_session_logout", "failed");
  }
}

/** OTP/refresh JSON is already a token pair; do not treat portal URLs as access tokens. */
function sessionFromTokenResponse(payload: unknown, missing: string): StoredSession {
  if (!isRecord(payload) || typeof payload.accessToken !== "string" || payload.accessToken === "") {
    throw new Error(missing);
  }
  const refresh = typeof payload.refreshToken === "string" ? payload.refreshToken.trim() : "";
  return refresh === ""
    ? { accessToken: payload.accessToken }
    : { accessToken: payload.accessToken, refreshToken: refresh };
}

let refreshInFlight: Promise<RefreshResult> | null = null;

/**
 * Rotate the access token. Clears storage only when this refresh token is
 * rejected (401), not on 429/5xx/network.
 */
export async function refreshAccessToken(): Promise<RefreshResult> {
  const stored = loadStoredSession();
  const refreshToken = stored?.refreshToken;
  if (refreshToken === undefined || refreshToken === "") {
    storeSession(null);
    logAuth("admin_session_refresh", "invalid");
    return { status: "invalid" };
  }
  if (refreshInFlight !== null) {
    return refreshInFlight;
  }
  logAuth("admin_session_refresh", "start");
  refreshInFlight = (async () => {
    try {
      const response = await fetch(`${API_BASE}/v1/auth/token/refresh`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Device-Id": deviceId(),
          "Idempotency-Key": `admin-${crypto.randomUUID()}`,
        },
        body: JSON.stringify({ refreshToken }),
      });
      const requestId = response.headers.get("X-Request-Id") ?? "";
      if (response.status === 401) {
        storeSession(null);
        logAuth("admin_session_refresh", "invalid", requestIdExtra(requestId));
        return { status: "invalid" };
      }
      if (!response.ok) {
        logAuth("admin_session_refresh", "unavailable", {
          ...requestIdExtra(requestId),
          httpStatus: response.status,
        });
        return { status: "unavailable" };
      }
      const next = sessionFromTokenResponse(
        await response.json(),
        "Refresh did not return an access token.",
      );
      storeSession({
        accessToken: next.accessToken,
        refreshToken: next.refreshToken ?? refreshToken,
      });
      logAuth("admin_session_refresh", "refreshed", requestIdExtra(requestId));
      return { status: "refreshed", accessToken: next.accessToken };
    } catch {
      logAuth("admin_session_refresh", "unavailable");
      return { status: "unavailable" };
    } finally {
      refreshInFlight = null;
    }
  })();
  return refreshInFlight;
}

/**
 * Prefer the stored access token (source of truth). One 401 retry after refresh;
 * the retry uses raw fetch so it cannot loop.
 */
async function authorizedFetch(
  path: string,
  token: string,
  init: { method?: string; body?: string; mutating?: boolean },
): Promise<Response> {
  const stored = loadStoredSession();
  const access = stored?.accessToken ?? token;
  const requestInit: RequestInit = {
    method: init.method ?? "GET",
    headers: adminHeaders(access, init.mutating === true),
    ...(init.body === undefined ? {} : { body: init.body }),
  };
  const response = await fetch(`${API_BASE}${path}`, requestInit);
  if (response.status !== 401) {
    return response;
  }
  const refresh = await refreshAccessToken();
  if (refresh.status === "refreshed") {
    logAuth("admin_session_retry", "ok");
    return fetch(`${API_BASE}${path}`, {
      ...requestInit,
      headers: adminHeaders(refresh.accessToken, init.mutating === true),
    });
  }
  if (refresh.status === "unavailable") {
    throw new AdminSessionError(
      "unavailable",
      "Could not refresh the operator session. Try again.",
    );
  }
  throw new AdminSessionError("invalid", "Authentication required.");
}

function requestIdExtra(requestId: string): Record<string, string> {
  return requestId === "" ? {} : { requestId };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
