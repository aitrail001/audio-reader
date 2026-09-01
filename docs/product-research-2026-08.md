# Product research: recovery, continuity, and operator trust

Date: 2026-08-29

This release prioritizes repeated workflow pain rather than adding another
content catalogue. The evidence is directional community and review feedback,
not a statistically representative survey, so it informs product sequencing
rather than market-size claims.

## Signals and product response

| Signal | User outcome | AudioReader response |
| --- | --- | --- |
| Imported text and audio must stay paired and repairable | A failed match does not strand the book | Paired audio/EPUB import, visible repair actions, immutable sources, and transcript correction overlays |
| Readers expect page/session continuity | Continue returns to the exact place without guesswork | Chapter-relative fractional progress, visible sync state, and explicit concurrent-position choice |
| Generated transcripts need correction | A recognition mistake can be fixed without destroying provenance | Validated sentence text/bounds overlays, preview, restore, stale-base retention, and shared presentation resolution |
| Study value comes from reusing encountered language | Saved words move into a real review workflow | Due-first Words and local TSV/M4A Anki export with text-only fallback |
| Operators need actionable failures, not a wall of equal cards | An incident can be followed from symptom to cause | Incident-first Desk, request-ID links, independent panels, typed errors, Trace, and Audit |

The source signals include LingQ discussion of import workflow reliability,
Language Reactor requests for book resume continuity, Aisten review feedback on
transcription quality and correction, and Coolify requests for more actionable
operator diagnostics:

- [LingQ import workflow discussion](https://forum.lingq.com/t/new-import-workflow-what-the/2574619)
- [Language Reactor book resume discussion](https://forum.languagelearningwithnetflix.com/t/page-by-page-reading-and-auto-resume-for-books/32568)
- [Aisten transcription reviews](https://apps.apple.com/us/app/aisten-podcast-transcription/id6453694910?platform=iphone&see-all=reviews)
- [Coolify diagnostics issue](https://github.com/coollabsio/coolify/issues/5025)

## Value and boundaries

The highest-value sequence is recovery first, continuity second, study export
third, and operator diagnosis throughout. This reduces the chance that a reader
loses imported work or study context before adding broader discovery or social
features.

This release intentionally excludes forced word alignment, `.apkg` generation,
AnkiConnect-only integration, public media discovery, social or gamification
features, alert delivery, and browser-managed backup/restore. Those features do
not solve the observed trust and recovery gaps as directly and would expand the
privacy or operational surface.
