export type AppEnvironment = "local" | "test" | "staging" | "production";

export type WorkerEnv = {
  ENVIRONMENT?: string;
  APP_VERSION?: string;
  CORS_ALLOWED_ORIGINS?: string;
  ADMIN_ORIGIN?: string;
  MAX_BODY_BYTES?: string;
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
