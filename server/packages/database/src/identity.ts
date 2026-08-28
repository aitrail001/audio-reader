import { restRow, restRows, type RestClient } from "./rest";

export type IdentityAccountStatus = "active" | "suspended" | "deletion_pending" | "deleted";

export type IdentityProfile = {
  id: string;
  accountId: string;
  email: string;
  displayName: string | null;
  avatarUrl: string | null;
  status: IdentityAccountStatus;
  createdAt: string;
  updatedAt: string;
  deletionPendingAt: string | null;
};

export type IdentityDevice = {
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

export type IdentitySettings = {
  revision: number;
  sourceLanguage: string;
  targetLanguage: string;
  readerLevel: "beginner" | "elementary" | "intermediate" | "upper_intermediate" | "advanced";
  playbackRate: number;
  skipSeconds: number;
  appearance: "system" | "light" | "dark";
  updatedAt: string;
};

export type IdentityBootstrapInput = {
  deviceId: string;
  platform: "macos" | "ios" | "ipados";
  deviceName?: string | null;
  appVersion: string;
  buildNumber?: string;
  locale?: string;
  timeZone?: string;
};

export type IdentityEnsureInput = {
  userId: string;
  email: string;
  displayName?: string | null;
  avatarUrl?: string | null;
};

export type IdentityProfilePatch = {
  displayName?: string | null;
  avatarUrl?: string | null;
};

export type IdentityBootstrapResult =
  | {
      ok: true;
      profile: IdentityProfile;
      device: IdentityDevice;
      settings: IdentitySettings;
      syncCursor: string;
    }
  | { ok: false; code: "device_revoked" };

export type IdentitySettingsPutResult =
  | { ok: true; value: IdentitySettings }
  | { ok: false; code: "conflict"; current: IdentitySettings };

export type IdentityStore = {
  ensureProfile(input: IdentityEnsureInput): Promise<IdentityProfile>;
  getProfileByUserId(userId: string): Promise<IdentityProfile | undefined>;
  patchProfile(userId: string, patch: IdentityProfilePatch): Promise<IdentityProfile | undefined>;
  getSettings(userId: string): Promise<IdentitySettings>;
  putSettings(userId: string, settings: IdentitySettings): Promise<IdentitySettingsPutResult>;
  bootstrapDevice(userId: string, input: IdentityBootstrapInput): Promise<IdentityBootstrapResult>;
  listDevices(userId: string): Promise<IdentityDevice[]>;
  revokeDevice(
    userId: string,
    deviceId: string,
  ): Promise<{ ok: true } | { ok: false; code: "not_found" }>;
  isDeviceRevoked(userId: string, deviceId: string): Promise<boolean>;
  // True only for a device this account registered and has not revoked.
  hasActiveDevice(userId: string, deviceId: string): Promise<boolean>;
  listProfiles(): Promise<IdentityProfile[]>;
  setAccountStatus(
    userId: string,
    status: IdentityAccountStatus,
  ): Promise<IdentityProfile | undefined>;
  hasAdminRole(userId: string): Promise<boolean>;
  // True when any unrevoked admin_roles row exists. Used so bootstrap email
  // grants at most the first operator and never re-grants after a revoke.
  hasAnyAdminRole(): Promise<boolean>;
  grantAdminRole(userId: string): Promise<void>;
  revokeAllDevices(userId: string): Promise<void>;
  seedActiveDevice?(userId: string, deviceId: string): void;
};

export function defaultIdentitySettings(nowIso: string): IdentitySettings {
  return {
    revision: 0,
    sourceLanguage: "en",
    targetLanguage: "en",
    readerLevel: "intermediate",
    playbackRate: 1,
    skipSeconds: 15,
    appearance: "system",
    updatedAt: nowIso,
  };
}

export function createMemoryIdentityStore(options: { now?: () => Date } = {}): IdentityStore {
  const now = options.now ?? (() => new Date());
  const profiles = new Map<string, IdentityProfile>();
  const devices = new Map<string, IdentityDevice[]>();
  const settings = new Map<string, IdentitySettings>();
  const admins = new Set<string>();

  function currentIso(): string {
    return now().toISOString();
  }

  function cloneProfile(profile: IdentityProfile): IdentityProfile {
    return { ...profile };
  }

  function cloneDevice(device: IdentityDevice): IdentityDevice {
    return { ...device };
  }

  function cloneSettings(value: IdentitySettings): IdentitySettings {
    return { ...value };
  }

  function ensureSettings(userId: string): IdentitySettings {
    const existing = settings.get(userId);
    if (existing !== undefined) {
      return cloneSettings(existing);
    }
    const created = defaultIdentitySettings(currentIso());
    settings.set(userId, created);
    return cloneSettings(created);
  }

  return {
    ensureProfile(input) {
      const existing = profiles.get(input.userId);
      const timestamp = currentIso();
      if (existing !== undefined) {
        if (existing.email !== input.email) {
          existing.email = input.email;
          existing.updatedAt = timestamp;
        }
        ensureSettings(input.userId);
        return Promise.resolve(cloneProfile(existing));
      }
      const profile: IdentityProfile = {
        id: crypto.randomUUID(),
        accountId: input.userId,
        email: input.email,
        displayName: input.displayName ?? null,
        avatarUrl: input.avatarUrl ?? null,
        status: "active",
        createdAt: timestamp,
        updatedAt: timestamp,
        deletionPendingAt: null,
      };
      profiles.set(input.userId, profile);
      ensureSettings(input.userId);
      return Promise.resolve(cloneProfile(profile));
    },

    getProfileByUserId(userId) {
      const existing = profiles.get(userId);
      return Promise.resolve(existing === undefined ? undefined : cloneProfile(existing));
    },

    patchProfile(userId, patch) {
      const existing = profiles.get(userId);
      if (existing === undefined) {
        return Promise.resolve(undefined);
      }
      if (patch.displayName !== undefined) {
        existing.displayName = patch.displayName;
      }
      if (patch.avatarUrl !== undefined) {
        existing.avatarUrl = patch.avatarUrl;
      }
      existing.updatedAt = currentIso();
      return Promise.resolve(cloneProfile(existing));
    },

    getSettings(userId) {
      return Promise.resolve(ensureSettings(userId));
    },

    putSettings(userId, incoming) {
      const current = ensureSettings(userId);
      if (incoming.revision !== current.revision) {
        return Promise.resolve({ ok: false, code: "conflict", current });
      }
      const next: IdentitySettings = {
        ...incoming,
        revision: current.revision + 1,
        updatedAt: currentIso(),
      };
      settings.set(userId, next);
      return Promise.resolve({ ok: true, value: cloneSettings(next) });
    },

    async bootstrapDevice(userId, input) {
      const profile = await this.ensureProfile({
        userId,
        email: profiles.get(userId)?.email ?? `${userId}@users.invalid`,
      });
      const listed = devices.get(userId) ?? [];
      const existing = listed.find((device) => device.id === input.deviceId);
      if (existing?.revoked) {
        return { ok: false, code: "device_revoked" };
      }
      const timestamp = currentIso();
      const device: IdentityDevice = {
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
      const next = listed.filter((item) => item.id !== input.deviceId);
      next.push(device);
      devices.set(userId, next);
      return {
        ok: true,
        profile,
        device: cloneDevice(device),
        settings: ensureSettings(userId),
        syncCursor: "0",
      };
    },

    listDevices(userId) {
      const listed = (devices.get(userId) ?? []).map(cloneDevice);
      listed.sort((left, right) => {
        const created = left.createdAt.localeCompare(right.createdAt);
        return created === 0 ? left.id.localeCompare(right.id) : created;
      });
      return Promise.resolve(listed);
    },

    revokeDevice(userId, deviceId) {
      const listed = devices.get(userId);
      const existing = listed?.find((device) => device.id === deviceId);
      if (existing === undefined) {
        return Promise.resolve({ ok: false, code: "not_found" });
      }
      if (!existing.revoked) {
        existing.revoked = true;
        existing.revokedAt = currentIso();
      }
      return Promise.resolve({ ok: true });
    },

    isDeviceRevoked(userId, deviceId) {
      const existing = devices.get(userId)?.find((device) => device.id === deviceId);
      return Promise.resolve(existing?.revoked === true);
    },

    hasActiveDevice(userId, deviceId) {
      const existing = devices.get(userId)?.find((device) => device.id === deviceId);
      return Promise.resolve(existing !== undefined && !existing.revoked);
    },

    seedActiveDevice(userId, deviceId) {
      const timestamp = currentIso();
      if (!profiles.has(userId)) {
        profiles.set(userId, {
          id: crypto.randomUUID(),
          accountId: userId,
          email: `${userId}@users.invalid`,
          displayName: null,
          avatarUrl: null,
          status: "active",
          createdAt: timestamp,
          updatedAt: timestamp,
          deletionPendingAt: null,
        });
      }
      const listed = devices.get(userId) ?? [];
      if (listed.some((device) => device.id === deviceId)) {
        return;
      }
      listed.push({
        id: deviceId,
        platform: "macos",
        name: null,
        appVersion: "test",
        createdAt: timestamp,
        lastSeenAt: timestamp,
        revoked: false,
        revokedAt: null,
      });
      devices.set(userId, listed);
    },

    listProfiles() {
      return Promise.resolve([...profiles.values()].map(cloneProfile));
    },

    setAccountStatus(userId, status) {
      const existing = profiles.get(userId);
      if (existing === undefined) {
        return Promise.resolve(undefined);
      }
      existing.status = status;
      existing.updatedAt = currentIso();
      if (status === "deletion_pending" || status === "deleted") {
        existing.deletionPendingAt = existing.updatedAt;
      }
      return Promise.resolve(cloneProfile(existing));
    },

    hasAdminRole(userId) {
      return Promise.resolve(admins.has(userId));
    },

    hasAnyAdminRole() {
      return Promise.resolve(admins.size > 0);
    },

    grantAdminRole(userId) {
      admins.add(userId);
      return Promise.resolve();
    },

    revokeAllDevices(userId) {
      const list = devices.get(userId) ?? [];
      const timestamp = currentIso();
      for (const device of list) {
        device.revoked = true;
        device.revokedAt = timestamp;
      }
      return Promise.resolve();
    },
  };
}

export function createSupabaseIdentityStore(rest: RestClient): IdentityStore {
  async function selectProfile(userId: string): Promise<IdentityProfile | undefined> {
    const response = await rest.request({
      method: "GET",
      path: "/profiles",
      query: { user_id: `eq.${userId}`, select: "*", limit: "1" },
    });
    if (response.status >= 400 || response.status === 0) {
      return undefined;
    }
    const row = restRow(response.body);
    return row === undefined ? undefined : profileFromRow(row);
  }

  async function insertProfile(input: IdentityEnsureInput): Promise<IdentityProfile | undefined> {
    const response = await rest.request({
      method: "POST",
      path: "/profiles",
      prefer: "return=representation",
      body: {
        user_id: input.userId,
        email: input.email,
        display_name: input.displayName ?? null,
        avatar_url: input.avatarUrl ?? null,
        account_status: "active",
      },
    });
    if (response.status === 409) {
      return selectProfile(input.userId);
    }
    if (response.status >= 400 || response.status === 0) {
      return undefined;
    }
    const row = restRow(response.body);
    return row === undefined ? undefined : profileFromRow(row);
  }

  async function selectSettings(userId: string): Promise<IdentitySettings | undefined> {
    const response = await rest.request({
      method: "GET",
      path: "/user_settings",
      query: { user_id: `eq.${userId}`, select: "*", limit: "1" },
    });
    if (response.status >= 400 || response.status === 0) {
      return undefined;
    }
    const row = restRow(response.body);
    return row === undefined ? undefined : settingsFromRow(row);
  }

  async function insertSettings(userId: string): Promise<IdentitySettings> {
    const defaults = defaultIdentitySettings(new Date().toISOString());
    const response = await rest.request({
      method: "POST",
      path: "/user_settings",
      prefer: "return=representation",
      body: {
        user_id: userId,
        source_language: defaults.sourceLanguage,
        target_language: defaults.targetLanguage,
        reader_level: defaults.readerLevel,
        playback_rate: defaults.playbackRate,
        skip_seconds: defaults.skipSeconds,
        appearance: defaults.appearance,
        server_version: defaults.revision,
      },
    });
    if (response.status === 409) {
      const existing = await selectSettings(userId);
      if (existing !== undefined) {
        return existing;
      }
    }
    const row = restRow(response.body);
    return row === undefined ? defaults : settingsFromRow(row);
  }

  async function ensureSettings(userId: string): Promise<IdentitySettings> {
    const existing = await selectSettings(userId);
    if (existing !== undefined) {
      return existing;
    }
    return insertSettings(userId);
  }

  async function selectDevices(userId: string): Promise<IdentityDevice[]> {
    const response = await rest.request({
      method: "GET",
      path: "/devices",
      query: {
        user_id: `eq.${userId}`,
        select: "*",
        order: "created_at.asc,id.asc",
      },
    });
    if (response.status >= 400 || response.status === 0) {
      return [];
    }
    return restRows(response.body).map(deviceFromRow);
  }

  return {
    async ensureProfile(input) {
      const existing = await selectProfile(input.userId);
      if (existing !== undefined) {
        if (existing.email !== input.email) {
          await rest.request({
            method: "PATCH",
            path: "/profiles",
            query: { user_id: `eq.${input.userId}` },
            prefer: "return=minimal",
            body: { email: input.email, updated_at: new Date().toISOString() },
          });
          existing.email = input.email;
          existing.updatedAt = new Date().toISOString();
        }
        await ensureSettings(input.userId);
        return existing;
      }
      const created = await insertProfile(input);
      if (created === undefined) {
        throw new Error("failed to persist profile");
      }
      await ensureSettings(input.userId);
      return created;
    },

    getProfileByUserId(userId) {
      return selectProfile(userId);
    },

    async patchProfile(userId, patch) {
      const body: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (patch.displayName !== undefined) {
        body.display_name = patch.displayName;
      }
      if (patch.avatarUrl !== undefined) {
        body.avatar_url = patch.avatarUrl;
      }
      const response = await rest.request({
        method: "PATCH",
        path: "/profiles",
        query: { user_id: `eq.${userId}` },
        prefer: "return=representation",
        body,
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : profileFromRow(row);
    },

    getSettings(userId) {
      return ensureSettings(userId);
    },

    async putSettings(userId, incoming) {
      const current = await ensureSettings(userId);
      if (incoming.revision !== current.revision) {
        return { ok: false, code: "conflict", current };
      }
      const response = await rest.request({
        method: "PATCH",
        path: "/user_settings",
        query: { user_id: `eq.${userId}`, server_version: `eq.${String(current.revision)}` },
        prefer: "return=representation",
        body: {
          source_language: incoming.sourceLanguage,
          target_language: incoming.targetLanguage,
          reader_level: incoming.readerLevel,
          playback_rate: incoming.playbackRate,
          skip_seconds: incoming.skipSeconds,
          appearance: incoming.appearance,
          server_version: current.revision + 1,
          updated_at: new Date().toISOString(),
        },
      });
      const row = restRow(response.body);
      if (row === undefined) {
        const latest = await ensureSettings(userId);
        return { ok: false, code: "conflict", current: latest };
      }
      return { ok: true, value: settingsFromRow(row) };
    },

    async bootstrapDevice(userId, input) {
      const profile = await this.ensureProfile({
        userId,
        email: (await selectProfile(userId))?.email ?? `${userId}@users.invalid`,
      });
      const existingList = await selectDevices(userId);
      const existing = existingList.find((device) => device.id === input.deviceId);
      if (existing?.revoked) {
        return { ok: false, code: "device_revoked" };
      }
      const timestamp = new Date().toISOString();
      const body: Record<string, unknown> = {
        id: input.deviceId,
        user_id: userId,
        platform: input.platform,
        name: input.deviceName ?? null,
        app_version: input.appVersion,
        last_seen_at: timestamp,
        revoked: false,
        revoked_at: null,
        updated_at: timestamp,
      };
      if (input.buildNumber !== undefined) {
        body.build_number = input.buildNumber;
      }
      const response = await rest.request({
        method: "POST",
        path: "/devices?on_conflict=user_id,id",
        prefer: "resolution=merge-duplicates,return=representation",
        body,
      });
      const row = restRow(response.body);
      const device = row === undefined ? existing : deviceFromRow(row);
      if (device === undefined) {
        throw new Error("failed to persist device");
      }
      return {
        ok: true,
        profile,
        device,
        settings: await ensureSettings(userId),
        syncCursor: "0",
      };
    },

    async listDevices(userId) {
      return selectDevices(userId);
    },

    async revokeDevice(userId, deviceId) {
      const response = await rest.request({
        method: "PATCH",
        path: "/devices",
        query: { user_id: `eq.${userId}`, id: `eq.${deviceId}` },
        prefer: "return=representation",
        body: {
          revoked: true,
          revoked_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
      });
      const row = restRow(response.body);
      if (row === undefined) {
        return { ok: false, code: "not_found" };
      }
      return { ok: true };
    },

    async isDeviceRevoked(userId, deviceId) {
      const response = await rest.request({
        method: "GET",
        path: "/devices",
        query: {
          user_id: `eq.${userId}`,
          id: `eq.${deviceId}`,
          select: "revoked",
          limit: "1",
        },
      });
      // Store errors must not look like "not revoked" — product auth fails closed.
      if (!isRestOk(response.status)) {
        return true;
      }
      const row = restRow(response.body);
      if (row !== undefined && !isDeviceRevocationRow(row)) {
        return true;
      }
      return row?.revoked === true;
    },

    async hasActiveDevice(userId, deviceId) {
      const response = await rest.request({
        method: "GET",
        path: "/devices",
        query: {
          user_id: `eq.${userId}`,
          id: `eq.${deviceId}`,
          select: "revoked",
          limit: "1",
        },
      });
      if (!isRestOk(response.status)) {
        return false;
      }
      const row = restRow(response.body);
      return isDeviceRevocationRow(row ?? {}) && row?.revoked === false;
    },

    async listProfiles() {
      const response = await rest.request({
        method: "GET",
        path: "/profiles",
        query: { select: "*", order: "created_at.asc" },
      });
      if (response.status >= 400 || response.status === 0) {
        return [];
      }
      return restRows(response.body).map(profileFromRow);
    },

    async setAccountStatus(userId, status) {
      const response = await rest.request({
        method: "PATCH",
        path: "/profiles",
        query: { user_id: `eq.${userId}` },
        prefer: "return=representation",
        body: {
          account_status: status,
          updated_at: new Date().toISOString(),
          deletion_pending_at:
            status === "deletion_pending" || status === "deleted" ? new Date().toISOString() : null,
        },
      });
      const row = restRow(response.body);
      return row === undefined ? undefined : profileFromRow(row);
    },

    async hasAdminRole(userId) {
      const response = await rest.request({
        method: "GET",
        path: "/admin_roles",
        query: {
          user_id: `eq.${userId}`,
          revoked_at: "is.null",
          select: "id",
          limit: "1",
        },
      });
      // 4xx/5xx bodies are JSON objects; never treat them as a role row.
      if (!isRestOk(response.status)) {
        return false;
      }
      return isAdminRoleRow(restRow(response.body));
    },

    async hasAnyAdminRole() {
      const response = await rest.request({
        method: "GET",
        path: "/admin_roles",
        query: {
          revoked_at: "is.null",
          select: "id",
          limit: "1",
        },
      });
      if (!isRestOk(response.status)) {
        return true;
      }
      return isAdminRoleRow(restRow(response.body));
    },

    async grantAdminRole(userId) {
      const response = await rest.request({
        method: "POST",
        path: "/admin_roles",
        prefer: "return=minimal",
        body: { user_id: userId, role: "operator" },
      });
      if (isRestOk(response.status) || response.status === 409) {
        return;
      }
      throw new Error("failed to persist admin role");
    },

    async revokeAllDevices(userId) {
      await rest.request({
        method: "PATCH",
        path: "/devices",
        query: { user_id: `eq.${userId}`, revoked: "eq.false" },
        prefer: "return=minimal",
        body: {
          revoked: true,
          revoked_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
      });
    },
  };
}

export function createUnavailableIdentityStore(): IdentityStore {
  return {
    ensureProfile() {
      return Promise.reject(new Error("database unavailable"));
    },
    getProfileByUserId() {
      return Promise.resolve(undefined);
    },
    patchProfile() {
      return Promise.resolve(undefined);
    },
    getSettings() {
      return Promise.reject(new Error("database unavailable"));
    },
    putSettings() {
      return Promise.reject(new Error("database unavailable"));
    },
    bootstrapDevice() {
      return Promise.resolve({ ok: false, code: "device_revoked" });
    },
    listDevices() {
      return Promise.resolve([]);
    },
    revokeDevice() {
      return Promise.resolve({ ok: false, code: "not_found" });
    },
    isDeviceRevoked() {
      return Promise.resolve(true);
    },
    hasActiveDevice() {
      return Promise.resolve(false);
    },
    listProfiles() {
      return Promise.resolve([]);
    },
    setAccountStatus() {
      return Promise.resolve(undefined);
    },
    hasAdminRole() {
      return Promise.resolve(false);
    },
    hasAnyAdminRole() {
      return Promise.resolve(true);
    },
    grantAdminRole() {
      return Promise.reject(new Error("database unavailable"));
    },
    revokeAllDevices() {
      return Promise.resolve();
    },
  };
}

function profileFromRow(row: Record<string, unknown>): IdentityProfile {
  const status = row.account_status;
  return {
    id: requiredString(row.id, row.user_id),
    accountId: requiredString(row.user_id, row.id),
    email: optionalString(row.email) ?? "",
    displayName: nullableString(row.display_name),
    avatarUrl: nullableString(row.avatar_url),
    status:
      status === "suspended" || status === "deletion_pending" || status === "deleted"
        ? status
        : "active",
    createdAt: requiredString(row.created_at, new Date().toISOString()),
    updatedAt: requiredString(row.updated_at, new Date().toISOString()),
    deletionPendingAt: nullableString(row.deletion_pending_at),
  };
}

function deviceFromRow(row: Record<string, unknown>): IdentityDevice {
  const platform = row.platform;
  const device: IdentityDevice = {
    id: requiredString(row.id),
    platform: platform === "ios" || platform === "ipados" ? platform : "macos",
    name: nullableString(row.name),
    appVersion: requiredString(row.app_version, "0"),
    createdAt: requiredString(row.created_at, new Date().toISOString()),
    lastSeenAt: requiredString(row.last_seen_at, new Date().toISOString()),
    revoked: row.revoked === true,
    revokedAt: nullableString(row.revoked_at),
  };
  const buildNumber = optionalString(row.build_number);
  if (buildNumber !== undefined) {
    device.buildNumber = buildNumber;
  }
  return device;
}

function settingsFromRow(row: Record<string, unknown>): IdentitySettings {
  const level = row.reader_level;
  const appearance = row.appearance;
  return {
    revision: numericValue(row.server_version, 0),
    sourceLanguage: optionalString(row.source_language) ?? "en",
    targetLanguage: optionalString(row.target_language) ?? "en",
    readerLevel:
      level === "beginner" ||
      level === "elementary" ||
      level === "intermediate" ||
      level === "upper_intermediate" ||
      level === "advanced"
        ? level
        : "intermediate",
    playbackRate: numericValue(row.playback_rate, 1),
    skipSeconds: numericValue(row.skip_seconds, 15),
    appearance: appearance === "light" || appearance === "dark" ? appearance : "system",
    updatedAt: requiredString(row.updated_at, new Date().toISOString()),
  };
}

function requiredString(value: unknown, fallback?: unknown): string {
  if (typeof value === "string" && value !== "") {
    return value;
  }
  if (typeof fallback === "string" && fallback !== "") {
    return fallback;
  }
  return "";
}

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed === "" ? undefined : trimmed;
}

function nullableString(value: unknown): string | null {
  return optionalString(value) ?? null;
}

function isRestOk(status: number): boolean {
  return status >= 200 && status < 300;
}

function isAdminRoleRow(row: Record<string, unknown> | undefined): boolean {
  if (row === undefined) {
    return false;
  }
  return (
    (typeof row.id === "string" && row.id.trim() !== "") ||
    (typeof row.user_id === "string" && row.user_id.trim() !== "")
  );
}

function isDeviceRevocationRow(row: Record<string, unknown>): boolean {
  return typeof row.revoked === "boolean";
}

function numericValue(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return fallback;
}
