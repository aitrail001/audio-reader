import type { AuthConfig } from "./types";

export const API_BASE = (import.meta.env.VITE_API_BASE_URL ?? "").replace(/\/$/, "");
export const DEVICE_STORAGE_KEY = "audio-reader-admin-device-id";
export const TOKEN_STORAGE_KEY = "audio-reader-admin-token";

export function deviceId(): string {
  const existing = localStorage.getItem(DEVICE_STORAGE_KEY);
  if (existing !== null && existing !== "") {
    return existing;
  }
  const created = crypto.randomUUID();
  localStorage.setItem(DEVICE_STORAGE_KEY, created);
  return created;
}

export function adminHeaders(token: string, mutating = false): HeadersInit {
  const headers: Record<string, string> = {
    authorization: `Bearer ${token.trim()}`,
    "X-Device-Id": deviceId(),
  };
  if (mutating) {
    headers["content-type"] = "application/json";
    headers["Idempotency-Key"] = `admin-${crypto.randomUUID()}`;
  }
  return headers;
}

export async function readError(response: Response): Promise<string> {
  try {
    const payload = (await response.json()) as { detail?: string; title?: string };
    return payload.detail ?? payload.title ?? `Request failed (${String(response.status)}).`;
  } catch {
    return `Request failed (${String(response.status)}).`;
  }
}

export async function getJson<T>(path: string, token: string): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, { headers: adminHeaders(token) });
  if (!response.ok) {
    throw new Error(await readError(response));
  }
  return (await response.json()) as T;
}

export async function getJsonOrNull<T>(path: string, token: string): Promise<T | null> {
  try {
    return await getJson<T>(path, token);
  } catch {
    return null;
  }
}

export async function sendJson<T>(
  path: string,
  token: string,
  method: string,
  body: unknown,
): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    method,
    headers: adminHeaders(token, true),
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(await readError(response));
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

export async function fetchAuthConfig(): Promise<AuthConfig> {
  const response = await fetch(`${API_BASE}/v1/auth/config`);
  if (!response.ok) {
    throw new Error(await readError(response));
  }
  return (await response.json()) as AuthConfig;
}

export async function requestOtp(email: string, turnstileToken: string | undefined): Promise<void> {
  const payload: Record<string, string> = { email };
  if (turnstileToken !== undefined && turnstileToken.trim() !== "") {
    payload.turnstileToken = turnstileToken.trim();
  }
  const response = await fetch(`${API_BASE}/v1/auth/email-otp/request`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Device-Id": deviceId(),
      "Idempotency-Key": `admin-${crypto.randomUUID()}`,
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(await readError(response));
  }
}

export async function verifyOtp(
  email: string,
  code: string,
  turnstileToken: string | undefined,
): Promise<string> {
  const payload: Record<string, string> = { email, code, deviceId: deviceId() };
  if (turnstileToken !== undefined && turnstileToken.trim() !== "") {
    payload.turnstileToken = turnstileToken.trim();
  }
  const response = await fetch(`${API_BASE}/v1/auth/email-otp/verify`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Device-Id": deviceId(),
      "Idempotency-Key": `admin-${crypto.randomUUID()}`,
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(await readError(response));
  }
  const body = (await response.json()) as { accessToken?: string };
  if (typeof body.accessToken !== "string" || body.accessToken === "") {
    throw new Error("Sign-in did not return an access token.");
  }
  return body.accessToken;
}
