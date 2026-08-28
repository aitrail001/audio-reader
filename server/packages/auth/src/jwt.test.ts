import { describe, expect, it } from "vitest";
import {
  LOCAL_JWT_CONFIG,
  extractBearerToken,
  signAccessToken,
  toBase64Url,
  validateAccessToken,
} from "./jwt";

function tamperPayload(token: string): string {
  const parts = token.split(".");
  expect(parts).toHaveLength(3);
  const header = parts[0];
  const payload = parts[1];
  const signature = parts[2];
  if (header === undefined || payload === undefined || signature === undefined) {
    throw new Error("expected three JWT parts");
  }
  const last = payload.slice(-1);
  const flipped = last === "A" ? "B" : "A";
  return `${header}.${payload.slice(0, -1)}${flipped}.${signature}`;
}

describe("ES256 JWKS validation", () => {
  it("accepts a hosted GoTrue token signed with ES256", async () => {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ]);
    if (!("publicKey" in pair) || !("privateKey" in pair)) {
      throw new Error("expected an ECDSA key pair");
    }
    const exported = await crypto.subtle.exportKey("jwk", pair.publicKey);
    if (!("kty" in exported)) {
      throw new Error("expected a JWK");
    }
    const jwk = exported as JsonWebKey & { kid?: string; use?: string; alg?: string };
    jwk.kid = "test-ec-kid";
    jwk.use = "sig";
    jwk.alg = "ES256";
    const now = Math.floor(Date.now() / 1000);
    const header = toBase64Url(
      new TextEncoder().encode(JSON.stringify({ alg: "ES256", typ: "JWT", kid: "test-ec-kid" })),
    );
    const payload = toBase64Url(
      new TextEncoder().encode(
        JSON.stringify({
          iss: "https://example.supabase.co/auth/v1",
          aud: "authenticated",
          sub: "user-es256",
          email: "reader@example.com",
          role: "authenticated",
          iat: now,
          exp: now + 3600,
        }),
      ),
    );
    const signingInput = `${header}.${payload}`;
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        pair.privateKey,
        new TextEncoder().encode(signingInput),
      ),
    );
    const token = `${signingInput}.${toBase64Url(signature)}`;
    const result = await validateAccessToken(token, {
      issuer: "https://example.supabase.co/auth/v1",
      audience: "authenticated",
      secret: "unused-for-es256",
      jwksUrl: "https://example.supabase.co/auth/v1/.well-known/jwks.json",
      fetch: () =>
        Promise.resolve(
          new Response(JSON.stringify({ keys: [jwk] }), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
        ),
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.sub).toBe("user-es256");
      expect(result.claims.email).toBe("reader@example.com");
    }
  });
});

describe("Supabase JWT validation", () => {
  const config = LOCAL_JWT_CONFIG;

  it("accepts a token with matching issuer, audience, subject, and expiry", async () => {
    const token = await signAccessToken({ sub: "user-1", email: "user@example.com" }, config);
    const result = await validateAccessToken(token, config);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.sub).toBe("user-1");
      expect(result.claims.iss).toBe(config.issuer);
      expect(result.claims.email).toBe("user@example.com");
    }
  });

  it("rejects an invalid issuer", async () => {
    const token = await signAccessToken(
      { sub: "user-1", email: "user@example.com", iss: "https://evil.example/auth/v1" },
      config,
    );
    const result = await validateAccessToken(token, config);
    expect(result).toEqual({ ok: false, code: "invalid_issuer" });
  });

  it("rejects an invalid audience", async () => {
    const token = await signAccessToken(
      { sub: "user-1", email: "user@example.com", aud: "anon" },
      config,
    );
    const result = await validateAccessToken(token, config);
    expect(result).toEqual({ ok: false, code: "invalid_audience" });
  });

  it("rejects an invalid signature", async () => {
    const token = await signAccessToken({ sub: "user-1", email: "user@example.com" }, config);
    const tampered = tamperPayload(token);
    const result = await validateAccessToken(tampered, config);
    expect(result).toEqual({ ok: false, code: "invalid_signature" });
  });

  it("rejects a token signed with a different secret", async () => {
    const token = await signAccessToken({ sub: "user-1" }, config);
    const result = await validateAccessToken(token, { ...config, secret: "other-secret" });
    expect(result).toEqual({ ok: false, code: "invalid_signature" });
  });

  it("rejects an expired token", async () => {
    const now = new Date("2026-01-01T00:00:00.000Z");
    const token = await signAccessToken(
      { sub: "user-1", exp: Math.floor(now.getTime() / 1000) - 60 },
      config,
    );
    const result = await validateAccessToken(token, config, now);
    expect(result).toEqual({ ok: false, code: "expired" });
  });

  it("rejects alg=none and missing subject", async () => {
    const encoder = new TextEncoder();
    const noneToken = `${toBase64Url(
      encoder.encode(JSON.stringify({ alg: "none", typ: "JWT" })),
    )}.${toBase64Url(
      encoder.encode(
        JSON.stringify({
          sub: "user-1",
          iss: config.issuer,
          aud: config.audience,
          exp: 9999999999,
        }),
      ),
    )}.`;
    expect(await validateAccessToken(noneToken, config)).toEqual({
      ok: false,
      code: "invalid_token",
    });

    const missingSub = await signAccessToken({ sub: "" }, config);
    expect(await validateAccessToken(missingSub, config)).toEqual({
      ok: false,
      code: "missing_subject",
    });
  });

  it("extracts a bearer token and ignores missing headers", () => {
    expect(extractBearerToken("Bearer abc.def.ghi")).toBe("abc.def.ghi");
    expect(extractBearerToken("bearer abc.def.ghi")).toBe("abc.def.ghi");
    expect(extractBearerToken("Basic abc")).toBeNull();
    expect(extractBearerToken(null)).toBeNull();
    expect(extractBearerToken("")).toBeNull();
  });
});
