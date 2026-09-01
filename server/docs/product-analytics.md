# Product analytics contract

The Operator Metrics view reads `GET /v1/admin/product-analytics`. The endpoint aggregates signed-in product events for a UTC window and never returns individual event payloads or raw account/device identifiers.

## Collected dimensions

- Cloudflare derives a two-letter country and first-level region code. The Worker does not store IP addresses, city, postal code, latitude, or longitude.
- The registered device is authoritative for platform, app version, and build number. Client-supplied values for those fields are discarded.
- Clients may provide normalized source/target language, reader level, content/chapter IDs, content category, feature/use-flow, review outcome, and sync phase/entity. The Worker replaces every client content or chapter ID with a deterministic SHA-256-based opaque reference before persistence.
- Titles, authors, sentences, vocabulary text, email addresses, arbitrary notes, secrets, and unknown property keys are rejected before persistence.

Country, region, language, level, content, and content-category distributions count distinct active learners and use a minimum bucket size of three learners. Smaller cohorts are combined into `Other`. Platform/app-version distributions count only events with registered device IDs; feature and outcome distributions count events. A learner can belong to more than one group during a window. Content IDs are hashed before aggregation. Activity rows re-sanitize both current and legacy properties and expose stable pseudonymous subject/device references rather than raw account or device IDs.

## Consent, storage, and deletion

`product_events` stores the server-owned account ID and optional device ID needed for ownership, deletion, and device-level aggregation. These durable keys are not returned by Activity or product-analytics responses. Country and first-level region are stored, but raw IP and precise location are not collected.

Learner behavior and learning events require the signed-in learner's explicit Operator analytics preference. The API fails closed when the preference is absent or cannot be read, and a database trigger independently rejects a learner-analytics insert without active consent. Disabling analytics atomically purges that learner's prior learning events and progress snapshot. Account-scoped Product Events queries return no rows while consent is disabled.

Required operational and security telemetry uses the separate `operational` purpose and does not contribute to learner behavior dashboards. Operator probes and privacy-export completion are operational; AI use, reading, review, and client-submitted events are learner analytics.

Scheduled Job Worker maintenance deletes all product-event purposes after 90 days. Account deletion physically cascades both event purposes before retaining the anonymous deleted tombstone.

## Anomaly indicators

Indicators are deterministic prompts for investigation, not automatic incident declarations:

- `failure_rate`: among terminal `ok`, `failed`, and `cancelled` events, at least 10 terminal events and at least 25% failed. It is critical at 50%. `started` events are excluded from the success-rate denominator; cancelled events are not successful.
- `volume_spike`: at least three buckets, with the latest bucket at least 10 events and at least twice the earlier-bucket mean (and five events above it). It is critical at three times the mean.

The Worker reads the complete retained time window with stable keyset pages before applying dashboard filters. The response therefore reports `sampled: false`; operators should still correlate an anomaly with Activity and Trace before acting.
