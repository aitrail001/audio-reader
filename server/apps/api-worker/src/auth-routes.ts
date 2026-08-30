import {
  AUTH_PROVIDERS,
  type AuthService,
  type PasswordlessDecision,
  type PasswordlessLimiter,
  type Principal,
  type ProductProfile,
  type ProductSettings,
} from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { OpsStore } from "@audio-reader/database";
import { readJsonObject } from "./body";
import { asHead, jsonResponse, problemResponse } from "./http";
import { withIdempotency, type IdempotencyStore } from "./idempotency";
import { requireBoundDevice } from "./route-helpers";

type Profile = components["schemas"]["Profile"];
type TokenPair = components["schemas"]["TokenPair"];
type BootstrapResponse = components["schemas"]["BootstrapResponse"];
type AuthConfig = components["schemas"]["AuthConfig"];
type AuthOAuthAuthorizeResponse = components["schemas"]["AuthOAuthAuthorizeResponse"];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const OTP_PATTERN = /^[0-9]{6,12}$/;
const PKCE_PATTERN = /^[A-Za-z0-9\-._~]{43,128}$/;
const STATE_PATTERN = /^[A-Za-z0-9\-._~:.]{8,256}$/;

const AUTH_METHODS: Record<string, readonly string[]> = {
  "/v1/auth/config": ["GET", "HEAD"],
  "/v1/auth/email-otp/request": ["POST"],
  "/v1/auth/email-otp/verify": ["POST"],
  "/v1/auth/oauth/authorize": ["POST"],
  "/v1/auth/oauth/local-complete": ["GET", "HEAD"],
  "/v1/auth/oauth/exchange": ["POST"],
  "/v1/auth/token/refresh": ["POST"],
  "/v1/auth/logout": ["POST"],
  "/v1/auth/bootstrap": ["POST"],
  "/v1/me": ["GET", "HEAD", "PATCH"],
  "/v1/me/settings": ["GET", "HEAD", "PUT"],
  "/v1/me/devices": ["GET", "HEAD"],
  "/v1/me/devices/{deviceId}": ["DELETE"],
  "/v1/admin/auth/blocked-attempts": ["GET", "HEAD"],
};

const DEVICE_REVOKE_PATH = /^\/v1\/me\/devices\/([^/]+)$/;

type ResolvedAuthPath = {
  route: string;
  deviceId?: string;
};

function resolveAuthPath(path: string): ResolvedAuthPath | undefined {
  if (path in AUTH_METHODS) {
    return { route: path };
  }
  const match = DEVICE_REVOKE_PATH.exec(path);
  const deviceId = match?.[1];
  if (deviceId !== undefined) {
    return { route: "/v1/me/devices/{deviceId}", deviceId };
  }
  return undefined;
}

export type AuthRouteContext = {
  request: Request;
  requestId: string;
  auth?: AuthService;
  authenticate: (request: Request) => Promise<Principal | null>;
  idempotencyStore: IdempotencyStore;
  passwordlessLimiter?: PasswordlessLimiter;
  localOAuthComplete: boolean;
  turnstileSiteKey?: string;
  ops?: OpsStore;
};

export function isAuthPath(path: string): boolean {
  return resolveAuthPath(path) !== undefined;
}

export function authMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  const resolved = resolveAuthPath(path);
  if (resolved === undefined) {
    return undefined;
  }
  const allowed = AUTH_METHODS[resolved.route];
  if (allowed === undefined || allowed.includes(method.toUpperCase())) {
    return undefined;
  }
  return methodNotAllowed(requestId, allowed);
}

export async function handleAuthRoute(context: AuthRouteContext): Promise<Response | undefined> {
  const path = new URL(context.request.url).pathname;
  const resolved = resolveAuthPath(path);
  if (resolved === undefined) {
    return undefined;
  }
  const allowed = AUTH_METHODS[resolved.route];
  if (allowed === undefined) {
    return undefined;
  }
  const method = context.request.method.toUpperCase();
  if (!allowed.includes(method)) {
    return methodNotAllowed(context.requestId, allowed);
  }

  switch (resolved.route) {
    case "/v1/auth/config":
      return asHead(context.request, jsonResponse(authConfig(context.turnstileSiteKey)));
    case "/v1/auth/email-otp/request":
      return requestEmailOtp(context);
    case "/v1/auth/email-otp/verify":
      return verifyEmailOtp(context);
    case "/v1/auth/oauth/authorize":
      return authorizeOAuth(context);
    case "/v1/auth/oauth/local-complete":
      return completeLocalOAuth(context);
    case "/v1/auth/oauth/exchange":
      return exchangeOAuth(context);
    case "/v1/auth/token/refresh":
      return refreshSession(context);
    case "/v1/auth/logout":
      return logout(context);
    case "/v1/auth/bootstrap":
      return bootstrapSession(context);
    case "/v1/me":
      return method === "PATCH" ? patchProfile(context) : getProfile(context);
    case "/v1/me/settings":
      return method === "PUT" ? putUserSettings(context) : getUserSettings(context);
    case "/v1/me/devices":
      return listDevices(context);
    case "/v1/me/devices/{deviceId}":
      return revokeDevice(context, resolved.deviceId ?? "");
    case "/v1/admin/auth/blocked-attempts":
      return listBlockedAttempts(context);
    default:
      return undefined;
  }
}

function authConfig(turnstileSiteKey?: string): AuthConfig {
  const key = turnstileSiteKey?.trim() ?? "";
  return {
    providers: [...AUTH_PROVIDERS],
    ...(key === "" ? {} : { turnstileSiteKey: key }),
  };
}

async function requestEmailOtp(context: AuthRouteContext): Promise<Response> {
  const auth = requireIssuance(context);
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
  const limited = await enforcePasswordlessLimit(context, "email_otp_request", body.value, email);
  if (limited !== undefined) {
    return limited;
  }
  const requested = await auth.requestEmailOtp(email);
  if (!requested.ok) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "email_otp_request_not_ready",
        requestId: context.requestId,
        code: requested.code,
      }),
    );
    return problemResponse({
      status: 503,
      code: "not_ready",
      title: "Service unavailable",
      detail:
        "Could not send a sign-in email. Check Resend and that OTP_FROM_EMAIL uses a verified domain.",
      traceId: context.requestId,
    });
  }
  return new Response(null, { status: 202 });
}

async function verifyEmailOtp(context: AuthRouteContext): Promise<Response> {
  const auth = requireIssuance(context);
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
    return fieldError(context.requestId, "code", "code must be a 6 to 12 digit one-time password.");
  }
  if (!UUID_PATTERN.test(deviceId)) {
    return fieldError(context.requestId, "deviceId", "deviceId must be a UUID.");
  }
  const limited = await enforcePasswordlessLimit(
    context,
    "email_otp_verify",
    body.value,
    email,
    deviceId,
  );
  if (limited !== undefined) {
    return limited;
  }
  const result = await auth.verifyEmailOtp(email, code, deviceId);
  if (!result.ok) {
    if (result.code === "not_ready") {
      return issuanceUnavailable(context.requestId);
    }
    await context.passwordlessLimiter?.recordVerifyFailure({
      email,
      ip: clientIp(context.request),
      deviceId,
      requestId: context.requestId,
    });
    return unauthorized(context.requestId, "The email code is invalid or expired.");
  }
  await context.passwordlessLimiter?.recordVerifySuccess({ email });
  return jsonResponse(toTokenPair(result.value.tokens));
}

async function authorizeOAuth(context: AuthRouteContext): Promise<Response> {
  const auth = requireIssuance(context);
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
  const normalizedChallenge = normalizePkce(codeChallenge);
  if (!PKCE_PATTERN.test(normalizedChallenge)) {
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
    codeChallenge: normalizedChallenge,
    state,
  });
  if (!result.ok) {
    if (result.code === "not_ready") {
      return issuanceUnavailable(context.requestId);
    }
    return unauthorized(context.requestId, "The OAuth request is invalid.");
  }
  const payload: AuthOAuthAuthorizeResponse = {
    authorizationUrl: context.localOAuthComplete
      ? localCompleteAuthorizationUrl(context.request, result.value.authorizationUrl)
      : result.value.authorizationUrl,
    state: result.value.state,
  };
  return jsonResponse(payload);
}

function localCompleteAuthorizationUrl(request: Request, issued: string): string {
  const issuedUrl = new URL(issued);
  const complete = new URL("/v1/auth/oauth/local-complete", request.url);
  for (const key of ["code", "state", "redirect_uri"] as const) {
    const value = issuedUrl.searchParams.get(key);
    if (value !== null && value !== "") {
      complete.searchParams.set(key, value);
    }
  }
  return complete.toString();
}

function completeLocalOAuth(context: AuthRouteContext): Response {
  if (!context.localOAuthComplete) {
    return new Response(null, { status: 404 });
  }
  const url = new URL(context.request.url);
  const code = url.searchParams.get("code")?.trim() ?? "";
  const state = url.searchParams.get("state")?.trim() ?? "";
  const redirectUri = url.searchParams.get("redirect_uri")?.trim() ?? "";
  if (code === "" || state === "" || !isAllowedLocalOAuthRedirect(redirectUri)) {
    return fieldError(
      context.requestId,
      "redirect_uri",
      "Local OAuth completion requires a bound audioreader or localhost redirect.",
    );
  }
  const target = new URL(redirectUri);
  target.searchParams.set("code", code);
  target.searchParams.set("state", state);
  return new Response(null, {
    status: 302,
    headers: { location: target.toString() },
  });
}

function isAllowedLocalOAuthRedirect(uri: string): boolean {
  try {
    const parsed = new URL(uri);
    if (parsed.protocol === "audioreader:" && parsed.host === "auth") {
      return true;
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return false;
    }
    return parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  } catch {
    return false;
  }
}

async function exchangeOAuth(context: AuthRouteContext): Promise<Response> {
  const auth = requireIssuance(context);
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
  const normalizedVerifier = normalizePkce(codeVerifier);
  if (!PKCE_PATTERN.test(normalizedVerifier)) {
    return fieldError(context.requestId, "codeVerifier", "codeVerifier must be a PKCE verifier.");
  }
  const state = optionalString(body.value.state);
  const deviceId = requireDeviceIdHeader(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  const result = await auth.exchangeOAuth({
    provider,
    code,
    codeVerifier: normalizedVerifier,
    redirectUri,
    deviceId,
    ...(state === undefined ? {} : { state }),
  });
  if (!result.ok) {
    if (result.code === "not_ready") {
      return issuanceUnavailable(context.requestId);
    }
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
  const deviceHeader = context.request.headers.get("X-Device-Id")?.trim() ?? "";
  const deviceId = UUID_PATTERN.test(deviceHeader) ? deviceHeader : undefined;
  const result = await auth.refresh(refreshToken, deviceId);
  if (!result.ok) {
    if (result.code === "not_ready") {
      console.warn(
        JSON.stringify({
          level: "warn",
          component: "auth-routes",
          message: "token_refresh",
          requestId: context.requestId,
          outcome: "not_ready",
        }),
      );
      return problemResponse({
        status: 503,
        code: "not_ready",
        title: "Service unavailable",
        detail: "Token refresh is temporarily unavailable.",
        traceId: context.requestId,
      });
    }
    console.warn(
      JSON.stringify({
        level: "warn",
        component: "auth-routes",
        message: "token_refresh",
        requestId: context.requestId,
        outcome: "invalid_refresh",
      }),
    );
    return unauthorized(context.requestId, "The refresh token is invalid.");
  }
  console.warn(
    JSON.stringify({
      level: "warn",
      component: "auth-routes",
      message: "token_refresh",
      requestId: context.requestId,
      outcome: "ok",
    }),
  );
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
  const deviceIdHeader = requireDeviceIdHeader(context.request, context.requestId);
  if (deviceIdHeader instanceof Response) {
    return deviceIdHeader;
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
      const listed = await auth.listDevices(principal);
      const active = listed.filter((device) => !device.revoked);
      const alreadyRegistered = active.some((device) => device.id === deviceId);
      if (!alreadyRegistered && context.ops !== undefined) {
        const quotas = await context.ops.quotasFor(principal.accountId);
        const devicesQuota = quotas.find((item) => item.key === "devices");
        const limit = devicesQuota?.limit ?? 2;
        if (active.length >= limit) {
          return problemResponse({
            status: 409,
            code: "device_limit",
            title: "Conflict",
            detail: `This account can have at most ${String(limit)} signed-in devices. Revoke another device and try again.`,
            traceId: context.requestId,
          });
        }
      }
      const bootstrapped = await auth.bootstrap(principal, {
        deviceId,
        platform,
        appVersion,
        ...(deviceName === undefined ? {} : { deviceName }),
        ...(buildNumber === undefined ? {} : { buildNumber }),
        ...(locale === undefined ? {} : { locale }),
        ...(timeZone === undefined ? {} : { timeZone }),
      });
      if (!bootstrapped.ok) {
        if (bootstrapped.code === "device_revoked") {
          return forbidden(context.requestId, "This device has been revoked.");
        }
        return unauthorized(context.requestId, "Authentication required.");
      }
      const flags =
        context.ops === undefined
          ? [...bootstrapped.value.featureFlags]
          : (await context.ops.listFlags()).map((flag) => ({
              key: flag.key,
              enabled: flag.enabled,
              variant: flag.variant,
              rolloutPercent: flag.rolloutPercent,
              minAppVersion: flag.minAppVersion,
              platforms: flag.platforms.filter(
                (item): item is "macos" | "ios" | "ipados" =>
                  item === "macos" || item === "ios" || item === "ipados",
              ),
            }));
      const quotas =
        context.ops === undefined
          ? [...bootstrapped.value.quotas]
          : await context.ops.quotasFor(principal.accountId);
      const payload: BootstrapResponse = {
        profile: toProfile(bootstrapped.value.profile),
        device: bootstrapped.value.device,
        settings: bootstrapped.value.settings,
        featureFlags: flags,
        quotas,
        syncCursor: bootstrapped.value.syncCursor,
      };
      return jsonResponse(payload);
    },
    context.requestId,
    principal,
  );
}

async function getProfile(context: AuthRouteContext): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const stored = await context.auth?.getProfile(principal);
  const profile = stored ?? profileFromPrincipal(principal);
  return asHead(context.request, jsonResponse(toProfile(profile)));
}

async function patchProfile(context: AuthRouteContext): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const deviceIdHeader = requireDeviceIdHeader(context.request, context.requestId);
  if (deviceIdHeader instanceof Response) {
    return deviceIdHeader;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const displayName = optionalNullableString(body.value.displayName);
      const avatarUrl = optionalNullableString(body.value.avatarUrl);
      const patched = await auth.patchProfile(principal, {
        ...(displayName === undefined ? {} : { displayName }),
        ...(avatarUrl === undefined ? {} : { avatarUrl }),
      });
      if (patched === undefined) {
        return notFound(context.requestId, "Profile not found.");
      }
      return jsonResponse(toProfile(patched));
    },
    context.requestId,
    principal,
  );
}

async function getUserSettings(context: AuthRouteContext): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const settings = await auth.getSettings(principal);
  if (settings === undefined) {
    return notFound(context.requestId, "Settings not found.");
  }
  return asHead(context.request, jsonResponse(toUserSettings(settings)));
}

async function putUserSettings(context: AuthRouteContext): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  const deviceIdHeader = requireDeviceIdHeader(context.request, context.requestId);
  if (deviceIdHeader instanceof Response) {
    return deviceIdHeader;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const body = await readJsonObject(context.request, context.requestId);
      if (!body.ok) {
        return body.response;
      }
      const parsed = parseUserSettings(body.value, context.requestId);
      if (parsed instanceof Response) {
        return parsed;
      }
      const result = await auth.putSettings(principal, parsed);
      if (!result.ok) {
        if (result.code === "conflict") {
          return problemResponse({
            status: 409,
            code: "conflict",
            title: "Conflict",
            detail: "Settings were updated on another device. Reload and retry.",
            traceId: context.requestId,
          });
        }
        return notFound(context.requestId, "Settings not found.");
      }
      return jsonResponse(toUserSettings(result.value));
    },
    context.requestId,
    principal,
  );
}

async function listDevices(context: AuthRouteContext): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  return asHead(context.request, jsonResponse(await auth.listDevices(principal)));
}

async function revokeDevice(context: AuthRouteContext, deviceId: string): Promise<Response> {
  const principal = await requireBoundProductPrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  if (!UUID_PATTERN.test(deviceId)) {
    return fieldError(context.requestId, "deviceId", "deviceId must be a UUID.");
  }
  const deviceIdHeader = requireDeviceIdHeader(context.request, context.requestId);
  if (deviceIdHeader instanceof Response) {
    return deviceIdHeader;
  }
  return withIdempotency(
    context.idempotencyStore,
    context.request,
    async () => {
      const result = await auth.revokeDevice(principal, deviceId);
      if (!result.ok) {
        return notFound(context.requestId, "Device not found.");
      }
      return new Response(null, { status: 204 });
    },
    context.requestId,
    principal,
  );
}

async function listBlockedAttempts(context: AuthRouteContext): Promise<Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  if (principal.role !== "admin") {
    return forbidden(context.requestId, "Administrator role required.");
  }
  if (
    !principal.adminRoles.some(
      (role) => role === "support_readonly" || role === "operator" || role === "superadmin",
    )
  ) {
    return forbidden(context.requestId, "Blocked sign-in attempts require access.read.");
  }
  const items = (await context.passwordlessLimiter?.listBlockedAttempts()) ?? [];
  return asHead(context.request, jsonResponse({ items }));
}

async function enforcePasswordlessLimit(
  context: AuthRouteContext,
  action: "email_otp_request" | "email_otp_verify",
  body: Record<string, unknown>,
  email: string,
  deviceId?: string,
): Promise<Response | undefined> {
  const limiter = context.passwordlessLimiter;
  if (limiter === undefined) {
    return undefined;
  }
  const headerDevice = optionalDeviceHeader(context.request);
  const resolvedDevice = deviceId ?? headerDevice;
  const turnstileToken = optionalTurnstileToken(body, context.request);
  const attempt = {
    email,
    ip: clientIp(context.request),
    requestId: context.requestId,
    ...(resolvedDevice === undefined ? {} : { deviceId: resolvedDevice }),
    ...(turnstileToken === undefined ? {} : { turnstileToken }),
  };
  const decision =
    action === "email_otp_request"
      ? await limiter.checkRequest(attempt)
      : await limiter.checkVerify(attempt);
  if (decision.ok) {
    return undefined;
  }
  return passwordlessDenied(context.requestId, decision);
}

function passwordlessDenied(
  requestId: string,
  decision: Exclude<PasswordlessDecision, { ok: true }>,
): Response {
  if (decision.code === "rate_limited") {
    return problemResponse({
      status: 429,
      code: "rate_limited",
      title: "Too many requests",
      detail: "Too many authentication attempts. Try again later.",
      traceId: requestId,
      retryAfterSeconds: decision.retryAfterSeconds,
      headers: { "Retry-After": String(decision.retryAfterSeconds) },
    });
  }
  return problemResponse({
    status: 403,
    code: "challenge_required",
    title: "Challenge required",
    detail: "Complete the Turnstile challenge and retry.",
    traceId: requestId,
  });
}

function clientIp(request: Request): string {
  const connecting = request.headers.get("CF-Connecting-IP")?.trim() ?? "";
  if (connecting !== "") {
    return connecting;
  }
  const forwarded = request.headers.get("X-Forwarded-For")?.trim() ?? "";
  const first = forwarded.split(",")[0]?.trim() ?? "";
  return first === "" ? "unknown" : first;
}

function optionalDeviceHeader(request: Request): string | undefined {
  const deviceId = request.headers.get("X-Device-Id")?.trim() ?? "";
  return UUID_PATTERN.test(deviceId) ? deviceId : undefined;
}

function optionalTurnstileToken(
  body: Record<string, unknown>,
  request: Request,
): string | undefined {
  const fromBody = optionalString(body.turnstileToken);
  if (fromBody !== undefined) {
    return fromBody;
  }
  const fromHeader = request.headers.get("cf-turnstile-response")?.trim() ?? "";
  return fromHeader === "" ? undefined : fromHeader;
}

async function requirePrincipal(context: AuthRouteContext): Promise<Principal | Response> {
  const principal = await context.authenticate(context.request);
  if (principal === null) {
    return unauthorized(context.requestId, "Authentication required.");
  }
  return principal;
}

async function requireBoundProductPrincipal(
  context: AuthRouteContext,
): Promise<Principal | Response> {
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const auth = context.auth;
  const bound = await requireBoundDevice({
    request: context.request,
    requestId: context.requestId,
    accountId: principal.accountId,
    hasActiveDevice: async (_accountId, deviceId) => {
      if (auth === undefined) {
        return false;
      }
      const devices = await auth.listDevices(principal);
      return devices.some((device) => device.id === deviceId && !device.revoked);
    },
  });
  if (bound instanceof Response) {
    return bound;
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

function requireIssuance(context: AuthRouteContext): AuthService | Response {
  const auth = requireAuthService(context);
  if (auth instanceof Response) {
    return auth;
  }
  if (!auth.canIssueSessions()) {
    return issuanceUnavailable(context.requestId);
  }
  return auth;
}

function issuanceUnavailable(requestId: string): Response {
  return problemResponse({
    status: 503,
    code: "not_ready",
    title: "Service unavailable",
    detail: "Passwordless and OAuth login are not available in this environment.",
    traceId: requestId,
  });
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

function toUserSettings(settings: ProductSettings) {
  return {
    revision: settings.revision,
    sourceLanguage: settings.sourceLanguage,
    targetLanguage: settings.targetLanguage,
    readerLevel: settings.readerLevel,
    playbackRate: settings.playbackRate,
    skipSeconds: settings.skipSeconds,
    appearance: settings.appearance,
    updatedAt: settings.updatedAt,
  };
}

function parseUserSettings(
  body: Record<string, unknown>,
  requestId: string,
): ProductSettings | Response {
  const sourceLanguage = requiredString(body.sourceLanguage, "sourceLanguage", requestId);
  if (sourceLanguage instanceof Response) {
    return sourceLanguage;
  }
  const targetLanguage = requiredString(body.targetLanguage, "targetLanguage", requestId);
  if (targetLanguage instanceof Response) {
    return targetLanguage;
  }
  const readerLevel = body.readerLevel;
  if (
    readerLevel !== "beginner" &&
    readerLevel !== "elementary" &&
    readerLevel !== "intermediate" &&
    readerLevel !== "upper_intermediate" &&
    readerLevel !== "advanced"
  ) {
    return fieldError(requestId, "readerLevel", "readerLevel is invalid.");
  }
  const appearance = body.appearance;
  if (appearance !== "system" && appearance !== "light" && appearance !== "dark") {
    return fieldError(requestId, "appearance", "appearance is invalid.");
  }
  if (typeof body.revision !== "number" || !Number.isInteger(body.revision) || body.revision < 0) {
    return fieldError(requestId, "revision", "revision must be a non-negative integer.");
  }
  if (typeof body.playbackRate !== "number" || body.playbackRate < 0.5 || body.playbackRate > 3) {
    return fieldError(requestId, "playbackRate", "playbackRate must be between 0.5 and 3.");
  }
  if (typeof body.skipSeconds !== "number" || body.skipSeconds < 1 || body.skipSeconds > 60) {
    return fieldError(requestId, "skipSeconds", "skipSeconds must be between 1 and 60.");
  }
  return {
    revision: body.revision,
    sourceLanguage,
    targetLanguage,
    readerLevel,
    playbackRate: body.playbackRate,
    skipSeconds: body.skipSeconds,
    appearance,
    updatedAt: typeof body.updatedAt === "string" ? body.updatedAt : new Date().toISOString(),
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
    if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      return text;
    }
    // Native ASWebAuthenticationSession cannot watch http(s).
    if (parsed.protocol === "audioreader:") {
      const href = parsed.href;
      if (
        parsed.host === "auth" ||
        href.startsWith("audioreader://auth/callback") ||
        href.startsWith("audioreader:auth/callback")
      ) {
        return text;
      }
    }
  } catch {
    // Invalid URI text falls through to the field error.
  }
  return fieldError(
    requestId,
    field,
    `${field} must be an http(s) URI or audioreader://auth callback.`,
  );
}

function requireDeviceIdHeader(request: Request, requestId: string): string | Response {
  const deviceIdHeader = request.headers.get("X-Device-Id")?.trim() ?? "";
  if (!UUID_PATTERN.test(deviceIdHeader)) {
    return problemResponse({
      status: 400,
      code: "bad_request",
      title: "Bad request",
      detail: "X-Device-Id must be a UUID.",
      traceId: requestId,
    });
  }
  return deviceIdHeader;
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

function normalizePkce(value: string): string {
  return value.replace(/=+$/g, "");
}

function fieldError(requestId: string, field: string, message: string): Response {
  return problemResponse({
    status: 400,
    code: "bad_request",
    title: "Bad request",
    detail: message,
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

function forbidden(requestId: string, detail: string): Response {
  return problemResponse({
    status: 403,
    code: "forbidden",
    title: "Forbidden",
    detail,
    traceId: requestId,
  });
}

function notFound(requestId: string, detail: string): Response {
  return problemResponse({
    status: 404,
    code: "not_found",
    title: "Not found",
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
