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

/** Accept a raw JWT, a magic-link URL, or a hash fragment that contains access_token. */
export function extractAccessToken(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed === "") {
    return "";
  }
  let candidate = trimmed;
  if (trimmed.includes("access_token=")) {
    const hashStart = trimmed.indexOf("#");
    const queryStart = trimmed.indexOf("access_token=");
    const encoded =
      hashStart >= 0 && (queryStart < 0 || hashStart < queryStart)
        ? trimmed.slice(hashStart + 1)
        : trimmed.slice(queryStart);
    try {
      const token = new URLSearchParams(encoded).get("access_token");
      if (typeof token === "string" && token.trim() !== "") {
        candidate = token.trim();
      }
    } catch {
      candidate = trimmed;
    }
  }
  const jwt = candidate.split(/\s+/)[0] ?? "";
  return jwt;
}
