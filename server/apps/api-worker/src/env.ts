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
  SUPABASE_ANON_KEY?: string;
  SUPABASE_JWT_SECRET?: string;
  SUPABASE_JWT_AUDIENCE?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  SUPABASE_SECRET_KEY?: string;
  SUPABASE_STORAGE_BUCKET?: string;
  SUPABASE_STORAGE_SIGNED_UPLOAD_TTL_SECONDS?: string;
  QWEN_API_KEY?: string;
  QWEN_BASE_URL?: string;
  QWEN_MODEL?: string;
  GCS_BUCKET?: string;
  GCS_SERVICE_ACCOUNT_JSON?: string;
  R2_ACCOUNT_ID?: string;
  R2_BUCKET_NAME?: string;
  R2_MANAGEMENT_API_TOKEN?: string;
  OPERATOR_CONFIG_KEY?: string;
  ADMIN_BOOTSTRAP_EMAIL?: string;
  TURNSTILE_SECRET_KEY?: string;
  TURNSTILE_SITE_KEY?: string;
  PASSWORDLESS_HMAC_SECRET?: string;
  CACHE_HMAC_SECRET?: string;
  LOCAL_DEV_OTP?: string;
  RESEND_API_KEY?: string;
  OTP_FROM_EMAIL?: string;
  ASSETS?: R2Bucket;
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
    const origin = url.replace(/\/$/, "");
    return {
      issuer: `${origin}/auth/v1`,
      audience,
      secret,
      accessTokenTtlSeconds: 3600,
      clockSkewSeconds: 0,
      jwksUrl: `${origin}/auth/v1/.well-known/jwks.json`,
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

export function resolveCacheHmacSecret(env: WorkerEnv): {
  secret: string;
  fromEnv: boolean;
} {
  const cache = env.CACHE_HMAC_SECRET?.trim() ?? "";
  if (cache !== "") {
    return { secret: cache, fromEnv: true };
  }
  const dedicated = env.PASSWORDLESS_HMAC_SECRET?.trim() ?? "";
  if (dedicated !== "") {
    return { secret: dedicated, fromEnv: true };
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

export function resolveHostedAuthConfig(
  env: WorkerEnv,
  environment: AppEnvironment,
): { url: string; anonKey: string } | undefined {
  if (environment === "local" || environment === "test") {
    return undefined;
  }
  const url = env.SUPABASE_URL?.trim() ?? "";
  const anonKey = env.SUPABASE_ANON_KEY?.trim() ?? "";
  if (url === "" || anonKey === "") {
    return undefined;
  }
  return { url: url.replace(/\/$/, ""), anonKey };
}

export function resolveSupabaseRestConfig(
  env: WorkerEnv,
): { url: string; serviceRoleKey: string } | undefined {
  const url = env.SUPABASE_URL?.trim() ?? "";
  const serviceRoleKey =
    env.SUPABASE_SERVICE_ROLE_KEY?.trim() || env.SUPABASE_SECRET_KEY?.trim() || "";
  if (url === "" || serviceRoleKey === "") {
    return undefined;
  }
  return { url: url.replace(/\/$/, ""), serviceRoleKey };
}

export type OperatorWrappingSource = "operator_config_key" | "cache_hmac" | "none";

// OPERATOR_CONFIG_KEY is the wrapping secret for Desk ciphertext. Falling back
// to the committed local-dev pepper (source "none") must not encrypt live keys.
export function resolveOperatorWrappingSecret(env: WorkerEnv): {
  secret: string;
  fromEnv: boolean;
  source: OperatorWrappingSource;
} {
  const dedicated = env.OPERATOR_CONFIG_KEY?.trim() ?? "";
  if (dedicated !== "") {
    return { secret: dedicated, fromEnv: true, source: "operator_config_key" };
  }
  const cache = resolveCacheHmacSecret(env);
  if (cache.fromEnv) {
    return { secret: cache.secret, fromEnv: true, source: "cache_hmac" };
  }
  return { secret: cache.secret, fromEnv: false, source: "none" };
}

export function resolveQwenConfig(
  env: WorkerEnv,
): { apiKey: string; baseUrl?: string; model?: string } | undefined {
  const apiKey = env.QWEN_API_KEY?.trim() ?? "";
  if (apiKey === "") {
    return undefined;
  }
  const baseUrl = env.QWEN_BASE_URL?.trim() ?? "";
  const model = env.QWEN_MODEL?.trim() ?? "";
  return {
    apiKey,
    ...(baseUrl === "" ? {} : { baseUrl }),
    ...(model === "" ? {} : { model }),
  };
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
