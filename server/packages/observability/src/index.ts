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

export function formatError(error: unknown): string {
  if (error instanceof Error) {
    return error.stack ?? error.message;
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    return JSON.stringify(error);
  } catch {
    return "unknown_error";
  }
}

export function logUnhandledError(requestId: string, error: unknown): void {
  console.error(
    JSON.stringify({
      level: "error",
      message: "unhandled_request_error",
      requestId,
      error: formatError(error),
    }),
  );
}

export type SecurityEventFields = {
  message: string;
  requestId: string;
  action?: string;
  emailHash?: string;
  ipHash?: string;
  deviceId?: string;
  reason?: string;
};

export function logSecurityEvent(event: SecurityEventFields): void {
  console.warn(
    JSON.stringify({
      level: "warn",
      ...event,
    }),
  );
}
