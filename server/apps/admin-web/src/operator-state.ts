import type { PolicyDraft, Section } from "./types";

const SECTION_IDS = new Set<Section>([
  "overview",
  "users",
  "access",
  "privacy",
  "policies",
  "cache",
  "jobs",
  "flags",
  "quotas",
  "metrics",
  "usage",
  "trace",
  "audit",
]);

export const FILTER_KEYS = [
  "userQuery",
  "jobStatus",
  "cacheState",
  "cacheTask",
  "cacheFingerprint",
  "auditActor",
  "auditAction",
  "auditRequestId",
  "eventRequestId",
  "eventKind",
  "eventTask",
  "usageName",
  "usageAccountId",
  "usageRequestId",
  "privacyStatus",
  "metricsCountry",
  "metricsFrom",
  "metricsTo",
  "metricsLanguage",
  "metricsReaderLevel",
  "metricsPlatform",
  "metricsFeature",
  "metricsContentCategory",
] as const;

export type OperatorFilters = Partial<Record<(typeof FILTER_KEYS)[number], string>>;

export type AdminLoadIdentity = { accessToken: string; generation: number };

/** Async Operator responses may update privileged state only for the session generation that made them. */
export function isCurrentAdminLoad(request: AdminLoadIdentity, active: AdminLoadIdentity): boolean {
  return request.accessToken === active.accessToken && request.generation === active.generation;
}

/** URL state intentionally excludes secrets and mutation reasons. */
export function initialOperatorLocation(search: string): {
  section: Section;
  filters: OperatorFilters;
} {
  const params = new URLSearchParams(search);
  const candidate = params.get("section") as Section | null;
  const filters: OperatorFilters = {};
  for (const key of FILTER_KEYS) {
    const value = params.get(key)?.trim() ?? "";
    if (value !== "") {
      filters[key] = value;
    }
  }
  return {
    section: candidate !== null && SECTION_IDS.has(candidate) ? candidate : "overview",
    filters,
  };
}

export function destinationQuery(section: Section, filters: OperatorFilters): URLSearchParams {
  const params = new URLSearchParams({ section });
  for (const key of FILTER_KEYS) {
    const value = filters[key]?.trim() ?? "";
    if (value !== "") {
      params.set(key, value);
    }
  }
  return params;
}

export function mutationSummary(label: string, before: string, after: string): string {
  return `${label}: ${before} → ${after}`;
}

export function quotaReductionNeedsConfirmation(before: number, after: number): boolean {
  return before > 0 && after <= before * 0.5;
}

export function policyDraftErrors(draft: PolicyDraft): Record<string, string> {
  const errors: Record<string, string> = {};
  if (draft.model.trim() === "") errors.model = "Model is required.";
  if (draft.promptVersion.trim() === "") errors.promptVersion = "Prompt version is required.";
  if (draft.schemaVersion.trim() === "") {
    errors.schemaVersion = "Schema version is required.";
  } else if (draft.schemaVersion.trim() !== "1") {
    errors.schemaVersion = "Only schema version 1 is supported.";
  }
  const allowed = new Set([
    "task",
    "source",
    "context",
    "segments",
    "question",
    "chapterId",
    "bookTitle",
    "author",
    "chapterTitle",
    "sourceLanguage",
    "targetLanguage",
    "learnerLevel",
  ]);
  for (const match of draft.userPrompt.matchAll(/\{\{\s*([^{}]+?)\s*\}\}/g)) {
    const name = match[1]?.trim() ?? "";
    if (!allowed.has(name)) {
      errors.userPrompt = `Unknown placeholder: {{${name}}}.`;
      break;
    }
  }
  validateInt(errors, "maxInputTokens", draft.maxInputTokens, 1, 1_000_000);
  validateInt(errors, "maxOutputTokens", draft.maxOutputTokens, 1, 1_000_000);
  validateInt(errors, "timeoutMs", draft.timeoutMs, 1_000, 300_000);
  validateInt(errors, "canaryPercent", draft.canaryPercent, 0, 100);
  return errors;
}

function validateInt(
  errors: Record<string, string>,
  field: string,
  value: string,
  min: number,
  max: number,
): void {
  const number = Number(value);
  if (!Number.isInteger(number) || number < min || number > max) {
    errors[field] = `Enter a whole number from ${String(min)} to ${String(max)}.`;
  }
}
