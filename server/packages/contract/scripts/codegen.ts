import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import openapiTS, { COMMENT_HEADER, astToString } from "openapi-typescript";

const packageRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = join(packageRoot, "..", "..", "..");

export const defaultSpecPath = join(repoRoot, "contracts", "openapi-v1.yaml");
export const defaultGeneratedPath = join(packageRoot, "src", "generated", "openapi.ts");

export type ContractPaths = {
  specPath: string;
  generatedPath: string;
};

export const defaultContractPaths: ContractPaths = {
  specPath: defaultSpecPath,
  generatedPath: defaultGeneratedPath,
};

export type ContractCheckResult = { ok: true } | { ok: false; message: string };

export async function generateContractTypes(specPath = defaultSpecPath): Promise<string> {
  const ast = await openapiTS(pathToFileURL(resolve(specPath)), { silent: true });
  return `${COMMENT_HEADER}${astToString(ast)}`;
}

export async function writeContractTypes(
  paths: ContractPaths = defaultContractPaths,
): Promise<string> {
  const contents = await generateContractTypes(paths.specPath);
  mkdirSync(dirname(paths.generatedPath), { recursive: true });
  writeFileSync(paths.generatedPath, contents, "utf8");
  return contents;
}

export async function checkContractTypes(
  paths: ContractPaths = defaultContractPaths,
): Promise<ContractCheckResult> {
  const expected = await generateContractTypes(paths.specPath);
  let actual: string;
  try {
    actual = readFileSync(paths.generatedPath, "utf8");
  } catch {
    return {
      ok: false,
      message: `Generated API contract types not found at ${paths.generatedPath}. Run \`pnpm contract:generate\` and commit the result.`,
    };
  }
  if (actual !== expected) {
    return {
      ok: false,
      message:
        "Generated API contract types are out of date. Run `pnpm contract:generate` and commit the result.",
    };
  }
  return { ok: true };
}

async function runContractCli(args: readonly string[]): Promise<number> {
  const command = args[0] ?? "generate";
  if (command === "check") {
    const result = await checkContractTypes();
    if (!result.ok) {
      process.stderr.write(`${result.message}\n`);
      return 1;
    }
    return 0;
  }
  if (command === "generate") {
    await writeContractTypes();
    return 0;
  }
  process.stderr.write(`Unknown command: ${command}\n`);
  return 1;
}

function isExecutedDirectly(): boolean {
  const entry = process.argv[1];
  if (entry === undefined || entry === "") {
    return false;
  }
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(entry);
  } catch {
    return resolve(entry) === fileURLToPath(import.meta.url);
  }
}

async function cliMain(): Promise<void> {
  try {
    const code = await runContractCli(process.argv.slice(2));
    if (code !== 0) {
      process.exitCode = code;
    }
  } catch (error: unknown) {
    const message = error instanceof Error ? (error.stack ?? error.message) : String(error);
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  }
}

if (isExecutedDirectly()) {
  void cliMain();
}
