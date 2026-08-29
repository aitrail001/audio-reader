import { describe, expect, it } from "vitest";
import {
  destinationQuery,
  initialOperatorLocation,
  mutationSummary,
  policyDraftErrors,
  quotaReductionNeedsConfirmation,
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
});

describe("safe mutations", () => {
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
});
