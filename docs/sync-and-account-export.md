# Sync and account export

AudioReader remains local-first: audiobook and EPUB files stay on the device.
When account sync is enabled, the app synchronizes the small records needed to
resume and study consistently across devices, including catalog metadata,
progress, vocabulary and review history, accepted learning data, transcripts,
and transcript correction overlays.

## Progress and conflicts

The reader resumes at the exact stored chapter and playback offset. Local
changes are shown as pending until the server acknowledges them. **Sync now**
requests a pull and push immediately. During a run, the status names the phase
and entity being processed—preparing, uploading, downloading, or applying
books, progress, vocabulary, reviews, transcripts, and overlays—and reports
batch/item progress plus pending or conflict counts when known. It then retains
the last successful detail, a retryable entity-specific failure, or a conflict.

Ordinary stale revisions are rebased and retried once in the same run; they do
not become user-facing conflicts. Repeated contention stops before pull and
keeps the local mutation pending for a later retry. When two devices genuinely
advance the same book from a common revision, AudioReader presents both chapter
positions with their device and timestamp and asks which position to keep.
Choosing a position creates the next synchronized revision; it does not delete
local media.

Transcript overlays use the same revision contract. Semantically identical
corrections are merged even when their IDs or provenance differ. Genuinely
different corrections appear in the affected chapter with both corrected texts,
timings, devices, and an explicit choice. The immutable base transcript applies
before its overlay. A restore is synchronized as removal of the overlay, and
stale-fingerprint overlays remain available for provenance but are not rendered.

Vocabulary card scheduling fields and immutable review events synchronize as
one learning contract. A device applies vocabulary parents before review
history, rejects persistence failures instead of acknowledging them, and keeps
the review visible if its local transaction fails. This preserves the same due
queue, interval, ease, retention statistics, and review history across devices.

Before upload, the native client collapses legacy repeated pending snapshots to
one mutation per entity and operation, retaining the latest payload and highest
known server revision. Superseded rows are acknowledged transactionally. This
prevents a large offline backlog from replaying obsolete copies as conflicts,
and a conflict retry cannot be downgraded to revision zero by the next local
snapshot.

The service applies each upload batch in one account-scoped Postgres
transaction. Mutation IDs remain replay-safe, entity revisions are checked in
order, duplicate IDs are rejected before writes, and rejected/conflicted
outcomes remain terminal on retry. A batch ID is bound to one canonical
mutation fingerprint, and account sequence allocation is serialized. Downloads use an
exclusive cursor and request one page bounded by both row count and one MiB of
encoded payload plus a has-more sentinel; the Worker never loads an account's
complete sync history or a transcript-heavy multi-megabyte page.
The native acknowledgement cursor advances only after every change in a pull
page is applied locally. A push response's server high-water mark never advances
that cursor because it may include unseen changes written by another device.
The service-role-only batch RPC accepts at most 500 mutations, while native
clients cap each request at 100 mutations and 2.625 MiB to bound both per-row
CPU work and transcript-heavy memory use. The RPC validates the active device
and keeps settings updates in the same transaction as their sync-log entry.

## Account export

An account export includes the server-held account, device, settings, catalog,
progress, vocabulary, transcript, transcript-overlay, job, usage, and audit data
the current user is permitted to receive. Portable vocabulary fields are
additive: older clients can ignore newer source-segment, word, language, and
translation metadata.

Account export does not contain audiobook, EPUB, cover, local credential-vault,
provider key, OAuth token, or Anki clip data. Anki export is created locally
because its audio comes from user-owned device media.

Operator privacy actions require a fresh, contextual change reason. Destructive
privacy requests require explicit confirmation and preserve their request ID so
the action can be followed through Activity, Trace, and Audit.
