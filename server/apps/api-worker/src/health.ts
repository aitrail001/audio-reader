import type { Health } from "./http";

type ReadinessStatus = "ok" | "unavailable";

export type DependencyProbe = {
  ping(): Promise<ReadinessStatus>;
};

async function safePing(probe: DependencyProbe): Promise<ReadinessStatus> {
  try {
    return await probe.ping();
  } catch {
    return "unavailable";
  }
}

export async function buildHealth(options: {
  version: string;
  includeDependencies: boolean;
  database: DependencyProbe;
  storage: DependencyProbe;
  qwen: DependencyProbe;
}): Promise<Health> {
  const time = new Date().toISOString();
  if (!options.includeDependencies) {
    return {
      status: "ok",
      version: options.version,
      time,
    };
  }
  const dependencies = {
    database: await safePing(options.database),
    storage: await safePing(options.storage),
    qwen: await safePing(options.qwen),
  };
  const ready = Object.values(dependencies).every((status) => status === "ok");
  return {
    status: ready ? "ok" : "degraded",
    version: options.version,
    time,
    dependencies,
  };
}

/** Auth, sync, and managed Qwen can serve without optional object storage (ADR-003). */
export function isServiceReady(
  dependencies: NonNullable<Health["dependencies"]> | undefined,
): boolean {
  if (dependencies === undefined) {
    return true;
  }
  return dependencies.database === "ok" && dependencies.qwen === "ok";
}
