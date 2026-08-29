import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "/private/tmp/audio-reader-playwright-results",
  snapshotPathTemplate: "{testDir}/__screenshots__/{arg}{ext}",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL: "http://127.0.0.1:5173",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "./apps/admin-web/node_modules/.bin/vite apps/admin-web --host 127.0.0.1",
    url: "http://127.0.0.1:5173/?preview=1",
    reuseExistingServer: true,
    timeout: 60_000,
  },
  projects: [
    {
      name: "desktop-light",
      use: {
        ...devices["Desktop Chrome"],
        colorScheme: "light",
        viewport: { width: 1440, height: 1000 },
      },
    },
    {
      name: "desktop-dark",
      use: {
        ...devices["Desktop Chrome"],
        colorScheme: "dark",
        viewport: { width: 1440, height: 1000 },
      },
    },
    { name: "tablet", use: { ...devices["iPad Pro 11"], browserName: "chromium" } },
    {
      name: "mobile-390",
      use: { ...devices["Desktop Chrome"], viewport: { width: 390, height: 844 } },
    },
  ],
});
