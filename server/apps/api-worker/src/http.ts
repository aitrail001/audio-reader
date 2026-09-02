import type { components } from "@audio-reader/contract";
import { REQUEST_ID_HEADER } from "./observability";

export type Problem = components["schemas"]["Problem"];
export type Health = components["schemas"]["Health"];

export const PROBLEM_CONTENT_TYPE = "application/problem+json";
export const JSON_CONTENT_TYPE = "application/json";

export type ProblemInput = {
  status: number;
  code: string;
  title: string;
  detail: string;
  traceId: string;
  retryAfterSeconds?: number | null;
  fieldErrors?: NonNullable<Problem["fieldErrors"]>;
  headers?: HeadersInit;
};

export function problemResponse(input: ProblemInput): Response {
  const body: Problem = {
    type: `https://api.example.com/problems/${input.code}`,
    title: input.title,
    status: input.status,
    code: input.code,
    detail: input.detail,
    traceId: input.traceId,
    retryAfterSeconds: input.retryAfterSeconds ?? null,
    fieldErrors: input.fieldErrors ?? [],
  };
  const headers = new Headers(input.headers);
  headers.set("content-type", PROBLEM_CONTENT_TYPE);
  return new Response(JSON.stringify(body), {
    status: input.status,
    headers,
  });
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": JSON_CONTENT_TYPE,
    },
  });
}

export function emptyResponse(status = 204): Response {
  return new Response(null, { status });
}

export function withRequestId(response: Response, requestId: string): Response {
  const headers = new Headers(response.headers);
  headers.set(REQUEST_ID_HEADER, requestId);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function asHead(request: Request, response: Response): Response {
  if (request.method !== "HEAD") {
    return response;
  }
  return new Response(null, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}
