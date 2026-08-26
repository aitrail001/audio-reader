import { createApiAppFromEnv, type ApiApp, type WorkerEnv } from "./app";

export { packageId } from "./packageId";
export { createApiApp, createApiAppFromEnv, createTestApp } from "./app";
export { createMemoryIdempotencyStore, withIdempotency } from "./idempotency";
export { createFakeObjectStore } from "./object-store";

let cachedEnv: WorkerEnv | undefined;
let cachedApp: ApiApp | undefined;

export function getOrCreateApiApp(env: WorkerEnv): ApiApp {
  if (cachedApp !== undefined && cachedEnv === env) {
    return cachedApp;
  }
  cachedEnv = env;
  cachedApp = createApiAppFromEnv(env);
  return cachedApp;
}

export function resetApiAppCache(): void {
  cachedEnv = undefined;
  cachedApp = undefined;
}

export default {
  fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    void ctx;
    return getOrCreateApiApp(env).fetch(request);
  },
} satisfies ExportedHandler<WorkerEnv>;
