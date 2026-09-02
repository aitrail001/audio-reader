import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

const expectedApps = ["api-worker", "job-worker", "admin-web"] as const;
const expectedPackages = ["contract", "database", "auth", "qwen", "observability"] as const;

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8")) as unknown;
}

describe("server workspace", () => {
  it("pins pnpm packageManager and node engines", () => {
    const pkg = readJson(join(serverRoot, "package.json")) as {
      packageManager?: string;
      engines?: { node?: string; pnpm?: string };
    };
    expect(pkg.packageManager).toMatch(/^pnpm@\d+\.\d+\.\d+$/);
    expect(pkg.engines?.node).toBeDefined();
    expect(pkg.engines?.pnpm).toBeDefined();
  });

  it("enables TypeScript strict mode", () => {
    const tsconfig = readJson(join(serverRoot, "tsconfig.base.json")) as {
      compilerOptions?: { strict?: boolean };
    };
    expect(tsconfig.compilerOptions?.strict).toBe(true);
  });

  it("declares apps and packages workspace globs", () => {
    const yaml = readFileSync(join(serverRoot, "pnpm-workspace.yaml"), "utf8");
    expect(yaml).toMatch(/apps\/\*/);
    expect(yaml).toMatch(/packages\/\*/);
  });

  it("enables engineStrict in the workspace manifest", () => {
    const yaml = readFileSync(join(serverRoot, "pnpm-workspace.yaml"), "utf8");
    expect(yaml).toMatch(/^engineStrict:\s*true\s*$/m);
    expect(existsSync(join(serverRoot, ".npmrc"))).toBe(false);
    const value = execFileSync("pnpm", ["config", "get", "engineStrict"], {
      cwd: serverRoot,
      encoding: "utf8",
    }).trim();
    expect(value).toBe("true");
  });

  it("does not declare removed onlyBuiltDependencies", () => {
    const yaml = readFileSync(join(serverRoot, "pnpm-workspace.yaml"), "utf8");
    expect(yaml).not.toMatch(/onlyBuiltDependencies/);
    expect(yaml).toMatch(/^allowBuilds:\s*$/m);
  });

  it("keeps a lockfile", () => {
    expect(existsSync(join(serverRoot, "pnpm-lock.yaml"))).toBe(true);
  });

  it("lists environment names without values", () => {
    const text = readFileSync(join(serverRoot, ".env.example"), "utf8");
    const names: string[] = [];
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (line === "" || line.startsWith("#")) {
        continue;
      }
      expect(line).toMatch(/^[A-Z][A-Z0-9_]+=$/);
      names.push(line.slice(0, -1));
    }
    expect(names).toEqual(expect.arrayContaining(["SUPABASE_URL", "QWEN_API_KEY"]));
    expect(new Set(names).size).toBe(names.length);
  });

  it.each(expectedApps)("includes app %s", (name) => {
    const pkgPath = join(serverRoot, "apps", name, "package.json");
    expect(existsSync(pkgPath)).toBe(true);
    const pkg = readJson(pkgPath) as { name?: string };
    expect(pkg.name).toBe(`@audio-reader/${name}`);
    expect(existsSync(join(serverRoot, "apps", name, "src"))).toBe(true);
  });

  it.each(expectedPackages)("includes package %s", (name) => {
    const pkgPath = join(serverRoot, "packages", name, "package.json");
    expect(existsSync(pkgPath)).toBe(true);
    const pkg = readJson(pkgPath) as { name?: string };
    expect(pkg.name).toBe(`@audio-reader/${name}`);
    expect(existsSync(join(serverRoot, "packages", name, "src", "index.ts"))).toBe(true);
  });
});
