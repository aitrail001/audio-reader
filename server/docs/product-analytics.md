# Product analytics contract

The Operator Metrics view reads `GET /v1/admin/product-analytics`. The endpoint aggregates signed-in product events for a UTC window and never returns individual event payloads or raw account/device identifiers.

## Collected dimensions

- Cloudflare derives a two-letter country and first-level region code. The Worker does not store IP addresses, city, postal code, latitude, or longitude.
- The registered device is authoritative for platform, app version, and build number. Client-supplied values for those fields are discarded.
- Clients may provide normalized source/target language, reader level, content/chapter IDs, content category, feature/use-flow, review outcome, and sync phase/entity. The Worker replaces every client content or chapter ID with a deterministic SHA-256-based opaque reference before persistence.
- Titles, authors, sentences, vocabulary text, email addresses, arbitrary notes, secrets, and unknown property keys are rejected before persistence.

Country, region, language, level, content, and content-category distributions count distinct active learners and use a minimum bucket size of three learners. Smaller cohorts are combined into `Other`. Platform/app-version distributions count only events with registered device IDs; feature and outcome distributions count events. A learner can belong to more than one group during a window. Content IDs are hashed before aggregation. Activity rows re-sanitize both current and legacy properties and expose stable pseudonymous subject/device references rather than raw account or device IDs.

## Storage and deletion

`product_events` stores the server-owned account ID and optional device ID needed for ownership, deletion, and device-level aggregation. These durable keys are not returned by Activity or product-analytics responses. Country and first-level region are stored, but raw IP and precise location are not collected.

No automatic product-event retention window is currently configured. Events remain until an operational retention process removes them or the owning profile row is physically deleted. The `product_events.user_id` foreign key uses `ON DELETE CASCADE`, so deleting the profile row deletes its product events.

Completing the current Operator deletion-request action marks the profile `deleted` and revokes its devices; it does not physically delete the profile or purge product events. The analytics privacy metadata reports both the database cascade and this current deletion-workflow limitation explicitly. Operators must not tell users that event erasure is complete until a separate purge has removed the profile or its events.

## Anomaly indicators

Indicators are deterministic prompts for investigation, not automatic incident declarations:

- `failure_rate`: among terminal `ok`, `failed`, and `cancelled` events, at least 10 terminal events and at least 25% failed. It is critical at 50%. `started` events are excluded from the success-rate denominator; cancelled events are not successful.
- `volume_spike`: at least three buckets, with the latest bucket at least 10 events and at least twice the earlier-bucket mean (and five events above it). It is critical at three times the mean.

The response reports whether its 5,000-event source window may be sampled. Operators should correlate an anomaly with Activity and Trace before acting.
