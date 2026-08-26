import type { ReadinessStatus } from "@audio-reader/domain";

export const packageId = "@audio-reader/database" as const;
export type { ReadinessStatus };
export {
  AUDIT_ACTOR_TYPES,
  CORE_TABLES,
  GLOBAL_TABLES,
  JWT_DENIED_TABLES,
  OPTIONAL_OWNER_TABLES,
  PRIVATE_TABLES,
  SERVER_ONLY_TABLES,
  SYNC_COLUMNS,
  SYNC_TABLES,
  TENANT_PARENT_TABLES,
  TRANSACTION_FUNCTIONS,
  USER_OWNED_TABLES,
  USER_READ_OWN_TABLES,
} from "./schema";
export type { CoreTable } from "./schema";

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
