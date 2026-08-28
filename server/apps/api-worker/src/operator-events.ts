export const SYSTEM_ACTOR_ID = "00000000-0000-4000-8000-0000000000ae" as const;

const RING = 250;

export type OperatorEvent = {
  id: string;
  at: string;
  kind: string;
  requestId: string;
  task?: string;
  status?: string;
  summary: string;
  detail?: string;
  metadata?: Record<string, unknown>;
};

const events: OperatorEvent[] = [];

export function recordOperatorEvent(
  input: Omit<OperatorEvent, "id" | "at"> & { at?: string },
): OperatorEvent {
  const event: OperatorEvent = {
    id: crypto.randomUUID(),
    at: input.at ?? new Date().toISOString(),
    kind: input.kind,
    requestId: input.requestId,
    summary: input.summary.slice(0, 500),
    ...(input.task === undefined || input.task === "" ? {} : { task: input.task }),
    ...(input.status === undefined || input.status === "" ? {} : { status: input.status }),
    ...(input.detail === undefined || input.detail === ""
      ? {}
      : { detail: input.detail.slice(0, 500) }),
    ...(input.metadata === undefined ? {} : { metadata: input.metadata }),
  };
  events.unshift(event);
  if (events.length > RING) {
    events.length = RING;
  }
  return event;
}

export function listOperatorEvents(
  filter: {
    requestId?: string;
    kind?: string;
    task?: string;
    limit?: number;
  } = {},
): OperatorEvent[] {
  const requestId = filter.requestId?.trim() ?? "";
  const kind = filter.kind?.trim() ?? "";
  const task = filter.task?.trim() ?? "";
  const limit = filter.limit ?? 100;
  return events
    .filter((event) => (requestId === "" ? true : event.requestId === requestId))
    .filter((event) => (kind === "" ? true : event.kind === kind))
    .filter((event) => (task === "" ? true : event.task === task))
    .slice(0, Math.min(Math.max(limit, 1), RING));
}

export function operatorEventFromAudit(event: {
  id: string;
  action: string;
  resourceType: string;
  resourceId: string;
  reason: string;
  traceId: string | null;
  metadata: Record<string, unknown>;
  createdAt: string;
}): OperatorEvent {
  return {
    id: event.id,
    at: event.createdAt,
    kind: event.action,
    requestId: event.traceId ?? event.id,
    summary: event.reason,
    ...(typeof event.metadata.task === "string" ? { task: event.metadata.task } : {}),
    ...(typeof event.metadata.status === "string" ? { status: event.metadata.status } : {}),
    ...(typeof event.metadata.detail === "string" ? { detail: event.metadata.detail } : {}),
    metadata: {
      resourceType: event.resourceType,
      resourceId: event.resourceId,
      ...event.metadata,
    },
  };
}
