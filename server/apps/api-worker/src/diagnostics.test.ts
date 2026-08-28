import { DEFAULT_ASSISTANT_PROMPTS } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { diagnosticNotes, formatQwenProbe, resolveTaskModel } from "./diagnostics";
import type { RuntimeConfigView } from "./runtime-config";

function runtime(overrides: Partial<RuntimeConfigView["qwen"]> = {}): RuntimeConfigView {
  return {
    qwen: {
      apiKeyConfigured: true,
      apiKeyLast4: "cret",
      baseUrl: "https://example.invalid/v1",
      model: "qwen3.7-flash",
      source: "admin",
      ciphertextPresent: true,
      secretsDecryptable: true,
      wrappingSecretConfigured: true,
      wrappingSecretSource: "operator_config_key",
      ...overrides,
    },
    storage: {
      provider: "none",
      serviceAccountConfigured: false,
      source: "none",
    },
    turnstile: { configured: false, source: "none" },
    bootstrap: {
      supabaseUrlConfigured: true,
      supabaseAnonKeyConfigured: true,
      supabaseServiceRoleConfigured: true,
      cacheHmacConfigured: true,
      operatorConfigKeyConfigured: true,
      adminBootstrapEmailConfigured: true,
      resendConfigured: true,
      otpFromConfigured: true,
      qwenEnvKeyConfigured: false,
    },
  };
}

describe("operator diagnostics helpers", () => {
  it("lets an enabled policy model override the Desk model", () => {
    expect(
      resolveTaskModel(
        [{ task: "translation", enabled: true, model: "qwen3.7-plus" }],
        "translation",
        "qwen3.7-flash",
      ),
    ).toEqual({
      disabled: false,
      model: "qwen3.7-plus",
      source: "policy",
      promptVersion: "qwen-managed-v1",
      systemPrompt: DEFAULT_ASSISTANT_PROMPTS.translation,
    });
  });

  it("treats a task as disabled when every matching policy is off", () => {
    expect(
      resolveTaskModel(
        [{ task: "chat", enabled: false, model: "qwen3.7-plus" }],
        "chat",
        "qwen3.7-flash",
      ),
    ).toEqual({
      disabled: true,
      model: "qwen3.7-flash",
      source: "desk",
      promptVersion: "qwen-managed-v1",
      systemPrompt: DEFAULT_ASSISTANT_PROMPTS.chat,
    });
  });

  it("formats probe failures with HTTP status and omits empty detail", () => {
    expect(formatQwenProbe({ status: "ok", httpStatus: 200 })).toBe("ok (HTTP 200)");
    expect(formatQwenProbe({ status: "unavailable", httpStatus: 401, detail: "invalid key" })).toBe(
      "unavailable HTTP 401: invalid key",
    );
  });

  it("warns when Desk secrets cannot be decrypted or a policy overrides the model", () => {
    const notes = diagnosticNotes({
      runtime: runtime({ secretsDecryptable: false, apiKeyConfigured: false, source: "none" }),
      flags: [{ key: "managed_qwen", enabled: true }],
      quotas: [],
      policies: [
        {
          id: "00000000-0000-4000-8000-0000000000aa",
          task: "translation",
          region: "ap-southeast-1",
          model: "qwen3.7-plus",
          promptVersion: "v1",
          systemPrompt: DEFAULT_ASSISTANT_PROMPTS.translation,
          schemaVersion: "1",
          policyVersion: "1",
          enabled: true,
          createdAt: "2026-08-28T00:00:00.000Z",
          updatedAt: "2026-08-28T00:00:00.000Z",
        },
      ],
      qwenProbe: "unavailable HTTP 401",
    });
    expect(notes.some((note) => note.includes("could not be decrypted"))).toBe(true);
    expect(notes.some((note) => note.includes("No Qwen API key"))).toBe(true);
    expect(notes.some((note) => note.includes("overrides Desk model"))).toBe(true);
    expect(notes.some((note) => note.includes("No quotas loaded"))).toBe(true);
  });
});
