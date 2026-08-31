import { LOCAL_PASSWORDLESS_HMAC_SECRET } from "@audio-reader/auth";
import { createFakeDatabaseClient, encryptOperatorSecrets } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { OperatorWrappingNotConfiguredError, createRuntimeConfigService } from "./runtime-config";

describe("runtime config wrapping", () => {
  it("fails storage resolution closed when hosted Operator settings cannot be read", async () => {
    const database = createFakeDatabaseClient();
    Object.assign(database.ops, {
      readOperatorSettings: () => Promise.resolve({ ok: false, error: "unavailable" } as const),
    });
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    await expect(runtime.resolveStorage({ useFakes: false })).rejects.toThrow(
      "operator_settings_unavailable",
    );
  });

  it("does not infer Supabase Storage from database credentials alone", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    await expect((await runtime.resolveStorage({ useFakes: false })).store.ping()).resolves.toBe(
      "unavailable",
    );
    await expect(runtime.view()).resolves.toMatchObject({ storage: { provider: "none" } });
  });

  it("selects an explicit Supabase bucket ahead of malformed GCS configuration", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        GCS_BUCKET: "selected-gcs",
        GCS_SERVICE_ACCOUNT_JSON: "{malformed",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
        SUPABASE_STORAGE_BUCKET: "selected-supabase",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    const resolved = await runtime.resolveStorage({ useFakes: false });
    expect(resolved.descriptor).toMatchObject({
      provider: "supabase",
      bucket: "selected-supabase",
      credentialsConfigured: true,
    });
    await expect(runtime.view()).resolves.toMatchObject({
      storage: {
        provider: "supabase",
        bucket: "selected-supabase",
        credentialsConfigured: true,
        source: "env",
      },
    });
  });

  it("does not read or decrypt stale saved GCS settings for explicit Supabase storage", async () => {
    const database = createFakeDatabaseClient();
    const cipher = await encryptOperatorSecrets("old-wrapping-secret", {
      gcsServiceAccountJson: '{"stale":"gcs"}',
    });
    await database.ops.putOperatorSettings({
      id: "default",
      payload: { gcsBucket: "stale-gcs" },
      ciphertext: cipher.ciphertext,
      nonce: cipher.nonce,
      updatedBy: "00000000-0000-4000-8000-000000000002",
    });
    const readOperatorSettings = database.ops.readOperatorSettings.bind(database.ops);
    let settingsReads = 0;
    Object.assign(database.ops, {
      readOperatorSettings: () => {
        settingsReads += 1;
        return readOperatorSettings();
      },
    });
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
        SUPABASE_STORAGE_BUCKET: "supabase-assets",
      },
      ops: database.ops,
      wrappingSecret: "new-wrapping-secret",
    });

    const resolved = await runtime.resolveStorage({ useFakes: false });
    expect(resolved.descriptor).toMatchObject({
      provider: "supabase",
      bucket: "supabase-assets",
      credentialsConfigured: true,
    });
    expect(settingsReads).toBe(0);
  });

  it("plumbs an explicit custom Supabase signed-upload TTL into storage capability", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        SUPABASE_URL: "https://storage.example.com",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
        SUPABASE_STORAGE_BUCKET: "supabase-assets",
        SUPABASE_STORAGE_SIGNED_UPLOAD_TTL_SECONDS: "600",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    const resolved = await runtime.resolveStorage({ useFakes: false });
    await expect(resolved.store.supportsBoundUpload()).resolves.toBe(true);
  });

  it("preserves GCS selection when no Supabase bucket is explicit", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        GCS_BUCKET: "selected-gcs",
        GCS_SERVICE_ACCOUNT_JSON: "{malformed",
        SUPABASE_URL: "https://example.supabase.co",
        SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    const resolved = await runtime.resolveStorage({ useFakes: false });
    expect(resolved.descriptor).toMatchObject({
      provider: "gcs",
      bucket: "selected-gcs",
      credentialsConfigured: false,
    });
    await expect(resolved.store.ping()).resolves.toBe("unavailable");
  });

  it("selects an R2 binding but fails credentials closed without scoped privacy proof", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: {
        ENVIRONMENT: "production",
        ASSETS: {} as R2Bucket,
      },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });

    await expect(runtime.resolveStorage({ useFakes: false })).resolves.toMatchObject({
      descriptor: {
        provider: "r2",
        credentialsConfigured: false,
      },
    });
  });

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

  it("persists Managed Qwen sentence context count on the public payload", async () => {
    const database = createFakeDatabaseClient();
    const runtime = createRuntimeConfigService({
      env: { ENVIRONMENT: "test" },
      ops: database.ops,
      wrappingSecret: "test-operator-secret-key",
    });
    expect((await runtime.view()).assistant.sentenceContextCount).toBe(1);
    const saved = await runtime.put(
      { assistant: { sentenceContextCount: 3 } },
      "00000000-0000-4000-8000-000000000002",
    );
    expect(saved.assistant.sentenceContextCount).toBe(3);
    expect((await runtime.view()).assistant.sentenceContextCount).toBe(3);
  });
});
