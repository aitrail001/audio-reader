import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const adminVersion = (
  JSON.parse(
    readFileSync(join(dirname(fileURLToPath(import.meta.url)), "package.json"), "utf8"),
  ) as {
    version: string;
  }
).version;

const apiProxyTarget =
  process.env.ADMIN_API_PROXY ??
  "https://audio-reader-api-worker-production.audio-reader-service.workers.dev";

export default defineConfig({
  plugins: [react()],
  define: {
    "import.meta.env.VITE_ADMIN_VERSION": JSON.stringify(adminVersion),
  },
  server: {
    port: 5173,
    proxy: {
      "/v1": {
        target: apiProxyTarget,
        changeOrigin: true,
      },
    },
  },
});
