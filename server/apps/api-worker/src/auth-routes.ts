import {
  AUTH_PROVIDERS,
  type AuthService,
  type Principal,
  type ProductProfile,
} from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import { readJsonObject } from "./body";
import { asHead, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";

type Profile = components["schemas"]["Profile"];
type TokenPair = components["schemas"]["TokenPair"];
type BootstrapResponse = components["schemas"]["BootstrapResponse"];
type AuthConfig = components["schemas"]["AuthConfig"];
type AuthOAuthAuthorizeResponse = components["schemas"]["AuthOAuthAuthorizeResponse"];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const OTP_PATTERN = /^[0-9]{6}$/;
const PKCE_PATTERN = /^[A-Za-z0-9\-._~]{43,128}$/;
const STATE_PATTERN = /^[\w.:-]{8,256}$/;

const AUTH_METHODS: Record<string, readonly string[]> = {
  "/v1/auth/config": ["GET", "HEAD"],
  "/v1/auth/email-otp/request": ["POST"],
  "/v1/auth/email-otp/verify": ["POST"],
  "/v1/auth/oauth/authorize": ["POST"],
  "/v1/auth/oauth/exchange": ["POST"],
  "/v1/auth/token/refresh": ["POST"],
  "/v1/auth/logout": ["POST"],
  "/v1/auth/bootstrap": ["POST"],
  "/v1/me": ["GET", "HEAD"],
};

export type AuthRouteContext = {
  request: Request;
  requestId: string;
  auth?: AuthService;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
};

export function isAuthPath(path: string): boolean {
  return path in AUTH_METHODS;
}

export function authMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const allowed = AUTH_METHODS[path];
  if (allowed === undefined || allowed.includes(method.toUpperCase())) {
    return undefined;
  }
  return methodNotAllowed(requestId, allowed);
}

export async function handleAuthRoute(context: AuthRouteContext): Promise<Response | undefined> {
  const path = new URL(context.request.url).pathname;
  const allowed = AUTH_METHODS[path];
  if (allowed === undefined) {
    return undefined;
  }
  const method = context.request.method.toUpperCase();
  if (!allowed.includes(method)) {
    return methodNotAllowed(context.requestId, allowed);
  }

  switch (path) {
    case "/v1/auth/config":
      return asHead(context.request, jsonResponse(authConfig()));
    case "/v1/auth/email-otp/request":
      return requestEmailOtp(context);
    case "/v1/auth/email-otp/verify":
      return verifyEmailOtp(context);
    case "/v1/auth/oauth/authorize":
      return authorizeOAuth(context);
    case "/v1/auth/oauth/exchange":
      return exchangeOAuth(context);
    case "/v1/auth/token/refresh":
      return refreshSession(context);
    case "/v1/auth/logout":
      return logout(context);
    case "/v1/auth/bootstrap":
      return bootstrapSession(context);
    case "/v1/me":
      return getProfile(context);
    default:
      return undefined;
  }
}

function authConfig(): AuthConfig {
  return { providers: [...AUTH_PROVIDERS] };
}

async function requestEmailOtp(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const email = requiredString(body.value.email, "email", context.requestId);
  if (email instanceof Response) {
    return email;
  }
  if (!EMAIL_PATTERN.test(email)) {
    return fieldError(context.requestId, "email", "email must be a valid email address.");
  }
  await auth.requestEmailOtp(email);
  return new Response(null, { status: 202 });
}

async function verifyEmailOtp(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const email = requiredString(body.value.email, "email", context.requestId);
  if (email instanceof Response) {
    return email;
  }
  const code = requiredString(body.value.code, "code", context.requestId);
  if (code instanceof Response) {
    return code;
  }
  const deviceId = requiredString(body.value.deviceId, "deviceId", context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  if (!EMAIL_PATTERN.test(email)) {
    return fieldError(context.requestId, "email", "email must be a valid email address.");
  }
  if (!OTP_PATTERN.test(code)) {
    return fieldError(context.requestId, "code", "code must be a 6-digit one-time password.");
  }
  if (!UUID_PATTERN.test(deviceId)) {
    return fieldError(context.requestId, "deviceId", "deviceId must be a UUID.");
  }
  const result = await auth.verifyEmailOtp(email, code);
  if (!result.ok) {
    return unauthorized(context.requestId, "The email code is invalid or expired.");
  }
  return jsonResponse(toTokenPair(result.value.tokens));
}

async function authorizeOAuth(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const provider = requiredProvider(body.value.provider, context.requestId);
  if (provider instanceof Response) {
    return provider;
  }
  const redirectUri = requiredUri(body.value.redirectUri, "redirectUri", context.requestId);
  if (redirectUri instanceof Response) {
    return redirectUri;
  }
  const codeChallenge = requiredString(
    body.value.codeChallenge,
    "codeChallenge",
    context.requestId,
  );
  if (codeChallenge instanceof Response) {
    return codeChallenge;
  }
  const state = requiredString(body.value.state, "state", context.requestId);
  if (state instanceof Response) {
    return state;
  }
  if (!PKCE_PATTERN.test(codeChallenge)) {
    return fieldError(
      context.requestId,
      "codeChallenge",
      "codeChallenge must be a PKCE S256 challenge.",
    );
  }
  if (!STATE_PATTERN.test(state)) {
    return fieldError(context.requestId, "state", "state must be 8-256 URL-safe characters.");
  }
  if (body.value.codeChallengeMethod !== undefined && body.value.codeChallengeMethod !== "S256") {
    return fieldError(
      context.requestId,
      "codeChallengeMethod",
      "codeChallengeMethod must be S256.",
    );
  }
  const result = await auth.authorizeOAuth({
    provider,
    redirectUri,
    codeChallenge,
    state,
  });
  if (!result.ok) {
    return unauthorized(context.requestId, "The OAuth request is invalid.");
  }
  const payload: AuthOAuthAuthorizeResponse = {
    authorizationUrl: result.value.authorizationUrl,
    state: result.value.state,
  };
  return jsonResponse(payload);
}

async function exchangeOAuth(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const provider = requiredProvider(body.value.provider, context.requestId);
  if (provider instanceof Response) {
    return provider;
  }
  const code = requiredString(body.value.code, "code", context.requestId);
  if (code instanceof Response) {
    return code;
  }
  const codeVerifier = requiredString(body.value.codeVerifier, "codeVerifier", context.requestId);
  if (codeVerifier instanceof Response) {
    return codeVerifier;
  }
  const redirectUri = requiredUri(body.value.redirectUri, "redirectUri", context.requestId);
  if (redirectUri instanceof Response) {
    return redirectUri;
  }
  if (!PKCE_PATTERN.test(codeVerifier)) {
    return fieldError(context.requestId, "codeVerifier", "codeVerifier must be a PKCE verifier.");
  }
  const state = optionalString(body.value.state);
  const result = await auth.exchangeOAuth({
    provider,
    code,
    codeVerifier,
    redirectUri,
    ...(state === undefined ? {} : { state }),
  });
  if (!result.ok) {
    return unauthorized(context.requestId, "The OAuth authorization code is invalid.");
  }
  return jsonResponse(toTokenPair(result.value.tokens));
}

async function refreshSession(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const refreshToken = await readRefreshToken(context);
  if (refreshToken instanceof Response) {
    return refreshToken;
  }
  const result = await auth.refresh(refreshToken);
  if (!result.ok) {
    return unauthorized(context.requestId, "The refresh token is invalid.");
  }
  return jsonResponse(toTokenPair(result.value.tokens));
}

async function logout(context: AuthRouteContext): Promise<Response> {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const refreshToken = await readRefreshToken(context);
  if (refreshToken instanceof Response) {
    return refreshToken;
  }
  await auth.logout(refreshToken);
  return new Response(null, { status: 204 });
}

async function bootstrapSession(context: AuthRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const deviceIdHeader = context.request.headers.get("X-Device-Id")?.trim() ?? "";
  if (!UUID_PATTERN.test(deviceIdHeader)) {
    return problemResponse({
      status: 400,
      code: "bad_request",
      title: "Bad request",
      detail: "X-Device-Id must be a UUID.",
      traceId: context.requestId,
    });
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const deviceId = requiredString(body.value.deviceId, "deviceId", context.requestId);
      if (deviceId instanceof Response) {
        return deviceId;
      }
      if (!UUID_PATTERN.test(deviceId) || deviceId !== deviceIdHeader) {
        return fieldError(context.requestId, "deviceId", "deviceId must match X-Device-Id.");
      }
      const platform = body.value.platform;
      if (platform !== "macos" && platform !== "ios" && platform !== "ipados") {
        return fieldError(context.requestId, "platform", "platform must be macos, ios, or ipados.");
      }
      const appVersion = requiredString(body.value.appVersion, "appVersion", context.requestId);
      if (appVersion instanceof Response) {
        return appVersion;
      }
      const deviceName = optionalNullableString(body.value.deviceName);
      const buildNumber = optionalString(body.value.buildNumber);
      const locale = optionalString(body.value.locale);
      const timeZone = optionalString(body.value.timeZone);
      const bootstrapped = auth.bootstrap(principal, {
        deviceId,
        platform,
        appVersion,
        ...(deviceName === undefined ? {} : { deviceName }),
        ...(buildNumber === undefined ? {} : { buildNumber }),
        ...(locale === undefined ? {} : { locale }),
        ...(timeZone === undefined ? {} : { timeZone }),
      });
      const payload: BootstrapResponse = {
        profile: toProfile(bootstrapped.profile),
        device: bootstrapped.device,
        settings: bootstrapped.settings,
        featureFlags: [...bootstrapped.featureFlags],
        quotas: [...bootstrapped.quotas],
        syncCursor: bootstrapped.syncCursor,
      };
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
  );
}

async function getProfile(context: AuthRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const stored = context.auth?.getProfile(principal);
  const profile = stored ?? profileFromPrincipal(principal);
  return asHead(context.request, jsonResponse(toProfile(profile)));
}

async function requirePrincipal(context: AuthRouteContext): Promise<Principal | Response> {
  const principal = await context.authenticate(context.request);
  if (principal === null) {
    return unauthorized(context.requestId, "Authentication required.");
  }
  return principal;
}

function requireAuthService(context: AuthRouteContext): AuthService | Response {
  if (context.auth === undefined) {
    return problemResponse({
      status: 503,
      code: "not_ready",
      title: "Service unavailable",
      detail: "Authentication is not configured.",
      traceId: context.requestId,
    });
  }
  return context.auth;
}

async function readRefreshToken(context: AuthRouteContext): Promise<string | Response> {
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const refreshToken = requiredString(body.value.refreshToken, "refreshToken", context.requestId);
  if (refreshToken instanceof Response) {
    return refreshToken;
  }
  if (refreshToken.length < 16) {
    return fieldError(
      context.requestId,
      "refreshToken",
      "refreshToken must be at least 16 characters.",
    );
  }
  return refreshToken;
}

function toTokenPair(tokens: {
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
  tokenType: "Bearer";
}): TokenPair {
  return {
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresAt: tokens.expiresAt,
    tokenType: tokens.tokenType,
  };
}

function toProfile(profile: ProductProfile): Profile {
  return {
    id: profile.id,
    accountId: profile.accountId,
    email: profile.email,
    displayName: profile.displayName,
    avatarUrl: profile.avatarUrl,
    createdAt: profile.createdAt,
    updatedAt: profile.updatedAt,
    deletionPendingAt: profile.deletionPendingAt,
  };
}

function profileFromPrincipal(principal: Principal): ProductProfile {
  const timestamp = new Date().toISOString();
  return {
    id: principal.profileId,
    accountId: principal.accountId,
    email: principal.email,
    displayName: null,
    avatarUrl: null,
    createdAt: timestamp,
    updatedAt: timestamp,
    deletionPendingAt: null,
  };
}

function requiredProvider(value: unknown, requestId: string): "google" | "microsoft" | Response {
  if (value !== "google" && value !== "microsoft") {
    return fieldError(requestId, "provider", "provider must be google or microsoft.");
  }
  return value;
}

function requiredUri(value: unknown, field: string, requestId: string): string | Response {
  const text = requiredString(value, field, requestId);
  if (text instanceof Response) {
    return text;
  }
  try {
    const parsed = new URL(text);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return fieldError(requestId, field, `${field} must be an http(s) URI.`);
    }
  } catch {
    return fieldError(requestId, field, `${field} must be an http(s) URI.`);
  }
  return text;
}

function requiredString(value: unknown, field: string, requestId: string): string | Response {
  if (typeof value !== "string" || value.trim() === "") {
    return fieldError(requestId, field, `${field} is required.`);
  }
  return value.trim();
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function optionalNullableString(value: unknown): string | null | undefined {
  if (value === null) {
    return null;
  }
  return optionalString(value);
}

function fieldError(requestId: string, field: string, message: string): Response {
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: "The request body is invalid.",
    traceId: requestId,
    fieldErrors: [{ field, message }],
  });
}

function unauthorized(requestId: string, detail: string): Response {
  return problemResponse({
    status: 401,
    code: "unauthorized",
    title: "Unauthorized",
    detail,
    traceId: requestId,
  });
}

function methodNotAllowed(requestId: string, allowed: readonly string[]): Response {
  return problemResponse({
    status: 405,
    code: "method_not_allowed",
    title: "Method not allowed",
    detail: `This endpoint accepts ${allowed.join(", ")}.`,
    traceId: requestId,
    headers: { Allow: allowed.join(", ") },
  });
}
