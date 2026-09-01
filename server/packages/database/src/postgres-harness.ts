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
  start(sql: string, options?: { timeout?: number }): Promise<SqlResult>;
  stop(): Promise<void>;
};

const PSQL_ARGS = ["-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-t", "-A", "-q"];
const DOCKER_PSQL_HOST = ["-h", "127.0.0.1"];
const READY_LOG = "database system is ready to accept connections";

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

export function dockerPsqlArgs(containerName: string): string[] {
  return ["exec", "-i", containerName, "psql", ...DOCKER_PSQL_HOST, ...PSQL_ARGS];
}

export function isTransientPostgresError(text: string): boolean {
  return /connection to server.*failed|could not connect to server|connection refused|connection reset|the database system is starting up|the database system is shutting down|server closed the connection/i.test(
    text,
  );
}

export async function startPostgres(): Promise<PostgresSession> {
  const dockerReasons: string[] = [];
  const docker = await tryDockerPostgres(dockerReasons);
  if (docker !== undefined) {
    return docker;
  }
  const local = await tryLocalPostgres();
  if (local !== undefined) {
    return local;
  }
  const detail = dockerReasons.length > 0 ? ` Docker: ${dockerReasons.join("; ")}.` : "";
  throw new Error(
    `PostgreSQL 15+ is required for RLS tests. Install Docker and pull ${DOCKER_IMAGE}, or install postgresql@18.${detail}`,
  );
}

async function tryDockerPostgres(reasons: string[]): Promise<PostgresSession | undefined> {
  if (!commandExists("docker")) {
    reasons.push("docker not on PATH");
    return undefined;
  }
  if (!(await dockerEngineReady())) {
    reasons.push("docker info failed");
    return undefined;
  }
  const name = `audio-reader-rls-${String(process.pid)}-${String(Date.now())}`;
  const runArgs = [
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
  ];
  let run = execCaptured("docker", runArgs, { timeout: 180_000 });
  if (!run.ok) {
    const pull = execCaptured("docker", ["pull", DOCKER_IMAGE], { timeout: 180_000 });
    if (!pull.ok) {
      reasons.push(pull.stderr || pull.stdout || "docker pull failed");
      return undefined;
    }
    run = execCaptured("docker", runArgs, { timeout: 180_000 });
  }
  if (!run.ok) {
    reasons.push(run.stderr || run.stdout || "docker run failed");
    return undefined;
  }
  try {
    await waitUntilDockerPostgresAcceptsQueries(name);
  } catch (error) {
    execCaptured("docker", ["rm", "-f", name], { timeout: 15_000 });
    throw error;
  }
  return makeSession("docker", dockerPsqlArgs(name), () => {
    execCaptured("docker", ["rm", "-f", name], { timeout: 15_000 });
    return Promise.resolve();
  });
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
  return makeSession(
    join(bin, "psql"),
    ["-h", "127.0.0.1", "-p", String(port), ...PSQL_ARGS],
    async () => {
      await stopChild(child);
      rmSync(dataDir, { recursive: true, force: true });
    },
  );
}

function makeSession(file: string, args: string[], stop: () => Promise<void>): PostgresSession {
  return {
    exec(sql: string): SqlResult {
      return execWithRetry(file, args, sql, 60_000);
    },
    start(sql: string, options: { timeout?: number } = {}) {
      return spawnCaptured(file, args, {
        input: sql,
        timeout: options.timeout ?? 60_000,
      });
    },
    stop,
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

async function dockerEngineReady(): Promise<boolean> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const result = execCaptured("docker", ["info"], { timeout: 10_000 });
    if (result.ok) {
      return true;
    }
    const detail = `${result.stderr}\n${result.stdout}`;
    if (/cannot connect to the docker daemon/i.test(detail)) {
      return false;
    }
    await delay(500);
  }
  return false;
}

async function waitUntilDockerPostgresAcceptsQueries(name: string): Promise<void> {
  const timeoutMs = 90_000;
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (dockerReadyLogCount(name) >= 2 && dockerQueryOk(name)) {
      return;
    }
    await delay(250);
  }
  // Images that omit the English ready log still need a server that survives
  // the initdb restart before migrations run.
  if (dockerQueryOk(name)) {
    await delay(1_000);
    if (dockerQueryOk(name)) {
      return;
    }
  }
  throw new Error(`timed out after ${String(timeoutMs)}ms waiting for postgres in ${name}`);
}

function dockerReadyLogCount(name: string): number {
  const logs = execCaptured("docker", ["logs", name], { timeout: 5_000 });
  const text = `${logs.stdout}\n${logs.stderr}`;
  if (!text.includes(READY_LOG)) {
    return 0;
  }
  return text.split(READY_LOG).length - 1;
}

function dockerQueryOk(name: string): boolean {
  return execCaptured("docker", dockerPsqlArgs(name), {
    input: "SELECT 1;",
    timeout: 5_000,
  }).ok;
}

function execWithRetry(file: string, args: string[], sql: string, timeout: number): SqlResult {
  const started = Date.now();
  let last = execCaptured(file, args, { input: sql, timeout });
  while (
    !last.ok &&
    isTransientPostgresError(`${last.stderr}\n${last.stdout}`) &&
    Date.now() - started < timeout
  ) {
    sleepSync(250);
    last = execCaptured(file, args, { input: sql, timeout });
  }
  return last;
}

function sleepSync(ms: number): void {
  execFileSync("sleep", [(ms / 1000).toFixed(3)], {
    stdio: "ignore",
    timeout: ms + 1_000,
  });
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

function spawnCaptured(
  file: string,
  args: string[],
  options: { input: string; timeout: number },
): Promise<SqlResult> {
  return new Promise((resolve) => {
    const child = spawn(file, args, { stdio: ["pipe", "pipe", "pipe"] });
    const stdoutChunks: string[] = [];
    const stderrChunks: string[] = [];
    child.stdout.on("data", (chunk: unknown) => {
      stdoutChunks.push(String(chunk));
    });
    child.stderr.on("data", (chunk: unknown) => {
      stderrChunks.push(String(chunk));
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, options.timeout);
    const finish = (ok: boolean, stderr: string): void => {
      clearTimeout(timer);
      resolve({
        ok,
        stdout: stdoutChunks.join(""),
        stderr,
      });
    };
    child.on("error", (error: unknown) => {
      finish(false, String(error));
    });
    child.on("close", (code) => {
      finish(code === 0, stderrChunks.join(""));
    });
    child.stdin.on("error", () => {
      // Process may exit before stdin is fully written.
    });
    child.stdin.end(options.input);
  });
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
