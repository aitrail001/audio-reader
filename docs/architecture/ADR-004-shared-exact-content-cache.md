# ADR-004: Shared exact-content cache

- Status: Accepted
- Date: 2026-08-26

## Context

Identical translation and explanation requests are common when many readers
study the same published sentence. Calling Qwen every time is slow and costly.
A naive shared cache that stored source passages or user identity would leak
private learning data and create a searchable corpus of copyrighted text.

## Decision

Eligible identical translation/explanation requests reuse a **shared
exact-content cache**. The key is an HMAC over the full reusable task contract
(task type, contract/schema/normalization versions, languages, normalized
source and context digests, edition fingerprint, learner-profile bucket,
prompt, model policy, glossary pack, and safety policy).

The cache stores structured results and operational metadata. It stores **no
user identity** and **no searchable source passage**. A hit is returned only
after the requester supplies the exact source needed to recompute the key.

Free-form chat, notes, review answers, custom instructions, and other personal
work are not shared. Every use still writes a private `user_assistant_results`
row for pending/accepted/rejected state.

## Cache identity

Sentence and chapter-batch rows key on the sentence text, languages, learner
level, edition fingerprint, and policy hash. Neighbor sentences are **generation
context only**; they are not part of the sentence cache key, so a later lookup
of the same sentence hits even if it was produced inside a larger block.

Word and `word_context` rows include the containing sentence in the context
digest so the same surface form can mean different things.

Chapter summaries key on the joined chapter segments plus languages, level,
edition fingerprint, and policy hash.

## Client and quota behavior

- `POST /v1/ai/translations` and `POST /v1/ai/chapter-summaries` check cache
  before Qwen. `lookupOnly` returns a hit or `404` and never generates.
- `POST /v1/ai/translation-batches` cache-checks each sentence (max 40), generates
  the remainder in one Qwen call, and stores each sentence under its own key.
  `lookupOnly` returns hits plus `missingIds` without generating. Duplicate or
  blank sentence ids are dropped; a batch with no usable sentence is `400`.
- Daily `qwen_tasks_day` quota is consumed only on a path that is about to call
  Qwen. Cache hits, lookup-only misses, and empty pending batches do not consume
  quota. A multi-sentence generate still costs one unit.
- `refresh` / `refreshIds` skip cache reads for that generate. Combined with
  `lookupOnly` they still never call Qwen: the single-item routes return `404`,
  and a batch returns the skipped ids in `missingIds`. Chat stays private and is
  not cached.

Native Managed Qwen auto-loads sentence translations and chapter summaries from
cache when the reader opens a chapter or reaches a sentence. A cache miss does
not generate unless **Auto-translate** is on; explicit Translate still sends the
chapter-aligned sentence block so neighbors are translated and cached together.
Word lookups stay on-demand (the cache key includes the containing sentence) and
are not auto-hydrated.

## Consequences

- Cache hits avoid a provider call without mixing users' libraries or notes.
- Prompt or model-policy changes naturally miss and populate a new key.
- Admins can quarantine or purge entries from metadata; they cannot search the
  global cache by source text.
- Single-flight inserts on `cache_key` prevent duplicate Qwen generations.
