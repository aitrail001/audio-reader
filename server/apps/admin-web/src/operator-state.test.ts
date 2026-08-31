import { describe, expect, it } from "vitest";
import {
  destinationQuery,
  initialOperatorLocation,
  mutationSummary,
  policyDraftErrors,
  quotaReductionNeedsConfirmation,
  isCurrentAdminLoad,
  canToggleAccountSync,
} from "./operator-state";

describe("operator URL state", () => {
  it("restores the destination and known filters from a shareable URL", () => {
    expect(
      initialOperatorLocation("?section=audit&auditActor=admin-1&auditAction=policy.patch"),
    ).toMatchObject({
      section: "audit",
      filters: { auditActor: "admin-1", auditAction: "policy.patch" },
    });
  });

  it("serializes only non-empty destination filters", () => {
    expect(
      destinationQuery("usage", {
        usageName: "ai.translation.*",
        usageAccountId: "",
        usageRequestId: "req-7",
      }).toString(),
    ).toBe("section=usage&usageName=ai.translation.*&usageRequestId=req-7");
  });

  it("round trips privacy-safe analytics filters", () => {
    const search = destinationQuery("metrics", {
      metricsFrom: "2026-08-01T00:00",
      metricsTo: "2026-08-31T00:00",
      metricsCountry: "AU",
      metricsLanguage: "zh-Hans",
      metricsReaderLevel: "intermediate",
      metricsPlatform: "macos",
      metricsFeature: "review",
      metricsContentCategory: "fiction",
    }).toString();
    expect(initialOperatorLocation(`?${search}`)).toMatchObject({
      section: "metrics",
      filters: {
        metricsFrom: "2026-08-01T00:00",
        metricsTo: "2026-08-31T00:00",
        metricsCountry: "AU",
        metricsLanguage: "zh-Hans",
        metricsReaderLevel: "intermediate",
        metricsPlatform: "macos",
        metricsFeature: "review",
        metricsContentCategory: "fiction",
      },
    });
  });
});

describe("safe mutations", () => {
  it("prevents enabling account sync until storage is ready but still allows requested-on to be disabled", () => {
    expect(canToggleAccountSync({ enabled: false }, { ready: false })).toBe(false);
    expect(canToggleAccountSync({ enabled: false }, { ready: true })).toBe(true);
    expect(canToggleAccountSync({ enabled: true }, { ready: false })).toBe(true);
  });

  it("summarizes before and after values without exposing secret input", () => {
    expect(mutationSummary("Managed Qwen", "enabled", "disabled")).toBe(
      "Managed Qwen: enabled → disabled",
    );
  });

  it("requires confirmation for reductions of at least 50 percent", () => {
    expect(quotaReductionNeedsConfirmation(100, 50)).toBe(true);
    expect(quotaReductionNeedsConfirmation(100, 51)).toBe(false);
  });

  it("validates policy contract fields inline", () => {
    const errors = policyDraftErrors({
      model: "",
      promptVersion: "v2",
      systemPrompt: "Return JSON.",
      userPrompt: "Translate {{source}}.",
      schemaVersion: "",
      maxInputTokens: "0",
      maxOutputTokens: "-1",
      timeoutMs: "999",
      canaryPercent: "101",
    });
    expect(errors.model).toBe("Model is required.");
    expect(errors.schemaVersion).toBe("Schema version is required.");
  });

  it("rejects unsupported schemas and unknown prompt placeholders inline", () => {
    const errors = policyDraftErrors({
      model: "qwen3.7-flash",
      promptVersion: "v2",
      systemPrompt: "Return JSON.",
      userPrompt: "Translate {{ source }} with {{hiddenInstruction}}.",
      schemaVersion: "2",
      maxInputTokens: "8000",
      maxOutputTokens: "2000",
      timeoutMs: "30000",
      canaryPercent: "100",
    });
    expect(errors.schemaVersion).toBe("Only schema version 1 is supported.");
    expect(errors.userPrompt).toContain("hiddenInstruction");
  });
});

describe("admin session transitions", () => {
  it("rejects a response ticket after the access token generation changes", () => {
    const request = { accessToken: "token-a", generation: 7 };
    expect(isCurrentAdminLoad(request, { accessToken: "token-a", generation: 7 })).toBe(true);
    expect(isCurrentAdminLoad(request, { accessToken: "token-b", generation: 8 })).toBe(false);
    expect(isCurrentAdminLoad(request, { accessToken: "token-a", generation: 8 })).toBe(false);
  });
});
