import type { WorkerEnv } from "./app";
import { getOrCreateApiApp } from "./index";

export default {
  fetch(request: Request, env: WorkerEnv, ctx: ExecutionContext): Promise<Response> {
    void ctx;
    return getOrCreateApiApp(env).fetch(request);
  },
} satisfies ExportedHandler<WorkerEnv>;
