import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = dirname(fileURLToPath(import.meta.url));
const source = ["app.tsx", "api.ts", "operator-table.tsx"]
  .map((name) => readFileSync(join(root, name), "utf8"))
  .join("\n");
const normalizedSource = source.replace(/\s+/g, " ");

describe("operator console coverage", () => {
  it("calls every admin management route", () => {
    const routes = [
      "/v1/health",
      "/v1/auth/config",
      "/v1/auth/email-otp/request",
      "/v1/auth/token/refresh",
      "/v1/auth/logout",
      "/v1/admin/runtime-config",
      "/v1/admin/capabilities",
      "/v1/admin/users",
      "/progress",
      "/suspend",
      "/unsuspend",
      "/revoke-sessions",
      "/grant-admin",
      "/v1/admin/llm/policies",
      "/v1/admin/jobs",
      "/retry",
      "/cancel",
      "/v1/admin/cache",
      "/actions",
      "/v1/admin/metrics",
      "/v1/admin/product-analytics",
      "/v1/admin/audit-events",
      "/v1/admin/auth/blocked-attempts",
      "/v1/admin/feature-flags",
      "/v1/admin/quotas",
      "/v1/admin/privacy-requests",
      "/v1/admin/diagnostics",
      "probe=complete",
      "systemPrompt",
      "userPrompt",
      "/v1/admin/events",
      "/v1/admin/product-events",
      "VITE_ADMIN_VERSION",
      "Operator console",
      "Activity",
      "User activity",
      "ai. or account.signed_in",
      "ai.translation.cached",
      "ai.chat.*",
      "Shared AI cache",
      "Source passages, private notes, chat",
      "prose-block",
      "cell-clip",
      "row-open",
      "prose-pair",
      "Last hit",
      "Translation",
      "Account id",
      'label="account id"',
      "user.accountId",
      "Progress and activity",
      "Open filtered activity",
      "consent required",
      "Reading text, transcripts, definitions, translations, and notes are never shown here",
      "Find in this page",
      "OperatorTable",
      "Sentence context",
      "loadingPanels",
      "Loading this view",
      "Learning and reading trends",
      "Country distribution",
      "Top content distribution",
      "Anomaly watch",
      "Small geographic and learning cohorts are grouped into Other",
    ];
    for (const route of routes) {
      expect(normalizedSource).toContain(route);
    }
  });

  it("does not embed a service role secret", () => {
    expect(source).not.toMatch(/SERVICE_ROLE|service_role/);
  });

  it("renders change review only for an active mutation context", () => {
    expect(normalizedSource).toContain('mutationPreview !== "" ? (');
    expect(normalizedSource).toContain("setMutationPreview(summary)");
  });

  it("gates mutation controls with server-reported capabilities", () => {
    for (const capability of [
      "users.manage",
      "roles.manage",
      "policies.manage",
      "ai.probe",
      "runtime.manage",
      "jobs.manage",
      "cache.manage",
      "flags.manage",
      "quotas.manage",
      "privacy.manage",
    ]) {
      expect(normalizedSource).toContain(capability);
    }
    expect(normalizedSource).toContain("disabled={props.busy || !props.canProbe}");
  });

  it("clears privileged data and secret drafts when the session changes", () => {
    expect(normalizedSource).toContain("function clearSessionScopedState()");
    for (const reset of [
      "setPolicies([])",
      "setCache([])",
      "setRuntime(null)",
      'setQwenKey("")',
      'setGcsJson("")',
      'setTurnstileSecret("")',
    ]) {
      expect(normalizedSource).toContain(reset);
    }
    expect(normalizedSource).toContain("activeAccessToken.current !== next.accessToken");
    expect(normalizedSource).toContain("adminLoadGeneration.current += 1");
    expect(normalizedSource).toContain("if (!isCurrentLoad()) return");
    expect(normalizedSource).toContain("storeSession(null); try");
  });
});
