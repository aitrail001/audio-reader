import type { ReadinessStatus } from "@audio-reader/domain";

export type ObjectStore = {
  ping(): Promise<ReadinessStatus>;
  put(key: string, value: Uint8Array): Promise<void>;
  get(key: string): Promise<Uint8Array | undefined>;
  delete(key: string): Promise<void>;
};

export function createFakeObjectStore(options: { status?: ReadinessStatus } = {}): ObjectStore {
  const objects = new Map<string, Uint8Array>();
  const status = options.status ?? "ok";
  return {
    ping: () => Promise.resolve(status),
    put: (key, value) => {
      objects.set(key, value);
      return Promise.resolve();
    },
    get: (key) => Promise.resolve(objects.get(key)),
    delete: (key) => {
      objects.delete(key);
      return Promise.resolve();
    },
  };
}
