export const packageId = "@audio-reader/observability" as const;

export const REQUEST_ID_HEADER = "X-Request-Id" as const;

const REQUEST_ID_PATTERN = /^[\w.:-]{8,128}$/;

export function resolveRequestId(header: string | null | undefined): string {
  const trimmed = header?.trim() ?? "";
  if (REQUEST_ID_PATTERN.test(trimmed)) {
    return trimmed;
  }
  return crypto.randomUUID();
}
