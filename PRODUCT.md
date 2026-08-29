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

AudioReader combines audiobook playback, on-device transcription with word timestamps, ebook alignment, dictionary lookup, vocabulary capture, and contextual LLM assistance. Success means readers can bring in MP3, M4B, ebook-paired, and accessible device-library audiobooks and move between listening and study without losing their place or context.

The operator console succeeds when a signed-in admin can change live Qwen, storage, and Turnstile configuration, and act on users, policies, jobs, cache, metrics, and audit events, without a Worker redeploy.

## Operating Context

Native apps stay local-first. The hosted API runs on Cloudflare Workers with Supabase Auth/Postgres. Operators use the web admin at `server/apps/admin-web` (Cloudflare Pages). They sign in with a product JWT. Runtime overlays persist in `operator_settings`; bootstrap secrets stay in Worker env.

## Capabilities and Constraints

Admin API: health, runtime-config, users (suspend, unsuspend, revoke sessions, grant admin), LLM policies, cache actions, jobs (retry/cancel), metrics, audit events, blocked passwordless attempts, feature flags, starter quotas, and privacy export/deletion requests. Native apps bootstrap those flags and quotas, default to the production Worker URL, and keep iPad playback in the background. Managed Qwen translations, sentence batches, and chapter summaries reuse the shared exact-content cache before calling Qwen; cache hits and lookup-only misses do not consume daily quota. Native Managed Qwen auto-loads cached sentence translations and chapter summaries, and translates chapter-aligned sentence blocks so neighbors are cached together. Word lookups stay on-demand and are keyed with the containing sentence. Microsoft Azure sign-in remains disabled until an Azure app is configured. GCS requires a GCP billing account; without it, object storage uses the existing Supabase Storage bucket.

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
6. The operator console is the same reading-desk product, adapted for operations: health and runtime config first, then people and jobs.

## Accessibility & Inclusion

Support Dynamic Type, VoiceOver labels, 44-point touch targets, semantic system controls, dark mode, portrait and landscape layouts, and reduced-motion preferences.
