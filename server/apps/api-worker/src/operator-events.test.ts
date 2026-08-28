import { describe, expect, it } from "vitest";
import { listOperatorEvents, recordOperatorEvent } from "./operator-events";

describe("operator events", () => {
  it("keeps the newest matching event first and filters by request id", () => {
    const stamp = crypto.randomUUID();
    const first = recordOperatorEvent({
      kind: "managed_qwen_ok",
      requestId: `${stamp}-a`,
      task: "translation",
      status: "ok",
      summary: "ok one",
    });
    const second = recordOperatorEvent({
      kind: "managed_qwen_failed",
      requestId: `${stamp}-b`,
      task: "chat",
      status: "rejected",
      summary: `failed two ${stamp}`,
    });
    expect(listOperatorEvents({ requestId: `${stamp}-a` }).map((event) => event.id)).toEqual([
      first.id,
    ]);
    expect(listOperatorEvents({ requestId: `${stamp}-b` })[0]?.id).toBe(second.id);
    expect(
      listOperatorEvents({ kind: "managed_qwen_failed" }).some(
        (event) => event.summary === `failed two ${stamp}`,
      ),
    ).toBe(true);
  });
});
