import { LOCAL_PASSWORDLESS_HMAC_SECRET } from "@audio-reader/auth";
import { createFakeDatabaseClient, encryptOperatorSecrets } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { OperatorWrappingNotConfiguredError, createRuntimeConfigService } from "./runtime-config";

describe("runtime config wrapping", () => {
  it("marks saved secrets undecryptable when the wrapping key changed", async () => {
    const database = createFakeDatabaseClient();
    const cipher = await encryptOperatorSecrets("old-wrapping-secret", {
      qwenApiKey: "sk-live-secret",
    });
    await database.ops.putOperatorSettings({
      id: "default",
      payload: { qwenModel: "qwen3.7-flash", qwenBaseUrl: "https://example.invalid/v1" },
      ciphertext: cipher.ciphertext,
      nonce: cipher.nonce,
      updatedBy: "00000000-0000-4000-8000-000000000002",
    });
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "test" },
      ops: database.ops,
      wrappingSecret: "new-wrapping-secret",
      wrappingSource: "operator_config_key",
    });
    const view = await runtime.view();
    expect(view.qwen.ciphertextPresent).toBe(true);
    expect(view.qwen.secretsDecryptable).toBe(false);
    expect(view.qwen.apiKeyConfigured).toBe(false);
    expect(view.qwen.source).toBe("none");
    expect(view.qwen.model).toBe("qwen3.7-flash");
    expect(view.qwen.wrappingSecretSource).toBe("operator_config_key");
    expect(JSON.stringify(view)).not.toContain("sk-live-secret");
  });

  it("does not fall back to env Qwen secrets when ciphertext cannot be decrypted", async () => {
    const database = createFakeDatabaseClient();
    const cipher = await encryptOperatorSecrets("old-wrapping-secret", {
      qwenApiKey: "sk-live-secret",
    });
    await database.ops.putOperatorSettings({
      id: "default",
      payload: { qwenModel: "qwen3.7-flash" },
      ciphertext: cipher.ciphertext,
      nonce: cipher.nonce,
      updatedBy: "00000000-0000-4000-8000-000000000002",
    });
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "production", QWEN_API_KEY: "sk-env-fallback" },
      ops: database.ops,
      wrappingSecret: "new-wrapping-secret",
      wrappingSource: "operator_config_key",
    });
    await expect(runtime.resolveQwen()).resolves.toBeUndefined();
    const view = await runtime.view();
    expect(view.qwen.apiKeyConfigured).toBe(false);
    expect(view.qwen.source).toBe("none");
    expect(JSON.stringify(view)).not.toContain("sk-env-fallback");
  });

  it("refuses to encrypt operator secrets with the local-dev wrapping pepper", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "production" },
      ops: database.ops,
      wrappingSecret: LOCAL_PASSWORDLESS_HMAC_SECRET,
      wrappingSource: "none",
    });
    await expect(
      runtime.put(
        { qwen: { apiKey: "sk-should-not-wrap" } },
        "00000000-0000-4000-8000-000000000002",
      ),
    ).rejects.toBeInstanceOf(OperatorWrappingNotConfiguredError);
  });
});
