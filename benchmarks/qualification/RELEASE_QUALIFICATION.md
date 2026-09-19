---
title: Release Qualification
version: v0.2
status: draft
date: 2026-09-17
description: The final pass before a version goes quiet, run by `make release-qualification PORT=`: setup verified, the faker smoke, the product smoke, one real unit through the whole line, and every ARIA tool fired once against a clone of it with each outcome pinned.
---

# Release qualification

The benchmarker is the product's validation. Debugging happens elsewhere,
with the product's own commands on scratch estates; when a fix is in, this
pass proves it. Nothing in it is bent to diagnose.

## Stations

    make release-qualification PORT=swift|rust [QUAL_DS=locomo] [QUAL_UNIT=conv-26]

1. `verify-setup`: the port's product binary and the dataset's seed projection
   exist (`make setup` made them).
2. `smoke-builder`: the assembly line on the faker.
3. `smoke-builder PRODUCT=1`: the same line on the product binary through the
   seam; writes the binary stamp the fleet builds require.
4. `proof-unit`: one real unit imported and settled by the product finisher
   into a scratch base under the work root.
5. `catalog-exercise`: every tool in `tools/list` fired once against a clone of
   that unit, in the order of `catalog-calls.json`, with the outcome of each
   call pinned. The report (`report.json`) records per call the arguments,
   wall latency, outcome, and the SHA-256 and byte count of the reply text;
   no reply content is kept. The source estate is never served.

Any station failing stops the pass. The report directory is
`<work root>/qualification/<port>-<stamp>/`.

## The call table

`catalog-calls.json` is the contract: one entry per tool (a tool may appear
twice with different arguments), in firing order. Each entry names its
`arguments`, may `capture` values from the reply's structured data into
placeholders (`${MEMORY_ID}`) for later entries, and states what it
`expect`s: `ok`, or `refusal:<code>` where a refusal is the contract being
exercised (a transient stdio serve has no federation peers, no monitoring
control, no second estate to compare against). A `note` says why. Every tool
`tools/list` names must be in the table, and every table entry must be in
the list; either gap fails the pass, so a catalog change is a table change.

`--record` (make `RECORD=1`) fires the table without judging and keeps the
first 200 characters of each reply, for building the table against a new
estate shape. A serve that dies under a call is recorded as `crash:` and
reopened on the same clone so one crash does not hide the next.

## Changelog

### v0.2 — 2026-09-17

The four parity gaps recorded by v0.1 are closed and their table rows carry
one expected outcome again: `moot_federated_recall`, `moot_migration_run` and
`moot_migration_confirm` refuse with `orchestration_unavailable` in both
ports; `moot_review_tunnel` endorse refuses with `mutation_unavailable` in
both; `moot_lens_divergence` and `moot_lens_overlap` against the estate itself
refuse with `lens_unavailable` in both (a comparison needs a second estate);
the Rust atomic filer answers `Stale` under the same guards as Swift. Ruled
alongside: a `moot_json_import` seed file that fails to decode is an
`invalid_argument` refusal naming the record, both ports; a path that does
not resolve stays `mobility_unavailable`.

### v0.1 — 2026-09-17

First version. Found on its first runs: `moot_lens_associations` took the
Swift serve down by encoding an infinite conviction (fixed in the wire
encoder, both ports write null); `moot_propose_contradictions` refused every
proposal as stale on Swift because the atomic filer's pair-key guard checked
a spelling the hunt never writes (fixed in LocusKit). Recorded as open parity
gaps in the table: the two ports refuse `moot_federated_recall`,
`moot_migration_run`, `moot_migration_confirm` and `moot_review_tunnel` with
different codes; `moot_lens_divergence` and `moot_lens_overlap` against the
estate itself answer on Rust and refuse on Swift; the Rust atomic filer has no
stale guard at all.
