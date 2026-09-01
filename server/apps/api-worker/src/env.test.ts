import { LOCAL_JWT_CONFIG, LOCAL_PASSWORDLESS_HMAC_SECRET } from "@audio-reader/auth";
import { describe, expect, it } from "vitest";
import {
  parseEnvironment,
  parseLocalDevOtp,
  resolveCacheHmacSecret,
  resolveHostedAuthConfig,
  resolveJwtSigningConfig,
  resolveOperatorWrappingSecret,
  resolvePasswordlessHmacSecret,
  resolveQwenConfig,
  resolveSupabaseRestConfig,
} from "./env";

describe("parseEnvironment", () => {
  it("preserves known environments", () => {
    expect(parseEnvironment("local")).toBe("local");
    expect(parseEnvironment("test")).toBe("test");
    expect(parseEnvironment("staging")).toBe("staging");
    expect(parseEnvironment("production")).toBe("production");
  });

  it("fails closed to production when the value is missing or unknown", () => {
    expect(parseEnvironment(undefined)).toBe("production");
    expect(parseEnvironment("")).toBe("production");
    expect(parseEnvironment("prod")).toBe("production");
    expect(parseEnvironment("Production")).toBe("production");
  });
});

describe("resolveJwtSigningConfig", () => {
  it("uses local defaults for local and test when no secret is set", () => {
    expect(resolveJwtSigningConfig({}, "local")).toEqual(LOCAL_JWT_CONFIG);
    expect(resolveJwtSigningConfig({}, "test")).toEqual(LOCAL_JWT_CONFIG);
  });

  it("fails closed in production without a JWT secret", () => {
    expect(resolveJwtSigningConfig({}, "production")).toBeUndefined();
    expect(resolveJwtSigningConfig({ SUPABASE_JWT_SECRET: "   " }, "staging")).toBeUndefined();
  });

  it("fails closed in staging and production when the secret is set but SUPABASE_URL is missing", () => {
    expect(
      resolveJwtSigningConfig({ SUPABASE_JWT_SECRET: "super-secret" }, "production"),
    ).toBeUndefined();
    expect(
      resolveJwtSigningConfig(
        { SUPABASE_JWT_SECRET: "super-secret", SUPABASE_URL: "   " },
        "staging",
      ),
    ).toBeUndefined();
  });

  it("does not use the local-dev issuer outside local and test", () => {
    const production = resolveJwtSigningConfig(
      {
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_JWT_SECRET: "super-secret",
      },
      "production",
    );
    expect(production?.issuer).toBe("https://example.supabase.co/auth/v1");
    expect(production?.issuer).not.toBe(LOCAL_JWT_CONFIG.issuer);
  });

  it("builds issuer and audience from Supabase env", () => {
    expect(
      resolveJwtSigningConfig(
        {
          SUPABASE_URL: "https://example.supabase.co/",
          SUPABASE_JWT_SECRET: "super-secret",
          SUPABASE_JWT_AUDIENCE: "authenticated",
        },
        "production",
      ),
    ).toMatchObject({
      issuer: "https://example.supabase.co/auth/v1",
      audience: "authenticated",
      secret: "super-secret",
      jwksUrl: "https://example.supabase.co/auth/v1/.well-known/jwks.json",
    });
  });
});

describe("resolveHostedAuthConfig", () => {
  it("is local/test only when issuance stays in-memory", () => {
    expect(
      resolveHostedAuthConfig(
        {
          SUPABASE_URL: "https://example.supabase.co",
          SUPABASE_ANON_KEY: "anon-key",
        },
        "local",
      ),
    ).toBeUndefined();
    expect(
      resolveHostedAuthConfig(
        {
          SUPABASE_URL: "https://example.supabase.co",
          SUPABASE_ANON_KEY: "anon-key",
        },
        "test",
      ),
    ).toBeUndefined();
  });

  it("requires both the project URL and anon key outside local and test", () => {
    expect(
      resolveHostedAuthConfig({ SUPABASE_URL: "https://example.supabase.co" }, "production"),
    ).toBeUndefined();
    expect(resolveHostedAuthConfig({ SUPABASE_ANON_KEY: "anon-key" }, "staging")).toBeUndefined();
    expect(
      resolveHostedAuthConfig(
        {
          SUPABASE_URL: "https://example.supabase.co/",
          SUPABASE_ANON_KEY: "anon-key",
        },
        "production",
      ),
    ).toEqual({ url: "https://example.supabase.co", anonKey: "anon-key" });
  });
});

describe("resolveSupabaseRestConfig", () => {
  it("requires both the project URL and service role key", () => {
    expect(
      resolveSupabaseRestConfig({ SUPABASE_URL: "https://example.supabase.co" }),
    ).toBeUndefined();
    expect(
      resolveSupabaseRestConfig({ SUPABASE_SERVICE_ROLE_KEY: "service-role" }),
    ).toBeUndefined();
    expect(
      resolveSupabaseRestConfig({
        SUPABASE_URL: "https://example.supabase.co/",
        SUPABASE_SERVICE_ROLE_KEY: "service-role",
      }),
    ).toEqual({ url: "https://example.supabase.co", serviceRoleKey: "service-role" });
    expect(
      resolveSupabaseRestConfig({
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SECRET_KEY: "secret-role",
      }),
    ).toEqual({ url: "https://example.supabase.co", serviceRoleKey: "secret-role" });
  });
});

describe("resolveOperatorWrappingSecret", () => {
  it("prefers OPERATOR_CONFIG_KEY then the cache HMAC secret", () => {
    expect(
      resolveOperatorWrappingSecret({
        OPERATOR_CONFIG_KEY: "operator",
        CACHE_HMAC_SECRET: "cache",
      }),
    ).toEqual({ secret: "operator", fromEnv: true, source: "operator_config_key" });
    expect(resolveOperatorWrappingSecret({ CACHE_HMAC_SECRET: "cache" })).toEqual({
      secret: "cache",
      fromEnv: true,
      source: "cache_hmac",
    });
    expect(resolveOperatorWrappingSecret({})).toMatchObject({
      fromEnv: false,
      source: "none",
    });
  });
});

describe("resolveQwenConfig", () => {
  it("is absent without an API key and keeps optional overrides exact", () => {
    expect(resolveQwenConfig({})).toBeUndefined();
    expect(resolveQwenConfig({ QWEN_API_KEY: "sk-test" })).toEqual({ apiKey: "sk-test" });
    expect(
      resolveQwenConfig({
        QWEN_API_KEY: "sk-test",
        QWEN_BASE_URL: "https://example.invalid/v1",
        QWEN_MODEL: "qwen-turbo",
      }),
    ).toEqual({
      apiKey: "sk-test",
      baseUrl: "https://example.invalid/v1",
      model: "qwen-turbo",
    });
  });
});

describe("resolvePasswordlessHmacSecret", () => {
  it("prefers PASSWORDLESS_HMAC_SECRET over CACHE_HMAC_SECRET", () => {
    expect(
      resolvePasswordlessHmacSecret({
        PASSWORDLESS_HMAC_SECRET: "dedicated",
        CACHE_HMAC_SECRET: "cache",
      }),
    ).toEqual({ secret: "dedicated", fromEnv: true });
  });

  it("falls back to CACHE_HMAC_SECRET when the dedicated secret is missing", () => {
    expect(resolvePasswordlessHmacSecret({ CACHE_HMAC_SECRET: "cache" })).toEqual({
      secret: "cache",
      fromEnv: true,
    });
  });

  it("uses the local-dev pepper when no env secret is set", () => {
    expect(resolvePasswordlessHmacSecret({})).toEqual({
      secret: LOCAL_PASSWORDLESS_HMAC_SECRET,
      fromEnv: false,
    });
  });
});

describe("resolveCacheHmacSecret", () => {
  it("prefers CACHE_HMAC_SECRET over the passwordless secret", () => {
    expect(
      resolveCacheHmacSecret({
        CACHE_HMAC_SECRET: "cache",
        PASSWORDLESS_HMAC_SECRET: "dedicated",
      }),
    ).toEqual({ secret: "cache", fromEnv: true });
  });

  it("falls back to PASSWORDLESS_HMAC_SECRET then the local-dev pepper", () => {
    expect(resolveCacheHmacSecret({ PASSWORDLESS_HMAC_SECRET: "dedicated" })).toEqual({
      secret: "dedicated",
      fromEnv: true,
    });
    expect(resolveCacheHmacSecret({})).toEqual({
      secret: LOCAL_PASSWORDLESS_HMAC_SECRET,
      fromEnv: false,
    });
  });
});

describe("parseLocalDevOtp", () => {
  it("returns a six-digit code in local and test", () => {
    expect(parseLocalDevOtp({ LOCAL_DEV_OTP: "123456" }, "local")).toBe("123456");
    expect(parseLocalDevOtp({ LOCAL_DEV_OTP: " 654321 " }, "test")).toBe("654321");
  });

  it("ignores LOCAL_DEV_OTP outside local and test", () => {
    expect(parseLocalDevOtp({ LOCAL_DEV_OTP: "123456" }, "staging")).toBeUndefined();
    expect(parseLocalDevOtp({ LOCAL_DEV_OTP: "123456" }, "production")).toBeUndefined();
  });

  it("rejects a non-digit local code", () => {
    expect(() => parseLocalDevOtp({ LOCAL_DEV_OTP: "abcdef" }, "local")).toThrow(/6-digit/);
  });
});
