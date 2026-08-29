export function pageItems<T>(payload: unknown): T[] {
  if (Array.isArray(payload)) {
    return payload as T[];
  }
  if (typeof payload === "object" && payload !== null && "items" in payload) {
    const items = (payload as { items?: T[] }).items;
    return Array.isArray(items) ? items : [];
  }
  return [];
}

export function nextCursorOf(payload: unknown): string | null {
  if (typeof payload === "object" && payload !== null && "nextCursor" in payload) {
    const cursor = (payload as { nextCursor?: unknown }).nextCursor;
    return typeof cursor === "string" && cursor.trim() !== "" ? cursor : null;
  }
  return null;
}

export function formatWhen(value: string | null | undefined): string {
  if (value === null || value === undefined || value.trim() === "") {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

export function shortId(value: string, keep = 8): string {
  const trimmed = value.trim();
  if (trimmed === "") {
    return "—";
  }
  if (trimmed.length <= keep + 1) {
    return trimmed;
  }
  return `${trimmed.slice(0, keep)}…`;
}

export function formatJson(value: unknown): string {
  try {
    return JSON.stringify(value ?? {}, null, 2);
  } catch {
    return "—";
  }
}

export function rowCountLabel(count: number, singular: string, plural = `${singular}s`): string {
  return `${String(count)} ${count === 1 ? singular : plural}`;
}

export function formatBytes(bytes: number | undefined): string {
  if (bytes === undefined || !Number.isFinite(bytes) || bytes <= 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB", "TB"] as const;
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = Number.isInteger(value) || value >= 10 || unit === 0 ? 0 : 1;
  const label = units[unit] ?? "B";
  return `${value.toFixed(digits)} ${label}`;
}

export function pipClass(status: string | undefined): string {
  if (status === "ok") {
    return "ok";
  }
  if (status === "unavailable" || status === "degraded") {
    return "warn";
  }
  return "";
}

export function statusTone(status: string): "ok" | "warn" | "bad" {
  if (
    status === "ok" ||
    status === "active" ||
    status === "enabled" ||
    status === "succeeded" ||
    status === "true" ||
    status.endsWith("_ok") ||
    status === "on"
  ) {
    return "ok";
  }
  if (
    status === "failed" ||
    status === "dead_letter" ||
    status === "deleted" ||
    status === "purged" ||
    status.includes("fail") ||
    status === "rejected" ||
    status === "policy_disabled"
  ) {
    return "bad";
  }
  return "warn";
}

export function reasonReady(reason: string): boolean {
  return reason.trim().length >= 5;
}

export type ExtractedSession = {
  accessToken: string;
  refreshToken?: string;
};

const JWT_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

function looksLikeJwt(value: string): boolean {
  return JWT_PATTERN.test(value);
}

/** Hash wins so fragment magic links are not mixed with query leftovers. */
function queryFrom(raw: string): URLSearchParams {
  const hashStart = raw.indexOf("#");
  if (hashStart >= 0) {
    return new URLSearchParams(raw.slice(hashStart + 1));
  }
  const searchStart = raw.indexOf("?");
  if (searchStart >= 0) {
    return new URLSearchParams(raw.slice(searchStart + 1));
  }
  const tokenStart = raw.search(/access_token=|refresh_token=/);
  if (tokenStart >= 0) {
    return new URLSearchParams(raw.slice(tokenStart));
  }
  return new URLSearchParams();
}

/** True when the location may leak tokens in history or Referer. */
export function hrefCarriesSessionTokens(href: string): boolean {
  return href.includes("access_token=") || href.includes("refresh_token=");
}

/** Accept a raw JWT, a magic-link URL, or a hash fragment. Portal URLs are not tokens. */
export function extractSession(raw: string): ExtractedSession | null {
  const trimmed = raw.trim();
  if (trimmed === "") {
    return null;
  }
  const bearer = /^(?:Bearer)\s+(\S+)/i.exec(trimmed);
  if (bearer?.[1] !== undefined && looksLikeJwt(bearer[1])) {
    return { accessToken: bearer[1] };
  }
  if (trimmed.includes("access_token=") || trimmed.includes("refresh_token=")) {
    const params = queryFrom(trimmed);
    const access = params.get("access_token")?.trim() ?? "";
    const refresh = params.get("refresh_token")?.trim() ?? "";
    if (!looksLikeJwt(access)) {
      return null;
    }
    return refresh === ""
      ? { accessToken: access }
      : { accessToken: access, refreshToken: refresh };
  }
  const jwt = trimmed.split(/\s+/)[0] ?? "";
  return looksLikeJwt(jwt) ? { accessToken: jwt } : null;
}

export function extractAccessToken(raw: string): string {
  return extractSession(raw)?.accessToken ?? "";
}
