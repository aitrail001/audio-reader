import { createMemorySyncStore } from "@audio-reader/database";
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
});
