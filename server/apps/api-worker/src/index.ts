import { createApiAppFromEnv, type WorkerEnv } from "./app";

export { packageId } from "./packageId";
export { createApiApp, createApiAppFromEnv, createTestApp } from "./app";
export { createMemoryIdempotencyStore, withIdempotency } from "./idempotency";
export { createFakeObjectStore } from "./object-store";

export default {
  fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    void ctx;
    return createApiAppFromEnv(env).fetch(request);
  },
} satisfies ExportedHandler<WorkerEnv>;
