# Sync and account export

AudioReader remains local-first: audiobook and EPUB files stay on the device.
When account sync is enabled, the app synchronizes the small records needed to
resume and study consistently across devices, including catalog metadata,
progress, vocabulary, accepted learning data, transcripts, and transcript
correction overlays.

## Progress and conflicts

The reader resumes at the exact stored chapter and playback offset. Local
changes are shown as pending until the server acknowledges them. **Sync now**
requests a pull and push immediately; the status reports the last successful
sync, pending work, a retryable failure, or a conflict.

Concurrent progress changes are never hidden. When two devices advance the
same book from a common revision, AudioReader presents both positions with the
device and timestamp and asks which position to keep. Choosing a position
creates the next synchronized revision; it does not delete local media.

Transcript overlays use the same revision contract. The immutable base
transcript applies before its overlay. A restore is synchronized as removal of
the overlay, and stale-fingerprint overlays remain available for provenance but
are not rendered.

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

