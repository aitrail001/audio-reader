# Product

<!-- impeccable:product-schema 1 -->

## Register

product

## Platform

adaptive

## Users

People using audiobooks for focused English study on Mac and iPad. They listen, follow spoken text, inspect unfamiliar language, translate passages, and return to saved vocabulary in the context of the original book.

Operators of the hosted AudioReader API. They keep Qwen, storage, Turnstile, users, jobs, cache, and policies healthy from a web console without editing Worker config files.

## Product Purpose

AudioReader combines audiobook playback, on-device transcription with word timestamps, ebook alignment, repairable sentence overlays, dictionary lookup, vocabulary capture, spaced review, local Anki export, exact resume, and contextual LLM assistance. Success means readers can pair audio and EPUB, recover from damaged imports or transcript mistakes, move between devices without ambiguous progress, and move between listening and study without losing place or context.

The operator console succeeds when a signed-in admin can change live Qwen, storage, and Turnstile configuration, and act on users, policies, jobs, cache, metrics, and audit events, without a Worker redeploy.

## Operating Context

Native apps stay local-first. The hosted API runs on Cloudflare Workers with Supabase Auth/Postgres. Operators use the web admin at `server/apps/admin-web` (Cloudflare Pages). They sign in with a product JWT. Runtime overlays persist in `operator_settings`; bootstrap secrets stay in Worker env.

## Capabilities and Constraints

Native reader: sidebar-owned Library, Now Reading, Words, and Settings; paired import and repair; exact Continue; visible pending/error/conflict sync with Sync now; one immutable transcript plus one validated correction overlay per sentence; due-review-first Words; and local TSV/M4A ZIP export. Every presented transcript consumer resolves through the same overlay contract. Corrections are sentence-level and do not claim forced word alignment. Audio, EPUB, credentials, and Anki clips remain local.

Admin API: global health, runtime config, users and access, privacy requests, LLM policies and cache, jobs, feature flags, quotas, metrics, activity, request trace, and audit. The Operator console opens on an incident-first Desk, loads destinations independently, preserves stale panels through refresh errors, persists destinations and filters in the URL, and follows actions by request ID. High-impact mutations use a contextual before/after reason and explicit confirmation. Native apps bootstrap flags and quotas, default to the production Worker URL, and keep iPad playback in the background. Managed Qwen translations, sentence batches, and chapter summaries reuse the shared exact-content cache before calling Qwen; cache hits and lookup-only misses do not consume daily quota. Word lookups stay on-demand and are keyed with the containing resolved sentence. Microsoft Azure sign-in remains disabled until an Azure app is configured. GCS requires a GCP billing account; without it, object storage uses the existing Supabase Storage bucket.

## Brand Personality

Calm, book-focused, and thoughtful. The interface should feel like a dedicated reading tool rather than a media dashboard.

## Anti-references

Avoid a cramped desktop interface transplanted onto iPad, web-shaped custom controls, decorative AI-dashboard styling, and dense configuration competing with the reading experience.

## Design Principles

1. Keep the book and current passage visually primary.
2. Use native platform navigation and controls so interaction feels immediate and familiar.
3. Reveal study and AI tools progressively without crowding playback.
4. Preserve reading context across playback, lookup, vocabulary, and chat.
5. State device-library and protected-content limitations clearly before the reader invests time.
6. Make recovery explicit: imported pairs, transcript edits, sync failures, and concurrent progress must always have a visible next action.
7. The operator console is the same reading-desk product, adapted for operations: incidents and request-linked evidence first, then configuration.

## Accessibility & Inclusion

Support Dynamic Type, VoiceOver labels and named actions, deterministic automation identifiers, 44-point touch targets, keyboard navigation, semantic system controls, system appearance by default, compliant light/dark contrast, portrait and landscape layouts, and reduced-motion preferences.
