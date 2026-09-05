import {
  DEFAULT_ASSISTANT_PROMPTS,
  DEFAULT_ASSISTANT_USER_PROMPTS,
  createFakeDatabaseClient,
} from "@audio-reader/database";
import { createFakeQwenClient } from "@audio-reader/qwen";
import { describe, expect, it } from "vitest";
import {
  buildOperatorDiagnostics,
  diagnosticNotes,
  formatQwenProbe,
  resolveTaskModel,
} from "./diagnostics";
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
      credentialsConfigured: false,
      serviceAccountConfigured: false,
      source: "none",
    },
    turnstile: { configured: false, source: "none" },
    assistant: { sentenceTranslationBatchSize: 5 },
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
  it("uses Desk when canary is 0 and a Desk model is set", () => {
    expect(
      resolveTaskModel(
        [{ task: "translation", enabled: true, model: "qwen3.7-plus", canaryPercent: 0 }],
        "translation",
        "qwen3.7-flash",
      ),
    ).toEqual({
      disabled: false,
      model: "qwen3.7-flash",
      source: "desk",
      promptVersion: "qwen-managed-v1",
      schemaVersion: "1",
      systemPrompt: DEFAULT_ASSISTANT_PROMPTS.translation,
      userPrompt: DEFAULT_ASSISTANT_USER_PROMPTS.translation,
    });
  });

  it("uses the policy model for a full canary", () => {
    expect(
      resolveTaskModel(
        [{ task: "translation", enabled: true, model: "qwen3.7-plus", canaryPercent: 100 }],
        "translation",
        "qwen3.7-flash",
      ),
    ).toEqual({
      disabled: false,
      model: "qwen3.7-plus",
      source: "policy",
      promptVersion: "qwen-managed-v1",
      schemaVersion: "1",
      systemPrompt: DEFAULT_ASSISTANT_PROMPTS.translation,
      userPrompt: DEFAULT_ASSISTANT_USER_PROMPTS.translation,
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
      schemaVersion: "1",
      systemPrompt: DEFAULT_ASSISTANT_PROMPTS.chat,
      userPrompt: DEFAULT_ASSISTANT_USER_PROMPTS.chat,
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
          userPrompt: DEFAULT_ASSISTANT_USER_PROMPTS.translation,
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
    expect(notes.some((note) => note.includes("Desk model qwen3.7-flash is live"))).toBe(true);
    expect(notes.some((note) => note.includes("No quotas loaded"))).toBe(true);
  });
});

describe("operator diagnostics cache notes", () => {
  it("tells operators which routes fill the shared cache", async () => {
    const database = createFakeDatabaseClient();
    const diagnostics = await buildOperatorDiagnostics({
      runtime: runtime(),
      flags: [{ key: "managed_qwen", enabled: true }],
      quotas: [],
      policies: [],
      qwen: createFakeQwenClient(),
      probeComplete: false,
      requestId: "diag-cache",
      ops: database.ops,
    });
    expect(diagnostics.notes.some((note) => note.includes("POST /v1/ai/translation-batches"))).toBe(
      true,
    );
    expect(diagnostics.notes.some((note) => note.includes("POST /v1/ai/chat does not write"))).toBe(
      true,
    );
  });

  it("does not treat populated cache or product-event counts as configuration drift", async () => {
    const database = createFakeDatabaseClient();
    await database.ops.putCache({
      id: "00000000-0000-4000-8000-0000000000c1",
      cacheKey: "ck-populated",
      task: "translation",
      state: "active",
      sourceLanguage: "en",
      targetLanguage: "zh",
      editionFingerprint: "ed-1",
      policyVersion: "qwen-managed-v1",
      payload: { translation: "你好" },
    });
    const diagnostics = await buildOperatorDiagnostics({
      runtime: runtime(),
      flags: [{ key: "managed_qwen", enabled: true }],
      quotas: [{ key: "qwen_tasks_day", used: 0, limit: 50, periodEndsAt: "9999-12-31T23:59:59.000Z" }],
      policies: [],
      qwen: createFakeQwenClient(),
      probeComplete: false,
      requestId: "diag-populated-cache",
      ops: database.ops,
    });
    expect(diagnostics.notes.some((note) => note.includes("visible to admin"))).toBe(false);
    expect(diagnostics.notes.some((note) => note.includes("product_events"))).toBe(false);
    expect(diagnostics.notes.some((note) => note.includes("POST /v1/ai/translation-batches"))).toBe(
      false,
    );
  });
});
