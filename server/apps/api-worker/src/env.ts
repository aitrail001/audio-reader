import {
  LOCAL_JWT_CONFIG,
  LOCAL_PASSWORDLESS_HMAC_SECRET,
  type JwtSigningConfig,
} from "@audio-reader/auth";

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
  PASSWORDLESS_HMAC_SECRET?: string;
  CACHE_HMAC_SECRET?: string;
  LOCAL_DEV_OTP?: string;
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

export function resolvePasswordlessHmacSecret(env: WorkerEnv): {
  secret: string;
  fromEnv: boolean;
} {
  const dedicated = env.PASSWORDLESS_HMAC_SECRET?.trim() ?? "";
  if (dedicated !== "") {
    return { secret: dedicated, fromEnv: true };
  }
  const cache = env.CACHE_HMAC_SECRET?.trim() ?? "";
  if (cache !== "") {
    return { secret: cache, fromEnv: true };
  }
  return { secret: LOCAL_PASSWORDLESS_HMAC_SECRET, fromEnv: false };
}

export function parseLocalDevOtp(env: WorkerEnv, environment: AppEnvironment): string | undefined {
  const raw = env.LOCAL_DEV_OTP?.trim() ?? "";
  if (raw === "") {
    return undefined;
  }
  const local = environment === "local" || environment === "test";
  if (!local) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "local_dev_otp_ignored",
        detail: "LOCAL_DEV_OTP is honored only in local and test environments.",
      }),
    );
    return undefined;
  }
  if (!/^[0-9]{6}$/.test(raw)) {
    throw new Error("LOCAL_DEV_OTP must be a 6-digit code when set in local or test.");
  }
  return raw;
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
