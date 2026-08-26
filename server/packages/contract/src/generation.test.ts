import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  checkContractTypes,
  defaultGeneratedPath,
  defaultSpecPath,
  generateContractTypes,
} from "../scripts/codegen";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

describe("OpenAPI contract generation", () => {
  it("writes generated types to the contract package", () => {
    expect(defaultGeneratedPath).toBe(
      join(serverRoot, "packages", "contract", "src", "generated", "openapi.ts"),
    );
    expect(defaultSpecPath).toBe(join(serverRoot, "..", "contracts", "openapi-v1.yaml"));
  });

  it("is deterministic", async () => {
    const first = await generateContractTypes(defaultSpecPath);
    const second = await generateContractTypes(defaultSpecPath);
    expect(first).toBe(second);
    expect(first.length).toBeGreaterThan(0);
  });

  it("fails check when the contract changes without regeneration", async () => {
    const generated = await generateContractTypes(defaultSpecPath);
    const dir = mkdtempSync(join(tmpdir(), "audio-reader-contract-"));
    const generatedPath = join(dir, "openapi.ts");
    writeFileSync(generatedPath, generated, "utf8");

    const inSync = await checkContractTypes({
      specPath: defaultSpecPath,
      generatedPath,
    });
    expect(inSync).toEqual({ ok: true });

    const driftedSpecPath = join(dir, "openapi.yaml");
    const spec = readFileSync(defaultSpecPath, "utf8").replace(
      "operationId: bootstrapSession",
      "operationId: bootstrapSessionDrifted",
    );
    expect(spec).toContain("operationId: bootstrapSessionDrifted");
    writeFileSync(driftedSpecPath, spec, "utf8");

    const drifted = await checkContractTypes({
      specPath: driftedSpecPath,
      generatedPath,
    });
    expect(drifted.ok).toBe(false);
  });

  it("fails check when committed generated types are missing or stale", async () => {
    const dir = mkdtempSync(join(tmpdir(), "audio-reader-contract-missing-"));
    const missing = await checkContractTypes({
      specPath: defaultSpecPath,
      generatedPath: join(dir, "missing.ts"),
    });
    expect(missing.ok).toBe(false);

    const stalePath = join(dir, "stale.ts");
    writeFileSync(stalePath, "export type paths = {};\n", "utf8");
    const stale = await checkContractTypes({
      specPath: defaultSpecPath,
      generatedPath: stalePath,
    });
    expect(stale.ok).toBe(false);
  });

  it("keeps the working copy in sync via pnpm contract:check", () => {
    const pkg = JSON.parse(readFileSync(join(serverRoot, "package.json"), "utf8")) as {
      scripts?: Record<string, string>;
    };
    expect(pkg.scripts?.["contract:generate"]).toBeDefined();
    expect(pkg.scripts?.["contract:check"]).toBeDefined();
    execFileSync("pnpm", ["contract:check"], {
      cwd: serverRoot,
      encoding: "utf8",
      stdio: "pipe",
    });
  });
});
