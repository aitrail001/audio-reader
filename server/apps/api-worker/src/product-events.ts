import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { OpsProductEvent, OpsStore } from "@audio-reader/database";
import { readJsonObject } from "./body";
import { jsonResponse } from "./http";
import { fieldError, methodNotAllowed, requireDeviceId, requirePrincipal } from "./route-helpers";

type ProductEvent = components["schemas"]["ProductEvent"];
type ProductEventBatch = components["schemas"]["ProductEventBatch"];

const EVENT_NAME = /^[a-z][a-z0-9_.]{1,80}$/;
const SECRET_KEY = /token|password|secret|otp|authorization|apikey|api_key|wrap/i;
const MAX_BATCH = 50;
const MAX_PROPERTY_KEYS = 16;
const MAX_PROPERTY_CHARS = 200;

export type ProductEventRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  ops?: OpsStore;
};

export function isProductEventPath(path: string): boolean {
  return path === "/v1/me/events";
}

export function productEventMethodError(
  path: string,
  method: string,
  requestId: string,
): Response | undefined {
  if (path === "/v1/me/events" && method.toUpperCase() !== "POST") {
    return methodNotAllowed(["POST"], requestId);
  }
  return undefined;
}

/** Persist a usage row without failing the caller. Analytics must not block product APIs. */
export async function captureProductEvent(
  ops: OpsStore | undefined,
  input: {
    accountId: string;
    deviceId?: string | null;
    name: string;
    outcome?: OpsProductEvent["outcome"];
    requestId: string;
    properties?: Record<string, unknown>;
  },
): Promise<void> {
  if (ops === undefined || !EVENT_NAME.test(input.name)) {
    return;
  }
  try {
    await ops.recordProductEvent({
      accountId: input.accountId,
      deviceId: input.deviceId ?? null,
      name: input.name,
      outcome: input.outcome ?? "ok",
      requestId: input.requestId,
      properties: sanitizeProperties(input.properties ?? {}),
    });
    console.warn(
      JSON.stringify({
        level: "info",
        message: "product_event",
        requestId: input.requestId,
        accountId: input.accountId,
        name: input.name,
        outcome: input.outcome ?? "ok",
      }),
    );
  } catch (error: unknown) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "product_event_failed",
        requestId: input.requestId,
        name: input.name,
        detail: error instanceof Error ? error.message : "unknown",
      }),
    );
  }
}

export async function handleProductEventRoute(
  context: ProductEventRouteContext,
): Promise<Response | undefined> {
  const path = new URL(context.request.url).pathname;
  if (!isProductEventPath(path)) {
    return undefined;
  }
  const methodError = productEventMethodError(path, context.request.method, context.requestId);
  if (methodError !== undefined) {
    return methodError;
  }
  const principal = await requirePrincipal(context);
  if (principal instanceof Response) {
    return principal;
  }
  const deviceId = requireDeviceId(context.request, context.requestId);
  if (deviceId instanceof Response) {
    return deviceId;
  }
  const ops = context.ops;
  if (ops === undefined) {
    return jsonResponse({ accepted: 0 }, 202);
  }
  const body = await readJsonObject(context.request, context.requestId);
  if (!body.ok) {
    return body.response;
  }
  const rawEvents = Array.isArray((body.value as ProductEventBatch).events)
    ? (body.value as ProductEventBatch).events
    : [];
  if (rawEvents.length > MAX_BATCH) {
    return fieldError(
      context.requestId,
      "events",
      `events must contain at most ${String(MAX_BATCH)} items.`,
    );
  }
  let accepted = 0;
  for (const item of rawEvents) {
    if (typeof item.name !== "string" || !EVENT_NAME.test(item.name)) {
      continue;
    }
    const outcome =
      item.outcome === "failed" || item.outcome === "cancelled" || item.outcome === "started"
        ? item.outcome
        : "ok";
    await captureProductEvent(ops, {
      accountId: principal.accountId,
      deviceId,
      name: item.name,
      outcome,
      requestId: context.requestId,
      properties: isRecord(item.properties) ? item.properties : {},
    });
    accepted += 1;
  }
  return jsonResponse({ accepted }, 202);
}

export function toProductEvent(event: OpsProductEvent): ProductEvent {
  return {
    id: event.id,
    accountId: event.accountId,
    name: event.name,
    outcome: event.outcome,
    createdAt: event.createdAt,
    ...(event.deviceId === null ? {} : { deviceId: event.deviceId }),
    ...(event.requestId === null ? {} : { requestId: event.requestId }),
    properties: event.properties,
  };
}

function sanitizeProperties(input: Record<string, unknown>): Record<string, unknown> {
  const next: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (Object.keys(next).length >= MAX_PROPERTY_KEYS) {
      break;
    }
    if (SECRET_KEY.test(key) || key.length > 40) {
      continue;
    }
    if (typeof value === "string") {
      next[key] = value.slice(0, MAX_PROPERTY_CHARS);
    } else if (typeof value === "number" && Number.isFinite(value)) {
      next[key] = value;
    } else if (typeof value === "boolean") {
      next[key] = value;
    }
  }
  return next;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
