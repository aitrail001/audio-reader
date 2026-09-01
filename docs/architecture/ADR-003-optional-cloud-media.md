# ADR-003: Optional cloud media

- Status: Accepted
- Date: 2026-08-26

## Context

Cross-device continuity needs settings, progress, vocabulary, reviews, and
transcripts. Audiobooks and EPUBs are large, often user-owned files. Forcing
every book into the cloud would blow storage quotas, raise copyright risk, and
break the local-first default.

## Decision

After the user opts into sync, synchronize small learning data. Keep audio and
EPUB files on the device unless the user enables cloud media **for that book**.

A book may be:

- **local-only** — metadata and progress can sync; another device must
  re-import the file;
- **matched locally** — another device imports the same bytes and links by
  exact hash;
- **cloud-available** — the private asset is uploaded to R2 and downloadable
  on authorized devices through short-lived scoped URLs.

## Consequences

- Existing libraries keep working without an account or upload.
- Cloud media is an explicit per-book choice, gated by quota.
- Signed media URLs must be short-lived and never public.
- Devices without the file still study from text and synced transcripts when
  those exist; playback of original audio requires a local or downloaded asset.
