import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function read(path: string): string {
  return readFileSync(path, "utf8");
}

describe("local development workspace", () => {
  it("tracks a secret-free Supabase CLI config", () => {
    const configPath = join(serverRoot, "supabase", "config.toml");
    expect(existsSync(configPath)).toBe(true);
    const config = read(configPath);
    expect(config).toMatch(/^project_id\s*=\s*"audio-reader"/m);
    expect(config).toMatch(/^\[db\]/m);
    expect(config).not.toMatch(/jwt_secret\s*=/);
    expect(config).not.toMatch(/service_role/i);
    expect(config).not.toMatch(/password\s*=\s*"/i);
    expect(config).not.toMatch(/secret\s*=\s*"(?!env\()/i);
  });

  it("provides a local database startup script", () => {
    const script = read(join(serverRoot, "scripts", "start-local-db.sh"));
    expect(script.startsWith("#!/usr/bin/env bash")).toBe(true);
    expect(script).toMatch(/supabase/);
    expect(script).toMatch(/--workdir/);
  });

  it("provides a Worker local runner", () => {
    const script = read(join(serverRoot, "scripts", "run-api-worker.sh"));
    expect(script.startsWith("#!/usr/bin/env bash")).toBe(true);
    expect(script).toMatch(/@audio-reader\/api-worker/);
    expect(script).toMatch(/wrangler|dev/);
  });

  it("does not let production Wrangler inherit local ENVIRONMENT or CORS", () => {
    const wrangler = read(join(serverRoot, "apps", "api-worker", "wrangler.toml"));
    expect(wrangler).toMatch(/^main = "src\/worker.ts"$/m);
    expect(wrangler).toMatch(/^ENVIRONMENT = "local"$/m);
    expect(wrangler).toContain("[env.production.vars]");
    expect(wrangler).toMatch(/\[env\.production\.vars\][\s\S]*ENVIRONMENT = "production"/);
    expect(wrangler).toMatch(
      /\[env\.production\.vars\][\s\S]*CORS_ALLOWED_ORIGINS = "https:\/\/audio-reader-admin\.pages\.dev"/,
    );
    expect(wrangler).not.toMatch(
      /\[env\.production\.vars\][\s\S]*CORS_ALLOWED_ORIGINS = "http:\/\/localhost/,
    );
    expect(wrangler).not.toMatch(
      /\[env\.production\.vars\][\s\S]*CORS_ALLOWED_ORIGINS = "[^"]*feature-cross-device/,
    );
    expect(wrangler).toMatch(/^LOCAL_DEV_OTP = "123456"$/m);
    expect(wrangler).toMatch(/\[env\.production\.vars\][\s\S]*LOCAL_DEV_OTP = ""/);
    expect(wrangler).toMatch(/\[env\.staging\.vars\][\s\S]*LOCAL_DEV_OTP = ""/);
    expect(wrangler).toContain("audio-reader-api-worker-staging");
    expect(wrangler).toContain("audio-reader-api-worker-production");
  });

  it("uses the same explicit Supabase Storage bucket in both hosted Workers", () => {
    const apiWrangler = read(join(serverRoot, "apps", "api-worker", "wrangler.toml"));
    const jobWrangler = read(join(serverRoot, "apps", "job-worker", "wrangler.toml"));
    for (const environment of ["staging", "production"]) {
      const sectionPattern = new RegExp(
        `\\[env\\.${environment}\\.vars\\][^[]*SUPABASE_STORAGE_BUCKET = "audio-reader-assets"`,
      );
      expect(apiWrangler).toMatch(sectionPattern);
      expect(jobWrangler).toMatch(sectionPattern);
    }
  });

  it("provides named-environment deploy scripts that refuse local vars", () => {
    const preflight = read(join(serverRoot, "scripts", "preflight-deploy.sh"));
    const deploy = read(join(serverRoot, "scripts", "deploy-worker.sh"));
    expect(preflight.startsWith("#!/usr/bin/env bash")).toBe(true);
    expect(deploy.startsWith("#!/usr/bin/env bash")).toBe(true);
    expect(preflight).toMatch(/staging\|production/);
    expect(preflight).toMatch(/LOCAL_DEV_OTP/);
    expect(preflight).toMatch(/SUPABASE_ANON_KEY/);
    expect(preflight).toMatch(/wrangler login/);
    expect(deploy).toMatch(/wrangler deploy --env/);
    expect(deploy).toMatch(/preflight-deploy/);
    const pkg = JSON.parse(read(join(serverRoot, "package.json"))) as {
      scripts?: Record<string, string>;
    };
    expect(pkg.scripts?.["deploy:staging"]).toMatch(/deploy-worker\.sh staging/);
    expect(pkg.scripts?.["deploy:production"]).toMatch(/deploy-worker\.sh production/);
    expect(pkg.scripts?.["preflight:deploy"]).toMatch(/preflight-deploy/);
    const missing = spawnSync("bash", [join(serverRoot, "scripts", "preflight-deploy.sh")], {
      encoding: "utf8",
    });
    expect(missing.status).not.toBe(0);
    expect(`${missing.stderr}${missing.stdout}`).toMatch(/staging\|production/);
    const local = spawnSync("bash", [join(serverRoot, "scripts", "preflight-deploy.sh"), "local"], {
      encoding: "utf8",
    });
    expect(local.status).not.toBe(0);
  });

  it("provides a Docker Compose local API stack", () => {
    const compose = read(join(serverRoot, "docker-compose.yml"));
    expect(compose).toMatch(/postgres:18-alpine/);
    expect(compose).toMatch(/postgres-data:\/var\/lib\/postgresql$/m);
    expect(compose).toMatch(/8787:8787/);
    expect(compose).toMatch(/LOCAL_DEV_OTP/);
    expect(existsSync(join(serverRoot, "Dockerfile"))).toBe(true);
    expect(existsSync(join(serverRoot, "scripts", "run-local-stack.sh"))).toBe(true);
    expect(existsSync(join(serverRoot, "scripts", "e2e-local-api.sh"))).toBe(true);
    expect(existsSync(join(serverRoot, "scripts", "apply-migrations.sh"))).toBe(true);
    const script = read(join(serverRoot, "scripts", "run-local-stack.sh"));
    expect(script).toMatch(/docker compose/);
    expect(script).toMatch(/e2e-local-api/);
    const worker = read(join(serverRoot, "apps", "api-worker", "src", "worker.ts"));
    expect(worker).toMatch(/export default/);
    expect(worker).not.toMatch(/packageId/);
  });

  it("exposes one command for contract, unit, and integration suites", () => {
    const pkg = JSON.parse(read(join(serverRoot, "package.json"))) as {
      scripts?: Record<string, string>;
    };
    expect(pkg.scripts?.["test:all"]).toBeDefined();
    expect(pkg.scripts?.["test:all"]).toMatch(/run-test-suites/);
    const script = read(join(serverRoot, "scripts", "run-test-suites.sh"));
    expect(script).toMatch(/unittest discover/);
    expect(script).toMatch(/Tests\/contract/);
    expect(script).toMatch(/contract:check/);
    expect(script).toMatch(/\bpnpm test\b/);
  });
});
