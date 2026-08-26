import type { ReadinessStatus } from "@audio-reader/domain";
import type { Health } from "./http";

export type DependencyProbe = {
  ping(): Promise<ReadinessStatus>;
};

export function unavailableProbe(): DependencyProbe {
  return {
    ping: () => Promise.resolve("unavailable"),
  };
}

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
  r2: DependencyProbe;
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
    r2: await safePing(options.r2),
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
