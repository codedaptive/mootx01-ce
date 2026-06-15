---
status: decided
question: Is `eventTime` the single authored-in-world origin-time primitive on `Drawer`, or should a parallel `occurredAt` primitive be introduced?
authors: MOOTx01 maintainers
date: 2026-06-03
relates_to:
  - docs/reference/LOCUSKIT_SPEC.md
  - docs/reference/LOCUSKIT_INTERFACE.md
supersedes: none
context:
  - A drawer carries two distinct time semantics — an ingest clock (`filedAt`) and an authored-in-world clock (`eventTime`).
  - The two-clock model shipped first in Swift; the Rust port had no `event_time`, a conformance gap against the published interface.
  - Scope is the `Drawer` origin-time field across both ports (Swift + Rust), its `CaptureFrame` capture slot, its SQLite column, and the fingerprint capture-week bucket that keys off it. LocusKit only.
---

# ADR-004 — `eventTime` is the Authored-in-World Origin-Time Primitive (Two-Clock Ingest)

**Status:** Accepted — 2026-06-03

**Evidence:** The two-clock ingest model shipped its Swift implementation; `Drawer.eventTime` and `CaptureFrame.eventTime` are canonical in `LOCUSKIT_INTERFACE.md`, and invariant **I-7** (ISO8601 date columns) includes `eventTime`.

## Context

A drawer carries two distinct time semantics:

- **`filedAt`** — the *ingest clock*: when the row entered the local store. Monotonically increasing, immutable, the anchor for CRDT convergence and audit ordering. "When did we learn this."
- **`eventTime`** — the *authored-in-world clock*: when the thing happened or was authored in the world. For streaming capture it coincides with `filedAt`; for bulk historical ingestion the caller supplies the original authorship date. "When did it actually happen." The fingerprint's capture-week bucket and all temporal-cognition primitives key off this field, not `filedAt`.

This two-clock model shipped first in Swift as `Drawer.eventTime`: full field, nullable SQLite column with NULL→`filedAt` backfill on read, `CaptureFrame.eventTime`, capture stamping (`frame.eventTime ?? now`), fingerprint integration, and an acceptance suite. It is canonical in the published interface (`Drawer.eventTime`, `CaptureFrame.eventTime`) and named in invariant I-7.

Two questions were open and are now closed:

1. A later proposal suggested a **new `occurredAt` primitive** for authored-in-world time — not realizing `eventTime` already provides exactly that semantic.
2. The Rust port had **zero** `event_time` despite the interface stating "Rust mirror these fields" — a pre-existing conformance gap, not a design question.

## Decision

**`eventTime` is the single authored-in-world origin-time primitive on `Drawer`. It is not renamed, and no parallel primitive is introduced.**

1. **No `occurredAt`.** A new `occurredAt` field would duplicate `eventTime`'s semantics. Rejected.
2. **No rename `eventTime → occurredAt`.** Renaming would diverge from the published `LOCUSKIT_INTERFACE`, edit I-7's column list, and ripple through every consumer for no semantic gain. Rejected.
3. **The Rust port mirrors Swift `eventTime` field-for-field:**
   - `Drawer.event_time: i64` — **non-optional**, mirroring Swift's non-optional `eventTime: Date`. `Drawer::new` defaults it to `filed_at` (the Rust expression of Swift's `eventTime ?? filedAt`).
   - `CaptureFrame.event_time: Option<i64>` — **nullable**, mirroring Swift's `eventTime: Date?` (default `None`).
   - Nullable `eventTime` SQLite column; the drawer row decoder backfills NULL/absent → `filed_at` on read (mirroring the Swift `DrawerStore` read path).
   - `capture` stamps `frame.event_time.unwrap_or(now)` (mirroring the Swift capture path in `EstateVerbs`).
   - The fingerprint capture-week bucket keys off `event_time`, not `filed_at` (mirroring the Swift `DrawerFingerprint` bucket logic).

**Storage discipline:** `eventTime` is TEXT ISO8601 at the SQLite boundary in both ports (the project-wide TEXT/ISO8601 date rule, I-7); the Rust port holds it as epoch-seconds `i64` internally, as it does for `filed_at`. The column lands additively in the v1 schema declaration with **no migration ladder** — no estate data has shipped (pre-1.0), so additive nullable columns are the sanctioned pattern.

## Alternatives considered

- **New `occurredAt` primitive** — rejected: duplicates an existing primitive; two fields for one semantic invites drift.
- **Rename `eventTime → occurredAt`** — rejected: published-interface divergence, I-7 edit, and a full consumer cascade with zero semantic benefit.
- **Rust `Drawer.event_time: Option<i64>`** (a tentative early suggestion) — rejected in favor of non-optional `i64`: Swift's `Drawer.eventTime` is non-optional and always concrete (= `filedAt` when unset). A non-optional Rust field is the faithful mirror; nullability belongs only on the `CaptureFrame` slot and the SQLite column, exactly as in Swift.

## Consequences

- **Cross-port fingerprint conformance holds.** Both ports now key the capture-week bucket off the authored-in-world clock. For streaming capture (`event_time == filed_at`) the bucket is unchanged, so existing conformance vectors stay byte-identical; the two clocks diverge only for historical ingest, where keying off `eventTime` is the correct behavior in both ports.
- **Security (advisory, non-blocking).** A trusted local caller can set `CaptureFrame.event_time` to an arbitrary epoch, shifting a drawer's SimHash temporal bucket (0–255). This affects only dedup clustering — no authorization or privacy-routing decision keys off the fingerprint bucket — and the exposure is identical in the already-shipped Swift port. Optional future mitigation: clamp `event_time` at capture if dedup ever becomes a trust boundary.
- **No spec/interface edit required.** The Rust change makes the port conform to the already-published `eventTime` contract; the interface's "Rust mirror these fields" clause already covers it.

## Out of scope (recorded so it is not lost)

**`SourceRef` (contentHash / mime / byteSize)** is genuinely net-new on *both* ports (additive over the existing `source_file`/`chunkIndex`) and remains deferred. It is a separate decision; it is *not* governed by this ADR.

## Status note

This ADR is the canonical, discoverable home for the keep-`eventTime` decision and the two-clock model, so they do not drift silently, and so any future "add an origin-time field" proposal is routed to `eventTime` rather than re-deriving it.
