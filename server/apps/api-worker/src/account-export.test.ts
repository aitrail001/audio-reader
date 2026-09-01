import { createMemoryOpsStore, createMemorySyncStore } from "@audio-reader/database";
import { describe, expect, it } from "vitest";
import { buildAccountExportPayload } from "./account-export";

describe("account export", () => {
  it("includes transcript overlays retained by generic sync", async () => {
    const sync = createMemorySyncStore();
    await sync.push({
      userId: "account-1",
      deviceId: "device-1",
      batchId: "batch-1",
      mutations: [
        {
          mutationId: "mutation-1",
          entityType: "transcript_overlay",
          entityId: "overlay-1",
          operation: "upsert",
          baseRevision: 0,
          occurredAt: "2026-08-29T00:00:00.000Z",
          payload: {
            chapterId: "chapter-1",
            segmentId: "segment-1",
            baseFingerprint: "sha256:base",
            correctedText: "Corrected sentence.",
          },
        },
      ],
    });

    const payload = await buildAccountExportPayload({ accountId: "account-1", sync });
    expect(payload.transcriptOverlays).toEqual([
      expect.objectContaining({ id: "overlay-1", correctedText: "Corrected sentence." }),
    ]);
  });

  it("separates shared cache references from durable private assistant content", async () => {
    const ops = createMemoryOpsStore();
    await ops.recordAssistantUse("account-1", {
      resultId: "11111111-1111-4111-8111-111111111111",
      task: "translation",
      cacheEntryId: "shared-entry-1",
      outputText: "Private accepted translation",
      model: "qwen3.5-plus-2026-08-01",
      promptVersion: "qwen-managed-v3",
      modelPolicyHash: "a".repeat(64),
    });

    const payload = await buildAccountExportPayload({ accountId: "account-1", ops });

    expect(Array.isArray(payload.assistantResults)).toBe(true);
    if (!Array.isArray(payload.assistantResults)) return;
    const assistantResults = payload.assistantResults as unknown[];
    const exported: unknown = assistantResults[0];
    expect(isRecord(exported)).toBe(true);
    if (!isRecord(exported)) return;
    expect(exported.sharedCacheReference).toEqual({ entryId: "shared-entry-1" });
    expect(isRecord(exported.privateContent) && exported.privateContent.outputText).toBe(
      "Private accepted translation",
    );
    expect(Array.isArray(exported.history)).toBe(true);
    expect(exported.promptVersion).toBe("qwen-managed-v3");
    expect(exported.modelPolicyHash).toBe("a".repeat(64));
    expect(JSON.stringify(payload)).not.toContain("cachePayload");
  });
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
