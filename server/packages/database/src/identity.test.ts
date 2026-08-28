import { describe, expect, it } from "vitest";
import { createMemoryIdentityStore, createSupabaseIdentityStore } from "./identity";
import { createSupabaseRestClient, type RestFetch } from "./rest";

const USER_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const DEVICE_A = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
const DEVICE_B = "3fa85f64-5717-4562-b3fc-2c963f66afa7";

type RecordedCall = {
  url: string;
  method: string;
  body: unknown;
  authorization: string | undefined;
  prefer: string | undefined;
};

function jsonResponse(status: number, body: unknown): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

describe("memory identity store", () => {
  it("creates a durable profile per auth subject and does not mix users", async () => {
    const store = createMemoryIdentityStore({
      now: () => new Date("2026-08-27T12:00:00.000Z"),
    });
    const first = await store.ensureProfile({ userId: USER_A, email: "a@example.com" });
    const again = await store.ensureProfile({ userId: USER_A, email: "a@example.com" });
    const other = await store.ensureProfile({ userId: USER_B, email: "b@example.com" });
    expect(again.id).toBe(first.id);
    expect(again.accountId).toBe(USER_A);
    expect(other.id).not.toBe(first.id);
    expect(other.accountId).toBe(USER_B);
    expect(await store.getProfileByUserId(USER_A)).toEqual(first);
  });

  it("bootstraps, lists, and revokes only the caller's devices", async () => {
    const store = createMemoryIdentityStore();
    await store.ensureProfile({ userId: USER_A, email: "a@example.com" });
    await store.ensureProfile({ userId: USER_B, email: "b@example.com" });
    const alice = await store.bootstrapDevice(USER_A, {
      deviceId: DEVICE_A,
      platform: "macos",
      appVersion: "1.0.0",
      deviceName: "Alice Mac",
    });
    const bob = await store.bootstrapDevice(USER_B, {
      deviceId: DEVICE_B,
      platform: "ios",
      appVersion: "1.0.0",
    });
    expect(alice.ok).toBe(true);
    expect(bob.ok).toBe(true);
    if (!alice.ok || !bob.ok) {
      return;
    }
    expect(alice.device.name).toBe("Alice Mac");
    expect(alice.settings.revision).toBe(0);
    expect((await store.listDevices(USER_A)).map((device) => device.id)).toEqual([DEVICE_A]);
    expect(await store.revokeDevice(USER_A, DEVICE_B)).toEqual({ ok: false, code: "not_found" });
    expect(await store.revokeDevice(USER_A, DEVICE_A)).toEqual({ ok: true });
    expect(await store.isDeviceRevoked(USER_A, DEVICE_A)).toBe(true);
    expect(await store.isDeviceRevoked(USER_B, DEVICE_B)).toBe(false);
    expect(await store.hasActiveDevice(USER_A, DEVICE_A)).toBe(false);
    expect(await store.hasActiveDevice(USER_B, DEVICE_B)).toBe(true);
    expect(await store.hasActiveDevice(USER_A, DEVICE_B)).toBe(false);
    expect(
      await store.bootstrapDevice(USER_A, {
        deviceId: DEVICE_A,
        platform: "macos",
        appVersion: "1.0.0",
      }),
    ).toEqual({ ok: false, code: "device_revoked" });
  });

  it("rejects stale settings replacements", async () => {
    const store = createMemoryIdentityStore();
    await store.ensureProfile({ userId: USER_A, email: "a@example.com" });
    const current = await store.getSettings(USER_A);
    const first = await store.putSettings(USER_A, {
      ...current,
      targetLanguage: "zh",
    });
    expect(first.ok).toBe(true);
    if (!first.ok) {
      return;
    }
    expect(first.value.revision).toBe(1);
    expect(first.value.targetLanguage).toBe("zh");
    const stale = await store.putSettings(USER_A, current);
    expect(stale.ok).toBe(false);
    if (stale.ok) {
      return;
    }
    expect(stale.code).toBe("conflict");
    expect(stale.current.revision).toBe(1);
  });
});

describe("supabase identity store", () => {
  it("loads and inserts profiles through PostgREST with the service role", async () => {
    const calls: RecordedCall[] = [];
    const fetchImpl: RestFetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const headers = new Headers(init?.headers);
      calls.push({
        url,
        method: init?.method ?? "GET",
        body: typeof init?.body === "string" ? (JSON.parse(init.body) as unknown) : null,
        authorization: headers.get("authorization") ?? undefined,
        prefer: headers.get("prefer") ?? undefined,
      });
      if (url.includes("/profiles") && (init?.method ?? "GET") === "GET") {
        return Promise.resolve(jsonResponse(200, []));
      }
      if (url.includes("/profiles") && init?.method === "POST") {
        return Promise.resolve(
          jsonResponse(201, [
            {
              id: "11111111-1111-4111-8111-111111111111",
              user_id: USER_A,
              email: "a@example.com",
              display_name: null,
              avatar_url: null,
              created_at: "2026-08-27T12:00:00.000Z",
              updated_at: "2026-08-27T12:00:00.000Z",
              deletion_pending_at: null,
            },
          ]),
        );
      }
      if (url.includes("/user_settings") && (init?.method ?? "GET") === "GET") {
        return Promise.resolve(jsonResponse(200, []));
      }
      if (url.includes("/user_settings") && init?.method === "POST") {
        return Promise.resolve(
          jsonResponse(201, [
            {
              user_id: USER_A,
              source_language: "en",
              target_language: "en",
              reader_level: "intermediate",
              playback_rate: 1,
              skip_seconds: 15,
              appearance: "system",
              server_version: 0,
              updated_at: "2026-08-27T12:00:00.000Z",
            },
          ]),
        );
      }
      return Promise.resolve(jsonResponse(500, { message: "unexpected" }));
    };
    const rest = createSupabaseRestClient({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role-key",
      fetch: fetchImpl,
    });
    const store = createSupabaseIdentityStore(rest);
    const profile = await store.ensureProfile({ userId: USER_A, email: "a@example.com" });
    expect(profile).toMatchObject({
      id: "11111111-1111-4111-8111-111111111111",
      accountId: USER_A,
      email: "a@example.com",
    });
    expect(calls[0]?.authorization).toBe("Bearer service-role-key");
    expect(calls.some((call) => call.url.includes("/rest/v1/profiles"))).toBe(true);
    expect(calls.some((call) => call.url.includes("/rest/v1/user_settings"))).toBe(true);
  });

  it("does not treat a PostgREST error body as an admin role", async () => {
    const fetchImpl: RestFetch = () =>
      Promise.resolve(jsonResponse(401, { message: "JWT expired", code: "PGRST301" }));
    const rest = createSupabaseRestClient({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role-key",
      fetch: fetchImpl,
    });
    const store = createSupabaseIdentityStore(rest);
    await expect(store.hasAdminRole(USER_A)).resolves.toBe(false);
  });

  it("treats device lookup failures as revoked", async () => {
    const fetchImpl: RestFetch = () =>
      Promise.resolve(jsonResponse(500, { message: "upstream unavailable" }));
    const rest = createSupabaseRestClient({
      url: "https://example.supabase.co",
      serviceRoleKey: "service-role-key",
      fetch: fetchImpl,
    });
    const store = createSupabaseIdentityStore(rest);
    await expect(store.isDeviceRevoked(USER_A, DEVICE_A)).resolves.toBe(true);
  });
});
