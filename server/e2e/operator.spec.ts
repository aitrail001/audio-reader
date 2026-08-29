import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "@playwright/test";

test("grouped destinations are keyboard reachable and preserve URL state", async ({ page }) => {
  await page.goto("/?preview=1&section=audit&auditAction=patch_policy");
  await expect(page.getByRole("heading", { name: "Audit" })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Operator sections" })).toContainText("People");
  await expect(page.getByRole("navigation", { name: "Operator sections" })).toContainText(
    "Observe",
  );
  await page.getByRole("button", { name: "Activity" }).focus();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/section=usage/);
  await page.getByLabel("Request id").fill("request-preview-001");
  await expect(page).toHaveURL(/usageRequestId=request-preview-001/);
});

test("preview is WCAG AA clean and never renders secret fixture material", async ({ page }) => {
  await page.goto("/?preview=1");
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
    .analyze();
  expect(results.violations).toEqual([]);
  await expect(page.locator("body")).not.toContainText(/api[_ -]?key\s*[:=]\s*[A-Za-z0-9_-]{12,}/i);
  await expect(page.locator("body")).not.toContainText(
    /service[_ -]?role\s*[:=]\s*[A-Za-z0-9._-]{12,}/i,
  );
});

test("layout remains operable at 200 percent zoom", async ({ page }) => {
  await page.goto("/?preview=1&section=overview");
  await page.evaluate("document.documentElement.style.zoom = '2'");
  await expect(page.getByRole("button", { name: "Users" })).toBeVisible();
  await page.getByRole("button", { name: "Users" }).click();
  await expect(page.getByRole("heading", { name: "Users" })).toBeVisible();
});

test("change review appears only after a mutation is initiated", async ({ page }) => {
  await page.goto("/?preview=1");
  const review = page.getByRole("region", { name: "Change review" });
  await expect(review).toHaveCount(0);

  await page.getByRole("button", { name: "Save runtime config" }).click();
  await expect(review).toBeVisible();
  await expect(review.getByLabel("Reason (5+ characters)")).toHaveValue("");
});

test("captures the incident-first Desk visual contract", async ({ page }, testInfo) => {
  await page.goto("/?preview=1&section=overview");
  await expect(page.getByRole("heading", { name: "Desk" })).toBeVisible();
  await expect(page).toHaveScreenshot(`desk-${testInfo.project.name}.png`, { fullPage: true });
});

test("expired operator token returns to the sign-in gate", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem(
      "audio-reader-admin-session",
      JSON.stringify({
        accessToken: "eyJhbGciOiJFUzI1NiJ9.e30.expired",
        refreshToken: "expired-refresh",
      }),
    );
  });
  await page.route("**/v1/health", (route) =>
    route.fulfill({ status: 200, json: { status: "ok" } }),
  );
  await page.route("**/v1/auth/config", (route) => route.fulfill({ status: 200, json: {} }));
  await page.route("**/v1/auth/token/refresh", (route) =>
    route.fulfill({
      status: 401,
      contentType: "application/problem+json",
      body: JSON.stringify({ detail: "expired" }),
    }),
  );
  await page.route("**/v1/admin/**", (route) =>
    route.fulfill({
      status: 401,
      contentType: "application/problem+json",
      body: JSON.stringify({ detail: "expired" }),
    }),
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Sign in to operate" })).toBeVisible();
});
