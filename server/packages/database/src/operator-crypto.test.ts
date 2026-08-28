import { describe, expect, it } from "vitest";
import { decryptOperatorSecrets, encryptOperatorSecrets } from "./operator-crypto";

describe("operator settings crypto", () => {
  it("round-trips secrets without storing plaintext JSON", async () => {
    const cipher = await encryptOperatorSecrets("wrapping-secret", {
      qwenApiKey: "sk-live-secret",
      gcsServiceAccountJson: '{"client_email":"sa@example.com"}',
      turnstileSecret: "0xturnstile",
    });
    expect(cipher.ciphertext).not.toContain("sk-live-secret");
    expect(cipher.ciphertext).not.toContain("sa@example.com");
    await expect(decryptOperatorSecrets("wrapping-secret", cipher)).resolves.toEqual({
      qwenApiKey: "sk-live-secret",
      gcsServiceAccountJson: '{"client_email":"sa@example.com"}',
      turnstileSecret: "0xturnstile",
    });
  });

  it("rejects a different wrapping secret", async () => {
    const cipher = await encryptOperatorSecrets("wrapping-secret", {
      qwenApiKey: "sk-live-secret",
    });
    await expect(decryptOperatorSecrets("other-secret", cipher)).rejects.toThrow();
  });
});
