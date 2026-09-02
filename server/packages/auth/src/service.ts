import {
  extractBearerToken,
  signAccessToken,
  toBase64Url,
  validateAccessToken,
  type JwtSigningConfig,
} from "./jwt";
import type { AdminRole, Principal } from "./principal";

export type OAuthProvider = "google" | "microsoft";
export type IdentityProvider = OAuthProvider | "email";
export type AuthProviderId = OAuthProvider | "email_otp";

export type SessionTokens = {
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
  tokenType: "Bearer";
};

export type ProductProfile = {
  id: string;
  accountId: string;
  email: string;
  displayName: string | null;
  avatarUrl: string | null;
  createdAt: string;
  updatedAt: string;
  deletionPendingAt: string | null;
};

export type ProductDevice = {
  id: string;
  platform: "macos" | "ios" | "ipados";
  name: string | null;
  appVersion: string;
  buildNumber?: string;
  createdAt: string;
  lastSeenAt: string;
  revoked: boolean;
  revokedAt: string | null;
};

export type ProductSettings = {
  revision: number;
  sourceLanguage: string;
  targetLanguage: string;
  readerLevel: "beginner" | "elementary" | "intermediate" | "upper_intermediate" | "advanced";
  playbackRate: number;
  skipSeconds: number;
  appearance: "system" | "light" | "dark";
  updatedAt: string;
};

export type BootstrapDeviceInput = {
  deviceId: string;
  platform: "macos" | "ios" | "ipados";
  deviceName?: string | null;
  appVersion: string;
  buildNumber?: string;
  locale?: string;
  timeZone?: string;
};

export type ProductFeatureFlag = {
  key: string;
  enabled: boolean;
  variant?: string | null;
};

export type ProductQuota = {
  key: string;
  used: number;
  limit: number;
  periodEndsAt: string;
};

export type BootstrapSession = {
  profile: ProductProfile;
  device: ProductDevice;
  settings: ProductSettings;
  featureFlags: readonly ProductFeatureFlag[];
  quotas: readonly ProductQuota[];
  syncCursor: string;
};

export type AuthFailureCode =
  | "invalid_otp"
  | "invalid_oauth"
  | "invalid_refresh"
  | "invalid_token"
  | "invalid_issuer"
  | "invalid_audience"
  | "invalid_signature"
  | "expired"
  | "missing_subject"
  | "not_ready"
  | "already_linked"
  | "device_revoked"
  | "not_found";

export type DeviceRevokeResult = { ok: true } | { ok: false; code: "not_found" };

export type AuthResult<T> = { ok: true; value: T } | { ok: false; code: AuthFailureCode };

export type OAuthAuthorizeInput = {
  provider: OAuthProvider;
  redirectUri: string;
  codeChallenge: string;
  state: string;
  identity?: { email: string; providerSubject: string };
};

export type OAuthExchangeInput = {
  provider: OAuthProvider;
  code: string;
  codeVerifier: string;
  redirectUri: string;
  state?: string;
  deviceId?: string;
};

export type LinkIdentityInput = {
  provider: IdentityProvider;
  providerSubject: string;
  email: string;
};

export type AuthenticatedSession = {
  tokens: SessionTokens;
  principal: Principal;
  profile: ProductProfile;
};

export const AUTH_PROVIDERS: readonly { id: AuthProviderId }[] = [
  { id: "google" },
  { id: "microsoft" },
  { id: "email_otp" },
];

export type MemoryAuthServiceOptions = {
  jwt: JwtSigningConfig;
  now?: () => Date;
  generateOtp?: () => string;
  otpTtlSeconds?: number;
  refreshTtlSeconds?: number;
  allowLocalIssuance?: boolean;
};

export type AuthIdentityStore = {
  ensureProfile(input: { userId: string; email: string }): Promise<ProductProfile>;
  getProfileByUserId(userId: string): Promise<ProductProfile | undefined>;
  patchProfile(
    userId: string,
    patch: { displayName?: string | null; avatarUrl?: string | null },
  ): Promise<ProductProfile | undefined>;
  getSettings(userId: string): Promise<ProductSettings>;
  putSettings(
    userId: string,
    settings: ProductSettings,
  ): Promise<
    { ok: true; value: ProductSettings } | { ok: false; code: "conflict"; current: ProductSettings }
  >;
  bootstrapDevice(
    userId: string,
    input: BootstrapDeviceInput,
  ): Promise<
    | {
        ok: true;
        profile: ProductProfile;
        device: ProductDevice;
        settings: ProductSettings;
        syncCursor: string;
      }
    | { ok: false; code: "device_revoked" }
  >;
  listDevices(userId: string): Promise<ProductDevice[]>;
  revokeDevice(userId: string, deviceId: string): Promise<DeviceRevokeResult>;
  isDeviceRevoked(userId: string, deviceId: string): Promise<boolean>;
  hasAdminRole?(userId: string): Promise<boolean>;
  adminRoles?(userId: string): Promise<AdminRole[]>;
  hasAnyAdminRole?(role?: AdminRole): Promise<boolean>;
  hasAdminRoleHistory?(userId: string, role: AdminRole): Promise<boolean>;
  grantAdminRole?(userId: string, role?: AdminRole): Promise<void>;
};

export type SettingsPutResult =
  | { ok: true; value: ProductSettings }
  | { ok: false; code: "conflict"; current: ProductSettings }
  | { ok: false; code: "not_found" };

export type AuthService = {
  authConfig(): { providers: readonly { id: AuthProviderId }[] };
  canIssueSessions(): boolean;
  authenticate(request: Request): Promise<Principal | null>;
  requestEmailOtp(email: string): Promise<AuthResult<{ accepted: true }>>;
  verifyEmailOtp(
    email: string,
    code: string,
    deviceId?: string,
  ): Promise<AuthResult<AuthenticatedSession>>;
  authorizeOAuth(
    input: OAuthAuthorizeInput,
  ): Promise<AuthResult<{ authorizationUrl: string; state: string }>>;
  exchangeOAuth(input: OAuthExchangeInput): Promise<AuthResult<AuthenticatedSession>>;
  refresh(
    refreshToken: string,
    deviceId?: string,
  ): Promise<AuthResult<{ tokens: SessionTokens; principal: Principal }>>;
  logout(refreshToken: string): Promise<void>;
  getProfile(principal: Principal): Promise<ProductProfile | undefined>;
  patchProfile(
    principal: Principal,
    patch: { displayName?: string | null; avatarUrl?: string | null },
  ): Promise<ProductProfile | undefined>;
  getSettings(principal: Principal): Promise<ProductSettings | undefined>;
  putSettings(principal: Principal, settings: ProductSettings): Promise<SettingsPutResult>;
  bootstrap(
    principal: Principal,
    input: BootstrapDeviceInput,
  ): Promise<AuthResult<BootstrapSession>>;
  listDevices(principal: Principal): Promise<ProductDevice[]>;
  revokeDevice(principal: Principal, deviceId: string): Promise<DeviceRevokeResult>;
  linkIdentity(
    principal: Principal,
    input: LinkIdentityInput,
  ): Promise<AuthResult<{ profile: ProductProfile }>>;
};

type IdentityRecord = {
  provider: IdentityProvider;
  providerSubject: string;
  email: string;
  accountId: string;
};

type AccountRecord = {
  id: string;
  subject: string;
  profileId: string;
};

type OtpRecord = {
  code: string;
  expiresAtMs: number;
};

type OAuthCodeRecord = {
  provider: OAuthProvider;
  redirectUri: string;
  challenge: string;
  state: string;
  identity: { email: string; providerSubject: string };
  expiresAtMs: number;
};

type RefreshRecord = {
  subject: string;
  expiresAtMs: number;
  // Bound at login so revoke can kill this device's session without logging out others.
  deviceId?: string;
};

const encoder = new TextEncoder();

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function createMemoryAuthService(options: MemoryAuthServiceOptions): AuthService {
  const now = options.now ?? (() => new Date());
  const generateOtp = options.generateOtp ?? randomOtp;
  const otpTtlSeconds = options.otpTtlSeconds ?? 600;
  const refreshTtlSeconds = options.refreshTtlSeconds ?? 60 * 60 * 24 * 30;
  const allowLocalIssuance = options.allowLocalIssuance ?? true;

  const accounts = new Map<string, AccountRecord>();
  const subjects = new Map<string, string>();
  const profiles = new Map<string, ProductProfile>();
  const identities = new Map<string, IdentityRecord>();
  const otps = new Map<string, OtpRecord>();
  const oauthCodes = new Map<string, OAuthCodeRecord>();
  const refreshTokens = new Map<string, RefreshRecord>();
  const devices = new Map<string, ProductDevice>();
  const settings = new Map<string, ProductSettings>();

  function currentIso(): string {
    return now().toISOString();
  }

  function principalFor(account: AccountRecord, email: string): Principal {
    return {
      subject: account.subject,
      profileId: account.profileId,
      accountId: account.id,
      role: "user",
      adminRoles: [],
      email,
    };
  }

  function getAccount(accountId: string): AccountRecord | undefined {
    return accounts.get(accountId);
  }

  function createAccount(email: string, subject = crypto.randomUUID()): AccountRecord {
    const timestamp = currentIso();
    const account: AccountRecord = {
      id: crypto.randomUUID(),
      subject,
      profileId: crypto.randomUUID(),
    };
    accounts.set(account.id, account);
    subjects.set(account.subject, account.id);
    profiles.set(account.profileId, {
      id: account.profileId,
      accountId: account.id,
      email,
      displayName: null,
      avatarUrl: null,
      createdAt: timestamp,
      updatedAt: timestamp,
      deletionPendingAt: null,
    });
    return account;
  }

  function identityKey(provider: IdentityProvider, providerSubject: string): string {
    return `${provider}:${providerSubject}`;
  }

  function accountForIdentity(
    provider: IdentityProvider,
    providerSubject: string,
    email: string,
  ): AccountRecord {
    const existing = identities.get(identityKey(provider, providerSubject));
    if (existing !== undefined) {
      const account = getAccount(existing.accountId);
      if (account !== undefined) {
        return account;
      }
    }
    const account = createAccount(email);
    identities.set(identityKey(provider, providerSubject), {
      provider,
      providerSubject,
      email,
      accountId: account.id,
    });
    return account;
  }

  function deviceKey(accountId: string, deviceId: string): string {
    return `${accountId}:${deviceId}`;
  }

  function dropRefreshTokens(subject: string, deviceId: string): void {
    for (const [token, record] of refreshTokens) {
      if (
        record.subject === subject &&
        (record.deviceId === deviceId || record.deviceId === undefined)
      ) {
        refreshTokens.delete(token);
      }
    }
  }

  // Claim login tokens that never became a listed device so they cannot outlive bootstrap.
  function bindBootstrapRefreshTokens(principal: Principal, deviceId: string): void {
    for (const record of refreshTokens.values()) {
      if (record.subject !== principal.subject) {
        continue;
      }
      if (record.deviceId === deviceId) {
        continue;
      }
      if (record.deviceId === undefined) {
        record.deviceId = deviceId;
        continue;
      }
      if (devices.get(deviceKey(principal.accountId, record.deviceId)) === undefined) {
        record.deviceId = deviceId;
      }
    }
  }

  function reactivateDevice(accountId: string, deviceId: string): void {
    const existing = devices.get(deviceKey(accountId, deviceId));
    if (existing?.revoked) {
      existing.revoked = false;
      existing.revokedAt = null;
      existing.lastSeenAt = currentIso();
    }
  }

  function isDeviceRevoked(accountId: string, deviceId: string): boolean {
    return devices.get(deviceKey(accountId, deviceId))?.revoked === true;
  }

  async function issueSession(
    account: AccountRecord,
    email: string,
    deviceId: string | undefined,
    mode: "login" | "refresh",
  ): Promise<AuthenticatedSession | undefined> {
    const profile = profiles.get(account.profileId);
    if (profile === undefined) {
      throw new Error("profile missing for account");
    }
    const expires = new Date(now().getTime() + (options.jwt.accessTokenTtlSeconds ?? 3600) * 1000);
    const accessToken = await signAccessToken({ sub: account.subject, email }, options.jwt, now());
    const refreshToken = randomToken();
    if (deviceId !== undefined) {
      if (mode === "login") {
        reactivateDevice(account.id, deviceId);
      } else if (isDeviceRevoked(account.id, deviceId)) {
        return undefined;
      }
    }
    refreshTokens.set(refreshToken, {
      subject: account.subject,
      expiresAtMs: now().getTime() + refreshTtlSeconds * 1000,
      ...(deviceId === undefined ? {} : { deviceId }),
    });
    return {
      tokens: {
        accessToken,
        refreshToken,
        expiresAt: expires.toISOString(),
        tokenType: "Bearer",
      },
      principal: principalFor(account, email),
      profile,
    };
  }

  async function loginSession(
    account: AccountRecord,
    email: string,
    deviceId?: string,
  ): Promise<AuthenticatedSession> {
    const session = await issueSession(account, email, deviceId, "login");
    if (session === undefined) {
      throw new Error("login session missing");
    }
    return session;
  }

  function principalFromSubject(subject: string, email: string): Principal {
    const accountId = subjects.get(subject);
    const account = accountId === undefined ? undefined : getAccount(accountId);
    if (account !== undefined) {
      const profile = profiles.get(account.profileId);
      return principalFor(account, profile?.email ?? email);
    }
    const created = createAccount(email, subject);
    return principalFor(created, email);
  }

  function profileForSubject(subject: string): ProductProfile | undefined {
    const accountId = subjects.get(subject);
    const account = accountId === undefined ? undefined : getAccount(accountId);
    if (account === undefined) {
      return undefined;
    }
    return profiles.get(account.profileId);
  }

  function ensureProfile(principal: Principal): ProductProfile {
    const existing = profiles.get(principal.profileId) ?? profileForSubject(principal.subject);
    if (existing !== undefined) {
      return existing;
    }
    const timestamp = currentIso();
    const account: AccountRecord = {
      id: principal.accountId,
      subject: principal.subject,
      profileId: principal.profileId,
    };
    accounts.set(account.id, account);
    subjects.set(account.subject, account.id);
    const profile: ProductProfile = {
      id: principal.profileId,
      accountId: principal.accountId,
      email: principal.email,
      displayName: null,
      avatarUrl: null,
      createdAt: timestamp,
      updatedAt: timestamp,
      deletionPendingAt: null,
    };
    profiles.set(profile.id, profile);
    return profile;
  }

  return {
    authConfig() {
      return { providers: AUTH_PROVIDERS };
    },

    canIssueSessions() {
      return allowLocalIssuance;
    },

    async authenticate(request) {
      const token = extractBearerToken(request.headers.get("authorization"));
      if (token === null) {
        return null;
      }
      const result = await validateAccessToken(token, options.jwt, now());
      if (!result.ok) {
        return null;
      }
      const principal = principalFromSubject(
        result.claims.sub,
        result.claims.email ?? `${result.claims.sub}@users.invalid`,
      );
      const deviceId = request.headers.get("X-Device-Id")?.trim() ?? "";
      if (deviceId !== "" && isDeviceRevoked(principal.accountId, deviceId)) {
        return null;
      }
      return principal;
    },

    requestEmailOtp(email) {
      if (!allowLocalIssuance) {
        return Promise.resolve({ ok: false as const, code: "not_ready" as const });
      }
      const normalized = normalizeEmail(email);
      otps.set(normalized, {
        code: generateOtp(),
        expiresAtMs: now().getTime() + otpTtlSeconds * 1000,
      });
      return Promise.resolve({ ok: true as const, value: { accepted: true as const } });
    },

    async verifyEmailOtp(email, code, deviceId) {
      if (!allowLocalIssuance) {
        return { ok: false, code: "not_ready" };
      }
      const normalized = normalizeEmail(email);
      const record = otps.get(normalized);
      if (record === undefined || record.expiresAtMs <= now().getTime() || record.code !== code) {
        return { ok: false, code: "invalid_otp" };
      }
      otps.delete(normalized);
      const account = accountForIdentity("email", normalized, normalized);
      return { ok: true, value: await loginSession(account, normalized, deviceId) };
    },

    authorizeOAuth(input) {
      if (!allowLocalIssuance) {
        return Promise.resolve({ ok: false as const, code: "not_ready" as const });
      }
      const identity = input.identity ?? {
        providerSubject: crypto.randomUUID(),
        email: `${input.provider}-${crypto.randomUUID()}@oauth.example.invalid`,
      };
      const code = randomToken();
      oauthCodes.set(code, {
        provider: input.provider,
        redirectUri: input.redirectUri,
        challenge: input.codeChallenge,
        state: input.state,
        identity: {
          email: normalizeEmail(identity.email),
          providerSubject: identity.providerSubject,
        },
        expiresAtMs: now().getTime() + 10 * 60 * 1000,
      });
      const authorizationUrl = new URL(`https://auth.example.invalid/oauth/${input.provider}`);
      authorizationUrl.searchParams.set("code", code);
      authorizationUrl.searchParams.set("state", input.state);
      authorizationUrl.searchParams.set("redirect_uri", input.redirectUri);
      return Promise.resolve({
        ok: true as const,
        value: { authorizationUrl: authorizationUrl.toString(), state: input.state },
      });
    },

    async exchangeOAuth(input) {
      if (!allowLocalIssuance) {
        return { ok: false, code: "not_ready" };
      }
      const record = oauthCodes.get(input.code);
      if (record === undefined || record.expiresAtMs <= now().getTime()) {
        return { ok: false, code: "invalid_oauth" };
      }
      if (
        record.provider !== input.provider ||
        record.redirectUri !== input.redirectUri ||
        (input.state !== undefined && input.state !== record.state)
      ) {
        return { ok: false, code: "invalid_oauth" };
      }
      const challenge = await pkceS256(input.codeVerifier);
      if (challenge !== record.challenge) {
        return { ok: false, code: "invalid_oauth" };
      }
      oauthCodes.delete(input.code);
      const account = accountForIdentity(
        input.provider,
        record.identity.providerSubject,
        record.identity.email,
      );
      return {
        ok: true,
        value: await loginSession(account, record.identity.email, input.deviceId),
      };
    },

    async refresh(refreshToken, deviceId) {
      const record = refreshTokens.get(refreshToken);
      if (record === undefined || record.expiresAtMs <= now().getTime()) {
        return { ok: false, code: "invalid_refresh" };
      }
      const accountId = subjects.get(record.subject);
      const account = accountId === undefined ? undefined : getAccount(accountId);
      const profile = account === undefined ? undefined : profiles.get(account.profileId);
      if (account === undefined || profile === undefined) {
        refreshTokens.delete(refreshToken);
        return { ok: false, code: "invalid_refresh" };
      }
      const boundDevice = deviceId ?? record.deviceId;
      if (record.deviceId !== undefined && deviceId !== undefined && deviceId !== record.deviceId) {
        return { ok: false, code: "invalid_refresh" };
      }
      if (boundDevice !== undefined) {
        const device = devices.get(deviceKey(account.id, boundDevice));
        if (device?.revoked) {
          refreshTokens.delete(refreshToken);
          return { ok: false, code: "invalid_refresh" };
        }
      }
      refreshTokens.delete(refreshToken);
      const session = await issueSession(account, profile.email, record.deviceId, "refresh");
      if (session === undefined) {
        return { ok: false, code: "invalid_refresh" };
      }
      return { ok: true, value: { tokens: session.tokens, principal: session.principal } };
    },

    logout(refreshToken) {
      refreshTokens.delete(refreshToken);
      return Promise.resolve();
    },

    getProfile(principal) {
      return Promise.resolve(
        profiles.get(principal.profileId) ?? profileForSubject(principal.subject),
      );
    },

    patchProfile(principal, patch) {
      const profile = ensureProfile(principal);
      if (patch.displayName !== undefined) {
        profile.displayName = patch.displayName;
      }
      if (patch.avatarUrl !== undefined) {
        profile.avatarUrl = patch.avatarUrl;
      }
      profile.updatedAt = currentIso();
      return Promise.resolve({ ...profile });
    },

    getSettings(principal) {
      const profile = ensureProfile(principal);
      const timestamp = currentIso();
      let userSettings = settings.get(profile.accountId);
      if (userSettings === undefined) {
        userSettings = {
          revision: 0,
          sourceLanguage: "en",
          targetLanguage: "en",
          readerLevel: "intermediate",
          playbackRate: 1,
          skipSeconds: 15,
          appearance: "system",
          updatedAt: timestamp,
        };
        settings.set(profile.accountId, userSettings);
      }
      return Promise.resolve({ ...userSettings });
    },

    async putSettings(principal, incoming) {
      const current = await this.getSettings(principal);
      if (current === undefined) {
        return { ok: false, code: "not_found" };
      }
      if (incoming.revision !== current.revision) {
        return { ok: false, code: "conflict", current };
      }
      const next: ProductSettings = {
        ...incoming,
        revision: current.revision + 1,
        updatedAt: currentIso(),
      };
      settings.set(principal.accountId, next);
      return { ok: true, value: { ...next } };
    },

    bootstrap(principal, input) {
      const profile = ensureProfile(principal);
      const timestamp = currentIso();
      const key = deviceKey(profile.accountId, input.deviceId);
      const existing = devices.get(key);
      if (existing?.revoked) {
        return Promise.resolve({ ok: false, code: "device_revoked" });
      }
      const device: ProductDevice = {
        id: input.deviceId,
        platform: input.platform,
        name: input.deviceName ?? null,
        appVersion: input.appVersion,
        createdAt: existing?.createdAt ?? timestamp,
        lastSeenAt: timestamp,
        revoked: false,
        revokedAt: null,
      };
      if (input.buildNumber !== undefined) {
        device.buildNumber = input.buildNumber;
      }
      devices.set(key, device);
      bindBootstrapRefreshTokens(principal, input.deviceId);
      let userSettings = settings.get(profile.accountId);
      if (userSettings === undefined) {
        userSettings = {
          revision: 0,
          sourceLanguage: "en",
          targetLanguage: "en",
          readerLevel: "intermediate",
          playbackRate: 1,
          skipSeconds: 15,
          appearance: "system",
          updatedAt: timestamp,
        };
        settings.set(profile.accountId, userSettings);
      }
      return Promise.resolve({
        ok: true,
        value: {
          profile,
          device,
          settings: userSettings,
          featureFlags: [],
          quotas: [],
          syncCursor: "0",
        },
      });
    },

    listDevices(principal) {
      const prefix = `${principal.accountId}:`;
      const listed: ProductDevice[] = [];
      for (const [key, device] of devices) {
        if (key.startsWith(prefix)) {
          listed.push({ ...device });
        }
      }
      listed.sort((left, right) => {
        const created = left.createdAt.localeCompare(right.createdAt);
        return created === 0 ? left.id.localeCompare(right.id) : created;
      });
      return Promise.resolve(listed);
    },

    revokeDevice(principal, deviceId) {
      const existing = devices.get(deviceKey(principal.accountId, deviceId));
      if (existing === undefined) {
        return Promise.resolve({ ok: false, code: "not_found" });
      }
      if (!existing.revoked) {
        existing.revoked = true;
        existing.revokedAt = currentIso();
      }
      dropRefreshTokens(principal.subject, deviceId);
      return Promise.resolve({ ok: true });
    },

    linkIdentity(principal, input) {
      const profile = profiles.get(principal.profileId);
      if (profile === undefined) {
        return Promise.resolve({ ok: false, code: "invalid_token" });
      }
      const key = identityKey(input.provider, input.providerSubject);
      const existing = identities.get(key);
      if (existing !== undefined && existing.accountId !== principal.accountId) {
        return Promise.resolve({ ok: false, code: "already_linked" });
      }
      if (existing === undefined) {
        identities.set(key, {
          provider: input.provider,
          providerSubject: input.providerSubject,
          email: normalizeEmail(input.email),
          accountId: principal.accountId,
        });
      }
      return Promise.resolve({ ok: true, value: { profile } });
    },
  };
}

function randomOtp(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return [...bytes].map((byte) => String(byte % 10)).join("");
}

function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toBase64Url(bytes);
}

async function pkceS256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(verifier));
  return toBase64Url(new Uint8Array(digest));
}
