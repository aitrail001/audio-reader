import { describe, expect, it } from "vitest";
import {
  extractAccessToken,
  extractSession,
  formatBytes,
  formatJson,
  hrefCarriesSessionTokens,
  nextCursorOf,
  pageItems,
  reasonReady,
  rowCountLabel,
  shortId,
  statusTone,
} from "./format";

describe("operator format helpers", () => {
  it("reads cursor pages and arrays", () => {
    expect(pageItems<number>({ items: [1, 2], nextCursor: "2" })).toEqual([1, 2]);
    expect(pageItems<number>([3])).toEqual([3]);
    expect(nextCursorOf({ items: [], nextCursor: "4" })).toBe("4");
    expect(nextCursorOf({ items: [] })).toBeNull();
  });

  it("formats byte counts", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(2048)).toBe("2 KB");
  });

  it("clips identifiers and counts rows", () => {
    expect(shortId("")).toBe("—");
    expect(shortId("abc")).toBe("abc");
    expect(shortId("00000000-0000-4000-8000-000000000031")).toBe("00000000…");
    expect(rowCountLabel(1, "entry", "entries")).toBe("1 entry");
    expect(rowCountLabel(2, "entry", "entries")).toBe("2 entries");
    expect(formatJson({ hits: 3 })).toContain("hits");
  });

  it("gates mutations on a five-character reason", () => {
    expect(reasonReady("abcd")).toBe(false);
    expect(reasonReady("abcde")).toBe(true);
  });

  it("maps operator states to tones", () => {
    expect(statusTone("succeeded")).toBe("ok");
    expect(statusTone("failed")).toBe("bad");
    expect(statusTone("queued")).toBe("warn");
  });

  it("pulls access_token out of a Supabase magic-link URL", () => {
    const jwt = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.e30.sig";
    expect(
      extractAccessToken(
        `http://localhost:3000/#access_token=${jwt}&expires_at=1&refresh_token=x&type=magiclink`,
      ),
    ).toBe(jwt);
    expect(extractAccessToken(`#access_token=${jwt}&type=magiclink`)).toBe(jwt);
    expect(
      extractAccessToken(
        `https://audio-reader-admin.pages.dev/#access_token=${jwt}&expires_in=3600&type=magiclink`,
      ),
    ).toBe(jwt);
    expect(extractAccessToken(jwt)).toBe(jwt);
    expect(extractAccessToken(`Bearer ${jwt}`)).toBe(jwt);
    expect(extractAccessToken("")).toBe("");
    expect(
      extractSession(
        `https://audio-reader-admin.pages.dev/#access_token=${jwt}&refresh_token=rt-admin-1&type=magiclink`,
      ),
    ).toEqual({ accessToken: jwt, refreshToken: "rt-admin-1" });
    expect(
      extractSession(
        `https://audio-reader-admin.pages.dev/?access_token=${jwt}&refresh_token=rt-query-1&type=magiclink`,
      ),
    ).toEqual({ accessToken: jwt, refreshToken: "rt-query-1" });
    expect(extractSession(`#refresh_token=rt-only`)).toBeNull();
    expect(hrefCarriesSessionTokens(`https://admin.example/#refresh_token=rt-admin-1`)).toBe(true);
    expect(hrefCarriesSessionTokens("https://audio-reader-admin.pages.dev/")).toBe(false);
  });

  it("does not treat the operator portal URL as a signed-in session", () => {
    expect(extractAccessToken("https://audio-reader-admin.pages.dev/")).toBe("");
    expect(extractAccessToken("https://audio-reader-admin.pages.dev/index.html")).toBe("");
    expect(extractAccessToken("http://localhost:5173/")).toBe("");
    expect(
      extractAccessToken("https://feature-cross-device-multi-u.audio-reader-admin.pages.dev"),
    ).toBe("");
  });
});
