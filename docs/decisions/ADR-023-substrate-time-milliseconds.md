---
status: decided
question: What is the canonical wire and in-memory representation of an instant across the Swift and Rust ports, so that both store byte-identical ISO-8601 timestamps and compute byte-identical time-derived values?
authors: MOOTx01 maintainers
date: 2026-07-02
relates_to:
  - docs/decisions/ADR-004-event-time-two-clock-ingest-primitive.md
  - docs/decisions/DECISION_MATRIXT_OCCUPANCY_CAP_2026-07-02.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/LOCUSKIT_SPEC.md
supersedes: KI-003 (maintainer KNOWN_ISSUES deferral of sub-second reconciliation to v1.1)
context:
  - The Swift port represents every instant as `Date` (a `Double` of seconds since the 2001 reference, carrying sub-second precision) and serialises it to SQLite as canonical ISO-8601 with a 3-digit fractional part (e.g. `2026-05-04T19:59:38.004Z`).
  - The Rust port uniformly mapped Swift's `Date filedAt` to `i64` epoch-SECONDS on every entity (Drawer.filed_at/event_time, Tunnel, Proposal, KGFact, DiaryEntry, Association, LearnedReference, CaptureFrame) plus VectorKit rows and NeuronKit topology, and the PersistenceKit SQLite codec formatted those i64 seconds with a `.000Z` fraction and parsed back to whole seconds.
  - Result: the two ports stored DIFFERENT bytes for the same instant (Swift `.004Z`, Rust `.000Z`), and Rust dropped the sub-second precision the source data (e.g. MemPalace chroma `filed_at`, microsecond) actually carried. On a 50k import Rust collapsed 50,143 event_times to 7,566 distinct values; Swift kept 47,833.
  - The Swift/Rust bit-identity mandate makes this a defect, not a v1.1 nicety. KI-003 had deferred it ("do not partially migrate — the unit must change everywhere at once"); this ADR reverses that deferral and does the migration atomically.
---

# ADR-023 — Substrate instants are epoch milliseconds

## Question

Swift holds instants as `Date` (sub-second) and stores ISO-8601 with a
millisecond fraction. Rust held them as `i64` epoch **seconds** and stored
`.000Z`. The two ports must be bit-identical — same stored bytes, same
time-derived values (fingerprints, recall scores, displayed dates). What is
the one canonical representation, and how must every system that touches an
instant conform to it?

## Decision

**An instant is `i64` epoch milliseconds, everywhere, in both ports.**

1. **Storage / wire.** The PersistenceKit `Timestamp` codec treats the `i64`
   as epoch **milliseconds**: it formats via `from_timestamp_millis` with the
   canonical `%Y-%m-%dT%H:%M:%S%.3fZ` shape, and parses with
   `timestamp_millis()`. The round-trip clamp bounds are the millisecond
   forms of the RFC-3339 year range. The stored ISO-8601 string is therefore
   byte-identical to Swift's `Date`-serialised form for the same instant.

2. **The deterministic clock.** `dispatch::wall_now()` (the `now` token
   threaded through the verb / recall / reward / dreaming stack) returns
   epoch **milliseconds** (`SystemTime … .as_millis()`). Every default that
   stamps a time field (`drawer.filed_at = frame.filed_at.unwrap_or(now)`)
   therefore writes milliseconds, and every field-vs-`now` comparison
   (age, `CreatedBefore`/`CreatedAfter` filters, merkle-rollup `now`) is
   unit-consistent because both sides are milliseconds.

3. **Computation mirrors Swift's `Date → TimeInterval`.** Swift performs its
   time math in **seconds** (a `Date` yields `timeIntervalSince1970`, a
   `Double` of seconds). To stay bit-identical, Rust holds the instant as
   milliseconds but **converts to seconds at each computation boundary**,
   leaving the tuned interval constants in seconds untouched:
   - **`f64` division (`ms as f64 / 1000.0`)** where sub-second precision
     affects the result — decay half-lives and any continuous scoring term.
   - **`i64` floor division (`ms.div_euclid(1000)`)** where it does not —
     the capture-week fingerprint bucket, calendar (Y/M/D/H/M/S) display
     conversion, whole-day/whole-week bucketing.
   Interval *durations* (a half-life, a 30-day window, a grant TTL, a
   cadence) remain expressed in seconds and are never rescaled; they are
   applied against the seconds-converted instant. This is exactly what the
   Swift port does, so the derived values match without moving any constant.

## Why this shape (and not "scale every constant ×1000")

Rescaling every temporal constant to milliseconds would touch dozens of
tuned values (decay half-lives, reward windows, cadences) and silently drift
recall scores on any single miss. Converting the *instant* to seconds at the
boundary — mirroring Swift's own `Date → TimeInterval` — keeps all those
constants fixed and makes the derived value provably identical to the Swift
oracle. The only values that become milliseconds are instants (stored fields
and the `now` clock); everything downstream reproduces Swift's seconds math.

## Conformance requirements (for every system that touches an instant)

Any code — in any kit, any port, and any EE-only system layered on the
substrate — that handles an instant MUST follow these rules. Systems that
currently assume seconds MUST be updated to conform.

1. **A stored/persisted instant is epoch milliseconds.** Entity time fields
   (`filed_at`, `event_time`, and every other `Date`-derived field), the
   `now`/`wall_now` clock token, and any timestamp written through a
   `Timestamp` column are milliseconds. Do not store epoch seconds.

2. **Never format or parse a timestamp by hand.** Route through the
   PersistenceKit `Timestamp` codec (or the Swift `ISO8601` canonical
   helper). Both emit/consume the 3-fractional-digit millisecond form. A
   hand-rolled `strftime`/`from_timestamp(secs, 0)` reintroduces the `.000Z`
   divergence.

3. **Convert ms → seconds at the computation boundary, not the constants.**
   When you need calendar components, a week/day bucket, an age, or a decay
   input, divide the millisecond instant by 1000 first (`/1000.0` if
   sub-second matters, `.div_euclid(1000)` otherwise) and keep your interval
   constants in seconds. This is the single rule that preserves cross-port
   bit-identity.

4. **Comparisons must be same-unit.** Comparing a stored instant against
   `now`, a filter bound, or another instant is valid because all are
   milliseconds. If a value crosses in from an external seconds source
   (e.g. a legacy import, a user parameter named `…Seconds`), convert it to
   milliseconds (`×1000`) before comparing against a stored instant.

5. **Interval / duration inputs stay in their declared unit.** A
   user-facing `halfLifeSeconds`, a `bucketSeconds`, a grant TTL in seconds,
   a cadence in seconds — these are *durations*, not instants. Keep them as
   declared; apply them against the seconds-converted instant (rule 3).

6. **Import boundaries convert to milliseconds, not seconds.** A source that
   supplies sub-second precision (chroma `filed_at` microseconds, Vault
   frontmatter dates) must land in the field as milliseconds. The former
   `event_time_ms / 1000` down-conversions at import seams are removed.

## Consequences

- Swift is the oracle and is unchanged (it already carried sub-second `Date`
  and stored the millisecond fraction). This migration is Rust-side: the
  storage codec, the clock, and the ms→seconds boundary conversions.
- The stored ISO-8601 for any instant is now byte-identical across ports, and
  Rust preserves the source's sub-second precision (imports no longer
  collapse distinct instants).
- Fingerprints, recall scores, and displayed dates are unchanged in value
  because the boundary conversion reproduces Swift's seconds-based math.
- KI-003 is superseded: the sub-second reconciliation is done now, atomically,
  under the bit-identity mandate — not deferred to v1.1.
- **EE follow-up:** systems in the Enterprise Edition that read, stamp,
  compare, or format substrate instants (dispatch/pump timestamps, routing
  and audit surfaces, any bespoke epoch-seconds arithmetic) must be audited
  against the conformance requirements above and updated to the millisecond
  representation. This ADR is the reference for that work.

## Alternatives considered

- **Keep Rust in seconds, widen the storage format only** — cannot preserve
  the source's sub-second precision and cannot bit-match Swift's stored ms.
- **Milliseconds everywhere, rescale every interval constant ×1000** —
  correct end state but high-risk: one missed half-life or window silently
  drifts recall. Rejected in favour of the boundary-conversion mechanic,
  which leaves the constants provably Swift-identical.
- **Store ms but keep the deterministic clock in seconds** — leaves a
  permanent unit split between `now` and the fields they stamp/compare, which
  is a standing foot-gun. Rejected.
