import type { Principal } from "@audio-reader/auth";
import type { components } from "@audio-reader/contract";
import type { IdentityStore, OpsProductEvent, OpsStore } from "@audio-reader/database";
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
const SAFE_PROPERTY_KEYS = new Set([
  "appVersion",
  "batch",
  "bookCount",
  "buildNumber",
  "bytes",
  "cacheHitCount",
  "cacheId",
  "chapterId",
  "code",
  "contentCategory",
  "contentId",
  "country",
  "feature",
  "format",
  "known",
  "kind",
  "lookupOnly",
  "method",
  "mode",
  "model",
  "modelSource",
  "platform",
  "provider",
  "readerLevel",
  "region",
  "reviewRating",
  "sourceLanguage",
  "status",
  "syncEntity",
  "syncPhase",
  "targetLanguage",
  "useFlow",
  "wordLength",
]);

export type ProductEventRouteContext = {
  request: Request;
  requestId: string;
  authenticate: (request: Request) => Promise<Principal | null>;
  ops?: OpsStore;
  identity?: IdentityStore;
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

/** Persist an explicitly permitted event without letting analytics availability block product APIs. */
export async function captureProductEvent(
  ops: OpsStore | undefined,
  input: {
    accountId: string;
    deviceId?: string | null;
    name: string;
    outcome?: OpsProductEvent["outcome"];
    requestId: string;
    purpose?: OpsProductEvent["purpose"];
    properties?: Record<string, unknown>;
  },
): Promise<boolean> {
  if (ops === undefined || !EVENT_NAME.test(input.name)) {
    return false;
  }
  try {
    const purpose = input.purpose ?? "learning_analytics";
    if (
      purpose === "learning_analytics" &&
      !(await ops.analyticsPreference(input.accountId)).operatorLearningAnalyticsEnabled
    ) {
      console.warn(
        JSON.stringify({
          level: "info",
          message: "product_event_suppressed",
          requestId: input.requestId,
          name: input.name,
          purpose,
          outcome: "analytics_disabled",
        }),
      );
      return false;
    }
    await ops.recordProductEvent({
      accountId: input.accountId,
      deviceId: input.deviceId ?? null,
      purpose,
      name: input.name,
      outcome: input.outcome ?? "ok",
      requestId: input.requestId,
      properties: await sanitizeProperties(input.properties ?? {}),
    });
    console.warn(
      JSON.stringify({
        level: "info",
        message: "product_event",
        requestId: input.requestId,
        name: input.name,
        outcome: input.outcome ?? "ok",
        purpose,
      }),
    );
    return true;
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
    return false;
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
  const serverProperties = await deriveServerProperties(
    context.request,
    principal.accountId,
    deviceId,
    context.identity,
  );
  for (const item of rawEvents) {
    if (typeof item.name !== "string" || !EVENT_NAME.test(item.name)) {
      continue;
    }
    const outcome =
      item.outcome === "failed" || item.outcome === "cancelled" || item.outcome === "started"
        ? item.outcome
        : "ok";
    const serverOwnedKeys = new Set(["country", "region", "platform", "appVersion", "buildNumber"]);
    const clientProperties = isRecord(item.properties)
      ? Object.fromEntries(
          Object.entries(item.properties).filter(([key]) => !serverOwnedKeys.has(key)),
        )
      : {};
    const stored = await captureProductEvent(ops, {
      accountId: principal.accountId,
      deviceId,
      name: item.name,
      outcome,
      requestId: context.requestId,
      properties: {
        ...clientProperties,
        ...serverProperties,
      },
    });
    if (stored) accepted += 1;
  }
  return jsonResponse({ accepted }, 202);
}

export async function toProductEvent(event: OpsProductEvent): Promise<ProductEvent> {
  return {
    id: event.id,
    subjectId: await pseudonymousReference("learner", event.accountId),
    name: event.name,
    outcome: event.outcome,
    createdAt: event.createdAt,
    ...(event.deviceId === null
      ? {}
      : { deviceSubjectId: await pseudonymousReference("device", event.deviceId) }),
    ...(event.requestId === null ? {} : { requestId: event.requestId }),
    properties: await sanitizeActivityProperties(event.properties),
  };
}

async function pseudonymousReference(prefix: string, value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  const hex = [...new Uint8Array(digest)]
    .slice(0, 8)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return `${prefix}-${hex}`;
}

async function sanitizeProperties(
  input: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const next: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(input)) {
    if (Object.keys(next).length >= MAX_PROPERTY_KEYS) {
      break;
    }
    if (
      SECRET_KEY.test(key) ||
      key.length > 40 ||
      (!SAFE_PROPERTY_KEYS.has(key) && key !== "bookId")
    ) {
      continue;
    }
    const normalizedKey = key === "bookId" ? "contentId" : key;
    if (typeof value === "string") {
      const normalized = normalizeProperty(normalizedKey, value);
      if (normalized !== "") {
        next[normalizedKey] = await opaqueContentProperty(normalizedKey, normalized);
      }
    } else if (normalizedKey === "contentId" || normalizedKey === "chapterId") {
      continue;
    } else if (typeof value === "number" && Number.isFinite(value)) {
      next[normalizedKey] = value;
    } else if (typeof value === "boolean") {
      next[normalizedKey] = value;
    }
  }
  return next;
}

/** Durable legacy rows are re-sanitized before Operator output without mutating provenance. */
async function sanitizeActivityProperties(
  input: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return sanitizeProperties(input);
}

async function opaqueContentProperty(key: string, value: string): Promise<string> {
  if (key !== "contentId" && key !== "chapterId") return value;
  const prefix = key === "contentId" ? "content" : "chapter";
  if (new RegExp(`^${prefix}-[0-9a-f]{16}$`).test(value)) return value;
  return pseudonymousReference(prefix, value);
}

/** Cloudflare and the registered device are authoritative for location and app dimensions. */
async function deriveServerProperties(
  request: Request,
  accountId: string,
  deviceId: string,
  identity: IdentityStore | undefined,
): Promise<Record<string, unknown>> {
  const properties: Record<string, unknown> = {};
  const cf = (request as Request & { cf?: unknown }).cf;
  if (isRecord(cf)) {
    const country = normalizeCountry(cf.country);
    if (country !== "") properties.country = country;
    const regionCode = normalizeRegion(cf.regionCode);
    if (country !== "" && regionCode !== "") properties.region = `${country}-${regionCode}`;
  }
  const devices = (await identity?.listDevices(accountId)) ?? [];
  const device = devices.find((item) => item.id === deviceId && !item.revoked);
  if (device !== undefined) {
    properties.platform = device.platform;
    properties.appVersion = device.appVersion;
    if (device.buildNumber !== undefined) properties.buildNumber = device.buildNumber;
  }
  return properties;
}

function normalizeProperty(key: string, value: string): string {
  const trimmed = value.trim().slice(0, MAX_PROPERTY_CHARS);
  if (key === "country") return normalizeCountry(trimmed);
  if (key === "region")
    return trimmed
      .toUpperCase()
      .replace(/[^A-Z0-9-]/g, "")
      .slice(0, 12);
  if (key === "sourceLanguage" || key === "targetLanguage") return normalizeLanguage(trimmed);
  if (
    key === "readerLevel" ||
    key === "contentCategory" ||
    key === "feature" ||
    key === "useFlow"
  ) {
    return trimmed
      .toLowerCase()
      .replace(/[^a-z0-9_.-]/g, "_")
      .slice(0, 40);
  }
  return trimmed;
}

function normalizeCountry(value: unknown): string {
  if (typeof value !== "string") return "";
  const country = value.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(country) ? country : "";
}

function normalizeRegion(value: unknown): string {
  if (typeof value !== "string") return "";
  return value
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, 6);
}

function normalizeLanguage(value: string): string {
  const parts = value.replaceAll("_", "-").split("-").filter(Boolean);
  return parts
    .map((part, index) => {
      if (index === 0) return part.toLowerCase();
      if (part.length === 4) return `${part[0]?.toUpperCase() ?? ""}${part.slice(1).toLowerCase()}`;
      return part.toUpperCase();
    })
    .join("-")
    .slice(0, 35);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
