import { extractBearerToken, validateAccessToken, type JwtSigningConfig } from "./jwt";
import type { Principal } from "./principal";
import {
  createMemoryAuthService,
  type AuthIdentityStore,
  type AuthService,
  type OAuthProvider,
  type ProductProfile,
  type SettingsPutResult,
} from "./service";
import type { AuthFailureCode, AuthResult, AuthenticatedSession, SessionTokens } from "./service";

export type HostedAuthFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export type HostedOtpMailer = (input: { to: string; code: string }) => Promise<boolean>;

export type HostedAuthServiceOptions = {
  jwt: JwtSigningConfig;
  supabaseUrl: string;
  supabaseAnonKey: string;
  serviceRoleKey?: string;
  sendOtpEmail?: HostedOtpMailer;
  fetch?: HostedAuthFetch;
  now?: () => Date;
  inner?: AuthService;
  identity?: AuthIdentityStore;
  adminBootstrapEmail?: string;
};

const GOTRUE_PROVIDERS: Record<OAuthProvider, string> = {
  google: "google",
  microsoft: "azure",
};

const BLOCKED_ACCOUNT_STATUSES = new Set(["suspended", "deletion_pending", "deleted"]);

export function createHostedAuthService(options: HostedAuthServiceOptions): AuthService {
  const now = options.now ?? (() => new Date());
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const authBase = `${options.supabaseUrl.replace(/\/$/, "")}/auth/v1`;
  const identity = options.identity;
  const inner =
    options.inner ??
    createMemoryAuthService({
      jwt: options.jwt,
      now,
      allowLocalIssuance: false,
    });

  // Admin comes from admin_roles, not the JWT. The configured bootstrap identity
  // receives one superadmin grant, including upgrades from legacy operator grants.
  async function principalFromProfile(
    profile: ProductProfile,
    subject: string,
    requestId: string,
  ): Promise<Principal> {
    let adminRoles = (await identity?.adminRoles?.(profile.accountId)) ?? [];
    let admin = adminRoles.length > 0;
    if (!admin && identity?.adminRoles === undefined) {
      admin = (await identity?.hasAdminRole?.(profile.accountId)) ?? false;
      adminRoles = admin ? ["operator"] : [];
    }
    const bootstrap = options.adminBootstrapEmail?.trim().toLowerCase() ?? "";
    const bootstrapMatch = bootstrap !== "" && profile.email.trim().toLowerCase() === bootstrap;
    if (bootstrapMatch && identity !== undefined) {
      const granted = await grantBootstrapAdmin(
        identity,
        profile.accountId,
        requestId,
        adminRoles.includes("operator"),
      );
      if (granted) {
        admin = true;
        adminRoles = [...new Set([...adminRoles, "superadmin" as const])];
      }
    }
    return {
      subject,
      profileId: profile.id,
      accountId: profile.accountId,
      role: admin ? ("admin" as const) : ("user" as const),
      adminRoles,
      email: profile.email,
    };
  }

  async function grantBootstrapAdmin(
    store: AuthIdentityStore,
    accountId: string,
    requestId: string,
    isLegacyAdmin: boolean,
  ): Promise<boolean> {
    let conflictingAdmin: boolean;
    let priorSuperadmin: boolean;
    try {
      conflictingAdmin =
        (await store.hasAnyAdminRole?.(isLegacyAdmin ? "superadmin" : undefined)) ?? true;
      priorSuperadmin = (await store.hasAdminRoleHistory?.(accountId, "superadmin")) ?? true;
    } catch {
      conflictingAdmin = true;
      priorSuperadmin = true;
    }
    // Multiple superadmins are valid; this guard only prevents late automatic bootstrap.
    if (conflictingAdmin || priorSuperadmin) {
      logAuthEvent({
        message: "admin_bootstrap_grant",
        requestId,
        accountId,
        outcome: "skipped",
        reason: priorSuperadmin
          ? "grant_history_exists"
          : isLegacyAdmin
            ? "superadmin_exists"
            : "admins_exist",
      });
      return false;
    }
    if (store.grantAdminRole === undefined) {
      return false;
    }
    try {
      await store.grantAdminRole(accountId, "superadmin");
      const activeRoles = await store.adminRoles?.(accountId);
      if (activeRoles?.includes("superadmin") !== true) {
        throw new Error("bootstrap superadmin grant was not persisted");
      }
      logAuthEvent({
        message: "admin_bootstrap_grant",
        requestId,
        accountId,
        outcome: "granted",
      });
      return true;
    } catch {
      logAuthEvent({
        message: "admin_bootstrap_grant",
        requestId,
        accountId,
        outcome: "failed",
        reason: "persist_failed",
      });
      return false;
    }
  }

  function headers(accessToken?: string, apiKey?: string): Record<string, string> {
    const token = accessToken ?? options.supabaseAnonKey;
    return {
      apikey: apiKey ?? options.supabaseAnonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    };
  }

  async function gotrue(
    pathAndQuery: string,
    init: { method: string; body?: unknown; accessToken?: string; apiKey?: string },
  ): Promise<{ status: number; body: unknown } | { status: 0; body: null }> {
    try {
      const response = await fetchImpl(`${authBase}${pathAndQuery}`, {
        method: init.method,
        headers: headers(init.accessToken, init.apiKey),
        ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
      });
      return { status: response.status, body: await readBody(response) };
    } catch {
      logAuthEvent({
        message: "hosted_gotrue_error",
        requestId: "auth",
        outcome: "network_error",
        reason: pathAndQuery.split("?")[0] ?? "gotrue",
      });
      return { status: 0, body: null };
    }
  }

  async function sessionFromGoTrue(
    body: unknown,
    deviceId: string | undefined,
    failure: AuthFailureCode,
  ): Promise<AuthResult<AuthenticatedSession>> {
    const tokens = parseSessionTokens(body, now());
    if (tokens === undefined) {
      return { ok: false, code: failure };
    }
    const requestHeaders = new Headers({ authorization: `Bearer ${tokens.accessToken}` });
    if (deviceId !== undefined && deviceId !== "") {
      requestHeaders.set("X-Device-Id", deviceId);
    }
    const principal = await authenticateWithHeaders(requestHeaders);
    if (principal === null) {
      return { ok: false, code: "invalid_token" };
    }
    const profile = await getStoredProfile(principal);
    if (profile === undefined) {
      return { ok: false, code: "invalid_token" };
    }
    return { ok: true, value: { tokens, principal, profile } };
  }

  // JWT proves the GoTrue subject. Device revoke and account status live in
  // identity storage; a valid signature is not enough to use the product API.
  async function authenticateWithHeaders(headers: Headers): Promise<Principal | null> {
    const requestId = headers.get("X-Request-Id")?.trim() || "auth";
    const request = new Request("https://audio-reader.local/session", { headers });
    if (identity === undefined) {
      return inner.authenticate(request);
    }
    const token = extractBearerToken(headers.get("authorization"));
    if (token === null) {
      return null;
    }
    const result = await validateAccessToken(token, options.jwt, now());
    if (!result.ok) {
      return null;
    }
    const email = result.claims.email ?? `${result.claims.sub}@users.invalid`;
    const profile = await identity.ensureProfile({ userId: result.claims.sub, email });
    const status = profileAccountStatus(profile);
    if (BLOCKED_ACCOUNT_STATUSES.has(status)) {
      logAuthEvent({
        message: "hosted_authenticate",
        requestId,
        accountId: profile.accountId,
        outcome: "blocked_status",
        reason: status,
      });
      return null;
    }
    const deviceId = headers.get("X-Device-Id")?.trim() ?? "";
    if (deviceId !== "" && (await identity.isDeviceRevoked(profile.accountId, deviceId))) {
      logAuthEvent({
        message: "hosted_authenticate",
        requestId,
        accountId: profile.accountId,
        outcome: "device_revoked",
      });
      return null;
    }
    return await principalFromProfile(profile, result.claims.sub, requestId);
  }

  async function getStoredProfile(principal: Principal): Promise<ProductProfile | undefined> {
    if (identity === undefined) {
      return inner.getProfile(principal);
    }
    const existing = await identity.getProfileByUserId(principal.accountId);
    if (existing !== undefined) {
      return existing;
    }
    return identity.ensureProfile({ userId: principal.subject, email: principal.email });
  }

  // GoTrue owns social-provider availability. Read its public settings with the
  // anon credential so the product API never advertises a disabled provider.
  async function enabledOAuthProviders(): Promise<Set<OAuthProvider> | undefined> {
    const result = await gotrue("/settings", { method: "GET" });
    if (result.status < 200 || result.status >= 300 || !isRecord(result.body)) {
      logAuthEvent({
        message: "hosted_auth_provider_settings",
        requestId: "auth",
        outcome: "unavailable",
        reason: `gotrue_${String(result.status)}`,
      });
      return undefined;
    }
    const external = result.body.external;
    if (!isRecord(external)) {
      logAuthEvent({
        message: "hosted_auth_provider_settings",
        requestId: "auth",
        outcome: "invalid_response",
      });
      return undefined;
    }
    return new Set(
      (["google", "microsoft"] as const).filter((provider) => {
        const gotrueProvider = GOTRUE_PROVIDERS[provider];
        return external[gotrueProvider] === true;
      }),
    );
  }

  return {
    async authConfig() {
      const enabled = await enabledOAuthProviders();
      return {
        providers: [
          ...(enabled?.has("google") === true ? [{ id: "google" as const }] : []),
          ...(enabled?.has("microsoft") === true ? [{ id: "microsoft" as const }] : []),
          { id: "email_otp" as const },
        ],
      };
    },

    canIssueSessions() {
      return true;
    },

    authenticate(request) {
      return authenticateWithHeaders(request.headers);
    },

    async requestEmailOtp(email) {
      const serviceRoleKey = options.serviceRoleKey?.trim() ?? "";
      const sendOtpEmail = options.sendOtpEmail;
      if (serviceRoleKey !== "" && sendOtpEmail !== undefined) {
        const generated = await gotrue("/admin/generate_link", {
          method: "POST",
          accessToken: serviceRoleKey,
          apiKey: serviceRoleKey,
          body: { type: "magiclink", email },
        });
        logAuthEvent({
          message: "hosted_otp_generate_link",
          requestId: "auth",
          outcome: generated.status === 0 ? "network" : `http_${String(generated.status)}`,
        });
        const code = extractEmailOtp(generated.body);
        if (code !== undefined) {
          const sent = await sendOtpEmail({ to: email, code });
          if (sent) {
            logAuthEvent({
              message: "hosted_otp_request",
              requestId: "auth",
              outcome: "code_mailed",
            });
            return { ok: true, value: { accepted: true } };
          }
          logAuthEvent({
            message: "hosted_otp_request",
            requestId: "auth",
            outcome: "mailer_failed",
          });
        } else if (generated.status > 0 && generated.status < 400) {
          logAuthEvent({
            message: "hosted_otp_request",
            requestId: "auth",
            outcome: "missing_code",
          });
        }
      }
      const result = await gotrue("/otp", {
        method: "POST",
        body: { email, create_user: true },
      });
      logAuthEvent({
        message: "hosted_otp_gotrue",
        requestId: "auth",
        outcome: result.status === 0 ? "network" : `http_${String(result.status)}`,
      });
      if (
        result.status === 0 ||
        result.status >= 500 ||
        result.status === 401 ||
        result.status === 429
      ) {
        return { ok: false, code: "not_ready" };
      }
      // 2xx and typical 4xx (unknown address, already registered) must look the same.
      return { ok: true, value: { accepted: true } };
    },

    async verifyEmailOtp(email, code, deviceId) {
      const types = ["email", "magiclink"] as const;
      let last: { status: number; body: unknown } | { status: 0; body: null } | undefined;
      for (const type of types) {
        const result = await gotrue("/verify", {
          method: "POST",
          body: { type, email, token: code },
        });
        last = result;
        if (result.status === 0 || result.status >= 500) {
          return { ok: false, code: "not_ready" };
        }
        if (result.status < 400) {
          return sessionFromGoTrue(result.body, deviceId, "invalid_otp");
        }
      }
      if (last !== undefined && last.status === 429) {
        return { ok: false, code: "not_ready" };
      }
      return { ok: false, code: "invalid_otp" };
    },

    async authorizeOAuth(input) {
      try {
        const enabled = await enabledOAuthProviders();
        if (enabled === undefined) {
          return { ok: false as const, code: "not_ready" as const };
        }
        if (!enabled.has(input.provider)) {
          logAuthEvent({
            message: "hosted_oauth_authorize",
            requestId: "auth",
            outcome: "provider_disabled",
            reason: input.provider,
          });
          return { ok: false as const, code: "provider_disabled" as const };
        }
        // Keep redirect_to exactly as allow-listed (no extra query). GoTrue
        // otherwise falls back to Site URL (default http://localhost:3000).
        new URL(input.redirectUri);
        const authorizationUrl = new URL(`${authBase}/authorize`);
        authorizationUrl.searchParams.set("provider", GOTRUE_PROVIDERS[input.provider]);
        authorizationUrl.searchParams.set("redirect_to", input.redirectUri);
        authorizationUrl.searchParams.set("code_challenge", input.codeChallenge);
        authorizationUrl.searchParams.set("code_challenge_method", "S256");
        // Forwarded to Google/Azure. Without this, a shared Safari Google
        // session silently re-auths the previous account after app sign-out.
        authorizationUrl.searchParams.set("prompt", "select_account");
        if (input.provider === "microsoft") {
          authorizationUrl.searchParams.set("scopes", "email");
        }
        return {
          ok: true as const,
          value: { authorizationUrl: authorizationUrl.toString(), state: input.state },
        };
      } catch {
        return { ok: false as const, code: "invalid_oauth" as const };
      }
    },

    async exchangeOAuth(input) {
      const result = await gotrue("/token?grant_type=pkce", {
        method: "POST",
        body: {
          auth_code: input.code,
          code_verifier: input.codeVerifier,
        },
      });
      if (result.status === 0 || result.status >= 500) {
        return { ok: false, code: "not_ready" };
      }
      if (result.status >= 400) {
        const upstreamCode =
          isRecord(result.body) && typeof result.body.error_code === "string"
            ? result.body.error_code
            : `gotrue_${String(result.status)}`;
        logAuthEvent({
          message: "hosted_oauth_exchange",
          requestId: "auth",
          outcome: "rejected",
          reason: upstreamCode,
        });
        if (upstreamCode === "bad_code_verifier") {
          return { ok: false, code: "pkce_mismatch" };
        }
        return { ok: false, code: "invalid_oauth" };
      }
      return sessionFromGoTrue(result.body, input.deviceId, "invalid_oauth");
    },

    async refresh(refreshToken, deviceId) {
      const result = await gotrue("/token?grant_type=refresh_token", {
        method: "POST",
        body: { refresh_token: refreshToken },
      });
      // Network / 5xx / 429 are provider outages. Only 4xx means the token is bad.
      if (result.status === 0 || result.status >= 500 || result.status === 429) {
        logAuthEvent({
          message: "hosted_refresh",
          requestId: "auth",
          outcome: "not_ready",
          reason: `gotrue_${String(result.status)}`,
        });
        return { ok: false, code: "not_ready" };
      }
      if (result.status >= 400) {
        logAuthEvent({
          message: "hosted_refresh",
          requestId: "auth",
          outcome: "invalid_refresh",
        });
        return { ok: false, code: "invalid_refresh" };
      }
      // Pass the caller device so a revoked X-Device-Id cannot mint a new pair.
      const session = await sessionFromGoTrue(result.body, deviceId, "invalid_refresh");
      if (!session.ok) {
        logAuthEvent({
          message: "hosted_refresh",
          requestId: "auth",
          outcome: session.code,
        });
        return session;
      }
      logAuthEvent({
        message: "hosted_refresh",
        requestId: "auth",
        accountId: session.value.principal.accountId,
        outcome: "ok",
      });
      return {
        ok: true,
        value: { tokens: session.value.tokens, principal: session.value.principal },
      };
    },

    async logout(refreshToken) {
      const refreshed = await gotrue("/token?grant_type=refresh_token", {
        method: "POST",
        body: { refresh_token: refreshToken },
      });
      const tokens = parseSessionTokens(refreshed.body, now());
      if (tokens !== undefined) {
        await gotrue("/logout?scope=global", {
          method: "POST",
          accessToken: tokens.accessToken,
        });
      }
    },

    getProfile(principal) {
      return getStoredProfile(principal);
    },

    patchProfile(principal, patch) {
      if (identity === undefined) {
        return inner.patchProfile(principal, patch);
      }
      return identity.patchProfile(principal.accountId, patch);
    },

    getSettings(principal) {
      if (identity === undefined) {
        return inner.getSettings(principal);
      }
      return identity.getSettings(principal.accountId);
    },

    putSettings(principal, settings): Promise<SettingsPutResult> {
      if (identity === undefined) {
        return inner.putSettings(principal, settings);
      }
      return identity.putSettings(principal.accountId, settings);
    },

    async bootstrap(principal, input) {
      if (identity === undefined) {
        return inner.bootstrap(principal, input);
      }
      const bootstrapped = await identity.bootstrapDevice(principal.accountId, input);
      if (!bootstrapped.ok) {
        return bootstrapped;
      }
      return {
        ok: true,
        value: {
          profile: bootstrapped.profile,
          device: bootstrapped.device,
          settings: bootstrapped.settings,
          featureFlags: [],
          quotas: [],
          syncCursor: bootstrapped.syncCursor,
        },
      };
    },

    listDevices(principal) {
      if (identity === undefined) {
        return inner.listDevices(principal);
      }
      return identity.listDevices(principal.accountId);
    },

    revokeDevice(principal, deviceId) {
      if (identity === undefined) {
        return inner.revokeDevice(principal, deviceId);
      }
      return identity.revokeDevice(principal.accountId, deviceId);
    },

    linkIdentity(principal, input) {
      return inner.linkIdentity(principal, input);
    },
  };
}

function parseSessionTokens(body: unknown, now: Date): SessionTokens | undefined {
  const record = unwrapSessionRecord(body);
  if (record === undefined) {
    return undefined;
  }
  const accessToken = sessionString(record, "access_token", "accessToken");
  const refreshToken = sessionString(record, "refresh_token", "refreshToken");
  if (accessToken === undefined || refreshToken === undefined) {
    return undefined;
  }
  return {
    accessToken,
    refreshToken,
    expiresAt: expiryIso(record, now),
    tokenType: "Bearer",
  };
}

function unwrapSessionRecord(body: unknown): Record<string, unknown> | undefined {
  if (!isRecord(body)) {
    return undefined;
  }
  if (isRecord(body.session)) {
    return { ...body, ...body.session };
  }
  return body;
}

function sessionString(record: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed !== "") {
        return trimmed;
      }
    }
  }
  return undefined;
}

function expiryIso(body: Record<string, unknown>, now: Date): string {
  if (typeof body.expires_at === "number" && Number.isFinite(body.expires_at)) {
    const milliseconds =
      body.expires_at > 1_000_000_000_000 ? body.expires_at : body.expires_at * 1000;
    return new Date(milliseconds).toISOString();
  }
  const seconds =
    typeof body.expires_in === "number" && Number.isFinite(body.expires_in)
      ? body.expires_in
      : 3600;
  return new Date(now.getTime() + seconds * 1000).toISOString();
}

async function readBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.trim() === "") {
    return null;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function profileAccountStatus(profile: ProductProfile): string {
  if (!("status" in profile)) {
    return "active";
  }
  const status = (profile as { status?: unknown }).status;
  return typeof status === "string" && status.trim() !== "" ? status : "active";
}

function logAuthEvent(event: {
  message: string;
  requestId: string;
  outcome: string;
  accountId?: string;
  reason?: string;
}): void {
  console.warn(
    JSON.stringify({
      level: "warn",
      component: "hosted-auth",
      ...event,
    }),
  );
}

export function extractEmailOtp(body: unknown): string | undefined {
  const records: unknown[] = [body];
  if (isRecord(body) && body.properties !== undefined) {
    records.push(body.properties);
  }
  for (const record of records) {
    if (!isRecord(record)) {
      continue;
    }
    const value = record.email_otp;
    if (typeof value === "string" && /^[0-9]{6,12}$/.test(value.trim())) {
      return value.trim();
    }
  }
  return undefined;
}
