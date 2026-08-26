import type { ReadinessStatus } from "@audio-reader/domain";

export const packageId = "@audio-reader/qwen" as const;
export type { ReadinessStatus };

export type QwenClient = {
  ping(): Promise<ReadinessStatus>;
};

export function createFakeQwenClient(options: { status?: ReadinessStatus } = {}): QwenClient {
  const status = options.status ?? "ok";
  return {
    ping: () => Promise.resolve(status),
  };
}
