import { LOCAL_JWT_CONFIG, type JwtSigningConfig } from "@audio-reader/auth";

export type AppEnvironment = "local" | "test" | "staging" | "production";

export type WorkerEnv = {
  ENVIRONMENT?: string;
  APP_VERSION?: string;
  CORS_ALLOWED_ORIGINS?: string;
  ADMIN_ORIGIN?: string;
  MAX_BODY_BYTES?: string;
  SUPABASE_URL?: string;
  SUPABASE_JWT_SECRET?: string;
  SUPABASE_JWT_AUDIENCE?: string;
  TURNSTILE_SECRET_KEY?: string;
};

export function parseEnvironment(value: string | undefined): AppEnvironment {
  if (value === "local" || value === "test" || value === "staging" || value === "production") {
    return value;
  }
  return "production";
}

export function parseOriginList(value: string | undefined): string[] {
  if (value === undefined || value.trim() === "") {
    return [];
  }
  return value
    .split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin !== "");
}

export function resolveJwtSigningConfig(
  env: WorkerEnv,
  environment: AppEnvironment,
): JwtSigningConfig | undefined {
  const secret = env.SUPABASE_JWT_SECRET?.trim() ?? "";
  const url = env.SUPABASE_URL?.trim() ?? "";
  const audience = env.SUPABASE_JWT_AUDIENCE?.trim() || "authenticated";
  const local = environment === "local" || environment === "test";
  if (secret !== "" && url !== "") {
    return {
      issuer: `${url.replace(/\/$/, "")}/auth/v1`,
      audience,
      secret,
      accessTokenTtlSeconds: 3600,
      clockSkewSeconds: 0,
    };
  }
  if (local && secret === "") {
    return LOCAL_JWT_CONFIG;
  }
  if (local && secret !== "") {
    return {
      ...LOCAL_JWT_CONFIG,
      audience,
      secret,
    };
  }
  return undefined;
}

export function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (value === undefined || value.trim() === "") {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return parsed;
}
