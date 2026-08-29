import type { CatalogStore, IdentityStore, SyncStore } from "@audio-reader/database";

/** Account-data JSON the native apps save. Omits secrets, wrapping keys, and OTP codes. */
export async function buildAccountExportPayload(input: {
  accountId: string;
  identity?: IdentityStore;
  catalog?: CatalogStore;
  sync?: SyncStore;
}): Promise<Record<string, unknown>> {
  const exportedAt = new Date().toISOString();
  const profile = await input.identity?.getProfileByUserId(input.accountId);
  const settings = await input.identity?.getSettings(input.accountId);
  const devices = (await input.identity?.listDevices(input.accountId)) ?? [];
  const books = (await input.catalog?.listBooks(input.accountId)) ?? [];
  const vocabulary = (await input.catalog?.listVocabulary(input.accountId)) ?? [];
  const lemmas = (await input.catalog?.listLemmas(input.accountId)) ?? [];
  const reviews =
    input.catalog === undefined
      ? []
      : await input.catalog.listDueReviews(input.accountId, exportedAt);
  const transcriptOverlays = await exportTranscriptOverlays(input.sync, input.accountId);
  const library = [];
  for (const book of books) {
    const chapters = (await input.catalog?.listChapters(input.accountId, book.id)) ?? [];
    const chapterRows = [];
    for (const chapter of chapters) {
      const progress = await input.catalog?.getProgress(input.accountId, chapter.id);
      const transcript = await input.catalog?.getActiveTranscript(input.accountId, chapter.id);
      chapterRows.push({
        id: chapter.id,
        index: chapter.index,
        title: chapter.title,
        durationSeconds: chapter.durationSeconds,
        progress: progress ?? null,
        transcript:
          transcript === undefined
            ? null
            : {
                id: transcript.id,
                version: transcript.version,
                engine: transcript.engine,
                locale: transcript.locale,
                segmentCount: Array.isArray(transcript.segments) ? transcript.segments.length : 0,
                segments: transcript.segments,
              },
      });
    }
    library.push({
      id: book.id,
      title: book.title,
      author: book.author,
      source: book.source,
      chapterCount: book.chapterCount,
      createdAt: book.createdAt,
      updatedAt: book.updatedAt,
      chapters: chapterRows,
    });
  }
  return {
    exportedAt,
    format: "json",
    account: profile
      ? {
          id: profile.accountId,
          email: profile.email,
          displayName: profile.displayName,
          status: profile.status,
          createdAt: profile.createdAt,
        }
      : { id: input.accountId },
    devices: devices.map((device) => ({
      id: device.id,
      platform: device.platform,
      name: device.name,
      appVersion: device.appVersion,
      createdAt: device.createdAt,
      lastSeenAt: device.lastSeenAt,
      revoked: device.revoked,
    })),
    settings: settings ?? null,
    library,
    vocabulary,
    lemmas,
    reviews,
    transcriptOverlays,
  };
}

/** Export latest overlay entities without resolving them; stale/conflicted provenance remains inspectable. */
async function exportTranscriptOverlays(
  sync: SyncStore | undefined,
  accountId: string,
): Promise<Record<string, unknown>[]> {
  if (sync === undefined) return [];
  const latest = new Map<string, Record<string, unknown>>();
  let cursor = "0";
  let hasMore = true;
  while (hasMore) {
    const page = await sync.pull({ userId: accountId, cursor, limit: 500 });
    for (const change of page.changes) {
      if (change.entityType !== "transcript_overlay") continue;
      if (change.operation === "delete") {
        latest.delete(change.entityId);
        continue;
      }
      latest.set(change.entityId, {
        id: change.entityId,
        revision: change.revision,
        changedAt: change.changedAt,
        ...change.payload,
      });
    }
    cursor = page.cursor;
    hasMore = page.hasMore;
  }
  return [...latest.values()].sort((left, right) =>
    String(left.id).localeCompare(String(right.id)),
  );
}
