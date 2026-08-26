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

## Consequences

- Cache hits avoid a provider call without mixing users' libraries or notes.
- Prompt or model-policy changes naturally miss and populate a new key.
- Admins can quarantine or purge entries from metadata; they cannot search the
  global cache by source text.
- Single-flight inserts on `cache_key` prevent duplicate Qwen generations.
