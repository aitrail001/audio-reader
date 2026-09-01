# ADR-001: Local-first native client

- Status: Accepted
- Date: 2026-08-26

## Context

AudioReader is already a native macOS and iPadOS immersion reader. Cross-device
accounts, sync, managed Qwen, and administration need a backend. A web reader
would be faster to share, but would drop local media, on-device transcription,
dictionary integration, EPUB alignment, and offline study.

## Decision

Keep AudioReader native and local-first. Native clients retain local media,
playback, dictionary lookup, on-device transcription, EPUB alignment, offline
reading, and immediate study interactions.

The backend is a coordination and managed-service layer: identity, sync,
optional cloud media, quotas, audit, and server-held Qwen. It is not a browser
replacement for the reader.

macOS and iPadOS remain two presentations of one product. Platform-specific
affordances may differ; local-first behavior and state transitions must not.

## Consequences

- Reading, playback, lookup, review, and local transcription continue without
  network or an account.
- Account, sync, and managed assistance are additive opt-in capabilities.
- A browser-based reader, public library, and marketplace are out of scope for
  the first multi-user release.
