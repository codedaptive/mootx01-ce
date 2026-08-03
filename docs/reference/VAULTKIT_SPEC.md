---
title: VaultKit Specification
version: v0.3
status: active
date: 2026-08-03
description: "Behavioral specification for VaultKit: invariants, behavioral contracts, and the guarantees the bridge makes to callers and the substrate."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/VAULTKIT_INTERFACE.md
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#6-vault-and-data-movement
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#7-federation-cryptography-and-sensitivity
  - docs/reference/GENIUSLOCUSKIT_INTERFACE.md
  - docs/reference/LOCUSKIT_INTERFACE.md
purpose: |
  VaultKit is the data-movement layer that bridges a MOOTx01 estate and
  the external world — human-readable Markdown vaults (Obsidian / OKF),
  programmatic exchange formats, and MemPalace. It owns import, export,
  and palace-pump operations: the substrate stays authoritative; the vault
  is a projection (export) or an external source (import). This SPEC
  defines the behavioral invariants the bridge enforces, the contracts it
  guarantees to callers, and the conformance requirements both the Swift
  and Rust ports must satisfy.
---

# VaultKit Specification

## § 1 — What this package is

VaultKit is the bulk data-movement kit. It moves estate content out to
Markdown vaults (export), pulls external content in (import), and pumps
the four-noun data model into a live MemPalace instance. It sits directly
above GeniusLocusKit — it consumes GLK verbs and LocusKit value types
through their public surfaces and modifies no substrate primitive,
schema, bitmap, or enum case.

The kit has three import paths and one export path:

1. **Obsidian / OKF vault import** (`VaultBridge.importVault`): reads a
   directory of `.md` files through a `VaultAdapter` into `NoteIR`, then
   captures each note via GLK's capture seam.
2. **MemPalace NoteIR import** (`VaultBridge.importMemPalace`): reads
   the three MemPalace stores (chroma.sqlite3, tunnels.json,
   knowledge_graph.sqlite3) through `MemPalaceChromaAdapter` into
   `NoteIR`, then routes through the same capture path as vault import.
3. **Direct palace import** (`PalaceBridge.importPalace`): reads the
   same three MemPalace stores and constructs `CaptureFrame`s natively,
   bypassing `NoteIR`. Higher throughput for large palaces; same four
   import guards as the NoteIR path.
4. **Export** (`VaultBridge.export`): projects believed drawers and their
   `.references` tunnels through a `VaultAdapter` to a vault directory.

A fifth surface — `PalacePump` — moves the whole estate to a live
MemPalace MCP server item by item; it is an outbound pump, not a
read/write bridge.

Both the Swift (async) and Rust (synchronous) legs are live. All public
invariants and behavioral contracts in this spec apply to both ports
unless a port adaptation is explicitly noted.

## § 2 — Scope

This specification defines:

- The privacy-tier enforcement contract on the export bulk channel.
- The sensitivity-floor invariant on import (no downgrade).
- The four import guards: tombstone, content-idempotent dedup, sensitivity
  floor, and tunnel signature dedup.
- The idempotency contract: what a re-import is guaranteed to produce.
- Audit receipt semantics: one per import/export run, diary-backed.
- The `CorpusDocument` format contract: strict versioned decode, canonical
  JSON byte-equality across ports.
- The FNV-1a 128-bit lineage derivation: the cross-language conformance
  anchor for vault identity.
- The `VaultAdapter` seam: the format-agnostic boundary contract.
- The `ImportPolicy` auto-size-gate: who chooses bulk vs stream write.
- MCP tool exposure: the `moot_vault_*` and `moot_palace_import` tool
  contracts.
- Conformance requirements (§ 7) both ports must satisfy.

This specification does NOT define:

- The public API signatures — those live in `VAULTKIT_INTERFACE.md`.
- Substrate schema, bitmap bits, or enum cases — VaultKit modifies none.
- The FDC classification engine — EideticLib owns it; VaultKit defers to
  it via a feature-flag-gated lookup.
- The QueueKit / dreaming pipeline — out of scope for this kit.

## § 3 — Position in the kit family

```
SubstrateLib
   ▲
LocusKit + GeniusLocusKit      ← VaultKit calls these, never below
   ▲
VaultKit                       ← this kit (bulk data-movement)
   ▲
AriaMcpKit                     ← exposes VaultBridge as MCP tools
```

**Depends on:** GeniusLocusKit (capture verbs, recall, diary), LocusKit
(value types: Filter, Frame, CaptureFrame, TunnelCaptureFrame, DiaryEntry,
KGFact), and their transitive substrate dependencies. No SQLite, no
PersistenceKit, no LocusKit internal types are reached directly — only
public kit surfaces.

**Consumed by:** AriaMcpKit (the `moot_vault_*` and `moot_palace_import`
tool handlers), product-level import/export flows.

## § 4 — Invariants

**I-1 (no substrate primitives touched):** VaultKit never reads or writes
a SQLite column, schema row, LocusKit internal type, or bitmap bit
directly. Every substrate operation routes through GLK's public verb
surface (`capture`, `captureBatch`, `recallTunnels`, `addDiaryEntry`,
etc.). This is a layering invariant, not a performance recommendation: if
a future change requires VaultKit to call a lower-level surface, it is a
layering violation and requires an ADR.

**I-2 (deterministic wall clock — `now` is always injected):** neither
`VaultBridge` nor `PalaceBridge` reads the wall clock internally.
Every operation that stamps a timestamp (capture frame `eventTime`, diary
receipt `filedAt`, audit receipt `occurredAt`) uses the `now` parameter
supplied by the caller. This applies to both ports: Swift's `now: Date`,
Rust's `now: i64` (milliseconds-since-epoch). Tests inject a fixed `now`
to assert deterministic outputs.

**I-3 (secret tier never rides bulk export):** the `.secret` sensitivity
tier never appears in a vault export, under any `VaultExportScope`. The
bulk channel enforces this AFTER the filter chain runs, by partitioning
the projection — so the secret-exclusion count is always reported in
`ExportReport.excludedSecretTier`, never silently dropped.

**I-4 (private tier opt-in):** the `.restricted` sensitivity tier is
excluded from bulk export unless the caller explicitly selects
`VaultExportScope.believedIncludingPrivate`. Every other scope silently
excludes the private tier, and the count is reported in
`ExportReport.excludedPrivateTier`. The owner-key ceremony that will gate
the `.believedIncludingPrivate` scope is the planned 1.1 vault
authorization gate; the scope is the enforcement hook it will attach to.

**I-5 (sensitivity floor on import — no downgrade):** a re-import may
RAISE a drawer's sensitivity tier but never LOWER it.
`DrawerMapping.importNote` / `import_note` snapshots the current tier of
every believed drawer before the import loop (across ALL sensitivity
tiers, including restricted and secret, via a lifted `.sensitivityAtMost(.secret)`
recall) and floors the incoming `CaptureFrame.sensitivity` to
`max(incoming, existing)`. This prevents a hostile vault file from
downgrading a victim drawer's tier through the supersession cascade.
Both ports enforce this; it is machine-tested by the `privacy_tiers`
fixture.

**I-6 (tombstone protection — no resurrection):** a lineage that has been
withdrawn (state `withdrawn`, i.e. deliberately operator-retracted) or
erased (cluster C tombstoned) is never resurrected by a vault or palace
re-import. The tombstone set is computed once before the import loop and
checked before any `CaptureFrame` is built. Both ports enforce this.

**I-7 (content-idempotent dedup — no spurious supersession):** a
re-import of a note whose lineage is already active with byte-identical
content produces no write — `drawersSkippedUnchanged` is incremented and
no supersession cascade fires. An exportability-only change (e.g.
public → private) on otherwise-identical content IS a meaningful write
that must not be suppressed; the skip gate checks all three conditions:
content match AND no sensitivity upgrade AND no exportability change.

**I-8 (tunnel signature dedup):** a tunnel whose `(sourceWing, sourceRoom,
targetRoom, label, kind)` signature is already present in the estate is
not recreated. The signature set is snapshotted once before the import
loop and checked per tunnel. This makes import idempotent on tunnels even
across multiple runs.

**I-9 (I-5 compliance on every captured drawer):** every `CaptureFrame`
built by `DrawerMapping` satisfies GLK's invariant I-5 (`content`,
`room`, `udcCode`, `addedBy`, and `embeddingModelID` are all non-empty).
Notes with empty content are rejected before a frame is built — counted
in `ImportReport.itemsSkipped`, never silently discarded. The mapping
uses `"000"` as the UDC sentinel (EideticLib classifies on ingestion) and
`"vaultkit-noembed-v1"` as the embedding model placeholder.

**I-10 (zero-loss accounting — C-13):** every `NoteIR` field that does
not ride into the substrate in a given import is recorded in
`ImportReport.fieldsDropped` (key = field name, value = note count). No
dropped field is silent. Currently all structured fields land (facts →
KGFacts, scope → KGFacts, tags → KGFacts, kind → KGFact), so the
dictionary is empty for fully-structured fixtures; the field remains on
the public struct for future additions.

**I-11 (audit receipts — one per run, diary-backed):** every successful
`export`, `importVault`, `importMemPalace`, and `importPalace` run writes
exactly one diary receipt under agent name `"vaultkit"`, topic
`"vault-receipt"`, wing `"wing_vaultkit"`, room `"receipts"`. The receipt
carries a canonical JSON body (sorted keys, no slash escaping) that is
byte-identical across Swift and Rust for the same inputs. Import receipts
include `drawersSkippedPartialWrite` in the body so partial-write events
are auditable. A run that throws before the receipt write produces no
receipt.

**I-12 (CorpusDocument strict-versioned decode):** `CorpusDocument.decode`
reads `formatVersion` FIRST and throws `VaultKitError.unsupportedFormatVersion(n)`
for any value other than `currentFormatVersion` (currently `1`). There is
no silent best-effort decoding of an unknown format. Decoding a
pre-extension `NoteIR` JSON (missing `facts`, `pathComponents`, `scope`,
or `kind` keys) succeeds with the documented defaults — backward-compatible
but not forward-compatible.

**I-13 (canonical JSON byte-equality across ports):** `CorpusDocument.canonicalJSON()`
/ `canonical_json()` and `ExchangeAdapter.encode` / `PalacePayloadEnvelope.encodeFields`
produce byte-identical output in both ports for the same input. Rules:
object keys sorted ascending (Swift `.sortedKeys` / Rust `BTreeMap`),
compact (no whitespace), forward slashes unescaped, optional fields
omit their key when nil, `mootID` serialized as uppercase hyphenated UUID
string. A shared golden fixture is asserted byte-for-byte in both test
suites.

**I-14 (FNV-1a lineage ID — cross-language conformance anchor):**
`DrawerMapping.lineageID(forStableSourceKey:)` / `DrawerMapping::lineage_id(key)`
implement FNV-1a 128-bit over the key's UTF-8 bytes with the standard
constants, packed big-endian into 16 UUID bytes. A shared conformance
vector (five canonical inputs including the empty string) is asserted
bit-identical in both test suites. This function is the single identity
anchor for import deduplication; no other lineage-derivation path is
permitted.

**I-15 (VaultAdapter seam — adapter never reaches the substrate):** a
`VaultAdapter` conformer reads and writes only its vault format.
It is permitted to touch the filesystem under `vaultURL`. It must not
call any GeniusLocusKit or LocusKit verb, open any SQLite connection, or
read any estate handle. `DrawerMapping` is the only type that crosses the
adapter-to-substrate boundary.

**I-16 (path traversal — vault containment enforced on write):** every
vault-relative output path is validated before any filesystem write by
`ObsidianAdapter.containedVaultURL(forRelativePath:under:)` (lexical
layer: rejects `..`, absolute prefixes, backslashes, empty/`.` components)
and `ensureContainedInVault(_:under:)` (symlink layer: resolves symlinks
and verifies the physical path is inside the vault root). A pre-existing
symlink at the exact output file path is refused by
`ensureWritableFileTarget`. Fail-closed: errors surface as
`VaultKitError.adapterError`, never silent. Rust mirrors identically via
`contained_vault_path` and `write_contained_file`. Both layers run for
every note write AND every `index.md` write.

**I-17 (ImportPolicy auto-size-gate — caller never selects write strategy):**
the decision between bulk `captureBatch` (one transaction) and per-item
streaming is made automatically by `ImportPolicy.useBulk(itemCount:)` and
the threshold is `ImportPolicy.streamThreshold` = 250,000 items. No
public API parameter controls the write strategy. `mode: EncodeSpeed`
controls the encode DRAIN speed (foreground / background) only; it does
not affect the write strategy. This ensures no caller can accidentally
issue a single transaction across a hundred-thousand-row import.

**I-18 (OKF v0.1 superset in default mode):** `ObsidianAdapter` in
default mode (`pureObsidianLinks = false`) emits output that satisfies
OKF v0.1: the `type:` frontmatter key is set on every note (derived from
`NoteIR.kind`), relationship links are rendered as standard-md
`[alias](relpath.md)`, and a frontmatter `tags:` array is emitted. The
skip rule — `index.md` and `log.md` stems are skipped during `toIR` —
prevents OKF navigation files from re-importing as spurious notes.

## § 5 — Behavioral contracts

**B-1 (export is a projection, not a destructive operation):** export
reads the estate but never writes to it. The vault directory receives the
output; the estate is unchanged. The only estate write is the audit
receipt (I-11).

**B-2 (import is idempotent on `stableSourceKey`):** running the same
import twice with no estate changes between runs produces the same final
estate as running it once. The second run increments
`drawersSkippedUnchanged` for every unchanged note and `itemsSkipped` for
empty-content notes; `drawersWritten` and `drawersUpdated` are both 0.

**B-3 (round-trip identity — `moot_id` rename safety):** an exported
note carries its drawer's `lineageID` as the `moot_id` frontmatter key.
On re-import, `DrawerMapping` uses `moot_id` as the capture frame's
`lineageID`, so the supersession cascade maps the re-import to the same
substrate lineage even when the human renames the file. Identity priority
order: (1) `NoteIR.mootID` parsed from `moot_id` frontmatter, (2)
`frontmatter["moot_id"]` → UUID, (3) FNV-1a hash of `stableSourceKey`.

**B-4 (sensitivity floor applies before the content-idempotent skip):**
the sensitivity floor check (I-5 guard) runs BEFORE the
content-idempotent dedup check (I-7 guard). A re-import of an unchanged
note that carries a HIGHER sensitivity tier still applies the upgrade
(the skip guard must not short-circuit a pending tier promotion).
Conversely, an exportability-only change (e.g. `public → private`) on
byte-identical content is also a meaningful write that bypasses the skip.

**B-5 (partial-write events are surfaced, never absorbed):**
`drawersSkippedPartialWrite` counts re-imports where a
`DisciplineViolation` fired after the supersession cascade committed the
successor drawer but before the predecessor belief-state flip completed —
leaving an orphaned successor in the estate. These events are always
surfaced in `ImportReport` and in the import audit receipt; they must not
be absorbed into `itemsSkipped`.

**B-6 (bulk `captureBatch` path enqueues encoding post-batch):** the bulk
write path intentionally skips per-item encode enqueue to avoid O(N)
queue writes inside a single transaction on large imports. After the
batch write completes, `importNotes` / `import_notes` calls
`reindexMissing` / `collect_reindex_jobs` (capped at 10,000 per call)
and reports the enqueued count in `ImportReport.enqueuedForEncode`. A
value of 0 on a bulk import means every drawer was already indexed
(idempotent re-import) or the estate has no registered Corpus.

**B-7 (drift manifest is tool-layer owned, not kit-owned):** the
`moot_vault_export` tool writes a per-note SHA-256 manifest at
`.moot/export-manifest.json` inside the vault (a hidden directory,
invisible to `ObsidianAdapter.toIR`'s `.skipsHiddenFiles` enumerator).
`VaultBridge.export` itself does not stamp per-note hashes — drift
detection is the tool layer's responsibility. `moot_vault_reconcile`
recomputes SHA-256 hashes and classifies notes as added, modified, or
deleted; deleted notes are reported only, never actioned.

**B-8 (candidate seam is return-only):** `moot_vault_reconcile` produces
a candidate list (added + modified notes) but writes no Proposal noun and
mounts no QueueKit instance. Deletions are reported in the diff, never
actioned (no drawer is expunged through the vault channel).

**B-9 (palace pump KG envelope rides `source_closet`):** when
`PalacePumpMapping.call(for:)` / `call(item)` maps a KG fact, the
envelope rides the `source_closet` field, never the `object` field.
MemPalace caps entity-name fields at 128 chars (`MAX_NAME_LENGTH`);
putting a large envelope on `object` would be rejected. A
`PalaceDriftDetector` diff runs before any write; a renamed tool or
changed required arg halts the pump with a precise finding list.

**B-10 (PalaceBridge bulk window is always used for chroma rows):** the
per-item streaming path for chroma rows is disabled as of the
develop/1.1.x line. All chroma rows are imported through `captureBatch`
in `ImportPolicy.bulkWindow`-sized transaction windows. KG entities,
triples, and tunnels continue to be imported per-item (they require
individual post-capture work). Both ports maintain the same window
discipline.

**B-11 (ExchangeAdapter canonical encode is idempotent and legacy-safe):**
`encode(decode(bytes))` is byte-stable: a legacy flat-note JSON (no
extended fields) re-encodes in the legacy flat shape (extended keys at
their defaults are omitted). `decode(encode(x)) == x` for format-
representable notes. Fields the exchange format cannot carry are
documented in the INTERFACE doc; none are silently dropped — this is the
enumerated list.

## § 6 — Error model

Errors are surfaced as `VaultKitError` (Swift) / `VaultKitError` (Rust).

| Category | Trigger | Recovery posture |
|---|---|---|
| `unsupportedFormatVersion(n)` | `CorpusDocument.decode` sees a `formatVersion` other than `currentFormatVersion` | Abort; the format is not supported |
| `adapterError(String)` / `AdapterError(String)` | Adapter-level failure: path traversal rejection, vault containment violation, malformed input, MemPalace write attempt | Surface to caller; describes the specific violation |
| `i5Violation` (Rust) | A frame fails the GLK I-5 pre-submission check | Abort; programmer error in frame construction |
| `verbError` (Rust) | A GLK capture verb returns an error | Surface and abort the current import/export run |
| `io` (Rust) | OS-level I/O error | Surface to caller |
| `serialization` (Rust) | JSON encode/decode failure | Surface to caller |

Swift surfaces non-`VaultKitError` errors as the originating Foundation
`DecodingError` / `EncodingError` (for corpus JSON) or rethrows the
underlying GLK or filesystem error. The Rust `Serialization` case is the
analogue for JSON failures.

Fail-closed for security: path traversal, vault containment violations,
and pre-existing symlink detections all throw — the write is never
performed silently.

### Planned 1.1 resident automation

The 1.1 product plan adds an optional resident control layer that automates
eligible vault import, export, and resync. This does not become a new
`VaultBridge` responsibility: the bridge remains a deterministic per-call
adapter. The resident scheduler owns filesystem watching, estate-change
observation, debounce/coalescing, retry, lifecycle, and operator status.

The scheduler builds on the existing tool-layer manifest:

- incremental sync handles ordinary eligible changes;
- full resync re-hashes the vault at startup, after watcher overflow or a
  detected event gap, on a periodic integrity cadence, and on explicit request;
- deletion remains report-only;
- a manifest advances only after the corresponding cycle succeeds;
- failures and policy-blocked candidates remain visible to the operator.

Automated mode is fail-closed and narrower than manual import/export:

- outbound selection is limited to public/exportable content;
- `.restricted` and `.secret` sensitivity tiers are always excluded;
- private/non-exportable content is excluded;
- inbound candidates marked private, restricted, or secret are rejected or
  quarantined before `DrawerMapping.importNote`;
- an existing restricted/secret lineage cannot be changed through the
  automated vault path;
- `.believedIncludingPrivate` is never a scheduler scope.

Manual, explicit, authorization-gated operations remain the only path for an
intentional private transfer. Secret content never rides bulk export.

The product calls this **insecure mode** because eligible content is
continuously projected into an ordinary filesystem vault whose permissions,
backups, sync providers, and plugins sit outside MOOTx01's estate boundary.
The label does not relax the automated data gate. Correct classification
remains necessary: automation cannot protect private text incorrectly marked
public/exportable and below the protected sensitivity tiers.

The always-running scheduler requires the resident service. Direct-stdio
processes are client-lifetime transports and do not own continuous vault
maintenance. `moot-mgr` is the operator surface for configured path, watcher
health, last successful cycle, resync reason, blocked-candidate counts, and
failures.

## § 7 — Conformance requirements

**C-1 (cross-port byte-identical canonical JSON):** `CorpusDocument.canonicalJSON()` /
`canonical_json()` and `ExchangeAdapter.encode` / `ExchangeExport.encode`
produce byte-identical output in both Swift and Rust for the same input.
A shared golden fixture is asserted byte-for-byte in both test suites.

**C-2 (FNV-1a conformance vector):** `DrawerMapping.lineageID(forStableSourceKey:)` /
`DrawerMapping::lineage_id(key)` produce bit-identical UUID output for
the five canonical conformance inputs (including the empty string) in
both test suites. Any change to the FNV implementation breaks this
vector and must be treated as a breaking contract change.

**C-3 (privacy-tier enforcement):** the `export_cap` / `privacy_tiers`
fixture asserts that secret-tier drawers never appear in any export
scope, and that private-tier drawers appear only under
`.believedIncludingPrivate`. Both ports assert this fixture.

**C-4 (import idempotence):** the `idempotent_import` fixture asserts
that importing the same vault or palace twice produces `drawersWritten = N`
on the first run and `drawersSkippedUnchanged = N` on the second, with
`drawersWritten = 0` on the second. Both ports assert this fixture.

**C-5 (sensitivity floor — no downgrade):** the `privacy_tiers` fixture
asserts that a re-import carrying a lower sensitivity tier for a
lineage that was previously elevated is rejected (floor enforced). Both
ports assert this fixture.

**C-6 (vault containment):** the `vault_containment` fixture asserts that
every path traversal attempt (`../`, absolute prefix, backslash,
empty component) throws `VaultKitError.adapterError` and produces no
filesystem write. Both ports assert this fixture.

**C-7 (MemPalace adapter golden fixture):** the `mem_palace_adapter`
fixture asserts that both ports produce an identical `[NoteIR]` slice
from the shared fixture palace directory. `originDate` normalization
(`canonicalISO8601(fromMemPalace:)` / `canonical_iso8601_from_mem_palace`)
is asserted for all four MemPalace timestamp shapes.

**C-8 (palace four-noun pump):** the `palace_four_noun` fixture asserts
byte-identical `PalacePayloadEnvelope` output for all four noun types in
both ports.

**C-9 (OKF round-trip):** the `wing_vault_layout` / `structured_import`
fixtures assert that a vault written by `ObsidianAdapter.fromIR` in
default OKF mode is readable by `ObsidianAdapter.toIR` with identical
`links`, `tags`, `frontmatter`, and `stableSourceKey` values. The
`type:` key written on export is NOT parsed back into `NoteIR.kind`
(it remains in the frontmatter map only — one-way derivation).

**C-10 (cross-port parity for `ObsidianAdapter`):** the `charter_and_provenance`
fixture and the golden OKF round-trip fixture are asserted byte-identically
in both ports.

## Changelog

### v0.3 — 2026-08-03

Bounded the MemPalace importer's reads and stated the adapter's trust
posture as a behavioural contract: the palace root is UNTRUSTED input, so
its size is an attacker-influenced value rather than a fact the importer
may assume. Four ceilings now hold for every MemPalace import, on both the
`MemPalaceChromaAdapter` path and the `PalaceBridge` direct-import path:
a `tunnels.json` maximum size checked BEFORE the file is opened, a maximum
SQLite row count, a maximum total of materialized column bytes, and a
SQLite progress-handler step budget that abandons a query whose plan
degenerates. Rows and bytes are accounted against ONE budget per import,
so both are real totals rather than a per-store allowance.

Two guarantees are load-bearing for callers. First, **a breach names both
the limit and the observed value** — an import that dies on an
unexplained cap is worse than one that is slow. Second, **a normal palace
imports exactly as before**: the defaults are sized against a measured
real palace with the headroom factors recorded in
`VAULTKIT_INTERFACE.md`, and the limit VALUES are identical in both ports
and asserted literally in both suites, because divergent caps would mean
an import that succeeds in one port and fails in the other.

Streaming was ruled out rather than overlooked: `VaultAdapter.toIR`
returns a fully-materialized array whose contract is deterministic order
by `stableSourceKey` bytes, and that sort requires every note resident.
Bounding the reads is the fix; the one materialization that could be
removed inside the adapter (the Swift chroma scan's second copy) was.

Front-matter version corrected from a stale v0.1 — a v0.2 entry already
existed below.

### v0.2 — 2026-07-23

Documented the planned 1.1 resident vault scheduler: continuous eligible sync,
full-resync triggers, manifest commit rules, `moot-mgr` observability, and the
fail-closed automated-mode gate that excludes private/non-exportable,
restricted, and secret content.

### v0.1 — 2026-07-16

Initial authorship. Covers behavioral invariants and contracts for the
develop/1.1.x codebase: privacy-tier enforcement, sensitivity floor,
four import guards, ImportPolicy auto-size-gate, audit receipt contract,
CorpusDocument strict decode, FNV-1a lineage anchor, vault containment,
OKF v0.1 superset, palace bulk window, and cross-port conformance
requirements.
