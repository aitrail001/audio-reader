export type RestFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export type RestRequest = {
  method: string;
  path: string;
  query?: Record<string, string>;
  body?: unknown;
  prefer?: string;
};

export type RestResponse = {
  status: number;
  body: unknown;
};

export type RestClient = {
  request(input: RestRequest): Promise<RestResponse>;
};

export type SupabaseRestOptions = {
  url: string;
  serviceRoleKey: string;
  fetch?: RestFetch;
};

export function createSupabaseRestClient(options: SupabaseRestOptions): RestClient {
  const origin = options.url.replace(/\/$/, "");
  const fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const key = options.serviceRoleKey;

  return {
    async request(input) {
      const url = new URL(
        `${origin}/rest/v1${input.path.startsWith("/") ? input.path : `/${input.path}`}`,
      );
      if (input.query !== undefined) {
        for (const [name, value] of Object.entries(input.query)) {
          url.searchParams.set(name, value);
        }
      }
      const headers: Record<string, string> = {
        apikey: key,
        authorization: `Bearer ${key}`,
        accept: "application/json",
        "content-type": "application/json",
      };
      if (input.prefer !== undefined && input.prefer !== "") {
        headers.prefer = input.prefer;
      }
      try {
        const response = await fetchImpl(url, {
          method: input.method,
          headers,
          ...(input.body === undefined ? {} : { body: JSON.stringify(input.body) }),
        });
        return { status: response.status, body: await readBody(response) };
      } catch {
        return { status: 0, body: null };
      }
    },
  };
}

export function restRows(body: unknown): Record<string, unknown>[] {
  if (Array.isArray(body)) {
    return body.filter(isRecord);
  }
  if (isRecord(body)) {
    return [body];
  }
  return [];
}

export function restRow(body: unknown): Record<string, unknown> | undefined {
  return restRows(body)[0];
}

/** True for 2xx. Status 0 is a network failure swallowed by request(); it is not success. */
export function restOk(response: RestResponse): boolean {
  return response.status >= 200 && response.status < 300;
}

/**
 * PostgREST error payloads are `{code, message, ...}` objects. They must not be
 * mapped as table rows — doing so makes a failed write look stored.
 */
export function isErrorBody(body: unknown): boolean {
  if (!isRecord(body)) {
    return false;
  }
  return typeof body.code === "string" && typeof body.message === "string";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readBody(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.trim() === "") {
    return null;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}
