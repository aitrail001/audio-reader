import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type SqlResult = {
  ok: boolean;
  stdout: string;
  stderr: string;
};

export type PostgresSession = {
  exec(sql: string): SqlResult;
  stop(): Promise<void>;
};

const DOCKER_IMAGE = "postgres:18-alpine";
const PG_BIN_CANDIDATES = [
  "/opt/homebrew/opt/postgresql@18/bin",
  "/usr/local/opt/postgresql@18/bin",
  "/opt/homebrew/opt/postgresql@17/bin",
  "/usr/local/opt/postgresql@17/bin",
  "/opt/homebrew/opt/postgresql@16/bin",
  "/usr/local/opt/postgresql@16/bin",
  "/opt/homebrew/opt/postgresql@15/bin",
  "/usr/local/opt/postgresql@15/bin",
];

export async function startPostgres(): Promise<PostgresSession> {
  const docker = await tryDockerPostgres();
  if (docker !== undefined) {
    return docker;
  }
  const local = await tryLocalPostgres();
  if (local !== undefined) {
    return local;
  }
  throw new Error(
    "PostgreSQL 15+ is required for RLS tests. Install Docker and pull postgres:18-alpine, or install postgresql@18.",
  );
}

async function tryDockerPostgres(): Promise<PostgresSession | undefined> {
  if (!commandExists("docker") || !dockerEngineReady()) {
    return undefined;
  }
  const name = `audio-reader-rls-${String(process.pid)}-${String(Date.now())}`;
  const run = execCaptured(
    "docker",
    [
      "run",
      "-d",
      "--rm",
      "--name",
      name,
      "-e",
      "POSTGRES_HOST_AUTH_METHOD=trust",
      "-e",
      "POSTGRES_USER=postgres",
      "-e",
      "POSTGRES_DB=postgres",
      DOCKER_IMAGE,
    ],
    { timeout: 180_000 },
  );
  if (!run.ok) {
    return undefined;
  }
  try {
    await waitFor(() => {
      const ready = execCaptured("docker", ["exec", name, "pg_isready", "-U", "postgres"], {
        timeout: 5_000,
      });
      return ready.ok;
    }, 60_000);
  } catch (error) {
    execCaptured("docker", ["rm", "-f", name], { timeout: 15_000 });
    throw error;
  }
  return {
    exec(sql: string): SqlResult {
      return execCaptured(
        "docker",
        [
          "exec",
          "-i",
          name,
          "psql",
          "-U",
          "postgres",
          "-d",
          "postgres",
          "-v",
          "ON_ERROR_STOP=1",
          "-t",
          "-A",
          "-q",
        ],
        { input: sql, timeout: 30_000 },
      );
    },
    stop() {
      execCaptured("docker", ["rm", "-f", name], { timeout: 15_000 });
      return Promise.resolve();
    },
  };
}

async function tryLocalPostgres(): Promise<PostgresSession | undefined> {
  const bin = findPostgresBin();
  if (bin === undefined) {
    return undefined;
  }
  const dataDir = mkdtempSync(join(tmpdir(), "audio-reader-pg-"));
  const init = execCaptured(
    join(bin, "initdb"),
    ["-D", dataDir, "-U", "postgres", "--locale=en_US.UTF-8", "-A", "trust", "--no-sync"],
    { timeout: 30_000 },
  );
  if (!init.ok) {
    rmSync(dataDir, { recursive: true, force: true });
    throw new Error(`initdb failed: ${init.stderr || init.stdout}`);
  }
  const port = await allocatePort();
  const child = spawn(
    join(bin, "postgres"),
    [
      "-D",
      dataDir,
      "-p",
      String(port),
      "-h",
      "127.0.0.1",
      "-k",
      dataDir,
      "-c",
      "listen_addresses=127.0.0.1",
      "-c",
      "logging_collector=off",
    ],
    {
      env: { ...process.env, LC_ALL: "en_US.UTF-8" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const stderrChunks: string[] = [];
  child.stderr.on("data", (chunk: unknown) => {
    stderrChunks.push(String(chunk));
  });
  const spawned = await new Promise<boolean>((resolve) => {
    child.once("error", () => {
      resolve(false);
    });
    child.once("spawn", () => {
      resolve(true);
    });
  });
  if (!spawned) {
    rmSync(dataDir, { recursive: true, force: true });
    return undefined;
  }
  try {
    await waitFor(() => {
      const ready = execCaptured(
        join(bin, "pg_isready"),
        ["-h", "127.0.0.1", "-p", String(port), "-U", "postgres"],
        { timeout: 5_000 },
      );
      return ready.ok;
    }, 30_000);
  } catch (error) {
    await stopChild(child);
    rmSync(dataDir, { recursive: true, force: true });
    throw new Error(`postgres failed to start: ${stderrChunks.join("") || String(error)}`, {
      cause: error,
    });
  }
  return {
    exec(sql: string): SqlResult {
      return execCaptured(
        join(bin, "psql"),
        [
          "-h",
          "127.0.0.1",
          "-p",
          String(port),
          "-U",
          "postgres",
          "-d",
          "postgres",
          "-v",
          "ON_ERROR_STOP=1",
          "-t",
          "-A",
          "-q",
        ],
        { input: sql, timeout: 30_000 },
      );
    },
    async stop() {
      await stopChild(child);
      rmSync(dataDir, { recursive: true, force: true });
    },
  };
}

function findPostgresBin(): string | undefined {
  for (const dir of PG_BIN_CANDIDATES) {
    if (existsSync(join(dir, "initdb")) && existsSync(join(dir, "postgres"))) {
      return dir;
    }
  }
  if (commandExists("initdb") && commandExists("postgres") && commandExists("psql")) {
    return "";
  }
  return undefined;
}

function commandExists(name: string): boolean {
  try {
    execFileSync("which", [name], { stdio: "ignore", timeout: 3_000 });
    return true;
  } catch {
    return false;
  }
}

function dockerEngineReady(): boolean {
  const result = execCaptured("docker", ["info"], { timeout: 2_000 });
  return result.ok;
}

function allocatePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address === null || typeof address === "string") {
        server.close();
        reject(new Error("could not allocate a TCP port"));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
    server.once("error", reject);
  });
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) {
      return;
    }
    await delay(250);
  }
  throw new Error(`timed out after ${String(timeoutMs)}ms`);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

async function stopChild(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) {
    return;
  }
  child.kill("SIGTERM");
  await delay(300);
  child.kill("SIGKILL");
  await delay(100);
}

type ExecFailure = {
  stdout: string;
  stderr: string;
  status: number | null;
};

function isExecFailure(error: unknown): error is ExecFailure {
  if (typeof error !== "object" || error === null) {
    return false;
  }
  if (!("stdout" in error) || !("stderr" in error)) {
    return false;
  }
  return typeof error.stdout === "string" && typeof error.stderr === "string";
}

function execCaptured(
  file: string,
  args: string[],
  options: { input?: string; timeout?: number } = {},
): SqlResult {
  try {
    const stdout = execFileSync(file, args, {
      encoding: "utf8",
      input: options.input,
      timeout: options.timeout,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { ok: true, stdout, stderr: "" };
  } catch (error) {
    if (!isExecFailure(error)) {
      return { ok: false, stdout: "", stderr: String(error) };
    }
    return {
      ok: false,
      stdout: error.stdout,
      stderr: error.stderr,
    };
  }
}
