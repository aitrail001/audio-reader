import type { ReadinessStatus } from "@audio-reader/domain";

export const packageId = "@audio-reader/database" as const;
export type { ReadinessStatus };

export type DatabaseClient = {
  ping(): Promise<ReadinessStatus>;
};

export function createFakeDatabaseClient(
  options: { status?: ReadinessStatus } = {},
): DatabaseClient {
  const status = options.status ?? "ok";
  return {
    ping: () => Promise.resolve(status),
  };
}
