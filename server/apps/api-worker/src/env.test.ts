import { LOCAL_JWT_CONFIG } from "@audio-reader/auth";
import { describe, expect, it } from "vitest";
import { parseEnvironment, resolveJwtSigningConfig } from "./env";

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
    });
  });
});
