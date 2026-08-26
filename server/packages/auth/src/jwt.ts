export type JwtSigningConfig = {
  issuer: string;
  audience: string;
  secret: string;
  accessTokenTtlSeconds?: number;
  clockSkewSeconds?: number;
};

export type JwtClaims = {
  sub: string;
  iss: string;
  aud: string | string[];
  exp: number;
  iat?: number;
  nbf?: number;
  email?: string;
  role?: string;
};

export type JwtFailureCode =
  | "invalid_token"
  | "invalid_issuer"
  | "invalid_audience"
  | "invalid_signature"
  | "expired"
  | "missing_subject";

export type JwtValidationResult =
  { ok: true; claims: JwtClaims } | { ok: false; code: JwtFailureCode };

export const LOCAL_JWT_CONFIG: JwtSigningConfig = {
  issuer: "http://127.0.0.1:54321/auth/v1",
  audience: "authenticated",
  secret: "local-dev-only-hs256-secret",
  accessTokenTtlSeconds: 3600,
  clockSkewSeconds: 0,
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function fromBase64Url(input: string): Uint8Array | undefined {
  try {
    const normalized = input.replaceAll("-", "+").replaceAll("_", "/");
    const pad = (4 - (normalized.length % 4)) % 4;
    const binary = atob(normalized + "=".repeat(pad));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  } catch {
    return undefined;
  }
}

export function extractBearerToken(header: string | null | undefined): string | null {
  const trimmed = header?.trim() ?? "";
  const match = /^(?:Bearer)\s+(\S+)$/i.exec(trimmed);
  const token = match?.[1];
  return token === undefined || token === "" ? null : token;
}

export type SignAccessTokenClaims = {
  sub: string;
  email?: string;
  iss?: string;
  aud?: string | string[];
  exp?: number;
  iat?: number;
  nbf?: number;
};

export async function signAccessToken(
  claims: SignAccessTokenClaims,
  config: JwtSigningConfig,
  now: Date = new Date(),
): Promise<string> {
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const ttl = config.accessTokenTtlSeconds ?? 3600;
  const payload: Record<string, unknown> = {
    iss: claims.iss ?? config.issuer,
    aud: claims.aud ?? config.audience,
    sub: claims.sub,
    jti: crypto.randomUUID(),
    role: "authenticated",
    iat: claims.iat ?? nowSeconds,
    exp: claims.exp ?? nowSeconds + ttl,
  };
  if (claims.email !== undefined) {
    payload.email = claims.email;
  }
  if (claims.nbf !== undefined) {
    payload.nbf = claims.nbf;
  }
  const header = toBase64Url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const signingInput = `${header}.${body}`;
  const signature = toBase64Url(await hmacSign(config.secret, signingInput));
  return `${signingInput}.${signature}`;
}

export async function validateAccessToken(
  token: string,
  config: JwtSigningConfig,
  now: Date = new Date(),
): Promise<JwtValidationResult> {
  const parts = token.split(".");
  if (
    parts.length !== 3 ||
    parts[0] === undefined ||
    parts[1] === undefined ||
    parts[2] === undefined
  ) {
    return { ok: false, code: "invalid_token" };
  }
  const header = decodeJson(parts[0]);
  if (!isRecord(header) || header.alg !== "HS256") {
    return { ok: false, code: "invalid_token" };
  }
  const signingInput = `${parts[0]}.${parts[1]}`;
  const signature = fromBase64Url(parts[2]);
  if (signature === undefined) {
    return { ok: false, code: "invalid_signature" };
  }
  const valid = await hmacVerify(config.secret, signingInput, signature);
  if (!valid) {
    return { ok: false, code: "invalid_signature" };
  }
  const payload = decodeJson(parts[1]);
  if (!isRecord(payload)) {
    return { ok: false, code: "invalid_token" };
  }
  const claims = parseClaims(payload);
  if (claims === undefined) {
    return { ok: false, code: "invalid_token" };
  }
  const skew = config.clockSkewSeconds ?? 0;
  const nowSeconds = Math.floor(now.getTime() / 1000);
  if (claims.nbf !== undefined && nowSeconds + skew < claims.nbf) {
    return { ok: false, code: "invalid_token" };
  }
  if (nowSeconds - skew >= claims.exp) {
    return { ok: false, code: "expired" };
  }
  if (claims.iss !== config.issuer) {
    return { ok: false, code: "invalid_issuer" };
  }
  if (!audienceMatches(claims.aud, config.audience)) {
    return { ok: false, code: "invalid_audience" };
  }
  if (claims.sub.trim() === "") {
    return { ok: false, code: "missing_subject" };
  }
  return { ok: true, claims };
}

function audienceMatches(aud: string | string[], expected: string): boolean {
  if (typeof aud === "string") {
    return aud === expected;
  }
  return aud.includes(expected);
}

function parseClaims(payload: Record<string, unknown>): JwtClaims | undefined {
  if (typeof payload.sub !== "string" || typeof payload.iss !== "string") {
    return undefined;
  }
  if (typeof payload.exp !== "number" || !Number.isFinite(payload.exp)) {
    return undefined;
  }
  const aud = payload.aud;
  if (typeof aud !== "string" && !isStringArray(aud)) {
    return undefined;
  }
  const claims: JwtClaims = {
    sub: payload.sub,
    iss: payload.iss,
    aud,
    exp: payload.exp,
  };
  if (typeof payload.iat === "number") {
    claims.iat = payload.iat;
  }
  if (typeof payload.nbf === "number") {
    claims.nbf = payload.nbf;
  }
  if (typeof payload.email === "string") {
    claims.email = payload.email;
  }
  if (typeof payload.role === "string") {
    claims.role = payload.role;
  }
  return claims;
}

function decodeJson(input: string): unknown {
  const bytes = fromBase64Url(input);
  if (bytes === undefined) {
    return undefined;
  }
  try {
    return JSON.parse(decoder.decode(bytes)) as unknown;
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    [usage],
  );
}

async function hmacSign(secret: string, signingInput: string): Promise<Uint8Array> {
  const key = await hmacKey(secret, "sign");
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput));
  return new Uint8Array(signature);
}

async function hmacVerify(
  secret: string,
  signingInput: string,
  signature: Uint8Array,
): Promise<boolean> {
  const key = await hmacKey(secret, "verify");
  return crypto.subtle.verify("HMAC", key, signature, encoder.encode(signingInput));
}
