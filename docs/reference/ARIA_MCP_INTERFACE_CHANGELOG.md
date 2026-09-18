---
title: aria-mcp Interface — Changelog
version: 4.7.1
date: 2026-09-15
description: "Historical changes to the ARIA MCP INTERFACE document."
status: active
---

# aria-mcp Interface — Changelog

### 4.7.1 -- 2026-09-15

Documented v23-attributed memory-get distillation parity and the product
`--version` hydration/recall converter identity lines. No wire schema change.

### 4.7.0 -- 2026-09-15

`moot_drain_status` always lists the `fact_extraction` lane: `pending` is
the count of drawers still owed fact extraction for the active recipe
(bit 28 clear), `state` is `draining` while any drawer is owed and `idle`
once none are. The report shape is unchanged. Both ports.

### 4.2.0 -- 2026-09-13

Added `moot_memory_get(depth: "skim")` and its preview-only `skim` object:
`text`, `complete`, `budgetHonored`, and `savings`. Retains id and full-fetch
reference. Corrected the public get argument names to `memory_id`/`memory_ids`.

### 4.1.0 -- 2026-09-13

Added the default-off report_withheld modifier, conditional sensitivity-only meta
count, ranked topK keystones hydration definition, and unchanged-schema contract.

### 4.0.0 -- 2026-09-11 (BREAKING)

The four work-packet operations retired from the ARIA surface, both ports:
`moot_file_packet` (§6.1, Tier 1 — Intake), `moot_packet_get`,
`moot_packet_list`, and `moot_packet_lineage` (§10, Utility family). Deleted
source: `PacketTools.swift`, `AriaV2PacketOperations.swift`,
`AriaMcpKit/rust/src/v2/packets.rs`. The `WorkPacketKit` dependency is
removed from `AriaMcpKit/Package.swift`; the Rust port never carried a
packet implementation, so no Rust source was removed there beyond the
catalog/surface/dispatch entries naming the four tools. `.interface`
provenance (§4.2) and the capture-family summary (§6) no longer mention
packet tools. Tool count moves from 84/77 (vault-on/off) to 80/73. Stored
packet drawers already committed to an estate are unaffected — this is a
surface retirement, not a schema change; no `mootx01 upgrade` step is
introduced. The capability digest changes accordingly (both ports compute
and agree on the same new value, pinned in `Registry/aria-v2-selected-release.json`
and both ports' `AriaV2CapabilityDigestTests`/`aria_v2_capability_digest_tests.rs`).

### 3.10.2 -- 2026-09-10

§12.5 coaching triggers wired to the v2 surface. `AriaV2Coach` (Swift) and
`v2::coach` (Rust) implement all six triggers from the §12.5 table. The v2
result envelope gains a hint slot: `structuredContent["hint"]` is set when a
trigger fires (string, sibling of `data` and `meta`, absent when no trigger
fires), and a `"\nhint: <text>"` line is appended to `content[0].text` after
the 512 Unicode-scalar clamp of the operation body (the hint line itself is
never clamped). Hints never attach to `isError: true` results. The first
matching trigger wins. The periodic coaching block (§12.4) is appended after
any hint line, preserving hint-before-block ordering. Estate-provisioned
`coaching_calls` and `sticky_enabled` are applied on the first dispatch call
of each session only (guarded by the `configuredFromEstate` once-flag).

Lens scope: the zero-results hint applies to `Recall`-family variants only
(`moot_recall_precise`, `moot_recall_temporal`, `moot_recall_connected`,
`moot_recall_shaped`, `moot_recall_distilled`, `moot_recall_vague`,
`moot_recall_walk`). `moot_federated_recall` and `moot_memory_recall_transcript`
route to separate enum variants (`FederatedRecall`, `TranscriptRecall`) and
never receive the zero-results hint. This is an intentional boundary documented
in §12.5.

### 3.7.0 -- 2026-09-07

The `moot_recall_shaped` roster under the dark switches, both ports (37 names
with `DenseFamilies`, 39 with `LSA`, 26 in the product build), and the
`mootx01 upgrade` whole-record vacuum line, byte-identical in both ports.
Full entry in ARIA_MCP_INTERFACE.md § Changelog.

### 3.6.0 -- 2026-09-07

The discrimination cap reads the span rerank stage alone, both ports; the
whole-record dense lane and its presets compile only under the
`WholeRecordDense` trait. Full entry in ARIA_MCP_INTERFACE.md § Changelog.

### 3.5.0 -- 2026-09-07

The live sensitivity grant ceiling floors `moot_file_packet` (new optional
`sensitivity` argument in the `moot_file_memory` shape; Swift only) and the
opt-in `memory` adapter's `create`, `str_replace` and `insert` (no
argument; both ports). Omitted tiers file at the grant's tier, an explicit
lower tier on `moot_file_packet` is refused with the `moot_file_memory`
text, and the replies name the tier while a grant is live. No change with
no grant live. Full entry in ARIA_MCP_INTERFACE.md § Changelog.

### 3.4.0 -- 2026-09-07

`moot_file_memory` files at the live sensitivity grant ceiling, both
ports: an omitted `sensitivity` takes the grant's tier, a lower explicit
tier returns `isError: true` naming the ceiling and writes nothing, and
the reply adds `sensitivity: <tier>` while a grant is live. No change
with no grant live. Full entry in ARIA_MCP_INTERFACE.md § Changelog.

### 3.1.0 -- 2026-09-06

`moot_memory_search` answer block parity (answer:always|auto), both ports.
The Rust reply renders the lines Swift `runMemorySearch` renders:
`confidence: confident|intermediate`, `citations:` with up to five ids, and
`signals: margin=<m1> lane_agreement=<m2> dense_spread=<m3>
containment=<m4>` in shortest two-decimal form. The Rust port composes no
answer text, so its `answer:` line stays absent. Rust reads m4 as false
with no composed answer and its citation ids are the first five hydrated
drawer ids (GENIUSLOCUSKIT_INTERFACE 3.1.0). Full entry in
ARIA_MCP_INTERFACE.md § Changelog.

### 2.13.0 -- 2026-09-05

ARIA-MSG-2: `moot_file_fact` with a `subject` that is empty or exceeds
120 characters after trimming now returns `isError: true` with the
contract message `"subject must be 1–120 characters (got N). One
telegraphic sentence in the AI-facing register — compress, don't
truncate."`, both ports. Previously the oversize subject reached the
generic catch wrapper and produced `"unexpected error in moot_file_fact:
invalidContent(…)"`, discarding the instructive text. Tests:
`fileFactOversizeSubjectReturnsContractError` and
`fileFactOversizeSubjectMessageMatchesRustPort` (Swift);
`file_fact_oversize_subject_returns_contract_error` and
`file_fact_oversize_subject_message_matches_swift_port` (Rust).

### 2.12.0 -- 2026-09-05

PAR-1: `moot_memory_search` reply parity, both ports. The Rust reply goes
through the shared S1 composer: adornment text in column 5 (no separate
`adornment:` line), structured rows carrying `score` / `eventTime` /
`firstSentence` / `adornment` / `adornments` / `room`, the removed
`recall_provenance:` line gone from the Rust reply, and the advertised
`explain` argument honoured in both ports with the explanation block
documented in §11.2 and pinned by the shared
`recall_explainer_fixture.json`.

### 2.11.0 -- 2026-09-04
Subject-length contract violations on `moot_file_memory` and `moot_update_memory` (`mutation=setSubject`) surface as `isError: true` results carrying the contract text instead of bare JSON-RPC `invalidParams` errors, both ports; a missing `subject` stays `invalidParams`.

### 2.9.1 -- 2026-09-03

Frozen posture (FRZ-3): `moot_synthesize` reclassified from the refused set
to the read set (`frozenReadTools` / `FROZEN_READ_TOOLS`) in both ports.
Grounded synthesis reads candidates via recall and generates text; it writes
no drawer, packet, journal, meta, trace, or reward, so a frozen serve must
answer it. The `moot_synthesize` entry gains the "Available under a frozen
serve" note. Both ports carry a new test `frozenSynthesizeProceedsAndEstateIsUnchanged`
/ `frozen_synthesize_proceeds_and_estate_is_unchanged` that verifies the
dispatcher lets the call through and the estate is byte-identical before and
after.

### 2.1.1 -- 2026-08-26

Vocabulary (mission SSC-RENAME): SSC defined as Semantic Search Candle
at first use; typed intermediate renamed `SemanticSearchCandleData`
(both ports), render fn `renderSemanticSearchCandleText` /
`render_semantic_search_candle_text`, row field `semanticSearchCandle` /
`semantic_search_candle`. Structured `ssc` key, row grammars, and all
rendered payloads byte-identical.

### 2.0.0 -- 2026-08-25

Adopted consolidation (Bob approval 2026-08-25) replacing the 1.59.0
document body with the consolidated interface reference drafted as
ARIA_PROPOSED_INTERFACE.md 0.1.0–0.3.0 (now archived): six-family tool
catalog; § 11 full result-format grammar catalog with Samples
(row-grammar rules, fixed-column canonical row, control-line grammars
with absolute trailing order, S2–S6 shapes, lossless tabular encoding,
structured base-row-plus-extensions schemas, zero/one/many
active-adornment composition with the ordered structured `adornments`
array); sensitivity-advisory relocation to tool descriptions +
estate_status; `ack` removed from recall_distilled. The entry ladder
below (1.0.0–1.59.0) is the verbatim pre-2.0.0 inline history,
externalized to this file at the 2.0.0 fold.

### 1.59.0 -- 2026-08-24

SCORE-ORDERING mission.

**`moot_memory_search` output format — score suffix:**
Every dense-row line in the response now ends with ` · %.4f` carrying the
final recall score (Swift `hit.score.final`, Rust `hit.score.final_score`).
Format: `<dense_row_content> · 0.8523`. The score is non-zero for every
ranked hit.

**`moot_memory_search` tool description — limit semantics:**
The `limit` parameter description now reads: "Relevance floor, not an exact
row count (default 20). Equal-scored results at the boundary are all
returned, so the actual count may exceed this value." Both the Swift
(`ToolProjection.swift`) and Rust (`tool_list.rs`) tool lists are updated.

**`moot_memory_search` — tie-disclosure message:**
When the GLK recall result carries `"tie.nonDeterminate"` in degraded stages,
the response appends: "note: additional results share this score on a
non-deterministic tie; refine the query". Rendered by both ports.

### 1.58.0 -- 2026-08-23

ADORNMENT mission.

**`register_default_standing_signals` signature (Rust):**
`register_default_standing_signals` in `autonomic_governor.rs` gains a
third `adornment_cycle: Option<Arc<dyn Fn(...)>>` parameter. All call
sites updated: `runtime.rs`, `governor_standing_signals.rs` tests,
ResidentDaemon.swift. Both ports change in the same commit.

**Swift `ResidentDaemon.setupStandingSignals()`:**
Third closure `adornmentCycle` wraps `kit.runAdornmentPass(handle:now:)`
and is passed to `registerDefaultStandingSignals`.

**Payload rendering:**
Adornment short form appended to dense-row output in
`denseRow(from:limit:adornmentSuppressed:)` when `adornment != nil` and
suppression env var is absent. Suppression seam: `adornmentSuppressed`
computed from `MOOT_SUPPRESS_ADORNMENT` env var at call site (benchmark-only).
Rust twin: `dense_row()` parity-updated.

**Dark tool registration:**
`RecipeTools.runAdornmentPassToolName = "moot_run_adornment_pass"` added
to `isRecipeTool(_:)`; dispatches to `runAdornmentPass(_:kit:handle:)`.
NOT added to `tools()` — dark, never listed.

### 1.57.0 -- 2026-08-22

MODES-PREFS mission: estate-provisioned modes preferences applied on first tool call.

**`ModeSessionState` changes (Swift actor / Rust `ModeSessionState`):**
- `configuredFromEstate: Bool` — new computed property backed by bitmap bit 1.
  Guards the apply-once contract: `applyPreferences` is a no-op after the first call.
- `applyPreferences(stickyEnabled:coachingCalls:)` / `apply_preferences(bool, usize)` —
  reads `ModesManifest` fields from the estate and applies them; subsequent calls are
  no-ops (bit 1 guard). Mirrors `GeniusLocusKit.provisionedModesConfig(for:)` round-trip.
- `setCoachingCallsX(_:)` / `set_coaching_calls_x(usize)` — now also sets
  `configuredFromEstate = true` so the seam takes precedence over the estate manifest
  in test contexts.

**`ToolDispatcher.dispatch` / `Dispatcher::tools_call` (Swift / Rust):**
On the first tool call (`!configuredFromEstate`), reads `provisionedModesConfig(for:)`
and calls `applyPreferences`. Subsequent calls skip the read. Absent or malformed
estate key falls through to spec defaults (stickyEnabled=true, coachingCalls=25).

Stale "future extension" comments removed from both ports.

### 1.56.1 -- 2026-08-22

Changelog repair: moved the orphan 1.55.0 entry from its prior
out-of-order position (after 1.1.0) to its correct chronological
position (after 1.56.0). No API change.

### 1.56.0 -- 2026-08-22

Moot Modes (MODES mission): five advisory tool-bundle modes at the ARIA door.

New symbols — both ports:
- `MootMode` enum (5 cases: Recall, Filing, Lenses, Vault, Curator) + `RecallVariant` enum (Auto, Rows, Answer)
- `ModeDeclaration` struct: `parse(_:)`, `recognizedMode`, `recognizedRecallVariant`, `unknownHint`
- `ModeSessionState`: `new()`, `recordCall(_:mode:)`, `stickyDeclaration`, `stickyEnabled`, `stickyRecallAnswerMode`, `coachingCallsX`, `totalCalls`, `snapshot()`
- `CoachingSnapshot` struct: `totalCalls`, `toolCounts`, `bigramCounts`, `modeAttributionCounts`
- `PeriodicCoach.renderBlock(for:)` / `render_block(snapshot)`: deterministic coaching block renderer
- `ToolDispatcher.modesStatusSection` / `modes_status_section()`: rendered modes roster appended to estate_status
- `TeachmeGuides.guide(for:)` now returns `String` (was static `&'static str` in Rust); `estate_status_guide()` renders dynamically from the registry
- `MootMode.coreToolsDescription` / `core_tools_description()`: "(plus the moot_lens_* family)" for Lenses
- `mode` arg on every tool (fail-open: unknown modes accepted and hinted)
- `modes.sticky_enabled` provisioned preference seam (always true in this build; `provisionedModesManifest` is a planned follow-up)

Conformance fixtures (shared between ports):
- `Tests/Conformance/modes_coaching_fixture.json` — coaching golden-pin
- `Tests/Conformance/modes_coaching_tie_fixture.json` — tiebreak golden-pin
- `Tests/Conformance/modes_status_section_fixture.json` — byte-identity pin for modesStatusSection

### 1.55.0 -- 2026-08-22

PACKAGER mission: `answer` arg added to `moot_memory_search` (both ports).

**`moot_memory_search` schema change (additive):**
New optional `answer` string property in the inputSchema. Valid values:
`"never"` (default, byte-identical), `"always"`, `"auto"`. Unknown values
return `invalidParams` (fail-closed). The property is discoverable via
`ToolProjection.tools()` (Swift) / `tool_list.rs` (Rust).

**Response shape when answer ≠ "never":**
`found N memory(s)` header, optionally followed by:
- `answer: <text>` (non-empty in Swift; empty in Rust — no Rust GroundedSynthesis)
- `confidence: high|medium|low`
- `citations: <uuid>, <uuid>, …`
- `signals: m1=… m2=… m3=… m4=…`
Then the scored rows (omitted for L0AnswerOnly).

### 1.54.0 -- 2026-08-22

Additive (front-door family — `door` argument + A1 manifest):
`moot_memory_search` gains a `door` adjective argument implementing the
front-door scoring-selection hierarchy (door > scoring > A1 DoorManifest
> matrixAware). Valid values: `guess`, `rrf`, `matrixAware`, `raw`,
`discriminative`; unknown strings fail closed. When neither `door` nor
`scoring` is supplied, the A1 `DoorManifest` is read from the estate
manifest (new default path). `scoring` description updated to note `door`
takes precedence. Interface section §scoring-and-door updated. Both ports.

### 1.53.0 -- 2026-08-21

Changelog ladder repair (merge of develop/1.1.x, 2026-08-21): the
moot_recall_temporal notes below were previously mis-filed as bullet
lines inside the 1.32.0 entry, self-labeled with version numbers
that the develop stream legitimately minted for unrelated changes.
They are re-homed here verbatim with their original self-labels
preserved as historical text; the labels do NOT refer to entries in
this ladder. No behavioral change in this entry.

- **v1.47.0 (2026-08-20)** — moot_recall_temporal description documents the date-seeking behavior; narration adds the date-seeking variant line. Schema unchanged.
- **v1.46.0 (2026-08-19)** — moot_recall_temporal schema gains `grab` (string: pool|dated, default pool). Narration line format: `temporal: <mode> (<source>, <grab>) window <bounds>[ ±Nd]`.
- **v1.45.0 (2026-08-19)** — moot_recall_temporal schema: query (required), window loose|tight (default loose), from/to (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ; explicit beats parsing), limit (default 20), pool (default 120), filter, wing, estateID; declares the shared recall-results output schema (sixth recall-family member).

### 1.52.0 -- 2026-08-21
Additive (D10 — walk_recall escalation ladder). `moot_recall_walk` MCP tool
added: recipe-provenance, 13th CognitionKit recipe tool in the `.recipe` bucket
(36 total recipe+lens, vault-on 76, vault-off 69). Recipe and lens tools section
updated: count 35→36, CognitionKit tools 12→13, `moot_recall_walk` added to
enumerated list and described. Arguments: `query` (required), `limit`,
`filter`, `wing`, `now`, `estateID`. Response: dense-row renderer output with
discrimination line and `walk:` metadata line. See `ARIA_MCP_SPEC.md §1.47.0`
for full invariant specification.

### 1.51.0 -- 2026-08-20
Additive (WIRE 1 + WIRE 2 — P4 study gaps). `moot_memory_search` and
`moot_recall_shaped` gain optional integer argument `frontier_k` (see argument
section above). `ShapedRecall.Input` / `shaped_recall::run` updated with an
additive `frontierK: Int? = nil` / `frontier_k: Option<usize>` parameter; all
existing callers compile unchanged (default nil). `tool_list.rs` and
`ToolProjection.swift` schemas expose the argument. Conformance:
`FrontierKArgumentTests.swift` (8 Swift tests). No Rust unit tests added
(boundary covered by Swift suite + Rust build gate). WIRE 2: benchmarker
`EstateSeams.swift` gains `MOOT_BENCH_PROVISION_RECALL_TUNING` seam — exact
mirror of `MOOT_BENCH_PROVISION_LANE_WEIGHTS` (env-var path → JSON-object
validation → SQLite INSERT OR REPLACE under manifest key `recall_tuning` →
stderr provenance line; hard-fail on any error). Called immediately after
`provisionLaneWeightsSeam` in `EstateCache.swift`. No Rust benchmarker mirror
(the Rust harness has no lane-weights seam — confirmed by empty grep). Seam
family doc block in `EstateSeams.swift` updated.

### 1.50.0 -- 2026-08-20

- `moot_json_import` seed schema v1.2 (mission P2a): each record may carry
  an optional `"capture_date"` key (UTC ISO8601, trailing `Z` required; same
  two accepted shapes as `event_time`; offset forms rejected). Wire contract:
  unknown-key error wording advances from "schema v1.1" to "schema v1.2";
  the key is validated in both Swift (`JsonImportBridge.swift`) and Rust
  (`json_import_bridge.rs`) before any estate work. Pipeline: when present,
  `CaptureFrame.captureDate` / `CaptureFrame.capture_date` carries the
  parsed instant into `captureBatch` / `capture_batch`; the drawer's
  `filedAt` is set to that instant (Swift: `frame.captureDate ?? now`;
  Rust: `frame.capture_date.unwrap_or(now)`). HLC physical time follows:
  Swift `insertFreshBatch` computes each HLC stamp from `d.filedAt` (was
  single batch `nowMillis`) so per-record override is honored at the CRDT
  layer too. Absent records use the batch wall-clock — byte-identical legacy
  behavior. Golden pin (both ports): `capture_date "2026-01-15T10:00:00Z"`
  → `filedAt = 1 768 471 200 000 ms`. `LOCUSKIT_INTERFACE` bumped to
  v1.29.0 documenting `CaptureFrame.captureDate` (Swift) and
  `CaptureFrame.capture_date` (Rust). New tests: 10 Swift
  (`JsonImportBridgeTests`) + 6 Rust (`json_import_bridge.rs`).

### 1.49.0 -- 2026-08-20
M3: `moot_memory_search` `scoring` parameter now accepts `discriminative` as a fourth valid value (in addition to `raw`, `rrf`, `matrixAware`). The `scoring` paragraph updated to describe the new mode and expand the valid-values list. Swift (`ToolProjection.swift` schema + `ToolDispatch.swift` parse) and Rust (`interface_tools.rs`) both updated. Decode remains fail-closed.

### 1.48.0 -- 2026-08-20

- `moot_memory_search` gains optional boolean argument `anomalous_filter`
  (§11.18). Absent/`null` = passthrough; `true` = anomalous-only; `false` =
  exclude anomalous. Decoded by `optionalBool` / `optional_bool` in both
  Swift `ToolDispatch` (`runMemorySearch`) and Rust `run_memory_search`.
  Non-boolean values return `invalidParams`. Maps to
  `GLKRecallRequest.anomalousFilter` / `anomalous_filter`.

### 1.47.0 -- 2026-08-17

- **`MootDaemonProvider` estate-convergence surface (MACD-2c2).** New public
  types in the shared provider module (apps/mootx01, linked identically by
  the direct daemon shell and the sandboxed helper): `DefaultEstateCensus`
  (pure disposition judge + file-level observation), `CensusCandidateRecord`
  / `CensusObservation` / `CensusIdentity` / `CensusDisposition` /
  `EstateCandidateClass`; `MigrationChallenge` / `MigrationGrantEnvelope` /
  `MigrationGrantAuthority` / `ConsumedGrant` (challenge-bound MAC,
  journal-first one-use consumption); `GrantResolutionPolicy` (production
  stale policy with F4 denial classification); `EscrowRules` /
  `KeyEscrowAuthority` (structurally mint-free); `DefaultEstateMigrator` /
  `MigrationReceipt` / `MigrationReceiptStore` / `MigrationTransaction` /
  `MigrationStep` (staged-before-rename receipts, idempotent resume);
  `SourceEstateAccess` / `FileMigrationAuthority` (injected seams — no
  production SQLite conformer in this module; arrives with MACD-3);
  `ProductionRandomness` (SecRandomCopyBytes, fail-closed);
  `ProviderLayoutContext` + layout-context-bound `ProviderLock.acquire(at:context:)`
  and the `ProductionCredentialAuthority` marker (a production Keychain
  authority refuses under any non-production lock proof or proof context).
  `ProviderRootLayout` gains `grantJournal`, `migrationReceiptFile`,
  `migrationChallengeFile`, `migrationGrantFile`.

- **Shell modes.** `DaemonShellMain` adds `census` (read-only file-level
  census; one JSON line of class labels, digests, and the conservative
  disposition — never a raw path) and `resident` (the LaunchAgent contract
  entry point; exits 4 `resident-unavailable` until MACD-3). The canonical
  self-report adds `grantDomain`, `receiptDomain`, `censusDispositions`,
  `migrationSteps`; the module digest changes accordingly (additive tail,
  both shells identical).

### 1.46.0 -- 2026-08-16

- **`ARIA_MCPDispatcher.firstPartyIdentity` is not an initializer
  parameter.** It is `public internal(set)` and is set only by the
  authenticated router, from the live `FirstPartyAuthServer`'s identity.
  Correcting 1.45.0, which documented an `init` parameter that would
  have let the unauthenticated lane advertise the capability.

- **`serverInfo.descriptorGeneration` and `serverInfo.credentialGeneration`
  are DECIMAL STRINGS, not JSON numbers.** They are `UInt64`; `Int64` and
  JSON's safe-integer range are both too small to carry the full range
  without trapping or losing exactness.

- **`FirstPartyAuthServer.identity` is actor-isolated and computed** from
  the descriptor currently in force, so `republish(descriptor:)` cannot
  leave a stale generation advertised. New
  `FirstPartyAuthServer.republish(descriptor:)`.

- **New on `FirstPartyAuthProtocol`:** `handshakeMaxBodyBytes`,
  `isExactContentType(_:)`, `strictJSONObject(_:expected:maxBytes:)`,
  `topLevelJSONKeys(_:)`, `exactUInt64(_:)`. New on
  `FirstPartyDescriptor`: `hasEncodableFieldWidths`.

- **`HTTPServer.legacyCollapsedRequest(_:maxBodyBytes:)`** reproduces
  `LoopbackHTTP.HTTPRequest.parse` for the public lane; the strict parser
  applies only under `/mcp/first-party`.

- **`MootGateway`:** `FirstPartyDaemonAuthenticator`'s handshake-exchange
  seam is now `internal`. The module's public surface offers exactly one
  initializer, which always uses the pinned, no-redirect, size-capped
  loopback exchange.

### 1.45.0 -- 2026-08-16

- **First-party authenticated wire surface (MACD-2b), dark.** New
  public types in `AriaMCP`:

  - `FirstPartyAuthProtocol` — the frozen constants, canonical
    encodings, HKDF/HMAC derivations, proofs, request/response MAC
    builders, base64url codec, canonical sequence parsing, and
    constant-time comparison.
  - `CanonicalEncoder` — length-prefixed, big-endian, fixed-order.
    `appendString`, `appendBytes`, `appendUInt16/32/64`, `appendUUID`,
    `appendCapabilities`.
  - `FirstPartyDescriptor` — descriptor schema 2, with `macInput()`,
    `canonicalBytes()`, `digest()`, and `verifyMAC(installationRoot:)`.
  - `ReplayWindow` — highest-seen plus a 128-bit history; `admit(_:)`,
    `isExhausted`.
  - `FirstPartyRootProviding`, `FixedFirstPartyRootProvider`,
    `FailingFirstPartyRootProvider`,
    `DataProtectionKeychainRootProvider` — the read-only root contract.
    No production root is minted in this revision.
  - `StrictHTTPRequest`, `StrictHeaderField`, `StrictHTTPParser` — a
    lossless, duplicate-preserving request parser for the
    authenticated lane only.
  - `FirstPartyServerIdentity`, `FirstPartyAuthServer`,
    `FirstPartyAuthenticatedRequest`, `FirstPartyAuthError`.

- **`HTTPServer.init` gains `firstPartyAuth:`, defaulted `nil`.**
  `HTTPServer.serve` gains the same parameter, likewise defaulted.
  With `nil` the entire `/mcp/first-party` subtree returns 404 and the
  request-reading path is unchanged. Existing call sites are source-
  and behaviour-compatible.

- **`ARIA_MCPDispatcher` gains `firstPartyIdentity`, `public internal(set)`.**
  It is NOT an initializer parameter and cannot be set by a caller: the
  authenticated router populates it from the live authenticator's own
  identity for the duration of one dispatch. With it `nil` — which is
  every third-party dispatcher — `initialize` output is byte-identical
  to revision 1.44.0.

- **`MootGateway` (macOS app) additions:** `DaemonDescriptor` gains the
  six schema-2 fields; `DaemonDescriptorDefect` gains
  `unsupportedAuthProtocol`, `unknownAuthKeyIdentifier`,
  `wrongEndpoint`, `unparseableBinaryVersion`,
  `malformedDescriptorMAC`, and `staleGeneration`;
  `DaemonCompatibility` gains `updateDaemonRequired` and
  `updateAppRequired`; `DaemonReadinessState` gains the matching two
  cases; new `SemanticVersion`, `FirstPartyDaemonAuthenticator`,
  `FirstPartyInstallationRootProviding`, and
  `FirstPartyAuthenticationError`.

- **`HTTPTransport.init` gains `verifyResponse:` and
  `redirectPolicy:`, both defaulted** to the pre-existing behaviour
  (`nil` and `.follow`). New `GatewayResponseVerification` typealias
  and `GatewayRedirectPolicy` enum; new
  `GatewayTransportError.responseVerificationFailed` and
  `.redirectRefused`.

- **Rust:** no interface change. The port gains a golden-vector test
  only and must not advertise `authenticated-first-party` until a
  separate parity mission implements the full wire.

### 1.44.0 -- 2026-08-15

- `moot_timing_report` window is bounded at the call level (AT-01,
  Codex Finding A): each call collects at most 262,144 audit events
  (64 full pages of 4,096; ~1.6× the largest real estate's audit log,
  measured 2026-08-15 at 162,860 events / 33 MB / ~216 B per row). A
  clamped call derives over what it collected and appends a final line
  `window: truncated at 262144 events — pass watermark_ms back as
  since_ms to continue`; untruncated reports keep the previous shape
  byte-identical. Clamp, not reject — the existing `watermark_ms`
  paging contract continues the scan. Both ports; tool descriptions
  updated to drop the unbounded "full-history scan" promise. The Rust
  port additionally seeds its paging cursor from `since_ms` (it
  previously re-paged the whole log from epoch on every call —
  same-symbol parity fix; the A6 exactly-once derivation contract is
  unchanged).
- Hint appenders preserve multi-block results (AT-01, Codex Finding B,
  Swift only): `appendUnknownArgsHint` and `applyHint` previously
  collapsed any result to its first content block, destroying
  `moot_json_import`'s `id_map` block whenever a hint fired. Both now
  append the hint to the first block's text and carry all trailing
  blocks through unchanged, matching the Rust `inject_hint` /
  `inject_unknown_args_hint` in-place behavior (Rust never had the
  defect). Error results remain untouched by the hint path.
- New tests: Swift `MultiBlockHintAndTimingWindowTests` (4); Rust
  `interface_tools::timing_window_tests` (2) plus `dispatch_tests`
  `timing_report_small_estate_has_watermark_and_no_truncation_line` and
  `json_import_id_map_block_survives_unknown_arg_hint`.

### 1.43.0 -- 2026-08-14

- Additive (mission BL-1 — botLink one-shot CLI transport, Swift port;
  Rust twin lands in BL-2): documented the cloud-agent access path in
  §1 — `mootx01-botLink` / `mootx01 botlink` (`ping`/`list`/`call`/
  `rpc`, machine-JSON stdout, loopback-only `--http` guard, exit codes
  0/1/2/64) — with the verbatim adapter-policy paragraph redirecting
  cloud agents away from `mootx01 query`. No wire-surface change; no
  client wiring change (`mcp.json` stays `http://127.0.0.1:4242`,
  `mootx01-proxy` stays the Desktop stdio face).

### 1.42.2 -- 2026-08-13

- Two more stale tool-count lines corrected (§1 memory-adapter baseline
  "71/65" → "74/67"; §5 Rust test census "71/71 / 65/65, Rust matches
  Swift exactly" → per-port truth 74/67 wire vs Swift 78/71 with the
  FAB5-I2 packet tools). Non-changelog current-state count claims now
  swept file-wide.

### 1.42.1 -- 2026-08-13

- Tool-count corrections: Swift `ToolProjection.tools()` is 78 vault-on /
  71 vault-off; the Rust wire surface is 74/67 (75/68 with the opt-in
  memory adapter) — the Swift surface minus the four Swift-side packet
  tools (FAB5-I2). The previous 71/65 and 72/66 figures had drifted
  across several tool additions.

### 1.42.0 -- 2026-08-13

- `moot_timing_report` (maintenance, both ports): argument `since_ms`
  (optional integer — a previous call's `watermark_ms`; omit or 0 for a
  full-history scan). Text report lines: `ingest_exact` /
  `cycle_vector` / `cycle_novel` / `cycle_dreamt` each as
  `n=<count>, p50=<ms>, p95=<ms>` (novel/dreamt add `unbounded=<count>`),
  `ingest_bulk` as `n=<units>, rows=<total>, rows_per_sec=<rate>`, and a
  final `watermark_ms: <ms>`. Line shapes are byte-compatible across
  ports so harness parsers read either. Registered in the maintenance
  tool family (now 6 tools).

### 1.41.0 -- 2026-08-12

- `moot_json_import` gains `return_id_map` (boolean, optional, default `false`; explicit `null` is invalidParams on both ports, message `"return_id_map must be a boolean; omit it to use the default"`). When true the reply carries a SECOND text block — `{"id_map":{"<record id>":"<drawer id>"}}`, one entry per seeded record, keys sorted so the bytes are identical across runs of the same seed. The prose receipt is block 0 and is unchanged, so every existing caller is unaffected.
- Why the argument exists: a record's lineage is deterministic (FNV-1a-128 of the record id), but the drawer id is minted fresh at insert and no recall surface addresses a drawer by lineage. A caller that must address what it just imported — cross-references, per-record reporting, or scoring retrieval against known records — otherwise has to re-discover each drawer by searching for its own content, which cannot be made exact because ranking decides what comes back.
- New dispatch primitive: `ToolDispatcher.textResultBlocks(_ blocks: [String])` (Swift) / `text_result_blocks(blocks: &[String])` (Rust), the multi-block success envelope. Deliberately NOT an overload of `textResult(_:)` — overloading on `String` vs `[String]` made the Swift type-checker weigh both candidates at every call site and it exceeded its time budget on this file's `+`-chained receipt strings.
- Backing field: `JsonImportReport.drawerIDByRecordID` / `drawer_id_by_record_id` (see VAULTKIT_INTERFACE 1.17.0), carried to in-process callers always; the argument gates only what the MCP reply renders.
- New tests: Swift `JsonImportToolTests` `returnIDMapNamesRealDrawerIDs` + `idMapIsOptInAndNullRejected`; Rust `dispatch_tests.rs` `json_import_return_id_map_names_drawer_ids` + `json_import_id_map_is_opt_in_and_null_rejected`. Both ports assert the mapped id addresses the drawer holding that record's content, not merely that the map is the right size. Tool count is unchanged.

### 1.40.0 -- 2026-08-11

- Bridge input limits (pc stream, security findings 012/036). §1 gains the two admission caps for `ProxyCommand.swift` and their `MootInstallerCore` primitives: `proxyMaxFrameBytes` (4 MB frame-size cap) and `ProxyConcurrencyGate` (16-slot actor-based counting gate). Both are byte-identical across Swift and Rust. `ProxyAdmissionGate.swift` is new in MootInstallerCore; `ProxyAdmissionTests.swift` is the new test suite.

### 1.39.0 -- 2026-08-11

- Bridge failure-response invariant (px stream). §1 documents `ProxyCommand.swift` (the stdio→HTTP bridge), `ProxyDispositionLogic.swift` (pure disposition and id-extraction functions in MootInstallerCore), and the four failure conditions that yield a synthesized -32603 error with the original request id. `proxyDisposition(statusCode:bodyEmpty:)` and `proxyRequestID(of:)` are the testable public surface; both exercised in `MootInstallerCoreTests/ProxyDispositionTests.swift`.

### 1.38.0 -- 2026-08-07

- MXE-CT3 P3 tiered contradiction surface. `moot_hunt_contradictions`:
  optional `tier` (1|2|3|"all", default "all") and `top_k` (1...50,
  default 5); default mode appends the tiered synthesis digest, single
  tier is a read-only purpose search. `moot_review_tunnel`: optional
  `reviewed_by` (default "user"), `verdict` extended with `"endorse"`;
  accept is user-only, a model reject is an objection. `moot_dream`:
  files tier-labeled candidates after the hunt phase and appends the
  tiered digest. Schemas declared identically in both ports.

### 1.37.0 -- 2026-08-06

- `moot_recall_connected` (recipe provenance, recall family, shares the
  recall-results output schema): args query (required), wing, limit,
  filter, estateID. Recipe tool roster 13.

### 1.36.0 -- 2026-08-06

- `moot_synthesize` grounding is now HYBRID: the raw query also drives a
  scored BM25+vector lane (reaching memories that share no query words);
  grounding becomes a ranking guarantee (term matches lead) rather than a
  hard lexical exclusion. Dispatch passes the base frame + query + terms;
  the recipe owns lanes and bounds.

### 1.35.0 -- 2026-08-06
Cue-ranking dispatch wiring for `moot_synthesize`:

- `runGroundedSynthesis` (Swift) / `run_grounded_synthesis_tool` (Rust) compute
  `frameLimit = max(userLimit, groundedSynthesisCuePoolBound=200)` and
  `recipeCap = userLimit` when a query is present. Both are threaded through to
  `GroundedSynthesis.Input` / `run_grounded_synthesis` so the cue-term reranker
  sees the full matched pool before the user's limit caps the synthesis.
- No change to the tool's public argument surface — this is an internal routing
  contract change only.

### 1.34.0 -- 2026-08-06

- `moot_synthesize` gains optional `query`: grounding-term extraction
  (stopword/short-fragment drop, digit exception, dedupe, cap 12) into an
  OR of case-insensitive content predicates AND-composed with `filter`;
  response names the cue with a `query:` line; all-stopword queries are
  rejected as invalidParams. Both ports. Completes the GroundedSynthesis
  recipe contract ("hybrid-recall a query and synthesize") at the ARIA
  surface — previously the tool accepted no cue and always produced a
  whole-estate recency digest.

### 1.33.0 -- 2026-08-05

- moot_dream `associates` argument (all|recent|off, default recent)
  and the zero-gated `associationsWritten:` report line, both ports
  (Swift step by the item-5 worker; Rust twin completes it).

### 1.32.0 -- 2026-08-04

- **Structured recall results (MXE-SS).** `ProjectedTool` gains an
  optional `outputSchema` (nil → key omitted from the `tools/list` entry;
  text-only tool entries byte-identical to before). The recall family
  (`moot_memory_search`, `moot_memory_get`, `moot_recall_shaped`,
  `moot_recall_precise`) declares the shared
  `recallResultsOutputSchema()` (Rust
  `tool_list.rs::recall_results_output_schema()`) and returns
  `structuredContent` alongside the unchanged text block through the new
  `structuredTextResult` envelope helper. Redaction parity per
  ARIA_MCP_SPEC 1.28.0 § 11.


### 1.31.0 -- 2026-08-04

- **`moot_erase_memory` partial-response contract (MXE-FA).** Documents
  the two response shapes: `erased memory <id>` (full) and
  `partially erased memory <id>: <N> accepted lineage sibling(s) refused
  erasure and remain readable: <ids>` (partial, `isError: false`). Backed
  by GLK's new `ExpungeVerbOutcome` return
  (GENIUSLOCUSKIT_INTERFACE 1.28.0). Teachme guides updated in both ports.

### 1.30.0 -- 2026-08-03
Observable output change on `moot_estate_status`: the `memories: N active
(M total)` and `subjects: N/M (K missing)` numbers now exclude restricted and
secret rows, as `wings:` already did. On an estate holding such rows both lines
report smaller numbers than before; on an estate without them nothing changes.
Field keys, field order, line count, and response shape are unchanged, so
consumers that read the body by prefix need no change — no in-repo consumer
parses these integers. Documents the drawer-aggregate ceiling and the
unfiltered non-drawer fields in the `moot_estate_status` section above.
Behavioural contract: `ARIA_MCP_SPEC.md` 1.26.0.

### 1.29.0 -- 2026-08-03
Observable output change on `moot_memory_search` and `moot_memory_get`: the
trailing `sensitivity_advisory:` line is now emitted whenever no sensitivity
grant is live, independent of what the estate contains. It previously also
required the estate to hold at least one `restricted`/`secret` row, which made
its presence an existence oracle for those rows. Both strings are reworded and
are byte-identical across the Swift and Rust ports; search and get keep distinct
phrasings. The `sensitivity_advisory: ` line prefix is unchanged, so consumers
that strip or detect the line by prefix (e.g. `MootSpotlightRecord.parse`) need
no change. Behavioural contract and the contents-independence invariant:
`ARIA_MCP_SPEC.md` 1.25.0.

### 1.28.0 -- 2026-08-03

- Typed conflict projection section (DCP M4): the three contradiction
  surfaces render the evaluator-backed section via one shared renderer
  (Swift `RecipeTools.conflictProjectionSection` ↔ Rust
  `conflict_projection_section`); GLK sweep verbs
  `conflictProjectionSweep` ↔ `conflict_projection_sweep`.

### 1.27.0 -- 2026-08-02

- Lens evidence addresses (PR-05): memory-listing lens findings cite
  memories as dense rows via the shared renderer (7 arms: keystones,
  free_association, cohesion, contradiction, trust_synthesis,
  partial_cue, successors); moot_lens_concepts lists member drawer ids
  capped at 20 (`lensExtentIDCap` ↔ `LENS_EXTENT_ID_CAP`);
  moot_lens_associations carries `exemplarDrawerIDs` (cap 5) per rule.
  Byte-identical across ports, golden-tested against the renderer.

### 1.26.0 -- 2026-08-02

- PR-04 utility tier: documented the estate-status `subjects: N/M
  (K missing)` line, the reserved `subject_backfill` drain-lane name
  (Swift `ToolDispatcher.subjectBackfillLaneName` ↔ Rust
  `SUBJECT_BACKFILL_LANE_NAME`), and the `verbose` flag on
  moot_list_lenses / moot_list_recipes (terse default). Estate-status
  teachme carries the consent-gated backfill standing behavior.

### 1.25.0 -- 2026-08-02

- Dense-row reply surface (PR-03): documented the five-field dense row
  as the default hit/citation shape across the recall family, the
  deviation-only narration contract, the `near:` anchor pivot on
  moot_memory_search + moot_recall_shaped (query no longer
  schema-required — exactly-one enforced at runtime), and
  moot_memory_get `ids:`/`depth:` (subject|distilled|full). Teachme
  guides for the recall family rewritten in both ports. Cross-port
  byte-identical goldens: DenseRowGoldenTests.swift ↔
  dense_row_golden.rs.

### 1.24.0 -- 2026-08-02

- Subject surface (progressive recall PR-02): documented the required
  `subject` argument on `moot_file_memory` (AI-facing register, 120-char
  contract), `moot_update_memory` `mutation=setSubject` + `subject`
  argument, and `moot_memory_list` `filter=missing_subject` (id-only
  subject-debt enumerator). Teachme guides for all three verbs updated in
  both ports.

### 1.23.0 -- 2026-07-20

- Updated intake/search language for GLK shared content: impatient writes index
  the canonical Drawer directly, and Corpus drain counts are Drawer-index
  counts rather than chunk counts.
- Confirmed that no ARIA/MOOTx01 surface enables CorpusKit passage chunking.

### 1.22.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line (see the "Upstream-release advisory"
subsection beside the version-skew one) when a newer product release exists
than the running binary. `ToolDispatcher` (Swift) gains
`updateAdvisoryProvider: (@Sendable () async -> String?)?` (defaulted `nil`);
`Dispatcher` (Rust) gains `update_advisory: Option<UpdateAdvisoryProvider>`
via the `with_update_advisory` builder (the Rust equivalent of the defaulted
Swift parameter — existing `Dispatcher::new` call sites unchanged), threaded
through `dispatch_tool_with_ledgers` / `interface_tools::dispatch` alongside
`version_skew`. Unlike `version_skew` the value is a lazily-evaluated
provider, not a startup-computed string — the resident daemon outlives
releases. Rate limiting (24h TTL), the 4s probe bound, failure caching, and
the `MOOTX01_NO_UPDATE_CHECK` kill switch live in the host advisor
(`MootInstallerCore.UpdateAdvisor` / `mootx01-cli::core::update_advisor`);
the kit only renders the line. Resident daemons only; stdio one-shots and
`aria-mcp-server` (both ports) never wire a provider. Both ports at parity.

### 1.21.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): `memory_adapter.rs`
implements all six commands (view, create, str_replace, insert, delete, rename),
the `MOOTX01_MEMORY_TOOL=1` opt-in gate, the Normal-tier sensitivity filter (mirrors
`isMemoryAdapterVisible` in Swift), and sensitivity-tier carry-forward on edits so
elevated-tier drawers are not silently downgraded. `tool_list.rs` gains
`memory_enabled()`, `build_tool_list_with_flags(vault_on, memory_on)`, and the
`memory_adapter_tool()` schema; `build_tool_list()` and `build_tool_list_with_vault_flag()`
delegate to it. When `memory_on=true` the `memory` tool is prepended (first in list,
mirrors Swift `memoryAdapterTools()` prepend order), raising the count to 72/66.
Existing dispatch and count tests updated to use `build_tool_list_with_flags(vault_enabled(), false)`
for determinism (prevents racing with env-var mutations in memory-tool tests). New test
file `tests/memory_adapter_tests.rs`: 19 tests covering env gate, tool-list projection,
and per-command happy + error paths. Updated §1 Rust package layout and Rust binary
description to document `memory_adapter.rs` and the opt-in gate.

### 1.20.0 -- 2026-07-16
Dataset tools (MX-TAB-7): three new tools `moot_file_dataset`,
`moot_dataset_query`, `moot_dataset_stats` with `.interface` provenance —
always visible, not vault-gated. Both ports (Swift `DatasetTools.swift`,
Rust `dataset_tools.rs`) at parity. Tool count: 68 → 71 (vault-on), 62 → 65
(vault-off). Adds new "Dataset tools" subsection in §2. Also adds previously
undocumented public types: `DiscriminationLevel`, `RecallDiscrimination`
(scale-independent recall confidence heuristic, both ports mirrored), and
`MonitoringControl` protocol (the monitoring-control injection seam). Adds
`memoryToolEnabled` to ToolProjection block (opt-in memory_20250818 adapter,
MOOTX01_MEMORY_TOOL=1). Updates stale Rust tool census (55 → 71).
Updates `DatasetTools.swift`, `RecallDiscrimination.swift`, and
`MemoryToolAdapter.swift` / `MonitoringControl.swift` to §1 package layout.

### 1.19.0 -- 2026-07-12
Contradiction hunter MCP surface (both ports at parity, tool count 66 → 68):
`moot_hunt_contradictions` (recipe — on-demand bounded content sweep; strong
findings persist as PROPOSED `contradicts` tunnels, borderline pairs return
with snippets for agent adjudication) and `moot_review_tunnel` (Tier 2 —
accept/reject a proposed tunnel via `Estate.respondToTunnel`; rejection is
durable). `moot_link_memories` gains optional `proposed: bool` (files the
link in the PROPOSED lifecycle). `moot_dream` now runs the hunt sweep as its
content-driven third phase and reports `contradictionsProposed` /
`contradictionCandidatesBorderline`. `moot_lens_contradiction` output gains
lifecycle tiers: proposed edges shown by default flagged
`proposed (agent-derived, unreviewed)`; withdrawn/superseded excluded.
Permission tier: both new tools `ask` (mutation table, both installer legs).
Teachme guides for both tools plus updated dream/link guides. Contract tests
updated: 68 total, 62 vault-off (Swift `ToolProjectionTests` /
`V1ConformanceTests` / `VaultToolsTests`; Rust `dispatch_tests`;
installer `PermissionsWriter` inventories both legs).

### 1.18.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: `moot_monitoring_status` tool (§2 Tool projection, Tier 5 —
Estate tools, monitoring-control entry). Injection pattern: `MonitoringControl`
protocol (Swift) / trait (Rust) defined in AriaMcpKit; concrete implementation
(`StatsStoreMonitoringControl`) in AriaResident (Swift) and `http_server.rs`
(Rust). Read path: absent `enabled` arg returns current flag state. Write path:
present `enabled: bool` persists the flag via `StatsStore.setMonitoringEnabled` /
`set_monitoring_enabled` (wave 8.1 API), echoes new state with
`monitoring_source: user` line. No-store case: returns `monitoring: unavailable`
— never fabricates state. Permission tier: `ask` in both namespace prefixes.
Wave 8.3 smoke: `HTTPReadAPITests.freshStoreMonitoringDefaultIsEnabled` verifies
fresh StatsStore seeds monitoring=ON (wave 8.1 regression gate). Tool count: 64
(Swift and Rust at parity).

### 1.17.0 -- 2026-07-05
the sensitivity-grant contract sensitivity unlock/lock control endpoints (§4.6). Documents
`POST /api/control/unlock` and `POST /api/control/lock` — platform-
specific identity verification (macOS: LocalAuthentication; Linux/Windows:
PBKDF2-HMAC-SHA256), request/response shapes, proof freshness gate,
CLI surface (`mootx01 unlock private|secret`, `mootx01 lock`). Both
Swift and Rust ports at parity. Redaction advisory
(`sensitivity_advisory:` line) added to `moot_memory_search` and
`moot_memory_get` output when no grant is active and estate has
restricted/secret rows.

### 1.16.0 -- 2026-07-04
Added `moot_memory_get` (§2 Tool projection, Tier 1 — Core Memory table)
— fetch-drawer-by-ID, build-now per Bob's ruling. Input: `id` (drawer UUID,
required) plus the standard `estateID` every direct tool accepts.
Output: verbatim content (hydration `.full`), room/wing, `filedAt`/
`eventTime`, the five adjective-axis fields (state, trust, sensitivity,
exportability, confirmation), lineage, and a linked-tunnel summary
(same tunnel-scan pattern as `moot_connection_search`/
`moot_connection_map`). Swift `ToolDispatcher.runMemoryGet` routes
through `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`; Rust
`interface_tools::run_memory_get` routes through the Rust twin
`Estate::get_drawers_matching_frame` — both with an empty filter chain,
so `moot_memory_search`'s default containment gate (see the `filter`
argument section above) applies unchanged. A drawer that exists but
fails the gate is reported with the same "Memory not found: `<id>`"
error `moot_link_memories` already uses for an unresolvable id — the
by-id door cannot confirm existence of content the gate would
otherwise hide. Tool surface: 62 -> 63 (Tier 1: 7 -> 8; vault-on
62 -> 63, vault-off 56 -> 57). teachme guide added on both ports. Both
ports at parity. New tests: `MemoryGetTests.swift` (10 tests); Rust
`dispatch_tests.rs` `memory_get_*` (7 tests) + 1 teachme test.

### 1.15.0 -- 2026-07-04
the connection-ownership contract §5: `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line (see the new "Version-skew advisory" subsection under
§`moot_estate_status` — sync field vocabulary, below) when the host detects a
mismatch between an installed plugin (currently Claude Code's
`mootx01@mootx01`) and the running binary's version. `ToolDispatcher`
(Swift) gains a `versionSkewAdvisory: String?` field, injected at
construction the same way `buildSerial` already is; `Dispatcher` (Rust)
gains a `version_skew: String` field (empty string ⇒ no advisory), threaded
through `dispatch_tool_with_vault_ledger` / `interface_tools::dispatch`
alongside `build_serial`. Computed once at server startup by the host binary
— `MootInstallerCore.VersionSkewAdvisory.compute` (Swift) /
`mootx01_cli::core::mcp_ownership::version_skew_advisory` (Rust) — never by
the kit itself, which does not read `~/.claude/plugins/` or know a product
version. `aria-mcp-server` (both ports) has no plugin concept and always
passes the empty/nil default. Both ports at parity.

### 1.14.0 -- 2026-06-29
Security fix (secfix/c-aria-minor, CAND-043): `GET /api/graph` now ignores the
`?estate=` query parameter and always reads the **default estate's** topology
snapshot. The Swift private function signature changed from
`graphSnapshot(estate:topologyReader:)` to `graphSnapshot(topologyReader:)`;
callers (the `route` function) no longer extract the `estate` query string or
pass it to the reader. The `queryValue(_:in:)` helper was removed as it had no
remaining callers. This matches the existing Rust posture where `get_graph_snapshot`
always uses `registry.default` and explicitly documents that `?estate=` is ignored.
The observable GET /api/graph response format is unchanged.

### 1.13.0 -- 2026-06-29
Vault cap ordering fix (secfix/c-vault-cap): corrected `moot_vault_import` preflight
ordering in the Swift port. Previously `hashAllNotes` ran BEFORE `checkAndRegister`,
allowing up to the HTTP transport concurrency limit worth of concurrent expensive
filesystem/SHA-256 preflight work outside the cap. The cap now binds the preflight:
`checkAndRegister` runs FIRST, then `hashAllNotes` runs while holding the slot. A new
pre-Task do/catch releases the slot via `fail(jobID:)` when `hashAllNotes` throws, so a
throwing preflight never permanently consumes a cap slot. §Vault job concurrency cap
updated to reflect the new ordering. Rust port unchanged — `Dispatcher` `Arc<Mutex<>>`
already serializes all calls (effective cap of 1, no concurrent preflight fan-out
possible). New tests: `import_cap_enforced_before_expensive_preflight`,
`import_throwing_preflight_releases_slot` (Swift). Supersedes/refines secfix/c-vault-jobslot
(1.12.0) which established the slot-release invariant but placed the preflight before
the cap acquisition.

### 1.12.0 -- 2026-06-28
Vault availability hardening (secfix/c-vault-jobslot): documented the vault job
concurrency cap (4 slots, Swift port) and the slot-release invariant. In the Swift
port, `moot_vault_import` ran `hashAllNotes` preflight BEFORE `checkAndRegister`
so a preflight failure never consumed a slot. Non-regular `.md` entries (directories,
symlinks) are skipped in `hashAllNotes` rather than causing a fatal throw. The Rust
port is safe by construction (`run_import` records jobs only after bridge completion;
`collect_and_hash` skips non-files). Both behaviors and the concurrency contract are
described in §Vault tools above. New tests: `hashAllNotes_skips_directory_named_md`,
`import_cap_not_exhausted_after_directory_md_vault` (Swift); `hash_all_notes_skips_directory_named_md`,
`import_with_directory_md_vault_does_not_exhaust_ledger` (Rust). Note: the preflight-
before-cap ordering in this version left `hashAllNotes` outside the cap — corrected in
1.13.0 (secfix/c-vault-cap).

### 1.11.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria).

(1) **`moot_erase_memory` AriaMcpKit gate** — `confirmed=true` check enforced at the
AriaMcpKit boundary before the substrate is called. Schema unchanged; `confirmed` was
already present in `required`. Error message updated to name `confirmed=true` explicitly
and explain the owner-review intent. Both ports updated.

(2) **`moot_federated_search` requester anti-spoof** — `requesterEstateID` changed from
required to optional. When omitted the requester is the default estate. When supplied it
must match the default estate's UUID. Schema: `required` array changed from
`["requesterEstateID"]` to `[]`; property description updated to document the optional
binding and the anti-spoof refusal. Both ports updated.

### 1.10.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `isOriginAllowed` in `HTTPServer.swift` / `http_server.rs`
and `HTTPReadAPI.swift` / `http_read_api.rs` now validate the suffix after the loopback host
prefix instead of a bare prefix check, blocking DNS-rebinding prefix-spoof origins like
`localhost.evil`. Tests added on all four files.

(2) **`moot_palace_import` vault gate** — when `MOOTX01_VAULT=0`, `moot_palace_import` is
absent from `tools/list` and returns a clear refusal at dispatch (same as vault tools). The
tool reads arbitrary local SQLite files; gating it matches the vault-surface security posture.
Vault-off surface count: 57 → 56. Both ports updated (`ToolProjection`, `ToolDispatch`,
`tool_list.rs`, `dispatch.rs`).

### 1.10.0 -- 2026-06-25
Docs/guidance (T8 — teachme reconcile): the teachme `palace_import` guide no
longer tells the AI that `moot_reindex` + `moot_dream` are a REQUIRED two-step
finish — that contradicted the tool's own description (the import triggers its
own background indexing; the resident dreams on cadence). Guides now say
indexing is automatic, point at `moot_drain_status` to watch convergence, and
note `moot_dream` is only needed manually when running without a resident.
Residual `batch`/`non-batch` wording from the T1/T7 rename swept out of both
ports' teachme and the `moot-agent-skills` HOW_TO. No surface change.

### 1.9.0 -- 2026-06-25
Changed (T7 — one ingest engine, many gates): `moot_vault_import` takes a `mode`
(foreground/background encode SPEED) arg, replacing the Swift-only `batch` flag,
and the Rust vault-import tool now exposes `mode` too (it previously had no such
arg — a fixed Swift/Rust parity gap). All import gates (palace + vault/Obsidian/
OKF) now share one policy: caller declares SPEED, write strategy is size-gated
automatically. No new tool. Both ports.

### 1.8.0 -- 2026-06-25
Added (T5 — drain lifecycle): new internal CLI subcommand `mootx01 drain [--db]`
— opens an estate, drains its encode queue to empty, then exits. It is the
detached finisher a direct-open stdio `serve` spawns on exit (setsid/detached);
rarely run by hand. Also: estate open now eager-mounts the corpus drain worker so
a restarted daemon resumes a non-empty queue (daemon resume-on-restart). No
`moot_*` tool-surface change. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve transport): an stdio `serve` forwards to a live resident
serving the same estate (estate-marker match + `daemon.port` probe → the `proxy`
stdin→HTTP bridge) instead of opening a second direct writer; falls back to a
direct open when no resident answers. Resident writes a `mootx01.estate` marker
(removed on exit). No tool-surface change; transport behavior only. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import` replaces its `batch` (bool) arg
with `mode` (string `"foreground"` | `"background"`, default `"foreground"`).
`mode` selects the post-import encode SPEED (drain QoS) only — foreground drains
the encode queue across all cores, background caps to ~a quarter for very large
imports. The WRITE strategy (bulk transaction vs per-item stream) is now chosen
AUTOMATICALLY by source size (≤250k rows → bulk; larger → stream), not by the
caller. Unknown `mode` is rejected (fail-closed). Both ports.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` (both
ports) — a read-only, pollable report of every long-running background drain the
estate runs. Today the only drain is `corpus_encode` (the encode/ingest queue);
each drain reports pending + in-flight job counts, a draining/idle state, and
optional drain-specific detail (the corpus drain reports its live encoded-chunk
count). Unlike `moot_estate_status` it does NOT append the session-protocol
block, so it is cheap to poll while a drain settles (e.g. after
`moot_palace_import`). The report is list-shaped so additional drains surface
automatically. The whole surface grows 55 → 56. Reachable from the CLI as
`mootx01 query drain_status`. Also fixed a stale `moot_reindex` doc-comment that
pointed callers at `moot_estate_status` for encode-queue depth (it never reported
it) — now points at `moot_drain_status`. Conformance: dispatch tool-count/name-set
gates (Swift `ToolProjection` / Rust `tool_list.rs`).

### 1.4.0 -- 2026-06-19
`moot_estate_ping` response now includes a build serial segment:
`pong: estate <name> [<uuid>] is live — build <serial>`. The serial is derived
once at `ToolDispatcher` (Swift) / `Dispatcher` (Rust) construction from the
running executable's mtime and size; stored as `buildSerial` on the dispatcher;
threaded to `runEstatePing` / `run_estate_ping` without per-call filesystem
access. Override via `MOOTX01_BUILD_SERIAL` env var (non-empty value used
verbatim). New tests: `testEstatePingIncludesBuildSerial`,
`testEstatePingHonorsBuildSerialOverride` (Swift);
`estate_ping_includes_injected_build_serial` (Rust). Spec companion: § 14 in
ARIA_MCP_SPEC.md updated to document the derivation contract.

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
New `AutonomicGovernor` PRODUCER DUTY on both ports: Swift
`AutonomicGovernor.graphCentralityScan(kit:handle:now:)` (a nonisolated static
duty dispatched on the `graphCentralityIntervalMs` cadence, default 10 min) and
Rust `graph_centrality_duty` (fired inside `tick` on the same cadence). The duty
reads the estate structure graph, computes per-drawer eigenvalue centrality via
the NeuronKit `keystones` oracle, and registers a `GraphCache`
(`registerGraphCache` / `register_graph_cache`). `GovernorReport` /
`GovernorReport` gains `graphCentralityFired` / `graph_centrality_fired`. Swift
`AutonomicGovernor.init` gains a `graphCentralityIntervalMs` parameter; Rust adds
the `set_graph_centrality_cadence_ms` test knob. This takes the
`unionBest`/`matrixAware` recall `graph` column from dark to live in production on
both ports. Corrects the prior text framing the recall-cache producers as
standing-signal seam plug-ins: they are governor DUTIES.

### 1.2.0 -- 2026-06-17
Additive (#8 Track 1 — Brain orchestration harness, Rust side). The Rust
`AutonomicGovernor` now OWNS this estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and ticks it each iteration,
mirroring the Swift governor's `kit.signalTick(in:handle:now:)` — previously the
Rust governor ticked dreaming + maintenance only and documented "no
standing-signal scheduler". New public Rust surface on `AutonomicGovernor`:
`register_default_standing_signals(model_id, now)` (the architecture-spec §11.2
bootstrap, reading the live VectorStore via `EstateCoordinator::vector_store_for`,
now `pub`), `register_standing_signal(spec, now)`, `signal_status()`,
`open_signal_count()`, `signal_request_fire(id, now)`; `GovernorReport` gains
`pub signals_ticked: bool` (parity with the Swift `TickReport.signalsTicked`).
The scheduler lives in the governor (not the GLK coordinator) to avoid a
dispatcher reference cycle. The registration methods are the producer SEAM where
Track 2 (graph-centrality) and Track 3 (Bradley-Terry) plug in — their outputs
land in GLK `recall::{GraphCache, PreferenceStore}`; the producers themselves are
NOT part of this harness. The resident HTTP bootstrap (`rust/src/runtime.rs`)
registers the defaults once at startup, best-effort (a missing VectorStore logs
and the governor benign-skips, parity with the Swift resident). Conformance:
`tests/governor_standing_signals.rs` (benign skip / registered-defaults fire /
queryable emission / interval cadence) over the existing GLK
`tests/scheduler_parity.rs` engine gate. Swift behavior unchanged.

### 1.1.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): new `moot_recall_shaped` recipe tool (both
ports) — a single recall tool with a discoverable `preset` enum selecting a named
`RecallShape` from the GLK roster (preferable to ~20 tools). The tool description
embeds the full roster (each preset name + one-line emphasis); the preset enum is
the GLK `presetNames` list. Validation is fail-CLOSED: an absent preset uses the
unsteered `balanced` default, a present-but-unknown name is rejected with a tool
error. Returns the same plain-text shape as `moot_memory_search`. The four ARIA
filtering adjectives compose orthogonally (the preset ranks, the `filter` arg
filters). The `.recipe` bucket grows to 29 tools and the whole surface to 55
(census references updated to the current live count, which prior additions
— `moot_reindex`, `moot_vault_job` — had left at the stale 53). Conformance:
`RecipeToolsTests.swift` shaped-recall cases / `dispatch_tests.rs`
`recall_shaped_*` + the tool-count/name-set gates.

### 1.0.1 -- 2026-06-14
Reconciled the `.recipe` provenance tool count: the §`Recipe and lens tools` body enumerated only 5 CognitionKit recipe tools (yielding 26 with the 21 lenses) while the heading, the `ToolProvenance` projection, and the 53-tool census all carry 28. Added the two missing recipe tools (`moot_recall_precise`, `moot_dream`) to the body so it lists all 7 recipe tools + 21 lenses = 28, consistent with the verified Swift/Rust surface (`ToolProjection.tools()` / `tool_list.rs`, both gated at 53).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

## Re-homed from develop/1.1.x (2026-08-26)

These entries were minted by the develop/1.1.x stream while this
document was reorganized to 2.x on the benchmark stream. Their version
labels collide with labels this ladder already used for different
changes; they are preserved verbatim as historical text and are not
index entries for this ladder.

### 1.53.0 -- 2026-08-21

Changelog ladder repair (merge of develop/1.1.x, 2026-08-21): the
moot_recall_temporal notes below were previously mis-filed as bullet
lines inside the 1.32.0 entry, self-labeled with version numbers
that the develop stream legitimately minted for unrelated changes.
They are re-homed here verbatim with their original self-labels
preserved as historical text; the labels do NOT refer to entries in
this ladder. No behavioral change in this entry.

- **v1.47.0 (2026-08-20)** — moot_recall_temporal description documents the date-seeking behavior; narration adds the date-seeking variant line. Schema unchanged.
- **v1.46.0 (2026-08-19)** — moot_recall_temporal schema gains `grab` (string: pool|dated, default pool). Narration line format: `temporal: <mode> (<source>, <grab>) window <bounds>[ ±Nd]`.
- **v1.45.0 (2026-08-19)** — moot_recall_temporal schema: query (required), window loose|tight (default loose), from/to (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ; explicit beats parsing), limit (default 20), pool (default 120), filter, wing, estateID; declares the shared recall-results output schema (sixth recall-family member).

### 1.52.0 -- 2026-08-21
Additive (D10 — walk_recall escalation ladder). `moot_recall_walk` MCP tool
added: recipe-provenance, 13th CognitionKit recipe tool in the `.recipe` bucket
(36 total recipe+lens, vault-on 76, vault-off 69). Recipe and lens tools section
updated: count 35→36, CognitionKit tools 12→13, `moot_recall_walk` added to
enumerated list and described. Arguments: `query` (required), `limit`,
`filter`, `wing`, `now`, `estateID`. Response: dense-row renderer output with
discrimination line and `walk:` metadata line. See `ARIA_MCP_SPEC.md §1.47.0`
for full invariant specification.

### 1.51.0 -- 2026-08-20
Additive (WIRE 1 + WIRE 2 — P4 study gaps). `moot_memory_search` and
`moot_recall_shaped` gain optional integer argument `frontier_k` (see argument
section above). `ShapedRecall.Input` / `shaped_recall::run` updated with an
additive `frontierK: Int? = nil` / `frontier_k: Option<usize>` parameter; all
existing callers compile unchanged (default nil). `tool_list.rs` and
`ToolProjection.swift` schemas expose the argument. Conformance:
`FrontierKArgumentTests.swift` (8 Swift tests). No Rust unit tests added
(boundary covered by Swift suite + Rust build gate). WIRE 2: benchmarker
`EstateSeams.swift` gains `MOOT_BENCH_PROVISION_RECALL_TUNING` seam — exact
mirror of `MOOT_BENCH_PROVISION_LANE_WEIGHTS` (env-var path → JSON-object
validation → SQLite INSERT OR REPLACE under manifest key `recall_tuning` →
stderr provenance line; hard-fail on any error). Called immediately after
`provisionLaneWeightsSeam` in `EstateCache.swift`. No Rust benchmarker mirror
(the Rust harness has no lane-weights seam — confirmed by empty grep). Seam
family doc block in `EstateSeams.swift` updated.

### 1.50.0 -- 2026-08-20

- `moot_json_import` seed schema v1.2 (mission P2a): each record may carry
  an optional `"capture_date"` key (UTC ISO8601, trailing `Z` required; same
  two accepted shapes as `event_time`; offset forms rejected). Wire contract:
  unknown-key error wording advances from "schema v1.1" to "schema v1.2";
  the key is validated in both Swift (`JsonImportBridge.swift`) and Rust
  (`json_import_bridge.rs`) before any estate work. Pipeline: when present,
  `CaptureFrame.captureDate` / `CaptureFrame.capture_date` carries the
  parsed instant into `captureBatch` / `capture_batch`; the drawer's
  `filedAt` is set to that instant (Swift: `frame.captureDate ?? now`;
  Rust: `frame.capture_date.unwrap_or(now)`). HLC physical time follows:
  Swift `insertFreshBatch` computes each HLC stamp from `d.filedAt` (was
  single batch `nowMillis`) so per-record override is honored at the CRDT
  layer too. Absent records use the batch wall-clock — byte-identical legacy
  behavior. Golden pin (both ports): `capture_date "2026-01-15T10:00:00Z"`
  → `filedAt = 1 768 471 200 000 ms`. `LOCUSKIT_INTERFACE` bumped to
  v1.29.0 documenting `CaptureFrame.captureDate` (Swift) and
  `CaptureFrame.capture_date` (Rust). New tests: 10 Swift
  (`JsonImportBridgeTests`) + 6 Rust (`json_import_bridge.rs`).

### 1.49.0 -- 2026-08-20
M3: `moot_memory_search` `scoring` parameter now accepts `discriminative` as a fourth valid value (in addition to `raw`, `rrf`, `matrixAware`). The `scoring` paragraph updated to describe the new mode and expand the valid-values list. Swift (`ToolProjection.swift` schema + `ToolDispatch.swift` parse) and Rust (`interface_tools.rs`) both updated. Decode remains fail-closed.

### 1.48.0 -- 2026-08-20

- `moot_memory_search` gains optional boolean argument `anomalous_filter`
  (§11.18). Absent/`null` = passthrough; `true` = anomalous-only; `false` =
  exclude anomalous. Decoded by `optionalBool` / `optional_bool` in both
  Swift `ToolDispatch` (`runMemorySearch`) and Rust `run_memory_search`.
  Non-boolean values return `invalidParams`. Maps to
  `GLKRecallRequest.anomalousFilter` / `anomalous_filter`.
### 1.54.0 -- 2026-08-26

- **`ProviderPreference` record (MACD-3B2, dark Wave 1).** New public value
  type in `MootDaemonProvider`.  Fields (P1 exact set): `preferredKind:
  ProviderKind`, `preferenceGeneration: UInt64`, `issuingIdentity:
  SigningIdentityDescriptor`, `issuedAt: UInt64`,
  `lastCompletedHandoverGeneration: UInt64`, `preferenceMAC: [UInt8]`.  No
  estate key, bearer credential, capability inventory, or migration bookmark.
  Static `preferenceKey(installationRoot:)` derives K_preference via
  HKDF-SHA256 with domain `"MOOTX01-PROVIDER-PREFERENCE-v1"` and zero salt
  (both legitimate writers derive independently from K_install — no per-write
  challenge to bind).  `macInput()` encodes all five fields via
  `CanonicalEncoder`.  `signing(installationRoot:)` and
  `verifyMAC(installationRoot:)` (constant-time).  `encoded()` produces
  canonical sorted-key JSON with 8 exact keys.  `decode(_:)` uses
  `strictJSONObject(expected:)` — extra or missing keys return nil (fail-closed).

- **`ProviderPreferenceObservation` enum (MACD-3B2).** Arbiter-facing summary:
  `.none` / `.verified(preferredKind: ProviderKind, preferenceGeneration:
  UInt64)` / `.invalid`.  Never carries raw MAC bytes.

- **`ProviderPreferenceStore` (MACD-3B2).** Durable store: atomic replace via
  `SecureFiles.atomicReplace`, fail-closed reads (unreadable / malformed /
  MAC-invalid / monotonic rollback → `.none` or `.invalid`, never permissive),
  monotonic generation enforcement on write (equal-or-lower generation refused
  with `DaemonProviderError.generationFault(.overflow)`) and on read
  (`minimumExpectedGeneration` parameter).  Lock-free: no provider lock required
  (the preference sits below the lock in the authority hierarchy).

- **`ArbiterObservation` extended (MACD-3B2).** Gains `preference:
  ProviderPreferenceObservation` (default `.none`) and six explicit repair-gate
  Bool inputs (all default `false`, fail-closed): `noAuthenticatedLockOwner`,
  `noHandoverInProgress`, `bundledArtifactAbsentOrUnusable`, `unambiguousCensus`,
  `directProviderSchemaCompatible`, `generationRollbackChecksPassed`.  All
  existing call sites compile unchanged (keyword-only, all-defaults init).

- **`ProviderArbiter.arbitrate(_:)` authority-level-4 branch (MACD-3B2).**
  After the dual-registration conflict check, when ALL six repair conditions
  are `true` AND preference is `.verified(.standalone)`, the dual-registration
  conflict is resolved to `.standaloneRegistered`.  A `.bundled` preference can
  never satisfy the repair gate: `bundledArtifactAbsentOrUnusable` is a
  required condition, proving the bundled artifact absent, so a `.bundled`
  preference falls through to `.conflicted(.dualRegistrationUnproven)` —
  `.bundledRegistered` is not a possible output of the authority-level-4
  branch.  A preference NEVER overrides a live owner, a handover, a
  recovery state, a compatibility failure, or an ambiguous census.  No new
  `ProviderArbiterState` wire encoding — the twelve frozen states are
  sufficient; `allWireEncodings` unchanged.

- **`ProviderRootLayout.preferenceFile` (MACD-3B2).** New computed var
  returning `"provider-preference.v1.json"` in `supportDirectory` beside the
  descriptor (same custody namespace as `migrationGrantFile` /
  `migrationChallengeFile` — NOT inside `providerDirectory`).

- **`ProviderSelfReport.digestInput` + `canonicalReport` (MACD-3B2).**
  `digestInput()` appends, after the MACD-3B1 schema-3 tail, the preference
  MAC domain constant and each of the 7 `ProviderPreference.macTranscriptFields`
  names (a transcript-field rename changes the module digest).
  `canonicalReport()` gains `"preferenceDomain"` and
  `"preferenceTranscriptFields"` keys.  Module digest changes
  by construction; both shells compute the same new digest.

#### Provider version vector and descriptor schema 3 (MACD-3B1)

- **`ProviderVersionVector` (MACD-3B1, dark Wave 1).** New public value type
  in `MootDaemonProvider`.  Fields: `providerReleaseGeneration: UInt64`,
  `managementRevisionMinimum/Maximum: UInt64`, `dataPlaneRevisionMinimum/Maximum: UInt64`,
  `estateSchemaMinimum/Maximum: UInt64`, `migrationTargetSchema: UInt64?`,
  `capabilityRevisions: [String:UInt64]`.  Static `.current` carries module
  compile-time constants.  `hasEncodableFieldWidths` safety gate.
  `appendWire1Fields` (fixed frozen MAC order for schema-3 MAC extension).
  `schema3MAC(descriptor:vector:installationRoot:)` computes schema-3 MAC.
  `isLegacyDescriptor(_:)` classifies schema-2 16-key records (R4 fail-closed
  legacy path).

- **`VersionCompatibilityVerdict` + `VersionVectorEvaluator` (MACD-3B1).**
  Pure-function evaluator implementing the design's 7-step deterministic
  coexistence policy.  Verdicts: `compatible`, `generationDowngrade`,
  `keepOwnerNoOverlap`, `candidateCannotReadEstate`,
  `legacyNotEligibleForAutomatedTakeover`, `updateApp`, `updateCliService`.

- **`DescriptorPublisher` schema-3 API (MACD-3B1).**  `fieldNames` now 23
  keys (16 + 7 new vector fields).  `encode(_ descriptor:, vector:)` and
  `decode(_ data:) -> (descriptor:, vector:)?` carry `ProviderVersionVector`
  companion.  `publish(_ descriptor:, vector:, lockProof:, estateReady:,
  bind:, authenticator:)` gains `vector` parameter.  Schema-2 records decode
  as `nil` (fail-closed).

- **`DaemonProviderConfiguration` + `ProviderActivation` (MACD-3B1).**
  Both gain `versionVector: ProviderVersionVector` (defaulted to `.current`
  in configuration, preserving existing call sites).

- **`CanonicalEncoder.appendSortedMap` (MACD-3B1).** Additive deterministic
  sorted-key map primitive (`[String:UInt64]`, UInt32-length-prefixed,
  lexicographic key order).  Consistent with `appendCapabilities` encoding.

- **`ProviderSelfReport.digestInput` + `canonicalReport` (MACD-3B1).**
  MACD-3B1 additive tail: `ProviderVersionVector.releaseGeneration` (UInt64)
  plus 7 frozen schema-3 wire field-identifier strings.  Module digest
  changes by construction; both shells compute the same new digest.
### 1.47.0 -- 2026-08-17

- **`MootDaemonProvider` estate-convergence surface (MACD-2c2).** New public
  types in the shared provider module (apps/mootx01, linked identically by
  the direct daemon shell and the sandboxed helper): `DefaultEstateCensus`
  (pure disposition judge + file-level observation), `CensusCandidateRecord`
  / `CensusObservation` / `CensusIdentity` / `CensusDisposition` /
  `EstateCandidateClass`; `MigrationChallenge` / `MigrationGrantEnvelope` /
  `MigrationGrantAuthority` / `ConsumedGrant` (challenge-bound MAC,
  journal-first one-use consumption); `GrantResolutionPolicy` (production
  stale policy with F4 denial classification); `EscrowRules` /
  `KeyEscrowAuthority` (structurally mint-free); `DefaultEstateMigrator` /
  `MigrationReceipt` / `MigrationReceiptStore` / `MigrationTransaction` /
  `MigrationStep` (staged-before-rename receipts, idempotent resume);
  `SourceEstateAccess` / `FileMigrationAuthority` (injected seams — no
  production SQLite conformer in this module; arrives with MACD-3);
  `ProductionRandomness` (SecRandomCopyBytes, fail-closed);
  `ProviderLayoutContext` + layout-context-bound `ProviderLock.acquire(at:context:)`
  and the `ProductionCredentialAuthority` marker (a production Keychain
  authority refuses under any non-production lock proof or proof context).
  `ProviderRootLayout` gains `grantJournal`, `migrationReceiptFile`,
  `migrationChallengeFile`, `migrationGrantFile`.

- **Shell modes.** `DaemonShellMain` adds `census` (read-only file-level
  census; one JSON line of class labels, digests, and the conservative
  disposition — never a raw path) and `resident` (the LaunchAgent contract
  entry point; exits 4 `resident-unavailable` until MACD-3). The canonical
  self-report adds `grantDomain`, `receiptDomain`, `censusDispositions`,
  `migrationSteps`; the module digest changes accordingly (additive tail,
  both shells identical).

### 1.46.0 -- 2026-08-16

- **`ARIA_MCPDispatcher.firstPartyIdentity` is not an initializer
  parameter.** It is `public internal(set)` and is set only by the
  authenticated router, from the live `FirstPartyAuthServer`'s identity.
  Correcting 1.45.0, which documented an `init` parameter that would
  have let the unauthenticated lane advertise the capability.

- **`serverInfo.descriptorGeneration` and `serverInfo.credentialGeneration`
  are DECIMAL STRINGS, not JSON numbers.** They are `UInt64`; `Int64` and
  JSON's safe-integer range are both too small to carry the full range
  without trapping or losing exactness.

- **`FirstPartyAuthServer.identity` is actor-isolated and computed** from
  the descriptor currently in force, so `republish(descriptor:)` cannot
  leave a stale generation advertised. New
  `FirstPartyAuthServer.republish(descriptor:)`.

- **New on `FirstPartyAuthProtocol`:** `handshakeMaxBodyBytes`,
  `isExactContentType(_:)`, `strictJSONObject(_:expected:maxBytes:)`,
  `topLevelJSONKeys(_:)`, `exactUInt64(_:)`. New on
  `FirstPartyDescriptor`: `hasEncodableFieldWidths`.

- **`HTTPServer.legacyCollapsedRequest(_:maxBodyBytes:)`** reproduces
  `LoopbackHTTP.HTTPRequest.parse` for the public lane; the strict parser
  applies only under `/mcp/first-party`.

- **`MootGateway`:** `FirstPartyDaemonAuthenticator`'s handshake-exchange
  seam is now `internal`. The module's public surface offers exactly one
  initializer, which always uses the pinned, no-redirect, size-capped
  loopback exchange.

### 1.45.0 -- 2026-08-16

- **First-party authenticated wire surface (MACD-2b), dark.** New
  public types in `AriaMCP`:

  - `FirstPartyAuthProtocol` — the frozen constants, canonical
    encodings, HKDF/HMAC derivations, proofs, request/response MAC
    builders, base64url codec, canonical sequence parsing, and
    constant-time comparison.
  - `CanonicalEncoder` — length-prefixed, big-endian, fixed-order.
    `appendString`, `appendBytes`, `appendUInt16/32/64`, `appendUUID`,
    `appendCapabilities`.
  - `FirstPartyDescriptor` — descriptor schema 2, with `macInput()`,
    `canonicalBytes()`, `digest()`, and `verifyMAC(installationRoot:)`.
  - `ReplayWindow` — highest-seen plus a 128-bit history; `admit(_:)`,
    `isExhausted`.
  - `FirstPartyRootProviding`, `FixedFirstPartyRootProvider`,
    `FailingFirstPartyRootProvider`,
    `DataProtectionKeychainRootProvider` — the read-only root contract.
    No production root is minted in this revision.
  - `StrictHTTPRequest`, `StrictHeaderField`, `StrictHTTPParser` — a
    lossless, duplicate-preserving request parser for the
    authenticated lane only.
  - `FirstPartyServerIdentity`, `FirstPartyAuthServer`,
    `FirstPartyAuthenticatedRequest`, `FirstPartyAuthError`.

- **`HTTPServer.init` gains `firstPartyAuth:`, defaulted `nil`.**
  `HTTPServer.serve` gains the same parameter, likewise defaulted.
  With `nil` the entire `/mcp/first-party` subtree returns 404 and the
  request-reading path is unchanged. Existing call sites are source-
  and behaviour-compatible.

- **`ARIA_MCPDispatcher` gains `firstPartyIdentity`, `public internal(set)`.**
  It is NOT an initializer parameter and cannot be set by a caller: the
  authenticated router populates it from the live authenticator's own
  identity for the duration of one dispatch. With it `nil` — which is
  every third-party dispatcher — `initialize` output is byte-identical
  to revision 1.44.0.

- **`MootGateway` (macOS app) additions:** `DaemonDescriptor` gains the
  six schema-2 fields; `DaemonDescriptorDefect` gains
  `unsupportedAuthProtocol`, `unknownAuthKeyIdentifier`,
  `wrongEndpoint`, `unparseableBinaryVersion`,
  `malformedDescriptorMAC`, and `staleGeneration`;
  `DaemonCompatibility` gains `updateDaemonRequired` and
  `updateAppRequired`; `DaemonReadinessState` gains the matching two
  cases; new `SemanticVersion`, `FirstPartyDaemonAuthenticator`,
  `FirstPartyInstallationRootProviding`, and
  `FirstPartyAuthenticationError`.

- **`HTTPTransport.init` gains `verifyResponse:` and
  `redirectPolicy:`, both defaulted** to the pre-existing behaviour
  (`nil` and `.follow`). New `GatewayResponseVerification` typealias
  and `GatewayRedirectPolicy` enum; new
  `GatewayTransportError.responseVerificationFailed` and
  `.redirectRefused`.

- **Rust:** no interface change. The port gains a golden-vector test
  only and must not advertise `authenticated-first-party` until a
  separate parity mission implements the full wire.

### 1.44.0 -- 2026-08-15

- `moot_timing_report` window is bounded at the call level (AT-01,
  Codex Finding A): each call collects at most 262,144 audit events
  (64 full pages of 4,096; ~1.6× the largest real estate's audit log,
  measured 2026-08-15 at 162,860 events / 33 MB / ~216 B per row). A
  clamped call derives over what it collected and appends a final line
  `window: truncated at 262144 events — pass watermark_ms back as
  since_ms to continue`; untruncated reports keep the previous shape
  byte-identical. Clamp, not reject — the existing `watermark_ms`
  paging contract continues the scan. Both ports; tool descriptions
  updated to drop the unbounded "full-history scan" promise. The Rust
  port additionally seeds its paging cursor from `since_ms` (it
  previously re-paged the whole log from epoch on every call —
  same-symbol parity fix; the A6 exactly-once derivation contract is
  unchanged).
- Hint appenders preserve multi-block results (AT-01, Codex Finding B,
  Swift only): `appendUnknownArgsHint` and `applyHint` previously
  collapsed any result to its first content block, destroying
  `moot_json_import`'s `id_map` block whenever a hint fired. Both now
  append the hint to the first block's text and carry all trailing
  blocks through unchanged, matching the Rust `inject_hint` /
  `inject_unknown_args_hint` in-place behavior (Rust never had the
  defect). Error results remain untouched by the hint path.
- New tests: Swift `MultiBlockHintAndTimingWindowTests` (4); Rust
  `interface_tools::timing_window_tests` (2) plus `dispatch_tests`
  `timing_report_small_estate_has_watermark_and_no_truncation_line` and
  `json_import_id_map_block_survives_unknown_arg_hint`.

### 1.43.0 -- 2026-08-14

- Additive (mission BL-1 — botLink one-shot CLI transport, Swift port;
  Rust twin lands in BL-2): documented the cloud-agent access path in
  §1 — `mootx01-botLink` / `mootx01 botlink` (`ping`/`list`/`call`/
  `rpc`, machine-JSON stdout, loopback-only `--http` guard, exit codes
  0/1/2/64) — with the verbatim adapter-policy paragraph redirecting
  cloud agents away from `mootx01 query`. No wire-surface change; no
  client wiring change (`mcp.json` stays `http://127.0.0.1:4242`,
  `mootx01-proxy` stays the Desktop stdio face).

### 1.42.2 -- 2026-08-13

- Two more stale tool-count lines corrected (§1 memory-adapter baseline
  "71/65" → "74/67"; §5 Rust test census "71/71 / 65/65, Rust matches
  Swift exactly" → per-port truth 74/67 wire vs Swift 78/71 with the
  FAB5-I2 packet tools). Non-changelog current-state count claims now
  swept file-wide.

### 1.42.1 -- 2026-08-13

- Tool-count corrections: Swift `ToolProjection.tools()` is 78 vault-on /
  71 vault-off; the Rust wire surface is 74/67 (75/68 with the opt-in
  memory adapter) — the Swift surface minus the four Swift-side packet
  tools (FAB5-I2). The previous 71/65 and 72/66 figures had drifted
  across several tool additions.

### 1.42.0 -- 2026-08-13

- `moot_timing_report` (maintenance, both ports): argument `since_ms`
  (optional integer — a previous call's `watermark_ms`; omit or 0 for a
  full-history scan). Text report lines: `ingest_exact` /
  `cycle_vector` / `cycle_novel` / `cycle_dreamt` each as
  `n=<count>, p50=<ms>, p95=<ms>` (novel/dreamt add `unbounded=<count>`),
  `ingest_bulk` as `n=<units>, rows=<total>, rows_per_sec=<rate>`, and a
  final `watermark_ms: <ms>`. Line shapes are byte-compatible across
  ports so harness parsers read either. Registered in the maintenance
  tool family (now 6 tools).

### 1.41.0 -- 2026-08-12

- `moot_json_import` gains `return_id_map` (boolean, optional, default `false`; explicit `null` is invalidParams on both ports, message `"return_id_map must be a boolean; omit it to use the default"`). When true the reply carries a SECOND text block — `{"id_map":{"<record id>":"<drawer id>"}}`, one entry per seeded record, keys sorted so the bytes are identical across runs of the same seed. The prose receipt is block 0 and is unchanged, so every existing caller is unaffected.
- Why the argument exists: a record's lineage is deterministic (FNV-1a-128 of the record id), but the drawer id is minted fresh at insert and no recall surface addresses a drawer by lineage. A caller that must address what it just imported — cross-references, per-record reporting, or scoring retrieval against known records — otherwise has to re-discover each drawer by searching for its own content, which cannot be made exact because ranking decides what comes back.
- New dispatch primitive: `ToolDispatcher.textResultBlocks(_ blocks: [String])` (Swift) / `text_result_blocks(blocks: &[String])` (Rust), the multi-block success envelope. Deliberately NOT an overload of `textResult(_:)` — overloading on `String` vs `[String]` made the Swift type-checker weigh both candidates at every call site and it exceeded its time budget on this file's `+`-chained receipt strings.
- Backing field: `JsonImportReport.drawerIDByRecordID` / `drawer_id_by_record_id` (see VAULTKIT_INTERFACE 1.17.0), carried to in-process callers always; the argument gates only what the MCP reply renders.
- New tests: Swift `JsonImportToolTests` `returnIDMapNamesRealDrawerIDs` + `idMapIsOptInAndNullRejected`; Rust `dispatch_tests.rs` `json_import_return_id_map_names_drawer_ids` + `json_import_id_map_is_opt_in_and_null_rejected`. Both ports assert the mapped id addresses the drawer holding that record's content, not merely that the map is the right size. Tool count is unchanged.

### 1.40.0 -- 2026-08-11

- Bridge input limits (pc stream, security findings 012/036). §1 gains the two admission caps for `ProxyCommand.swift` and their `MootInstallerCore` primitives: `proxyMaxFrameBytes` (4 MB frame-size cap) and `ProxyConcurrencyGate` (16-slot actor-based counting gate). Both are byte-identical across Swift and Rust. `ProxyAdmissionGate.swift` is new in MootInstallerCore; `ProxyAdmissionTests.swift` is the new test suite.

### 1.39.0 -- 2026-08-11

- Bridge failure-response invariant (px stream). §1 documents `ProxyCommand.swift` (the stdio→HTTP bridge), `ProxyDispositionLogic.swift` (pure disposition and id-extraction functions in MootInstallerCore), and the four failure conditions that yield a synthesized -32603 error with the original request id. `proxyDisposition(statusCode:bodyEmpty:)` and `proxyRequestID(of:)` are the testable public surface; both exercised in `MootInstallerCoreTests/ProxyDispositionTests.swift`.

### 1.38.0 -- 2026-08-07

- MXE-CT3 P3 tiered contradiction surface. `moot_hunt_contradictions`:
  optional `tier` (1|2|3|"all", default "all") and `top_k` (1...50,
  default 5); default mode appends the tiered synthesis digest, single
  tier is a read-only purpose search. `moot_review_tunnel`: optional
  `reviewed_by` (default "user"), `verdict` extended with `"endorse"`;
  accept is user-only, a model reject is an objection. `moot_dream`:
  files tier-labeled candidates after the hunt phase and appends the
  tiered digest. Schemas declared identically in both ports.

### 1.37.0 -- 2026-08-06

- `moot_recall_connected` (recipe provenance, recall family, shares the
  recall-results output schema): args query (required), wing, limit,
  filter, estateID. Recipe tool roster 13.

### 1.36.0 -- 2026-08-06

- `moot_synthesize` grounding is now HYBRID: the raw query also drives a
  scored BM25+vector lane (reaching memories that share no query words);
  grounding becomes a ranking guarantee (term matches lead) rather than a
  hard lexical exclusion. Dispatch passes the base frame + query + terms;
  the recipe owns lanes and bounds.

### 1.35.0 -- 2026-08-06
Cue-ranking dispatch wiring for `moot_synthesize`:

- `runGroundedSynthesis` (Swift) / `run_grounded_synthesis_tool` (Rust) compute
  `frameLimit = max(userLimit, groundedSynthesisCuePoolBound=200)` and
  `recipeCap = userLimit` when a query is present. Both are threaded through to
  `GroundedSynthesis.Input` / `run_grounded_synthesis` so the cue-term reranker
  sees the full matched pool before the user's limit caps the synthesis.
- No change to the tool's public argument surface — this is an internal routing
  contract change only.

### 1.34.0 -- 2026-08-06

- `moot_synthesize` gains optional `query`: grounding-term extraction
  (stopword/short-fragment drop, digit exception, dedupe, cap 12) into an
  OR of case-insensitive content predicates AND-composed with `filter`;
  response names the cue with a `query:` line; all-stopword queries are
  rejected as invalidParams. Both ports. Completes the GroundedSynthesis
  recipe contract ("hybrid-recall a query and synthesize") at the ARIA
  surface — previously the tool accepted no cue and always produced a
  whole-estate recency digest.

### 1.33.0 -- 2026-08-05

- moot_dream `associates` argument (all|recent|off, default recent)
  and the zero-gated `associationsWritten:` report line, both ports
  (Swift step by the item-5 worker; Rust twin completes it).

### 1.32.0 -- 2026-08-04

- **Structured recall results (MXE-SS).** `ProjectedTool` gains an
  optional `outputSchema` (nil → key omitted from the `tools/list` entry;
  text-only tool entries byte-identical to before). The recall family
  (`moot_memory_search`, `moot_memory_get`, `moot_recall_shaped`,
  `moot_recall_precise`) declares the shared
  `recallResultsOutputSchema()` (Rust
  `tool_list.rs::recall_results_output_schema()`) and returns
  `structuredContent` alongside the unchanged text block through the new
  `structuredTextResult` envelope helper. Redaction parity per
  ARIA_MCP_SPEC 1.28.0 § 11.


### 1.31.0 -- 2026-08-04

- **`moot_erase_memory` partial-response contract (MXE-FA).** Documents
  the two response shapes: `erased memory <id>` (full) and
  `partially erased memory <id>: <N> accepted lineage sibling(s) refused
  erasure and remain readable: <ids>` (partial, `isError: false`). Backed
  by GLK's new `ExpungeVerbOutcome` return
  (GENIUSLOCUSKIT_INTERFACE 1.28.0). Teachme guides updated in both ports.

### 1.30.0 -- 2026-08-03
Observable output change on `moot_estate_status`: the `memories: N active
(M total)` and `subjects: N/M (K missing)` numbers now exclude restricted and
secret rows, as `wings:` already did. On an estate holding such rows both lines
report smaller numbers than before; on an estate without them nothing changes.
Field keys, field order, line count, and response shape are unchanged, so
consumers that read the body by prefix need no change — no in-repo consumer
parses these integers. Documents the drawer-aggregate ceiling and the
unfiltered non-drawer fields in the `moot_estate_status` section above.
Behavioural contract: `ARIA_MCP_SPEC.md` 1.26.0.

### 1.29.0 -- 2026-08-03
Observable output change on `moot_memory_search` and `moot_memory_get`: the
trailing `sensitivity_advisory:` line is now emitted whenever no sensitivity
grant is live, independent of what the estate contains. It previously also
required the estate to hold at least one `restricted`/`secret` row, which made
its presence an existence oracle for those rows. Both strings are reworded and
are byte-identical across the Swift and Rust ports; search and get keep distinct
phrasings. The `sensitivity_advisory: ` line prefix is unchanged, so consumers
that strip or detect the line by prefix (e.g. `MootSpotlightRecord.parse`) need
no change. Behavioural contract and the contents-independence invariant:
`ARIA_MCP_SPEC.md` 1.25.0.

### 1.28.0 -- 2026-08-03

- Typed conflict projection section (DCP M4): the three contradiction
  surfaces render the evaluator-backed section via one shared renderer
  (Swift `RecipeTools.conflictProjectionSection` ↔ Rust
  `conflict_projection_section`); GLK sweep verbs
  `conflictProjectionSweep` ↔ `conflict_projection_sweep`.

### 1.27.0 -- 2026-08-02

- Lens evidence addresses (PR-05): memory-listing lens findings cite
  memories as dense rows via the shared renderer (7 arms: keystones,
  free_association, cohesion, contradiction, trust_synthesis,
  partial_cue, successors); moot_lens_concepts lists member drawer ids
  capped at 20 (`lensExtentIDCap` ↔ `LENS_EXTENT_ID_CAP`);
  moot_lens_associations carries `exemplarDrawerIDs` (cap 5) per rule.
  Byte-identical across ports, golden-tested against the renderer.

### 1.26.0 -- 2026-08-02

- PR-04 utility tier: documented the estate-status `subjects: N/M
  (K missing)` line, the reserved `subject_backfill` drain-lane name
  (Swift `ToolDispatcher.subjectBackfillLaneName` ↔ Rust
  `SUBJECT_BACKFILL_LANE_NAME`), and the `verbose` flag on
  moot_list_lenses / moot_list_recipes (terse default). Estate-status
  teachme carries the consent-gated backfill standing behavior.

### 1.25.0 -- 2026-08-02

- Dense-row reply surface (PR-03): documented the five-field dense row
  as the default hit/citation shape across the recall family, the
  deviation-only narration contract, the `near:` anchor pivot on
  moot_memory_search + moot_recall_shaped (query no longer
  schema-required — exactly-one enforced at runtime), and
  moot_memory_get `ids:`/`depth:` (subject|distilled|full). Teachme
  guides for the recall family rewritten in both ports. Cross-port
  byte-identical goldens: DenseRowGoldenTests.swift ↔
  dense_row_golden.rs.

### 1.24.0 -- 2026-08-02

- Subject surface (progressive recall PR-02): documented the required
  `subject` argument on `moot_file_memory` (AI-facing register, 120-char
  contract), `moot_update_memory` `mutation=setSubject` + `subject`
  argument, and `moot_memory_list` `filter=missing_subject` (id-only
  subject-debt enumerator). Teachme guides for all three verbs updated in
  both ports.

### 1.23.0 -- 2026-07-20

- Updated intake/search language for GLK shared content: impatient writes index
  the canonical Drawer directly, and Corpus drain counts are Drawer-index
  counts rather than chunk counts.
- Confirmed that no ARIA/MOOTx01 surface enables CorpusKit passage chunking.

### 1.22.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line (see the "Upstream-release advisory"
subsection beside the version-skew one) when a newer product release exists
than the running binary. `ToolDispatcher` (Swift) gains
`updateAdvisoryProvider: (@Sendable () async -> String?)?` (defaulted `nil`);
`Dispatcher` (Rust) gains `update_advisory: Option<UpdateAdvisoryProvider>`
via the `with_update_advisory` builder (the Rust equivalent of the defaulted
Swift parameter — existing `Dispatcher::new` call sites unchanged), threaded
through `dispatch_tool_with_ledgers` / `interface_tools::dispatch` alongside
`version_skew`. Unlike `version_skew` the value is a lazily-evaluated
provider, not a startup-computed string — the resident daemon outlives
releases. Rate limiting (24h TTL), the 4s probe bound, failure caching, and
the `MOOTX01_NO_UPDATE_CHECK` kill switch live in the host advisor
(`MootInstallerCore.UpdateAdvisor` / `mootx01-cli::core::update_advisor`);
the kit only renders the line. Resident daemons only; stdio one-shots and
`aria-mcp-server` (both ports) never wire a provider. Both ports at parity.

### 1.21.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): `memory_adapter.rs`
implements all six commands (view, create, str_replace, insert, delete, rename),
the `MOOTX01_MEMORY_TOOL=1` opt-in gate, the Normal-tier sensitivity filter (mirrors
`isMemoryAdapterVisible` in Swift), and sensitivity-tier carry-forward on edits so
elevated-tier drawers are not silently downgraded. `tool_list.rs` gains
`memory_enabled()`, `build_tool_list_with_flags(vault_on, memory_on)`, and the
`memory_adapter_tool()` schema; `build_tool_list()` and `build_tool_list_with_vault_flag()`
delegate to it. When `memory_on=true` the `memory` tool is prepended (first in list,
mirrors Swift `memoryAdapterTools()` prepend order), raising the count to 72/66.
Existing dispatch and count tests updated to use `build_tool_list_with_flags(vault_enabled(), false)`
for determinism (prevents racing with env-var mutations in memory-tool tests). New test
file `tests/memory_adapter_tests.rs`: 19 tests covering env gate, tool-list projection,
and per-command happy + error paths. Updated §1 Rust package layout and Rust binary
description to document `memory_adapter.rs` and the opt-in gate.

### 1.20.0 -- 2026-07-16
Dataset tools (MX-TAB-7): three new tools `moot_file_dataset`,
`moot_dataset_query`, `moot_dataset_stats` with `.interface` provenance —
always visible, not vault-gated. Both ports (Swift `DatasetTools.swift`,
Rust `dataset_tools.rs`) at parity. Tool count: 68 → 71 (vault-on), 62 → 65
(vault-off). Adds new "Dataset tools" subsection in §2. Also adds previously
undocumented public types: `DiscriminationLevel`, `RecallDiscrimination`
(scale-independent recall confidence heuristic, both ports mirrored), and
`MonitoringControl` protocol (the monitoring-control injection seam). Adds
`memoryToolEnabled` to ToolProjection block (opt-in memory_20250818 adapter,
MOOTX01_MEMORY_TOOL=1). Updates stale Rust tool census (55 → 71).
Updates `DatasetTools.swift`, `RecallDiscrimination.swift`, and
`MemoryToolAdapter.swift` / `MonitoringControl.swift` to §1 package layout.

### 1.19.0 -- 2026-07-12
Contradiction hunter MCP surface (both ports at parity, tool count 66 → 68):
`moot_hunt_contradictions` (recipe — on-demand bounded content sweep; strong
findings persist as PROPOSED `contradicts` tunnels, borderline pairs return
with snippets for agent adjudication) and `moot_review_tunnel` (Tier 2 —
accept/reject a proposed tunnel via `Estate.respondToTunnel`; rejection is
durable). `moot_link_memories` gains optional `proposed: bool` (files the
link in the PROPOSED lifecycle). `moot_dream` now runs the hunt sweep as its
content-driven third phase and reports `contradictionsProposed` /
`contradictionCandidatesBorderline`. `moot_lens_contradiction` output gains
lifecycle tiers: proposed edges shown by default flagged
`proposed (agent-derived, unreviewed)`; withdrawn/superseded excluded.
Permission tier: both new tools `ask` (mutation table, both installer legs).
Teachme guides for both tools plus updated dream/link guides. Contract tests
updated: 68 total, 62 vault-off (Swift `ToolProjectionTests` /
`V1ConformanceTests` / `VaultToolsTests`; Rust `dispatch_tests`;
installer `PermissionsWriter` inventories both legs).

### 1.18.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: `moot_monitoring_status` tool (§2 Tool projection, Tier 5 —
Estate tools, monitoring-control entry). Injection pattern: `MonitoringControl`
protocol (Swift) / trait (Rust) defined in AriaMcpKit; concrete implementation
(`StatsStoreMonitoringControl`) in AriaResident (Swift) and `http_server.rs`
(Rust). Read path: absent `enabled` arg returns current flag state. Write path:
present `enabled: bool` persists the flag via `StatsStore.setMonitoringEnabled` /
`set_monitoring_enabled` (wave 8.1 API), echoes new state with
`monitoring_source: user` line. No-store case: returns `monitoring: unavailable`
— never fabricates state. Permission tier: `ask` in both namespace prefixes.
Wave 8.3 smoke: `HTTPReadAPITests.freshStoreMonitoringDefaultIsEnabled` verifies
fresh StatsStore seeds monitoring=ON (wave 8.1 regression gate). Tool count: 64
(Swift and Rust at parity).

### 1.17.0 -- 2026-07-05
the sensitivity-grant contract sensitivity unlock/lock control endpoints (§4.6). Documents
`POST /api/control/unlock` and `POST /api/control/lock` — platform-
specific identity verification (macOS: LocalAuthentication; Linux/Windows:
PBKDF2-HMAC-SHA256), request/response shapes, proof freshness gate,
CLI surface (`mootx01 unlock private|secret`, `mootx01 lock`). Both
Swift and Rust ports at parity. Redaction advisory
(`sensitivity_advisory:` line) added to `moot_memory_search` and
`moot_memory_get` output when no grant is active and estate has
restricted/secret rows.

### 1.16.0 -- 2026-07-04
Added `moot_memory_get` (§2 Tool projection, Tier 1 — Core Memory table)
— fetch-drawer-by-ID, build-now per Bob's ruling. Input: `id` (drawer UUID,
required) plus the standard `estateID` every direct tool accepts.
Output: verbatim content (hydration `.full`), room/wing, `filedAt`/
`eventTime`, the five adjective-axis fields (state, trust, sensitivity,
exportability, confirmation), lineage, and a linked-tunnel summary
(same tunnel-scan pattern as `moot_connection_search`/
`moot_connection_map`). Swift `ToolDispatcher.runMemoryGet` routes
through `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`; Rust
`interface_tools::run_memory_get` routes through the Rust twin
`Estate::get_drawers_matching_frame` — both with an empty filter chain,
so `moot_memory_search`'s default containment gate (see the `filter`
argument section above) applies unchanged. A drawer that exists but
fails the gate is reported with the same "Memory not found: `<id>`"
error `moot_link_memories` already uses for an unresolvable id — the
by-id door cannot confirm existence of content the gate would
otherwise hide. Tool surface: 62 -> 63 (Tier 1: 7 -> 8; vault-on
62 -> 63, vault-off 56 -> 57). teachme guide added on both ports. Both
ports at parity. New tests: `MemoryGetTests.swift` (10 tests); Rust
`dispatch_tests.rs` `memory_get_*` (7 tests) + 1 teachme test.

### 1.15.0 -- 2026-07-04
the connection-ownership contract §5: `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line (see the new "Version-skew advisory" subsection under
§`moot_estate_status` — sync field vocabulary, below) when the host detects a
mismatch between an installed plugin (currently Claude Code's
`mootx01@mootx01`) and the running binary's version. `ToolDispatcher`
(Swift) gains a `versionSkewAdvisory: String?` field, injected at
construction the same way `buildSerial` already is; `Dispatcher` (Rust)
gains a `version_skew: String` field (empty string ⇒ no advisory), threaded
through `dispatch_tool_with_vault_ledger` / `interface_tools::dispatch`
alongside `build_serial`. Computed once at server startup by the host binary
— `MootInstallerCore.VersionSkewAdvisory.compute` (Swift) /
`mootx01_cli::core::mcp_ownership::version_skew_advisory` (Rust) — never by
the kit itself, which does not read `~/.claude/plugins/` or know a product
version. `aria-mcp-server` (both ports) has no plugin concept and always
passes the empty/nil default. Both ports at parity.

### 1.14.0 -- 2026-06-29
Security fix (secfix/c-aria-minor, CAND-043): `GET /api/graph` now ignores the
`?estate=` query parameter and always reads the **default estate's** topology
snapshot. The Swift private function signature changed from
`graphSnapshot(estate:topologyReader:)` to `graphSnapshot(topologyReader:)`;
callers (the `route` function) no longer extract the `estate` query string or
pass it to the reader. The `queryValue(_:in:)` helper was removed as it had no
remaining callers. This matches the existing Rust posture where `get_graph_snapshot`
always uses `registry.default` and explicitly documents that `?estate=` is ignored.
The observable GET /api/graph response format is unchanged.

### 1.13.0 -- 2026-06-29
Vault cap ordering fix (secfix/c-vault-cap): corrected `moot_vault_import` preflight
ordering in the Swift port. Previously `hashAllNotes` ran BEFORE `checkAndRegister`,
allowing up to the HTTP transport concurrency limit worth of concurrent expensive
filesystem/SHA-256 preflight work outside the cap. The cap now binds the preflight:
`checkAndRegister` runs FIRST, then `hashAllNotes` runs while holding the slot. A new
pre-Task do/catch releases the slot via `fail(jobID:)` when `hashAllNotes` throws, so a
throwing preflight never permanently consumes a cap slot. §Vault job concurrency cap
updated to reflect the new ordering. Rust port unchanged — `Dispatcher` `Arc<Mutex<>>`
already serializes all calls (effective cap of 1, no concurrent preflight fan-out
possible). New tests: `import_cap_enforced_before_expensive_preflight`,
`import_throwing_preflight_releases_slot` (Swift). Supersedes/refines secfix/c-vault-jobslot
(1.12.0) which established the slot-release invariant but placed the preflight before
the cap acquisition.

### 1.12.0 -- 2026-06-28
Vault availability hardening (secfix/c-vault-jobslot): documented the vault job
concurrency cap (4 slots, Swift port) and the slot-release invariant. In the Swift
port, `moot_vault_import` ran `hashAllNotes` preflight BEFORE `checkAndRegister`
so a preflight failure never consumed a slot. Non-regular `.md` entries (directories,
symlinks) are skipped in `hashAllNotes` rather than causing a fatal throw. The Rust
port is safe by construction (`run_import` records jobs only after bridge completion;
`collect_and_hash` skips non-files). Both behaviors and the concurrency contract are
described in §Vault tools above. New tests: `hashAllNotes_skips_directory_named_md`,
`import_cap_not_exhausted_after_directory_md_vault` (Swift); `hash_all_notes_skips_directory_named_md`,
`import_with_directory_md_vault_does_not_exhaust_ledger` (Rust). Note: the preflight-
before-cap ordering in this version left `hashAllNotes` outside the cap — corrected in
1.13.0 (secfix/c-vault-cap).

### 1.11.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria).

(1) **`moot_erase_memory` AriaMcpKit gate** — `confirmed=true` check enforced at the
AriaMcpKit boundary before the substrate is called. Schema unchanged; `confirmed` was
already present in `required`. Error message updated to name `confirmed=true` explicitly
and explain the owner-review intent. Both ports updated.

(2) **`moot_federated_search` requester anti-spoof** — `requesterEstateID` changed from
required to optional. When omitted the requester is the default estate. When supplied it
must match the default estate's UUID. Schema: `required` array changed from
`["requesterEstateID"]` to `[]`; property description updated to document the optional
binding and the anti-spoof refusal. Both ports updated.

### 1.10.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `isOriginAllowed` in `HTTPServer.swift` / `http_server.rs`
and `HTTPReadAPI.swift` / `http_read_api.rs` now validate the suffix after the loopback host
prefix instead of a bare prefix check, blocking DNS-rebinding prefix-spoof origins like
`localhost.evil`. Tests added on all four files.

(2) **`moot_palace_import` vault gate** — when `MOOTX01_VAULT=0`, `moot_palace_import` is
absent from `tools/list` and returns a clear refusal at dispatch (same as vault tools). The
tool reads arbitrary local SQLite files; gating it matches the vault-surface security posture.
Vault-off surface count: 57 → 56. Both ports updated (`ToolProjection`, `ToolDispatch`,
`tool_list.rs`, `dispatch.rs`).

### 1.10.0 -- 2026-06-25
Docs/guidance (T8 — teachme reconcile): the teachme `palace_import` guide no
longer tells the AI that `moot_reindex` + `moot_dream` are a REQUIRED two-step
finish — that contradicted the tool's own description (the import triggers its
own background indexing; the resident dreams on cadence). Guides now say
indexing is automatic, point at `moot_drain_status` to watch convergence, and
note `moot_dream` is only needed manually when running without a resident.
Residual `batch`/`non-batch` wording from the T1/T7 rename swept out of both
ports' teachme and the `moot-agent-skills` HOW_TO. No surface change.

### 1.9.0 -- 2026-06-25
Changed (T7 — one ingest engine, many gates): `moot_vault_import` takes a `mode`
(foreground/background encode SPEED) arg, replacing the Swift-only `batch` flag,
and the Rust vault-import tool now exposes `mode` too (it previously had no such
arg — a fixed Swift/Rust parity gap). All import gates (palace + vault/Obsidian/
OKF) now share one policy: caller declares SPEED, write strategy is size-gated
automatically. No new tool. Both ports.

### 1.8.0 -- 2026-06-25
Added (T5 — drain lifecycle): new internal CLI subcommand `mootx01 drain [--db]`
— opens an estate, drains its encode queue to empty, then exits. It is the
detached finisher a direct-open stdio `serve` spawns on exit (setsid/detached);
rarely run by hand. Also: estate open now eager-mounts the corpus drain worker so
a restarted daemon resumes a non-empty queue (daemon resume-on-restart). No
`moot_*` tool-surface change. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve transport): an stdio `serve` forwards to a live resident
serving the same estate (estate-marker match + `daemon.port` probe → the `proxy`
stdin→HTTP bridge) instead of opening a second direct writer; falls back to a
direct open when no resident answers. Resident writes a `mootx01.estate` marker
(removed on exit). No tool-surface change; transport behavior only. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import` replaces its `batch` (bool) arg
with `mode` (string `"foreground"` | `"background"`, default `"foreground"`).
`mode` selects the post-import encode SPEED (drain QoS) only — foreground drains
the encode queue across all cores, background caps to ~a quarter for very large
imports. The WRITE strategy (bulk transaction vs per-item stream) is now chosen
AUTOMATICALLY by source size (≤250k rows → bulk; larger → stream), not by the
caller. Unknown `mode` is rejected (fail-closed). Both ports.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` (both
ports) — a read-only, pollable report of every long-running background drain the
estate runs. Today the only drain is `corpus_encode` (the encode/ingest queue);
each drain reports pending + in-flight job counts, a draining/idle state, and
optional drain-specific detail (the corpus drain reports its live encoded-chunk
count). Unlike `moot_estate_status` it does NOT append the session-protocol
block, so it is cheap to poll while a drain settles (e.g. after
`moot_palace_import`). The report is list-shaped so additional drains surface
automatically. The whole surface grows 55 → 56. Reachable from the CLI as
`mootx01 query drain_status`. Also fixed a stale `moot_reindex` doc-comment that
pointed callers at `moot_estate_status` for encode-queue depth (it never reported
it) — now points at `moot_drain_status`. Conformance: dispatch tool-count/name-set
gates (Swift `ToolProjection` / Rust `tool_list.rs`).

### 1.4.0 -- 2026-06-19
`moot_estate_ping` response now includes a build serial segment:
`pong: estate <name> [<uuid>] is live — build <serial>`. The serial is derived
once at `ToolDispatcher` (Swift) / `Dispatcher` (Rust) construction from the
running executable's mtime and size; stored as `buildSerial` on the dispatcher;
threaded to `runEstatePing` / `run_estate_ping` without per-call filesystem
access. Override via `MOOTX01_BUILD_SERIAL` env var (non-empty value used
verbatim). New tests: `testEstatePingIncludesBuildSerial`,
`testEstatePingHonorsBuildSerialOverride` (Swift);
`estate_ping_includes_injected_build_serial` (Rust). Spec companion: § 14 in
ARIA_MCP_SPEC.md updated to document the derivation contract.

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
New `AutonomicGovernor` PRODUCER DUTY on both ports: Swift
`AutonomicGovernor.graphCentralityScan(kit:handle:now:)` (a nonisolated static
duty dispatched on the `graphCentralityIntervalMs` cadence, default 10 min) and
Rust `graph_centrality_duty` (fired inside `tick` on the same cadence). The duty
reads the estate structure graph, computes per-drawer eigenvalue centrality via
the NeuronKit `keystones` oracle, and registers a `GraphCache`
(`registerGraphCache` / `register_graph_cache`). `GovernorReport` /
`GovernorReport` gains `graphCentralityFired` / `graph_centrality_fired`. Swift
`AutonomicGovernor.init` gains a `graphCentralityIntervalMs` parameter; Rust adds
the `set_graph_centrality_cadence_ms` test knob. This takes the
`unionBest`/`matrixAware` recall `graph` column from dark to live in production on
both ports. Corrects the prior text framing the recall-cache producers as
standing-signal seam plug-ins: they are governor DUTIES.

### 1.2.0 -- 2026-06-17
Additive (#8 Track 1 — Brain orchestration harness, Rust side). The Rust
`AutonomicGovernor` now OWNS this estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and ticks it each iteration,
mirroring the Swift governor's `kit.signalTick(in:handle:now:)` — previously the
Rust governor ticked dreaming + maintenance only and documented "no
standing-signal scheduler". New public Rust surface on `AutonomicGovernor`:
`register_default_standing_signals(model_id, now)` (the architecture-spec §11.2
bootstrap, reading the live VectorStore via `EstateCoordinator::vector_store_for`,
now `pub`), `register_standing_signal(spec, now)`, `signal_status()`,
`open_signal_count()`, `signal_request_fire(id, now)`; `GovernorReport` gains
`pub signals_ticked: bool` (parity with the Swift `TickReport.signalsTicked`).
The scheduler lives in the governor (not the GLK coordinator) to avoid a
dispatcher reference cycle. The registration methods are the producer SEAM where
Track 2 (graph-centrality) and Track 3 (Bradley-Terry) plug in — their outputs
land in GLK `recall::{GraphCache, PreferenceStore}`; the producers themselves are
NOT part of this harness. The resident HTTP bootstrap (`rust/src/runtime.rs`)
registers the defaults once at startup, best-effort (a missing VectorStore logs
and the governor benign-skips, parity with the Swift resident). Conformance:
`tests/governor_standing_signals.rs` (benign skip / registered-defaults fire /
queryable emission / interval cadence) over the existing GLK
`tests/scheduler_parity.rs` engine gate. Swift behavior unchanged.

### 1.1.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): new `moot_recall_shaped` recipe tool (both
ports) — a single recall tool with a discoverable `preset` enum selecting a named
`RecallShape` from the GLK roster (preferable to ~20 tools). The tool description
embeds the full roster (each preset name + one-line emphasis); the preset enum is
the GLK `presetNames` list. Validation is fail-CLOSED: an absent preset uses the
unsteered `balanced` default, a present-but-unknown name is rejected with a tool
error. Returns the same plain-text shape as `moot_memory_search`. The four ARIA
filtering adjectives compose orthogonally (the preset ranks, the `filter` arg
filters). The `.recipe` bucket grows to 29 tools and the whole surface to 55
(census references updated to the current live count, which prior additions
— `moot_reindex`, `moot_vault_job` — had left at the stale 53). Conformance:
`RecipeToolsTests.swift` shaped-recall cases / `dispatch_tests.rs`
`recall_shaped_*` + the tool-count/name-set gates.

### 1.0.1 -- 2026-06-14
Reconciled the `.recipe` provenance tool count: the §`Recipe and lens tools` body enumerated only 5 CognitionKit recipe tools (yielding 26 with the 21 lenses) while the heading, the `ToolProvenance` projection, and the 53-tool census all carry 28. Added the two missing recipe tools (`moot_recall_precise`, `moot_dream`) to the body so it lists all 7 recipe tools + 21 lenses = 28, consistent with the verified Swift/Rust surface (`ToolProjection.tools()` / `tool_list.rs`, both gated at 53).

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

## Changelog

### 3.0.0 -- 2026-09-06

Removed stale adornment and stored-distillation contracts from the living
document. Aligned candidate rows and hydration with the schema-19 source.
The earlier entries remain historical records.
