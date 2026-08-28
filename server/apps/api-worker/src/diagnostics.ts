import type { components } from "@audio-reader/contract";
import { defaultAssistantPrompt } from "@audio-reader/database";
import type { QwenClient, QwenPingDetail } from "@audio-reader/qwen";
import { listOperatorEvents } from "./operator-events";
import { hostOf, type RuntimeConfigView } from "./runtime-config";

type FeatureFlag = components["schemas"]["FeatureFlag"];
type Quota = components["schemas"]["Quota"];
type LlmPolicy = components["schemas"]["LlmPolicy"];
type OperatorDiagnostics = components["schemas"]["OperatorDiagnostics"];
type QwenCompleteProbe = components["schemas"]["QwenCompleteProbe"];

export type TaskPolicyInput = {
  task: string;
  enabled: boolean;
  model: string;
  promptVersion?: string;
  systemPrompt?: string;
  canaryPercent?: number;
};

export type TaskModelResolution = {
  disabled: boolean;
  model: string;
  source: "policy" | "desk";
  promptVersion: string;
  systemPrompt: string;
};

export function canaryBucket(accountId: string, task: string): number {
  const material = `${accountId}:${task}`;
  let hash = 2166136261;
  for (let index = 0; index < material.length; index += 1) {
    hash ^= material.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0) % 100;
}

export function resolveTaskModel(
  policies: readonly TaskPolicyInput[],
  task: string,
  deskModel: string,
  options: { accountId?: string } = {},
): TaskModelResolution {
  const matching = policies.filter((policy) => policy.task === task);
  const enabled = matching.find((policy) => policy.enabled);
  const promptVersion = enabled?.promptVersion?.trim() || "qwen-managed-v1";
  const systemPrompt = enabled?.systemPrompt?.trim() || defaultAssistantPrompt(task);
  if (matching.length > 0 && matching.every((policy) => !policy.enabled)) {
    return {
      disabled: true,
      model: deskModel,
      source: "desk",
      promptVersion,
      systemPrompt: defaultAssistantPrompt(task),
    };
  }
  const policyModel = enabled?.model.trim() ?? "";
  const desk = deskModel.trim();
  const canary = enabled?.canaryPercent ?? 0;
  const usePolicy = shouldUsePolicyModel(policyModel, desk, canary, options.accountId, task);
  const model = usePolicy ? policyModel : desk || policyModel;
  return {
    disabled: false,
    model,
    source: usePolicy && policyModel !== "" ? "policy" : "desk",
    promptVersion,
    systemPrompt,
  };
}

function shouldUsePolicyModel(
  policyModel: string,
  desk: string,
  canaryPercent: number,
  accountId: string | undefined,
  task: string,
): boolean {
  if (policyModel === "") {
    return false;
  }
  if (canaryPercent <= 0) {
    return desk === "";
  }
  if (canaryPercent >= 100) {
    return true;
  }
  const id = accountId?.trim() ?? "";
  if (id === "") {
    return true;
  }
  return canaryBucket(id, task) < canaryPercent;
}

export function formatQwenProbe(detail: QwenPingDetail): string {
  if (detail.status === "ok") {
    return detail.httpStatus === undefined ? "ok" : `ok (HTTP ${String(detail.httpStatus)})`;
  }
  const status = detail.httpStatus === undefined ? "" : ` HTTP ${String(detail.httpStatus)}`;
  const extra = detail.detail === undefined || detail.detail === "" ? "" : `: ${detail.detail}`;
  return `${detail.status}${status}${extra}`.slice(0, 280);
}

export function diagnosticNotes(input: {
  runtime: RuntimeConfigView;
  flags: readonly FeatureFlag[];
  quotas: readonly Quota[];
  policies: readonly LlmPolicy[];
  qwenProbe: string;
  qwenComplete?: QwenCompleteProbe;
}): string[] {
  const notes: string[] = [];
  const { runtime } = input;
  if (!runtime.qwen.secretsDecryptable) {
    notes.push(
      "Saved operator secrets could not be decrypted. The Desk Qwen key is not what the Worker uses. Set OPERATOR_CONFIG_KEY (or CACHE_HMAC_SECRET) to the wrapping secret that encrypted the row.",
    );
  }
  if (!runtime.qwen.apiKeyConfigured) {
    notes.push(
      "No Qwen API key is active. Paste a key on Desk and save, or set Worker secret QWEN_API_KEY.",
    );
  }
  if (runtime.qwen.ciphertextPresent && runtime.qwen.source !== "admin") {
    notes.push(
      `Operator ciphertext is present but the active Qwen key source is ${runtime.qwen.source}. Decrypt may have failed, or the row has no Qwen key.`,
    );
  }
  if (!runtime.qwen.wrappingSecretConfigured || runtime.qwen.wrappingSecretSource === "none") {
    notes.push(
      "Operator wrapping key is the local-dev fallback. Set OPERATOR_CONFIG_KEY (preferred) or CACHE_HMAC_SECRET on the Worker.",
    );
  } else if (
    runtime.qwen.wrappingSecretSource === "cache_hmac" &&
    !runtime.bootstrap.operatorConfigKeyConfigured
  ) {
    notes.push(
      "Operator wrapping uses CACHE_HMAC_SECRET because OPERATOR_CONFIG_KEY is unset. Changing CACHE_HMAC_SECRET will make saved Desk secrets unreadable.",
    );
  }
  if (runtime.qwen.baseUrl.trim() === "") {
    notes.push(
      "Qwen base URL is empty; the Worker will use the package default Singapore endpoint.",
    );
  }
  if (runtime.qwen.model.trim() === "") {
    notes.push(
      "Desk Qwen model is empty; completions use the package default unless a policy sets a model.",
    );
  }
  const managed = input.flags.find((flag) => flag.key === "managed_qwen");
  if (managed !== undefined && !managed.enabled) {
    notes.push(
      "Feature flag managed_qwen is off. The app will get 403 until you enable it under Flags.",
    );
  }
  const maintenance = input.flags.find((flag) => flag.key === "maintenance_mode");
  if (maintenance?.enabled === true) {
    notes.push("Feature flag maintenance_mode is on. Managed Qwen returns 503.");
  }
  if (input.quotas.length === 0) {
    notes.push(
      "No quotas loaded. Apply supabase migration 20260828130000_quota_limits.sql, or the Worker is using an empty fallback.",
    );
  }
  for (const task of ["translation", "chapter_summary", "chat"]) {
    const resolved = resolveTaskModel(input.policies, task, runtime.qwen.model);
    if (resolved.disabled) {
      notes.push(
        `All ${task} policies are disabled. The app cannot call managed Qwen for ${task}.`,
      );
    } else if (
      resolved.source === "desk" &&
      runtime.qwen.model !== "" &&
      (input.policies.find((policy) => policy.task === task && policy.enabled)?.model ?? "") !==
        "" &&
      input.policies.find((policy) => policy.task === task && policy.enabled)?.model !==
        runtime.qwen.model
    ) {
      notes.push(
        `Desk model ${runtime.qwen.model} is live for ${task}. Policy model ${
          input.policies.find((policy) => policy.task === task && policy.enabled)?.model ?? ""
        } applies when canary is 100 or the account is in the canary bucket.`,
      );
    }
  }
  if (!input.qwenProbe.startsWith("ok") && runtime.qwen.apiKeyConfigured) {
    notes.push(
      `Qwen /models probe failed (${input.qwenProbe}). Completions will fail until this is reachable.`,
    );
  }
  if (
    input.qwenComplete !== undefined &&
    input.qwenComplete.status !== "ok" &&
    input.qwenComplete.status !== "skipped"
  ) {
    const extra =
      input.qwenComplete.detail === undefined || input.qwenComplete.detail === ""
        ? ""
        : ` ${input.qwenComplete.detail}`;
    notes.push(
      `Qwen completion probe ${input.qwenComplete.status} using ${input.qwenComplete.model ?? "default"}${input.qwenComplete.httpStatus === undefined ? "" : ` (HTTP ${String(input.qwenComplete.httpStatus)})`}.${extra}`,
    );
  }
  return notes;
}

export async function buildOperatorDiagnostics(input: {
  runtime: RuntimeConfigView;
  flags: FeatureFlag[];
  quotas: Quota[];
  policies: LlmPolicy[];
  qwen: QwenClient;
  probeComplete: boolean;
  requestId: string;
}): Promise<OperatorDiagnostics> {
  const ping = await input.qwen.pingDetailed();
  const qwenProbe = formatQwenProbe(ping);
  const translation = resolveTaskModel(input.policies, "translation", input.runtime.qwen.model);
  let qwenComplete: QwenCompleteProbe = { status: "skipped" };
  if (input.probeComplete) {
    qwenComplete = await probeCompletion(
      input.qwen,
      translation,
      input.runtime.qwen.apiKeyConfigured,
    );
  }
  const notes = diagnosticNotes({
    runtime: input.runtime,
    flags: input.flags,
    quotas: input.quotas,
    policies: input.policies,
    qwenProbe,
    qwenComplete,
  });
  console.warn(
    JSON.stringify({
      level: "warn",
      message: "operator_diagnostics",
      requestId: input.requestId,
      qwenConfigured: input.runtime.qwen.apiKeyConfigured,
      qwenSource: input.runtime.qwen.source,
      qwenModel: input.runtime.qwen.model,
      qwenBaseUrlHost: hostOf(input.runtime.qwen.baseUrl),
      wrappingSource: input.runtime.qwen.wrappingSecretSource,
      secretsDecryptable: input.runtime.qwen.secretsDecryptable,
      ciphertextPresent: input.runtime.qwen.ciphertextPresent,
      qwenProbe,
      qwenCompleteStatus: qwenComplete.status,
      flagCount: input.flags.length,
      quotaCount: input.quotas.length,
      policyCount: input.policies.length,
      notes,
    }),
  );
  return {
    runtime: input.runtime,
    flags: input.flags,
    quotas: input.quotas,
    policies: input.policies,
    qwenProbe,
    notes,
    qwenComplete,
    recentEvents: listOperatorEvents({ limit: 12 }),
  };
}

async function probeCompletion(
  qwen: QwenClient,
  translation: TaskModelResolution,
  apiKeyConfigured: boolean,
): Promise<QwenCompleteProbe> {
  if (!apiKeyConfigured) {
    return { status: "no_key", model: translation.model };
  }
  if (translation.disabled) {
    return { status: "policy_disabled", model: translation.model };
  }
  const completed = await qwen.complete({
    messages: [{ role: "user", content: "Reply with the single word pong." }],
    ...(translation.model === "" ? {} : { model: translation.model }),
  });
  if (completed.ok) {
    return { status: "ok", model: completed.model };
  }
  return {
    status: completed.code,
    ...(completed.httpStatus === undefined ? {} : { httpStatus: completed.httpStatus }),
    model: completed.usedModel,
    ...(completed.detail === undefined || completed.detail === ""
      ? {}
      : { detail: completed.detail }),
  };
}
