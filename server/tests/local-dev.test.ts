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
