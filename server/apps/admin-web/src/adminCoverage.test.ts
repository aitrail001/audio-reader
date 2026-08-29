import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const root = dirname(fileURLToPath(import.meta.url));
const source = ["app.tsx", "api.ts", "operator-table.tsx"]
  .map((name) => readFileSync(join(root, name), "utf8"))
  .join("\n");

describe("operator console coverage", () => {
  it("calls every admin management route", () => {
    const routes = [
      "/v1/health",
      "/v1/auth/config",
      "/v1/auth/email-otp/request",
      "/v1/auth/token/refresh",
      "/v1/auth/logout",
      "/v1/admin/runtime-config",
      "/v1/admin/users",
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
      "does not write this table",
      "ai.translation.cached",
      "ai.chat.*",
      "cacheOriginal",
      "cacheBook",
      "prose-block",
      "cell-clip",
      "row-open",
      "prose-pair",
      "Last hit",
      "Translation",
      "Account id",
      "label=\"account id\"",
      "user.accountId",
      "Find in this page",
      "OperatorTable",
      "Sentence context",
    ];
    for (const route of routes) {
      expect(source).toContain(route);
    }
  });

  it("does not embed a service role secret", () => {
    expect(source).not.toMatch(/SERVICE_ROLE|service_role/);
  });
});
