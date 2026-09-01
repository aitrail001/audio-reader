import type { ReadinessStatus } from "@audio-reader/domain";

export const packageId = "@audio-reader/qwen" as const;
export type { ReadinessStatus };

export const DEFAULT_QWEN_BASE_URL =
  "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1" as const;
export const DEFAULT_QWEN_MODEL = "qwen3.7-plus" as const;

export type QwenFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export type QwenMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

export type QwenCompletionRequest = {
  messages: readonly QwenMessage[];
  jsonObject?: boolean;
  model?: string;
};

export type QwenCompletionResult =
  | { ok: true; text: string; model: string }
  | {
      ok: false;
      code: "unavailable" | "rejected";
      usedModel: string;
      httpStatus?: number;
      detail?: string;
    };

export type QwenPingDetail = {
  status: ReadinessStatus;
  httpStatus?: number;
  detail?: string;
};

export type QwenClient = {
  ping(): Promise<ReadinessStatus>;
  pingDetailed(): Promise<QwenPingDetail>;
  complete(request: QwenCompletionRequest): Promise<QwenCompletionResult>;
};

export type QwenClientOptions = {
  apiKey: string;
  baseUrl?: string;
  model?: string;
  fetch?: QwenFetch;
};

export function createFakeQwenClient(
  options: {
    status?: ReadinessStatus;
    text?: string;
    model?: string;
    delayMs?: number;
    onComplete?: () => void;
  } = {},
): QwenClient {
  const status = options.status ?? "ok";
  const model = options.model ?? DEFAULT_QWEN_MODEL;
  const text = options.text ?? '{"ok":true}';
  return {
    ping: () => Promise.resolve(status),
    pingDetailed: () =>
      Promise.resolve(
        status === "ok"
          ? { status, httpStatus: 200 }
          : { status, httpStatus: 503, detail: "fake qwen client is unavailable" },
      ),
    complete: async () => {
      options.onComplete?.();
      if (options.delayMs !== undefined && options.delayMs > 0) {
        await new Promise((resolve) => {
          setTimeout(resolve, options.delayMs);
        });
      }
      return status === "ok"
        ? { ok: true, text, model }
        : {
            ok: false,
            code: "unavailable",
            usedModel: model,
            detail: "fake qwen client is unavailable",
          };
    },
  };
}

export function createQwenClient(options: QwenClientOptions): QwenClient {
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const baseUrl = (options.baseUrl ?? DEFAULT_QWEN_BASE_URL).replace(/\/$/, "");
  const model = options.model ?? DEFAULT_QWEN_MODEL;
  const headers = {
    authorization: `Bearer ${options.apiKey}`,
    "content-type": "application/json",
  };

  return {
    async ping() {
      return (await this.pingDetailed()).status;
    },

    async pingDetailed() {
      try {
        const response = await fetchImpl(`${baseUrl}/models`, {
          method: "GET",
          headers,
        });
        if (response.ok) {
          return { status: "ok" as const, httpStatus: response.status };
        }
        return {
          status: "unavailable" as const,
          httpStatus: response.status,
          detail: redactProviderBody(await response.text()),
        };
      } catch (error: unknown) {
        return {
          status: "unavailable" as const,
          detail: error instanceof Error ? error.message.slice(0, 240) : "network error",
        };
      }
    },

    async complete(request) {
      try {
        const usedModel = request.model?.trim() || model;
        const body: Record<string, unknown> = {
          model: usedModel,
          messages: request.messages,
        };
        if (request.jsonObject === true) {
          body.response_format = { type: "json_object" };
        }
        const response = await fetchImpl(`${baseUrl}/chat/completions`, {
          method: "POST",
          headers,
          body: JSON.stringify(body),
        });
        const raw = await response.text();
        if (response.status === 400 || response.status === 422) {
          return {
            ok: false,
            code: "rejected",
            usedModel,
            httpStatus: response.status,
            detail: redactProviderBody(raw),
          };
        }
        if (!response.ok) {
          return {
            ok: false,
            code: "unavailable",
            usedModel,
            httpStatus: response.status,
            detail: redactProviderBody(raw),
          };
        }
        let payload: unknown;
        try {
          payload = raw === "" ? {} : (JSON.parse(raw) as unknown);
        } catch {
          return {
            ok: false,
            code: "rejected",
            usedModel,
            httpStatus: response.status,
            detail: "provider returned non-JSON",
          };
        }
        const text = completionText(payload);
        if (text === undefined) {
          return {
            ok: false,
            code: "rejected",
            usedModel,
            httpStatus: response.status,
            detail: "provider JSON had no assistant text",
          };
        }
        return { ok: true, text, model: completionModel(payload) ?? usedModel };
      } catch (error: unknown) {
        return {
          ok: false,
          code: "unavailable",
          usedModel: request.model?.trim() || model,
          detail: error instanceof Error ? error.message.slice(0, 240) : "network error",
        };
      }
    },
  };
}

function completionText(payload: unknown): string | undefined {
  if (!isRecord(payload) || !Array.isArray(payload.choices)) {
    return undefined;
  }
  const choices: unknown[] = payload.choices;
  const first = choices[0];
  if (!isRecord(first) || !isRecord(first.message)) {
    return undefined;
  }
  return typeof first.message.content === "string" ? first.message.content : undefined;
}

function completionModel(payload: unknown): string | undefined {
  if (!isRecord(payload) || typeof payload.model !== "string") {
    return undefined;
  }
  return payload.model;
}

function redactProviderBody(raw: string): string {
  const trimmed = raw.replace(/\s+/g, " ").trim();
  const redacted = trimmed
    .replace(/sk-[A-Za-z0-9_-]+/g, "sk-[redacted]")
    .replace(/Bearer\s+\S+/gi, "Bearer [redacted]");
  return redacted.slice(0, 240);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const textEncoder = new TextEncoder();

export type SharedCacheParts = {
  taskType: string;
  contractVersion?: string;
  schemaVersion?: string;
  normalizationVersion?: string;
  sourceLanguage: string;
  targetLanguage: string;
  source: string;
  context?: string;
  editionFingerprint?: string;
  learnerProfileBucket?: string;
  promptVersion?: string;
  modelPolicyHash?: string;
  glossaryPackHash?: string;
  safetyPolicyVersion?: string;
};

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", textEncoder.encode(value));
  return toHex(new Uint8Array(digest));
}

export async function hmacCacheKey(secret: string, material: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, textEncoder.encode(material));
  return toHex(new Uint8Array(signature));
}

export async function sharedCacheMaterial(parts: SharedCacheParts): Promise<string> {
  const sourceHash = await sha256Hex(parts.source.normalize("NFC").trim());
  const contextHash = await sha256Hex((parts.context ?? "").normalize("NFC").trim());
  return [
    parts.taskType,
    parts.contractVersion ?? "1",
    parts.schemaVersion ?? "1",
    parts.normalizationVersion ?? "1",
    parts.sourceLanguage,
    parts.targetLanguage,
    sourceHash,
    contextHash,
    parts.editionFingerprint ?? "",
    parts.learnerProfileBucket ?? "intermediate",
    parts.promptVersion ?? "qwen-managed-v1",
    parts.modelPolicyHash ?? "qwen-managed-v1",
    parts.glossaryPackHash ?? "",
    parts.safetyPolicyVersion ?? "1",
  ].join("|");
}

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
