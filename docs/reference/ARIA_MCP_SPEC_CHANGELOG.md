---
version: 4.5.1
date: 2026-09-15
description: "Historical changes to the ARIA MCP SPEC document."
status: active
---

# ARIA MCP Specification — Changelog

### 4.5.1 -- 2026-09-15

Memory-get distilled output uses v23-attributed in both ports and retained
dispatch paths, replacing the v2 prefix-truncation defect. Authorization and
Skim are unchanged; converter identity comes from the executed selection.

### 4.3.0 -- 2026-09-13

Added explicit memory-get Skim: authorized complete distillation followed by
source-order preview at a fixed 512 UTF-8 byte target. Documented the
`budgetHonored` and `complete` flags, the savings line, and exclusion of the
omitted tail.
No stored schema, ranking, or other hydration-depth behavior changes.

### 4.2.0 -- 2026-09-13

Added the default-off report_withheld modifier, conditional sensitivity-only meta
count, ranked topK keystones hydration definition, and unchanged-schema contract.

### 4.1.0 -- 2026-09-12

§ 12.4 gains the mutation-gate invariant. Every write verb that names a
memory (`moot_update_memory`, `moot_withdraw_memory`, `moot_erase_memory`,
`moot_confirm_memory`, `moot_move_memory`, `moot_link_memories`,
`moot_review_tunnel`) resolves its target through the read path's
sensitivity gate; an above-ceiling target is refused with the absent-id
envelope and nothing is written; `moot_link_memories` gates both endpoints;
`correct_sensitivity` may raise a readable row's tier and cannot reach an
unreadable one. Records behaviour shipped in both ports; no new argument.

### 4.0.0 -- 2026-09-11 (BREAKING)

The four work-packet operations are retired from the ARIA surface. §12.4's
filing-floor rule no longer names `moot_file_packet` among the verbs a
sensitivity argument applies to. Stored packet drawers already committed
to an estate are unaffected; this is a surface retirement, not a schema
change, and no `mootx01 upgrade` step is introduced. See
`ARIA_MCP_INTERFACE_CHANGELOG.md` 4.0.0 for the full removed-operation
list, deleted source files, and new tool counts.

### 3.5.2 -- 2026-09-10

§12.5 coaching triggers are now active on the v2 dispatch path in both ports.
All six triggers from the §12.5 table are implemented in `AriaV2Coach` (Swift)
and `v2::coach` (Rust). The v2 result envelope gains a hint slot as specified
in `ARIA_MCP_INTERFACE.md §3.10.2`: `structuredContent["hint"]` and an
appended `"\nhint: <text>"` line in `content[0].text`. Estate-provisioned
`coaching_calls` and `sticky_enabled` are applied on the first dispatch call of
each session. Full wire contract details are in the interface document.

### 3.2.0 -- 2026-09-07

§ 12.4: the filing floor covers every filing verb, with a sensitivity
argument (`moot_file_memory`, `moot_file_packet`: omitted files at the
ceiling, lower explicit refused) or without one (the `memory` adapter's
content-bearing writes file at the higher of their own tier and the
ceiling). Full entry in ARIA_MCP_SPEC.md § Changelog.

### 3.1.0 -- 2026-09-07

§ 12.4: a live sensitivity grant floors filings as well as lifting reads;
an omitted sensitivity files at the grant's tier, a lower explicit tier is
refused with the ceiling named. Full entry in ARIA_MCP_SPEC.md § Changelog.

### 2.0.1 -- 2026-08-26

Vocabulary (mission SSC-RENAME): the § 8.3 fourth column's acronym is
now defined at its definition site — Semantic Search Candle (SSC).
Terminology only; no behavioral change; rendered payloads and the
structured `ssc` key are byte-identical.

### 2.0.0 -- 2026-08-25

Adopted consolidation (Bob approval 2026-08-25) replacing the 1.55.2
document body with the consolidated behavioral specification drafted as
ARIA_PROPOSED_SPEC.md 0.1.0–0.3.0 (now archived): Spec/Interface
authority split; six-family external organization; § 8 retrieval
contract — return-shape taxonomy S1–S7, composer invariant, canonical
seven-column candidate row with fixed `-` absence columns, deviation-only
control lines with absolute trailing order and the degradation
predicate, structured base-row-plus-extensions contract with the
machine-MUST/AI-MAY consumption rule, fact/edge/tabular semantics,
empty-result rule; runtime-active zero/one/many adornment composition
over LocusKit's normalized adornment store (LOCUSKIT_SPEC 2.0.0);
sensitivity-advisory relocation to tool descriptions + estate-status;
the known-gap category deleted (spec leads, code follows — deviations
are conformance-backlog defects).

### 1.55.2 -- 2026-08-25

Structural reorganization per outside (Codex) review, grade C+ on
presentation: body restructured to a 16-section shape (status/scope,
normative labels, language model, interface model, profiles, lifecycle,
tool families, shared conventions, candidate-row contracts,
cross-cutting behaviors, resident lifecycle, HTTP endpoints,
conformance, rationale appendix, known-gaps appendix, history link);
table of contents added; this changelog externalized from the spec body
(was 46.8% of the file); category labels defined in § 2; design notes
moved to the rationale appendix; known conformance defects and Rust
deviations moved to the gaps appendix. Behavioral text preserved
verbatim — reorganization, not rewriting; zero body lines dropped
(verified against the prior version line-by-line).

### 1.55.1 -- 2026-08-25

Language ruling (Bob 2026-08-25): hedging vocabulary removed — "honesty",
"honest", "truth", "truthful" replaced with factual statements throughout
(12 occurrences; e.g. "Partial-erase honesty" § is now "Partial-erase
reporting"). Facts are stated as facts; no behavioral change.

### 1.55.0 -- 2026-08-25

Result-surface rulings (Bob 2026-08-25) — canonical candidate row + Samples.

**New § 12.9 Canonical candidate row (normative):** one line per memory —
UUID · subject · first sentence · SSC facts · adornment · event time ·
score — header `found N candidate memories, one per line`; mandatory for
every list/candidate-returning tool; Sample blocks required in every
response-shape section of this spec.

**Adornment weld corrections (supersedes the 1.53.0 wording):** the
adornment AUGMENTS its record's line/excerpt — it never replaces it — and
carries NO label (the former `adornment:` prefix is scaffold vocabulary
that taints the calling AI's context). Shipped in ContextSynthesizer both
ports 2026-08-25.

**moot_synthesize surface:** the digest's record list is renamed from
`keyInsights` to the candidate-memories form and emits canonical rows.
(The digest's remaining scaffold — summary/patterns/successRate/
recommendations — is under review; not yet changed by this entry.)

### 1.54.0 -- 2026-08-24

SCORE-ORDERING mission (Score-Transparent Ordering contract).

**`moot_memory_search` — score field on every dense row:**
Every row in the search response now carries the final recall score as a
suffix in the format ` · %.4f`. The score field is always present for
hits from a scoring-enabled lane; it is never zero for a hit that was
actually ranked.

**`moot_memory_search` — limit semantics:**
The `limit` parameter is now a **relevance floor**, not an exact row count.
Equal-scored results at the boundary are all returned, so the actual count
may exceed `limit` (pool-exhaustion expansion, disclosed in the payload) or be below `limit`
(determinate-prefix when a tie group straddles the window and the pool has
more items). The tool description is updated to reflect this contract.

**`moot_memory_search` — tie-disclosure message:**
When `GLKRecallResult.degradedStages` contains `"tie.nonDeterminate"`, the
response appends the message: "note: additional results share this score on
a non-deterministic tie; refine the query". Both the Swift (`ToolDispatch.swift`)
and Rust (`interface_tools.rs`) ports render this message.

### 1.53.0 -- 2026-08-23

ADORNMENT mission — payload rendering and dark tool.

**Candidate-list payload §:**
All candidate payloads returned by `moot_memory_search`, `moot_memory_get`,
and the recall tools ALWAYS include the adornment short form when present
(SPEC_ADORNMENT §5). The adornment line appears immediately after the content
line in the dense-row format. Suppression is a benchmark-internal seam only
(`MOOT_SUPPRESS_ADORNMENT` env var, `EstateSeams` pattern) — NOT a tool
argument and NOT part of the public ARIA surface. No schema text anywhere
in `tools/list` may mention suppression.

**moot_synthesize §:**
`GroundedSynthesisRecipe` reads adornments preferentially: when a candidate
has a non-nil adornment, the synthesis layer uses it as the primary content
input for that candidate's contribution (shorter, denser, date-grounded).

**Dark tool: `moot_run_adornment_pass`:**
`isRecipeTool` returns true for `moot_run_adornment_pass`; the tool is
dispatched but never listed in `tools/list`. The benchmark mint subcommand
invokes it by name to drive one on-demand AdornmentPass over a cached estate.
`adornment_max_length` argument is a harness-only audition override; absent
means the product default (`ADORNMENT_MAX_LENGTH` from AdornmentLib) applies.

### 1.52.0 -- 2026-08-22

MODES-PREFS mission: estate-provisioned modes preferences.

**New spec invariant — estate-provisioned modes preferences:**

The estate manifest key `"modes_config"` stores a JSON object with two optional fields:
- `sticky_enabled` (bool, default true): when false, mode declarations are accepted
  and a hint is returned, but the session sticky state is never set.
- `coaching_calls` (int, default 25): how many tool calls between coaching blocks;
  0 = off.

The server reads this manifest key on the FIRST tool call of the session and applies it
via `applyPreferences`. Subsequent calls skip the read (apply-once contract, guarded by
`configuredFromEstate`). Absent key or malformed JSON falls through to spec defaults.

**Seam precedence rule:** Test seams that call `setCoachingCallsX` directly also set
`configuredFromEstate = true` so the estate manifest does not override the seam value.
This rule applies to both Swift and Rust ports.

**No wire change**: `modes_config` is an estate-internal manifest key; the MCP tool
surface is unchanged. Existing tool contracts are unaffected.

### 1.52.1 -- 2026-08-22

Corrects a stale symbol name in the 1.51.1 changelog: `GUIDE_ESTATE_STATUS`
was the original constant name before the Rust port refactored the estate-status
teachme text into the `estate_status_guide()` function. The changelog entry now
references `estate_status_guide()` which is the actual current symbol.
No behavioral change.

### 1.51.1 -- 2026-08-22

Corrects the sticky-session-state description (§Sticky session state): the
claim that HTTP mode state is per-request was wrong. HTTP state is currently
process-global and shared across all clients in the same server process.
A per-client-id map with TTL for HTTP is noted as a planned follow-up with
the resident HTTP server. No behavioral change — this entry corrects the
documentation to match the implementation. Both ports' teachme text
(`estate_status_guide()` / `modesTeachmeGuide`) updated to match.

### 1.51.0 -- 2026-08-22

Moot Modes (MODES mission): five advisory tool-bundle modes at the ARIA door.
Modes are fail-open and advisory; every tool keeps working in every mode.

- New `mode` arg on every tool: accepts `"ModeName"` or `"ModeName=Variant"` strings.
- Five roster modes: Recall, Filing, Lenses, Vault, Curator.
- Recall has three behavior variants: `Recall=Auto` (answer:auto), `Recall=Rows`
  (answer:never), `Recall=Answer` (answer:always). Other modes have no variants.
- Unknown mode names and unknown variants: accepted (fail-open) with advisory hint.
- Sticky session state: last-declared mode wins for the session. An unrecognized
  mode declaration is IGNORED ENTIRELY — it does not clobber valid sticky state.
- Periodic coaching: every X calls (default 25, 0=off), a deterministic coaching
  block rendered from `CoachingSnapshot` is appended to the response.
- `modesStatusSection` added to every `moot_estate_status` response; rendered
  from the live mode registry (both ports, byte-identical).
- New `modes.sticky_enabled` provisioned preference (default true) controls
  whether mode declarations persist across calls; the seam is wired but a
  provisioned manifest family (`provisionedModesManifest`) is a planned
  follow-up (Finding 6 — deferred).
- Gate tests: 23 Swift tests (ModesDispatchTests, PeriodicCoachTests),
  20 Rust tests (modes_tests); shared conformance fixtures for coaching
  golden-pin and modesStatusSection byte-identity.

### 1.50.0 -- 2026-08-22

Additive (answer arg + GLKResultsPackager): `moot_memory_search` now accepts
`answer` arg (`auto` | `never` | `always`) controlling response shaping.
`GLKResultsPackager` synthesizes AI answer blocks when `answer` is `always`
or when `answer` is `auto` and confidence exceeds the gate. Both ports
(Swift/Rust) are byte-identical on the dense-row baseline. Gate tests: 26 Swift
tests (AnswerArgDispatchTests), 9 Rust tests (packager_tests).

### 1.49.0 -- 2026-08-22

Additive (front-door family, step 2 — `door` argument + A1 manifest):
`moot_memory_search` now accepts an optional `door` adjective argument
implementing the front-door family scoring-selection hierarchy:

```
explicit door arg > explicit scoring arg > A1 DoorManifest (provisioned) > matrixAware
```

Valid door values: `guess` (reads the per-estate `DoorManifest` provisioned
by the quality optimizer; falls back to `matrixAware` when absent), `rrf`,
`matrixAware`, `raw`, `discriminative` (direct scoring overrides). Unknown
strings including reserved `hedge`/`thorough` fail CLOSED (`invalidParams`)
— they will be wired at the recipe layer in a future build.

When neither `door` nor `scoring` is supplied, the A1 per-corpus
`DoorManifest` is read from the estate manifest store; an un-provisioned
estate produces byte-identical behavior to the pre-1.49 default.

The `scoring` argument's documentation is updated to clarify that `door`
takes precedence when both are supplied.

Both ports (Swift `ToolDispatch.swift` / `ToolProjection.swift`, Rust
`interface_tools.rs` / `tool_list.rs`) are identical. Gate tests: 12
new Swift tests, 9 new Rust tests (DoorDispatchTests, dispatch_tests).

### 1.48.0 -- 2026-08-21

Changelog ladder repair (merge of develop/1.1.x, 2026-08-21): the
moot_recall_temporal notes below were previously mis-filed as bullet
lines inside the 1.28.0 entry, self-labeled with version numbers
that the develop stream legitimately minted for unrelated changes.
They are re-homed here verbatim with their original self-labels
preserved as historical text; the labels do NOT refer to entries in
this ladder. No behavioral change in this entry.

- **v1.41.0 (2026-08-20)** — moot_recall_temporal: date-seeking questions with no stated date rank real-dated memories first; narration line `temporal: <mode> date-seeking — …read the answer from each row's event_time`; description carries the steering sentence.
- **v1.40.0 (2026-08-19)** — moot_recall_temporal v2: new `grab` argument (pool default | dated — unions a date-indexed store fetch into the candidate pool); sliding-window widening ±1..±10 days when the stated window holds fewer than limit matches, rows ranked date-proximity-first then text affinity; the temporal: narration line now names the grab arm and any applied widening (±Nd).
- **v1.39.0 (2026-08-19)** — Added moot_recall_temporal (recipe tier): reads the absolute date stated in the query — or an explicit from/to window, which wins — and matches it against drawer event_time; window=loose ranks in-window first keeping everything, window=tight returns in-window only and errors without a window. Dense-row reply plus a temporal: narration line. Tool counts: Swift 79 (14 recipe tools), Rust 75 vault-on / 68 vault-off.

### 1.47.0 -- 2026-08-21
Additive (D10 — walk_recall escalation ladder): `moot_recall_walk` tool exposes
`WalkRecall.run` to the MCP surface. Cheap Stage 1 (ShapedRecall /
`session_hybrid` preset, pool 20) runs first; if the top-gap confidence margin
`(s0 - s1) / max(|s0|, ε) ≥ 0.25` is met, results are returned immediately
(`stoppedEarly=true`). Otherwise Stage 2 (PreciseRecall / `hamming+text`
composition) runs and its results are returned. Empty pool after Stage 1 also
escalates. Arguments: `query` (required string), `limit` (int, default 5,
clamped 1–50), `filter` (string, default "unconfirmed"), `wing` (string,
optional), `now` (ISO8601 string, optional), `estateID` (string, optional).
Response: structured-text dense rows with discrimination line on Low/Medium,
plus `walk:` metadata line with `stage` and `stoppedEarly`. Both Swift and Rust
ports. Registered in `RecipeCatalog` / `catalog.rs` as entry 30. Tool counts:
vault-on 76, vault-off 69. Conformance: `WalkRecallTests.swift` (Swift CK, 7
tests) + Rust in-module tests (5); `RecipeToolsTests.swift` (3 new ARIA tests).

### 1.46.0 -- 2026-08-20
Additive (WIRE 1 — P4 study gap): `moot_memory_search` and `moot_recall_shaped`
gain an optional integer argument `frontier_k`. When present it overrides the
per-call candidate-pool depth in `GLKRecallRequest.frontierK` /
`frontier_k` — the same engine field that `RecallShape` presets can set, but
overridable at call time without changing the preset or shape. The engine clamps
the value to `[RecallShape.frontierKFloor, RecallShape.frontierKCeiling]` ([64,
256]). Absent or null → engine formula `min(max(limit × 4, 64), 256)`,
byte-identical to prior releases. Non-integer value → fail-closed
invalid-params error naming the argument. Both Swift and Rust ports. Swift
dispatch: `ToolDispatch.swift` (`runMemorySearch`) and
`RecipeTools.swift` (`runShapedRecall`) via `optionalInt`; Rust: `interface_tools.rs`
(`run_memory_search`) and `recipe_tools.rs` (`run_shaped_recall_tool`) via
`optional_integer`, threading through updated `shaped_recall.run` /
`CognitionKit::shaped_recall::run`. Schema exposed in `ToolProjection.swift`
/ `tool_list.rs` so the MCP tool list reflects the argument. Conformance:
`FrontierKArgumentTests.swift` (8 tests: schema × 2, absent × 2, integer × 2,
non-integer × 2).

### 1.45.0 -- 2026-08-20

- `moot_json_import` seed schema v1.2 (mission P2a). Each record in the
  `records[]` array may carry an optional `"capture_date"` key (UTC ISO8601,
  REQUIRED trailing `Z`; same two accepted shapes as `event_time`; offset
  forms are rejected for cross-port parity). When present, that record's
  drawer receives the given instant as its `filedAt` ingest clock (the CRDT
  ordering stamp, audit HLC physical time, and the capture-spread benchmark
  seam). Absent records use the batch wall-clock — byte-identical legacy
  behavior. Unknown-key guard error message updated from "schema v1.1" to
  "schema v1.2". Golden pin: `capture_date "2026-01-15T10:00:00Z"` →
  `filedAt = 1 768 471 200 000 ms` (both ports). New tests: 10 Swift
  (`JsonImportBridgeTests`) + 6 Rust (`json_import_bridge.rs`) covering
  parse, pipeline wiring, legacy bracket, and golden pin.

### 1.44.0 -- 2026-08-20
M3: `moot_memory_search` `scoring` parameter gains a fourth valid value `discriminative`. The mode computes RRF fusion and scales the composite score by the dense-lane saturation discount (factor ∈ [0, 1]) with no matrix steer. Decode remains fail-closed — the accepted value list is now `raw`, `rrf`, `matrixAware`, `discriminative`.

### 1.43.0 -- 2026-08-20

- `moot_memory_search` gains optional boolean argument `anomalous_filter`:
  `null`/absent = no filter (passthrough), `true` = surface only drawers
  whose `isAnomalous` bit (bit 26) is set (low-cohesion outliers), `false` =
  exclude anomalous drawers. Decoded in both Swift and Rust `ToolDispatch`;
  maps to `GLKRecallRequest.anomalousFilter` / `anomalous_filter`. Both
  ports decode the argument via `optionalBool` / `optional_bool` helpers
  (same helpers already in use for other optional boolean args). Additive:
  consumers that omit the argument get passthrough behaviour identical to
  prior releases.

### 1.42.0 -- 2026-08-20

- `moot_memory_get` is now a B-10a dereference verb (W1 mission). When it
  successfully returns a drawer body that was previously surfaced by
  `moot_memory_search` in the same session, it calls `noteUsage` /
  `note_usage` → `markRecallUsed` / `mark_recall_used` to flip the
  `used` bit on the corresponding recall-trace rows. The dreaming daemon's
  reward sweep subsequently assigns `reward=1.0` for those rows.
  Applies to the single-id depth:full path AND the batch/shallow-depth path.
  Both ports (Swift and Rust). Conformance-gated by new tests:
  `memoryGetAfterTracedSearchSetsUsedBit` (Swift) and
  `memory_get_after_search_sets_used_bit` (Rust).
- Bug fix (also B-10a): `moot_memory_search` now records ALL surfaced hit ids
  in the session ledger using `hit.id` (always non-optional) rather than
  `hit.drawer?.id` / `hit.drawer.as_ref().map(|d| d.id)`. Previously,
  unhydrated hits (drawer == nil / None) were silently dropped from the ledger,
  making the dereference reward path unreachable for those rows. Both ports.

### 1.41.0 -- 2026-08-17

- **Descriptor v2 FILE format (MACD-2c2).** The published first-party
  descriptor is a single canonical JSON object at
  `<App Group container>/Library/Application Support/MOOTx01/daemon-descriptor.v2.json`
  (beside — not inside — the provider directory; its readers are clients).
  Exactly sixteen keys: `schemaVersion`, `providerIdentifier`,
  `serviceIdentifier`, `endpoint`, `authProtocol`, `authKeyIdentifier`,
  `publishedAt`, `instanceIdentifier`, `estateIdentifier`, `binaryVersion`,
  `contractRevision`, `mcpProtocolVersion`, `capabilities`,
  `credentialGeneration`, `descriptorGeneration`, `descriptorMAC`. Sorted
  keys; UUIDs canonical-string; generations DECIMAL STRINGS; `descriptorMAC`
  base64url without padding; capabilities sorted. A reader refuses any record
  with a different key set, non-canonical spellings, or >64 KiB.

- **Attended migration grant (MACD-2c2), first-party lane.** Cross-process
  contract for converging a legacy default estate onto the canonical App
  Group estate. The provider (holding the exclusive provider lock, census
  showing exactly one otherwise-valid candidate) writes a CHALLENGE file
  `migration-challenge.v1.json` beside the descriptor: exactly nine keys —
  `challengeIdentifier`, `providerInstance`, `candidateClass`, `nonce`
  (base64url, 32 bytes), `issuedAt`, `expiresAt`, `credentialGeneration`,
  `providerGeneration`, `descriptorGeneration` (decimal strings). The signed
  first-party app answers with a GRANT ENVELOPE `migration-grant.v1.json`
  (the ONE place opaque bookmark bytes exist): exactly thirteen keys —
  `grantIdentifier`, `providerInstance`, `candidateClass`,
  `challengeIdentifier`, the three generations copied from the challenge,
  `issuedAt`, `expiresAt`, `bookmarkDigest`, `bookmark` (both base64url),
  `escrowMarker` (`none`|`escrowed`), `grantMAC`. Envelope cap 16384 bytes,
  judged before parsing.

- **Grant MAC domains.** `K_grant = HKDF-SHA256(K_install,
  salt = SHA-256(challenge transcript), info = "MOOTX01-MIGRATION-GRANT-v1")`;
  the challenge transcript is CanonicalEncoder length-prefixed under
  `"MOOTX01-MIGRATION-CHALLENGE-v1"` over all nine fields, so an envelope
  verifies only against the exact outstanding challenge and the exact
  generations it named. The MAC input covers every envelope field except the
  raw bookmark bytes, which participate via `bookmarkDigest`. Bookmarks are
  created with `bookmarkData(options: [])` exactly — no security scope.
  Possession of K_install (read via the READ-ONLY data-protection Keychain
  root provider) is the provenance proof; a nonce never authenticates.
  Consumption is one-use, journal-first (durable record fsynced before the
  bookmark resolves), refusing replay, expiry, wrong
  instance/candidate/challenge, and any non-current credential generation.
  The migration receipt domain is `"MOOTX01-MIGRATION-RECEIPT-v1"`.

- **Census dispositions and migration steps in the self-report.** The
  provider module digest gains an additive tail: the grant and receipt
  domains, the five census disposition encodings (`none-found`, `one-valid`,
  `already-converged`, `byte-identical-duplicates`,
  `multiple-estates-hard-stop`), and the thirteen migration step encodings
  (`migration-census` … `migration-recovery-required`, with
  `awaiting-migration-grant` carrying the mission name). The TWELVE arbiter
  wire encodings are unchanged and remain frozen; migration state is a
  separate vocabulary, never an arbiter state.

- **First-party lane posture unchanged.** The authenticated first-party lane
  remains dark: no shipping GUI consumes the transport, and no production
  build opens the canonical estate through it. The daemon provider bundle
  registers DISABLED; its `resident` mode refuses with exit 4 until
  estate routing lands (MACD-3).

### 1.40.0 -- 2026-08-16

Corrections to 1.39.0, from independent review. Each fixes a statement the
implementation did not honour.

- **`serverInfo` generations are DECIMAL STRINGS.**
  `descriptorGeneration` and `credentialGeneration` are `UInt64`; a JSON
  number cannot carry that range (the encoder's integer is `Int64`, and
  double-typed numbers lose exactness above 2^53). A decimal string is
  exact for every value and cannot trap.

- **The identity reported on the first-party lane is derived from the
  live authenticator**, never configured alongside it. Two independent
  settings that had to agree could disagree — and did, in both
  directions: an unauthenticated `initialize` advertising the capability
  and publishing daemon identifiers, or an authenticated one omitting
  them. It also tracks descriptor republication, so a stale generation
  cannot be advertised after the descriptor moves.

- **The public lane's grammar is frozen and independent of the
  first-party lane.** Public requests are parsed with the legacy
  loopback grammar whether or not the authenticated lane is configured;
  the strict grammar applies only under `/mcp/first-party`, and the
  routing decision is taken from the legacy parse so lane selection never
  depends on strictness.

- **`Content-Type` is compared for EXACT equality**, after trimming and
  lowercasing, on the request lane and both handshake steps. A prefix
  comparison accepted `application/json-evil` and parameterized forms
  the specification already forbade.

- **Both peers apply the same strict JSON object shape** to handshake
  payloads before authentication: exact key set, no unknown keys, no
  duplicate keys, and a hard size cap. Duplicate keys matter because
  permissive parsers silently keep the last occurrence, so two
  implementations can disagree about a value while both believing they
  parsed the same document.

- **Handshake bodies are size-capped at 8 KiB, enforced at the read.**
  Previously the client buffered whatever a peer sent before any proof or
  parsing, which an unauthenticated port squatter could exploit.

- **Every integer conversion on the untrusted path is total.** Descriptor
  version fields are signed on the decoded record and unsigned on the
  wire, and canonicalization runs before the MAC verifies; a negative
  value previously trapped. Such descriptors now have no canonical
  encoding and are refused.

### 1.39.0 -- 2026-08-16

- **Authenticated first-party wire (MACD-2b), dark.** Adds a second HTTP
  lane on the resident server at the exact endpoint
  `http://127.0.0.1:4242/mcp/first-party`, alongside the existing
  third-party lane, whose behaviour is unchanged. The lane is
  UNAVAILABLE unless a first-party authenticator is explicitly
  configured; no shipping build configures one. MACD-2c supplies the
  signed provider, the provider lock, and descriptor publication;
  MACD-3 performs production routing.

- **Descriptor schema 2, contract revision 2.** The descriptor gains
  `authProtocol` (`hmac-sha256-hkdf-v1`), `authKeyIdentifier`
  (`installation-root-v1`), `publishedAt`, `credentialGeneration`,
  `descriptorGeneration`, and `descriptorMAC`. It still carries no
  estate path, estate key, authentication root, session key, nonce,
  bearer token, install path, or PID. Schema 1 records are refused
  rather than upgraded: a schema-1 descriptor carries no MAC, so
  nothing can verify it.

- **Canonical bytes.** All MAC and digest inputs use a fixed-order,
  length-prefixed binary encoding: UTF-8 strings preceded by a UInt32
  big-endian byte length, UInt64/UInt32/UInt16 big-endian, UUIDs as
  their 16 RFC 4122 bytes, byte arrays length-prefixed, capability
  sets sorted by wire spelling then counted. Delimiter concatenation,
  JSON key order, locale-dependent formatting, and platform-native
  integer encoding are all prohibited — `"a" || "bc"` and
  `"ab" || "c"` concatenate identically, so a MAC over a delimited
  concatenation authenticates neither field.

- **Derivation ladder.** `K_install` is 32 random bytes in the macOS
  data-protection Keychain (service
  `com.codedaptive.mootx01.daemon-auth`, account
  `installation-root-v1`, `kSecUseDataProtectionKeychain` true,
  non-synchronizable, fully expanded access group). It is never used
  directly as a request key. Three derivations, each with a distinct
  HKDF-SHA256 `info` domain:
  `K_descriptor` (salt = 32 zero octets, the RFC 5869 omitted-salt
  value), `K_auth` (salt = descriptor digest), and `K_session`
  (salt = SHA-256 of the session transcript).

- **Mutual handshake.** `POST /mcp/first-party/session/challenge` and
  `POST /mcp/first-party/session/establish`. A 19-field canonical
  transcript binds the descriptor digest, both identities, the exact
  endpoint, both generations, both nonces, the session identifier,
  and all three timestamps. Server and client proofs use distinct
  domains so a reflected server proof cannot satisfy the client
  check; the establishment proof is taken under `K_session`.

- **Request and response authentication.** Every request carries
  `Authorization: Mootx01Session <base64url>`, `Mootx01-Sequence`
  (canonical unsigned decimal, no leading zero, never 0), and
  `Mootx01-Request-MAC`. The request MAC covers the protocol domain,
  session identifier, sequence, uppercase method, exact path, exact
  content type, and SHA-256 of the exact body — not the body alone.
  Every response carries `Mootx01-Response-MAC` over the domain,
  session identifier, request sequence, HTTP status, content type,
  and SHA-256 of the body, including the empty 204 a notification
  receives.

- **Bounded state.** At most 128 outstanding challenges (single-use,
  30-second lifetime) and 64 live sessions (15-minute idle, 8-hour
  absolute). Expired entries are removed before capacity is judged,
  and at capacity the server refuses rather than evicting a live
  entry. Replay protection is a highest-seen sequence plus a 128-bit
  bitmap, so genuine out-of-order arrivals are admitted while
  duplicates and too-old sequences are refused. Replay state is
  committed only after the request MAC verifies.

- **Fail-closed compatibility.** Schema, auth protocol, contract
  revision, and MCP version must match exactly and are never
  negotiated down. The daemon binary version must lie in
  `[1.0.0, 2.0.0)` and must equal the authenticated
  `serverInfo.version`; below the range yields Update Daemon, at or
  above yields Update App. Descriptor and credential generations are
  monotonic.

- **Capability advertisement matches implementation.** `authenticated-first-party` is advertised,
  and the extra `serverInfo` fields (`instanceIdentifier`,
  `estateIdentifier`, `descriptorGeneration`, `credentialGeneration`,
  `contractRevision`, `mcpProtocolVersion`) emitted, ONLY when a
  validated root, an active descriptor, a bounded session store, and
  the request/response MAC middleware are all present. With the lane
  unconfigured the whole subtree 404s and `initialize` is
  byte-identical to before this revision.

- **Golden vectors.** `docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json`
  is the language-neutral authoritative definition, verified independently by
  the Swift and Rust test suites. The Rust port implements the
  verifier only; per the parity boundary it must not advertise or
  partially implement the runtime protocol.

### 1.38.0 -- 2026-08-15

- `moot_timing_report` gains a call-level collection bound (AT-01):
  at most 262,144 audit events per call, clamp-not-reject, with the
  clamp reported in the result text and the `watermark_ms` paging
  contract continuing the scan. Removes a caller-triggerable resource
  exhaustion (any connected client could force the entire audit log
  into daemon memory with `since_ms: 0`). Both ports; the Rust port's
  paging cursor is now seeded from `since_ms` like Swift's.
- Hint injection contract sharpened (AT-01): hints append to the FIRST
  content block's text and never drop trailing blocks, so multi-block
  results (`moot_json_import` with `return_id_map`) survive coaching
  and unrecognized-argument hints intact. This was already the Rust
  behavior; Swift previously collapsed to a single block.

### 1.37.3 -- 2026-08-14

- §12 tier decomposition now reconciles to the stated totals: Tier 7 is
  9 (recipe is thirteen tools, not twelve — `moot_recall_connected` was
  missing from the §2 enumeration and from the remaining-recipe count),
  and the four non-tier FAB5-I2 packet tools are named with an explicit
  reconciliation line (74 + 4 packet = 78). Found by Bob's audit: the
  corrected Tier-5 line still summed to 73 against a stated 78.

### 1.37.2 -- 2026-08-14

- §12 Tier 5 breakdown corrected: "(7 always + 1 vault-gated)" →
  "(8 always + 2 vault-gated)" — `moot_timing_report` (+1 always) and
  `moot_json_import` (+1 vault-gated) had landed since the text was
  set. Found by the pinned-model Adams re-run of rounds 3–4.

### 1.37.1 -- 2026-08-13

- Tool-count corrections: the total-surface figures had drifted across
  several tool additions (packet tools, `moot_json_import`,
  `moot_recall_connected`, `moot_timing_report`). Current counts: 78 tools
  vault-on / 71 vault-off on the Swift surface; the teachme live counts
  match.

### 1.37.0 -- 2026-08-13

- New maintenance tool `moot_timing_report` (C3+A6, benchmark reset):
  derives INGEST and CYCLE timing metrics from the estate's audit markers
  via NeuronKit's single derivation engine — the same derivation the
  performance-health duty will consume (§6b one-derivation-two-consumers).
  Read-only and stateless server-side: the caller keeps the returned
  `watermark_ms` and passes it back as `since_ms` for incremental scans.
  Rows with no subsequent retrain or dream are reported as unbounded
  counts, never dropped. Both ports; no orientation block (pollable, like
  `moot_drain_status`).

### 1.36.0 -- 2026-08-11

- Bridge input limits (pc stream, security findings 012/036). §5 gains the bridge input limits subsection documenting the two admission caps enforced by both ports: 4 MB per frame (oversized frames dropped with a stderr diagnostic, no synthesized error) and 16 frames in flight maximum (17th frame waits, never dropped). Both limits are byte-identical across the Swift `ProxyCommand` and Rust `proxy.rs` implementations.

### 1.35.0 -- 2026-08-11

- Bridge failure-response invariant (px stream). §5 gains the stdio→HTTP bridge subsection documenting the proxy adapter, the per-frame id-echoing error contract, the four conditions that trigger a synthesized error frame, and the stateless-per-frame session model. Root cause documented: `id: null` synthesized errors caused "Server disconnected" failures in Claude Desktop (MCP client schema-rejects `id: null` at parse time, poisoning the whole stream). Fix: all failure paths on id-bearing frames now echo the original request id via a -32603 synthesized error; notifications and `id: null` frames produce no reply per spec.

### 1.34.0 -- 2026-08-07

- Tiered contradiction surface (MXE-CT3 P3). `moot_hunt_contradictions`
  gains optional `tier` (1|2|3|"all", default "all") and `top_k`
  (1...50, default 5): default mode appends a tiered synthesis digest
  after the unchanged legacy report; a single tier is a read-only
  purpose search. `moot_review_tunnel` gains `reviewed_by` (default
  "user") and the `endorse` verdict — the review ladder: accept is
  user-only, a model reject is an objection (withdraw or contest),
  endorse records a vote without activating. `moot_dream` files
  tier-labeled conflict-tunnel candidates (`proposeConflictTunnels`)
  after its hunt phase and appends the tiered digest via the shared
  renderer.

### 1.33.0 -- 2026-08-06

- New recipe tool `moot_recall_connected`: multi-hop retrieval by graph
  diffusion — a scored anchor search seeds a deterministic
  walk-with-restart over tunnels (validated) ∪ dream-produced pending
  associations (Bob's 2026-08-06 ruling: pending edges are walkable,
  ~2–3% less confident; the discount is recorded, not applied — below
  Monte Carlo visit-count resolution). RRF fusion with the anchor
  ranking; memory_search output shape + a `connected:` lane-provenance
  line. The EXPENSIVE recall path; escalation is caller-side. Tool
  totals: 76 vault-on / 70 vault-off (Swift), 72 / 66 (Rust surface).

### 1.32.0 -- 2026-08-06

- `moot_synthesize` grounding contract extended to HYBRID pool
  acquisition: the raw query drives a scored BM25+vector lane beside the
  lexical term lane; ranking-rule paragraph updated (fusion only while
  the scored lane bears scoring evidence; lexical-dominant otherwise;
  zero-term-match rows never outrank term matches).

### 1.31.0 -- 2026-08-06
Cue-ranking grounding contract extension for `moot_synthesize`:

- When `query` is present, the recall frame is widened to
  `max(limit, groundedSynthesisCuePoolBound=200)` so the full matched pool
  is available for ranking. The user's `limit` is applied as a post-rank cap so
  only the top-N cue-ranked drawers feed synthesis.
- The dispatch layer extracts `cueTerms` from the grounding terms and passes
  them through to `GroundedSynthesis.Input` so the HybridRecallEngine's
  cue-term lane can rank the pool before the cap is applied.
- Empty `cueTerms` (no query) preserves previous output exactly — no change
  to the whole-estate digest path.

### 1.30.0 -- 2026-08-06

- `moot_synthesize` grounding contract: optional `query` scopes the
  recalled pool via deterministic grounding-term extraction (port-identical
  pure function) into OR'd case-insensitive content predicates, AND-composed
  with `filter`; the response names the cue; all-stopword queries are
  invalidParams. Query omitted = whole-estate digest, unchanged.

### 1.29.0 -- 2026-08-05

- moot_dream gains the association sweep (step 3.5): `associates`
  argument `all` (full-estate coverage, for post-import runs) /
  `recent` (default, the standing-signal window) / `off`. Report line
  appends `associationsWritten: N (probed: P, deduplicated: D)` —
  additive and zero-gated (silent when nothing was probed or written).
  Dreaming now triggers every cognition layer: matrix, proposals,
  contradiction hunt, associations, subject backfill.

### 1.28.0 -- 2026-08-04

- **Structured recall results (MXE-SS).** New § 11 subsection: the recall
  family (`moot_memory_search`, `moot_memory_get`, `moot_recall_shaped`,
  `moot_recall_precise`) declares an `outputSchema` and returns
  `structuredContent` (`results[]` of `id`/`room`/`content`/`subject`)
  alongside a byte-identical text block, with redaction parity as an
  invariant: no structured field ever carries what the text withheld.
  Both ports, one shared schema. No consumer changed (that is MXE-DF).


### 1.27.0 -- 2026-08-04

- **Partial-erase reporting (MXE-FA).** New § documenting the
  `moot_erase_memory` response contract: full erasure keeps
  `erased memory <id>` byte-identical; a lineage expunge the audit gate
  refused for accepted siblings responds
  `partially erased memory <id>: <N> accepted lineage sibling(s) refused
  erasure and remain readable: <ids>` (`isError: false`). No response ever
  claims a plain success for an expunge that refused a sibling. Both ports;
  teachme guides document both shapes.

### 1.26.0 -- 2026-08-03
Every drawer-derived aggregate in the `moot_estate_status` response now reads
the sensitivity-filtered set. `subjects: N/M (K missing)` and
`memories: N active (M total)` previously counted the raw cluster-A and
non-tombstoned sets, so an ungranted caller learned how many live rows were
hidden from it and how many of those carried content and a subject — on a
surface whose neighbouring `wings:` line was already filtered for exactly that
reason, and whose sibling `moot_memory_list filter:missing_subject` enumerator
already filtered before listing. The counter and that enumerator now describe
one population. On an estate holding restricted/secret rows these numbers drop;
that is the correction, not a regression. No sensitivity-grant plumbing is
added — `moot_estate_status` has none, and a grant-lifted true count remains a
feature request. Non-drawer aggregates on the same surface (`kg facts:`,
`trace_rows:`, `sync:`, `fdc_recalculation*`, `shared_content_migration:`) are
unchanged: they count no drawer set. Both ports, with the ceiling rule stated
in-code so aggregates added later inherit it.

### 1.25.0 -- 2026-08-03
The sensitivity advisory on `moot_memory_search` and `moot_memory_get` is now
emitted on grant state alone. Its previous second condition — an estate-contents
check for `restricted`/`secret` rows — made advisory presence an estate-wide
existence oracle for those rows, readable by a caller with no grant, and the
check itself defeated the sensitivity ceiling to run (an explicit sensitivity
filter suppresses `BitmapEvaluator`'s `sensitivityAtMost(elevated)` default).
The probe is deleted in both ports rather than narrowed, which also removes its
untraced `origin: internal` recall. Both advisory strings are reworded so they
are true regardless of estate contents and no longer assert that results are
being hidden; search and get keep distinct phrasings and each is byte-identical
across ports. Advisory absence under a live grant is unchanged. Adds the
contents-independence invariant above and its two-estate conformance test in
both ports.

### 1.24.0 -- 2026-08-03

- Typed conflict projection (DCP M4). moot_hunt_contradictions,
  moot_dream, and moot_lens_contradiction APPEND one shared additive
  section: `proven:`, `historical:`, `compatible:`, `candidates:`
  (lexical lane, hunt/dream only), `unknown_or_invalid:`,
  `coverage: projected/scanned`, `truncated_buckets:` (deviation-only).
  Per-proven block: result id, rule@version, coordinate, value digests,
  temporal bases, reason codes, and the two source ids as dense rows.
  Redaction ceiling = MAX endpoint sensitivity: restricted collapses to
  a coordinate-digest line, secret is counted with no block. Every
  existing line is unchanged; the lens's legacy grouped-objects view
  remains decodable. Retrieval proposes; typed constraints prove.

### 1.23.0 -- 2026-08-02

- Lens evidence addresses (PR-05): lens findings that name memories cite
  them as dense rows via the shared renderer (7 memory-listing arms,
  golden-tested byte-identical both ports); concepts extent ids capped
  at 20, association exemplar ids capped at 5 — every lens claim is
  hydratable via moot_memory_get.

### 1.22.0 -- 2026-08-02

- Utility tier (progressive recall PR-04). moot_estate_status gains the
  subject-debt counter line `subjects: N/M (K missing)` (presence debt
  over the live cluster-A non-empty-content set) with a STANDING
  BEHAVIOR contract in its teachme: when K > 0 the AI offers a
  consent-gated interactive backfill (missing_subject walk →
  setSubject), never a silent one. moot_drain_status reserves the
  `subject_backfill` lane name (constants both ports; the PR-09/10
  rider registers the live lane, and the benchmarker's non-gating
  denylist must gain the name in that same mission). moot_list_lenses
  and moot_list_recipes default to a terse catalogue (name +
  first-sentence one-liner) with the full catalogue behind
  `verbose: true`.

### 1.21.0 -- 2026-08-02

- Recall surface (progressive recall PR-03). The DEFAULT reply row for
  every recall-family hit and citation is the DENSE ROW:
  `uuid · subject · fdc:<code> · qid:<QID> · <event_time ISO8601>` —
  adopted by moot_memory_search, moot_recall_precise, moot_recall_shaped,
  moot_recall_vague (hits and originals), moot_recall_distilled (row then
  distilled text), moot_federated_search, moot_memory_list, and
  moot_connection_search/map citations. Absence markers are uniform and
  fixed ("(no subject)", "-"); redaction markers replace the subject on
  provenance restricted/secret rows. Narration is DEVIATION-ONLY: the
  "found N memory(s)" header stays (fail-loud harness contract); the
  [distilled] tag and per-hit tokens:/source: metadata lines are removed
  ("source: content (not yet distilled)" appears on fallback hits ONLY);
  the discrimination line appears only at effective low/medium; the
  recall_provenance line appears only when the dense lane is dark or
  stages degraded — absence means nominal.
- Anchor pivot: moot_memory_search and moot_recall_shaped accept
  `near:<uuid>` as an alternative to `query:` (exactly one required,
  runtime-enforced) — the anchor's content re-queries the same scored
  pipeline, the anchor is excluded from its own neighbors, and a gated
  anchor reads as not-found (oracle-free, no grant lift).
- Hydration depth: moot_memory_get gains `ids:[...]` batch and
  `depth: subject|distilled|full` (default full — the single-id full
  record keeps its original shape, now with a `subject:` line when
  present). Batch gate failures render as per-row "not found:" lines.
- BitmapOnly hydration now strips the distilled quad and subject trio in
  BOTH ports (the Rust leg previously cleared only `content` — a
  pre-existing parity divergence surfaced by the dense row on federated
  bitmapOnly reads).

### 1.20.0 -- 2026-08-02

- Subject surface (progressive recall PR-02): `moot_file_memory` now REQUIRES
  a `subject` argument (one sentence ≤120 chars, AI-facing register —
  returned in recall rows, never searched; LocusKit SPEC § 14).
  `moot_update_memory` gains `mutation=setSubject` with a dedicated `subject`
  argument (the backfill/correction path). `moot_memory_list` gains
  `filter=missing_subject` (id-only subject-debt enumerator). Intake verbs
  (palace_import, vault_import, file_dataset, file_packet) deliberately file
  NULL subjects — absence flows to the debt counter. The consolidation
  vague-tier writer emits its own deterministic subject at creation
  (pipeline `consolidation-v1`). Session protocol line updated.

### 1.19.0 -- 2026-07-20

- Aligned the ARIA projection with GLK 1.1 shared content: writes store one
  canonical Drawer, CorpusKit indexes that Drawer ID, and every recall lens
  returns the same object identity.
- Made standalone Corpus passage/chunk compatibility explicitly unreachable
  from MOOTx01.

### 1.18.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line when a newer product release exists on the
release feed than the running binary. Sibling of the 1.10.0 `version_skew:`
line (that one reports local plugin/binary skew; this one reports "the world
has moved past this install"), and deliberately confined to the same two
session-orientation tools so MCP clients are informed once at orientation
time, never nagged per call. Unlike `version_skew` the value is NOT computed
at startup: the resident daemon outlives releases, so the host injects a
PROVIDER (Swift `ToolDispatcher.updateAdvisoryProvider` closure; Rust
`Dispatcher.update_advisory` via `with_update_advisory`) that the two tools
evaluate lazily behind a host-owned 24h-TTL cache (Swift
`MootInstallerCore.UpdateAdvisor`; Rust `mootx01-cli::core::update_advisor`).
Probe bounded (4s) and failure-cached; resident daemons only (stdio
one-shots and aria-mcp dev never probe); disabled by
`MOOTX01_NO_UPDATE_CHECK` — the same kill switch as the Claude Code plugin's
SessionStart update hook. Line text: ``v<latest> is available (installed
<current>) — upgrade with `mootx01 upgrade` ``. Both ports at parity. New
tests: `testUpdateAdvisorySurfacesInPingAndStatus`,
`testNilUpdateAdvisoryOmitsField` (Swift `ServerTests.swift`);
`update_advisory_surfaces_when_wired_and_omitted_when_none` (Rust
`dispatch_tests.rs`); `UpdateAdvisorTests` (Swift, 8) and
`core::update_advisor::tests` (Rust, 6) unit-test the TTL/kill-switch cache.

### 1.17.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): the `memory` tool
is now at full parity in both ports. `memory_adapter.rs` implements all six commands
(view, create, str_replace, insert, delete, rename), the `MOOTX01_MEMORY_TOOL=1`
opt-in gate (off by default — 71/65 baseline unchanged), the Normal-tier sensitivity
gate (Restricted/Secret drawers not visible), and sensitivity-tier carry-forward on
edit/rename so elevated drawers are not silently downgraded. Wire contract is
byte-identical to the Swift `MemoryToolAdapter.swift` adapter per the no-FFI law.

### 1.16.0 -- 2026-07-16
§12 teachme guide: corrects stale tier tallies (Tier 1: 7→9, Tier 2: 3→4,
Tier 6: 18→27, Tier 8: 4→5, Total: 56→71/65) and expands from nine to ten
tiers (adds Tier 8 Dataset, Tier 7 Extended Cognition, renumbers Vault→Tier 9
and Federation→Tier 10). The guide is now a computed var deriving all counts
from ToolProjection.tools() at call time — it can never silently drift from
the shipped surface. Adds moot_memory_list to Tier 1 listing and its teachme
guide. Adds moot_review_tunnel to Tier 2 listing. Adds moot_vault_job to the
vault generic guide. New test (sp-3b) pins that the guide's count matches the
live registry.

### 1.15.0 -- 2026-07-16
Dataset tools (MX-TAB-7, §11): corrects the stale "44 tools / 19 interface /
16 lens / 4 vault / 4 recipe" figures throughout §11 to reflect the current
shipped surface (71 vault-on / 65 vault-off; 22 five-tier interface tools;
23 lens tools; 5 vault tools; 12 recipe tools; 3 new dataset tools
`moot_file_dataset`, `moot_dataset_query`, `moot_dataset_stats`). Updates
§12 moot_list_lenses cognition-menu count from 18 to 27 (23 lens + 4 recipe
tier-6 tools). Corrects the guide's stated total from the wrong "44 tools"
(written when the guide code said 44; the code now says "56 tools") to "56
tools", pointing to ARIA_MCP_INTERFACE.md §2 as the authoritative live count.

### 1.14.0 -- 2026-07-12
Contradiction hunter surface (§11): `moot_hunt_contradictions` (recipe,
on-demand bounded content sweep), `moot_review_tunnel` (Tier 2 review verb
over `Estate.respondToTunnel`), `moot_link_memories` optional
`proposed: bool`, `moot_dream` third phase (hunt sweep + contradiction
counts), `moot_lens_contradiction` lifecycle tiers (proposed shown by
default, flagged). Total tool count: 68 (was 66). Permission tier `ask`
for both new tools. Both Swift and Rust ports at parity.

### 1.13.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: adds `moot_monitoring_status` to the interface-tool surface.
Reifies the ARIA `read` verb on the monitoring object (estate-scoped, daemon
daemon-global flag). Args: absent `enabled` → read current state; present
`enabled: bool` → write flag + echo new state with `monitoring_source: user`.
When no telemetry store is wired (stdio, test harnesses, provision-less
contexts), reports `monitoring: unavailable` — never fabricates enabled/disabled.
Permission tier: `ask` in both `mcp__mootx01__` and `mcp__plugin_mootx01_mootx01__`
namespaces. Total tool count: 64 (was 63). Both Swift and Rust ports at parity.

### 1.12.0 -- 2026-07-05
the sensitivity-grant contract: sensitivity unlock/lock control endpoints (§19). Adds
`POST /api/control/unlock` and `POST /api/control/lock` — loopback-only
endpoints for out-of-band sensitivity-tier grants and revocations. Grant
TTLs: restricted → next local midnight; secret → 30 minutes. Proof
freshness gate ±10s. Platform identity: macOS/Swift via LocalAuthentication;
Linux/Windows/Rust via PBKDF2-HMAC-SHA256 (260,000 iterations) against
the `sensitivity_hashes.json` sidecar. CLI surface: `mootx01 unlock
private|secret` and `mootx01 lock`. Both ports at parity. Also adds
redaction advisory (`sensitivity_advisory:` trailing line) to
`moot_memory_search` and `moot_memory_get` when no grant is active and
the estate has restricted/secret rows.

### 1.11.0 -- 2026-07-04
Added `moot_memory_get` (§11) — fetch-drawer-by-ID, build-now per Bob's
ruling on the parking-lot gap ("no verb to fetch a full drawer by UUID on
the MCP surface — recollect covers distilled factoids only"). Reifies the
`recall` verb, named as a `moot_memory_search` sibling per the lexicon's
`<noun>_<verb>` query-tool naming discipline. Routes through the existing
frame-faithful by-id load (`Estate.getDrawers(ids:matchingFrame:
hydrationLevel:)` / Rust `Estate::get_drawers_matching_frame`) with an
empty filter chain, so it inherits `moot_memory_search`'s default
containment gate unchanged — a drawer that exists but fails the gate is
reported not-found identically to a genuinely absent id, closing off the
by-id door as a gate-bypass vector. Returns verbatim content plus the full
adjective-axis metadata and a linked-tunnel summary. Tool surface: 19 -> 20
interface tools (Tier 1: 7 -> 8). Both ports at parity; teachme guide
added on both. New tests: `MemoryGetTests.swift` (10 tests, AriaMcpKit);
`memory_get_*` (7 tests) + 1 teachme test in Rust `dispatch_tests.rs`.

### 1.10.0 -- 2026-07-04
the connection-ownership contract §5 (MCP connection ownership, plugin transport, and install-moment
dedupe): `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line when the host has detected a mismatch between an
installed plugin (currently Claude Code's `mootx01@mootx01`) and this
running binary's version. Runtime detection (rather than only at install
time) catches skew regardless of install order — plugin-then-binary or
binary-then-plugin both leave a point-in-time version pinned in
`~/.claude/plugins/installed_plugins.json` that can drift as either side
upgrades independently. Computed once at server startup (Swift
`ServeCommand`; Rust `commands::serve::run`), never per-call, and threaded
through the dispatcher (`ToolDispatcher.versionSkewAdvisory` / Rust
`Dispatcher.version_skew`) exactly like the existing build-serial pattern
(§ 14). Empty/`nil` when no plugin is detected or versions match — the
common case, which leaves the response shape byte-identical to before this
change. Both ports at parity. New tests:
`testVersionSkewAdvisorySurfacesInPingAndStatus`,
`testNoVersionSkewAdvisoryOmitsField` (Swift, AriaMcpKit `ServerTests.swift`);
`version_skew_advisory_surfaces_when_present_and_omitted_when_absent` (Rust,
`dispatch_tests.rs`); `VersionSkewAdvisory` / `version_skew_advisory` unit
tests in `MootInstallerCore` (Swift) and `mootx01-cli::core::mcp_ownership`
(Rust).

### 1.9.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria). Framed as
planned hardening to lock down prompt-injection attack surfaces.

(1) **`moot_erase_memory` gate** — the `confirmed=true` + `reason` requirement is
now enforced at the AriaMcpKit boundary BEFORE calling the substrate. A prompt-injected
agent that receives `confirmed=false` (or omits `confirmed`) cannot trigger irreversible
erasure regardless of any other argument. Tool stays on the surface; gate is the defense.
Both ports updated. Schema unchanged; field was already present.

(2) **Federated-search requester anti-spoof** — `requesterEstateID` in
`moot_federated_search` is now OPTIONAL. When omitted the requester is bound to the
default (authenticated caller) estate. When supplied it must match the default estate's
UUID exactly; a different UUID is refused (anti-spoof gate). This prevents a prompt-injected
agent from spoofing another estate's identity to escalate cross-estate read scope.
`required` array changed from `["requesterEstateID"]` to `[]`. Both ports updated.

(3) **Direct estate routing restricted to default estate** — `estateID` in direct MCP
tool calls (all Tier 1–5 interface tools, recipe tools, vault tools, lens primary estate)
is restricted to the default estate. A present `estateID` that names any registered
non-default estate is refused with `invalidParams`. Callers must use `moot_federated_search`
for grant-authorized cross-estate reads. Lens comparison tools (`moot_lens_overlap`,
`moot_lens_divergence`) are explicitly exempted for their `estateIDB` argument. Both ports
updated.

### 1.8.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `HTTPServer.isOriginAllowed` and `HTTPReadAPI.isOriginAllowed`
now validate the suffix after the loopback scheme+host prefix (must be empty or `:PORT`) instead
of a bare prefix check. A bare prefix check accepted attacker-owned names like `localhost.evil`
or `127.0.0.1.evil` DNS-resolved to loopback (the DNS-rebinding prefix-spoof vector). Both
ports (Swift + Rust) updated in lockstep: AriaMcpKit `HTTPServer`, moot-mgr `HTTPReadAPI`.
Tests added in `HTTPServerTests`, `HTTPReadAPITests`, `http_transport_tests.rs`,
`http_control_tests.rs`.

(2) **`moot_palace_import` vault gate** — `moot_palace_import` is now hidden from `tools/list`
and refused at dispatch when `MOOTX01_VAULT=0` (installed with `--vault-off`). The tool opens
arbitrary SQLite files from the local filesystem; gating it under the vault surface matches the
security posture of vault import/export and mitigates an arbitrary-path-traversal vector
(a caller could pass any filesystem path). Vault-off tool count: 57 → 56. Both ports updated.

### 1.8.0 -- 2026-06-25
Changed (T5 — drain lifecycle): (1) **daemon resume-on-restart** — opening an
estate now EAGER-mounts the corpus's lease-gated drain worker, so a restarted
resident drains a non-empty persisted queue immediately instead of waiting for a
fresh capture. (Swift already eager-mounted via `wireSubstores`; Rust now mounts
in `wire_sqlite_semantic_recall` rather than lazily on first capture — a fixed
Swift/Rust parity gap.) (2) **detached stdio finisher** — a direct-open stdio
`serve`, on exit with encode work still queued, spawns a detached `mootx01 drain`
that takes the T3 lease and drains to empty, so a client SIGKILL on disconnect no
longer abandons the queue. The finisher detaches via `setsid` (unix) /
`DETACHED_PROCESS` (windows) and is gated on the maildir actually having pending
work. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve lease-aware transport): an stdio `serve` now **forwards** to a
live resident that serves the same estate instead of opening a second direct
writer. On start it checks a resident-written estate marker (`mootx01.estate`)
against its own estate and, on match, probes the resident port (`daemon.port`);
if the resident answers it runs the stdin→loopback-HTTP bridge (the `proxy`
path), so all traffic funnels through the one resident writer and the resident's
in-RAM derived state stays coherent. If no resident answers (stale marker) it
opens the estate directly. Detection is a port probe + estate-marker match
(uniform Swift↔Rust, dep-free) — not PID-liveness. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import`'s caller-facing knob is now
`mode` (foreground/background encode SPEED), not `batch`. Contract: the caller
declares SPEED only; the server chooses the WRITE strategy automatically by
source size. Foreground/background select the drain's embed concurrency (all
cores vs ~a quarter) and never change the encoded output — byte-identical either
way. Unknown `mode` is a fail-closed invalid-params error. Both ports conform.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` joins the
behavioral surface. It is a read-only observer of the estate's long-running
background drains (today only `corpus_encode`, the encode/ingest queue): it reads
each drain's pending + in-flight frontiers and reports a draining/idle state plus
optional detail, never claiming or draining. Contract guarantees: (1) read-only —
polling it has no effect on drain progress and is safe from any process; (2)
factual empties — `drains: none` (no drain registered, e.g. a bare estate) is
distinct from a drain listed at `pending: 0, in_flight: 0` (idle); (3) no
session-protocol block, so it is cheap to poll. Both ports conform.

### 1.4.0 -- 2026-06-19
`moot_estate_ping` now surfaces the build serial in its response:
`pong: estate <name> [<uuid>] is live — build <serial>`. § 14 updated with the
full derivation contract: mtime+size fingerprint (`<yyyyMMddHHmmss>/<8-hex>`)
computed once at server construction, `MOOTX01_BUILD_SERIAL` env override
honored verbatim. Both Swift and Rust ports at parity. Tests asserting the
exact `estate_ping` text updated to assert the stable prefix/shape rather than
a specific serial. New unit and dispatch tests added for serial threading and
the env override path.

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-PREF-PRODUCER — Bradley-Terry preference producer, both
ports). Documents the new preference PRODUCER DUTY on the `AutonomicGovernor`, the
sibling of the graph-centrality producer: on a cadence (default 10 min) it reads
the estate's recall-trace reward history (`RecallTraceItem` target+used), shapes it
into per-drawer `(endorsements, dismissals)` curation records (surfaced-and-used →
endorsement, surfaced-and-passed → dismissal), fits per-drawer Bradley-Terry
preference strengths via the NeuronKit `learnedPreference` / `learned_preference`
anchor-reduction fitter (I-17, no math reinvented), and registers a
`PreferenceStore` — taking the `unionBest`/`matrixAware` recall `preference` column
from dark to live on BOTH ports. `GovernorReport` gains `preferenceFired` /
`preference_fired`. The outcome source is the existing recall reward cycle; no new
substrate data was required. Both recall-cache producer boundaries (graph +
preference) are now closed. Swift + Rust at parity; conformance
`PreferenceProducerTests.swift` / `preference_producer_parity.rs`.

### 1.2.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
Documents the new graph-centrality PRODUCER DUTY on the `AutonomicGovernor`: on a
cadence (default 10 min) it reads the estate structure graph (drawers + tunnels +
kg_facts), computes per-drawer eigenvalue centrality via the NeuronKit `keystones`
oracle, and registers a `GraphCache` — taking the `unionBest`/`matrixAware` recall
`graph` column from dark to live on BOTH ports. `GovernorReport` gains
`graphCentralityFired` / `graph_centrality_fired`. Corrects the prior text that
implied the recall-cache producers plug into the standing-signal registration
seam: the producers are governor DUTIES (the scheduler emission model cannot
register a cache, and its synchronous emit closure has no `&mut` coordinator). The
Bradley-Terry preference producer remains a separate future duty. Swift + Rust at
parity; conformance `GraphCentralityProducerTests.swift` /
`graph_centrality_parity.rs`.

### 1.50.0 -- 2026-08-22
PACKAGER mission: `answer` arg on `moot_memory_search` + GLKResultsPackager response shaping.

**New `answer` argument on `moot_memory_search`:**
- Type: string, optional (default `"never"`).
- Valid values: `"never"` / `"always"` / `"auto"`.
- Unknown value → `invalidParams` (fail-closed); never silently coerces to `"never"`.
- `"never"` (default): dense rows only, byte-identical to the pre-packager path.
- `"always"`: compose an answer block (via GroundedSynthesis — Swift only; Rust path
  carries block with empty text) plus rows at minimum L1-full level.
- `"auto"`: server selects level by GLKResultsPackager confidence gate:
  - CONFIDENT → L0AnswerOnly (answer block, no rows).
  - INTERMEDIATE → L1Full (answer block + rows).
  - WEAK → RowsOnly (rows only, gate ran).

**Response levels (non-never modes):**
- L0AnswerOnly: `answer:`, `confidence:`, `citations:`, `signals:` lines prepended to
  `found N memory(s)` header; rows list empty.
- L1Full: same answer block prepended, then dense rows.
- RowsOnly: `found N memory(s)` header then dense rows (same as `answer:never`).

**Score-cliff row cutoff (non-never modes):**
Rows are cliff-cut by `GLKResultsPackager` using `PackagerThresholds` from the
estate's `RecallTuningManifest`. k_min rows are always included; a gap ≥ c × stddev
fires the cutoff; k_max caps the total. Default: k_min=3, k_max=20, c=0.20.

**One-seam guarantee:**
`moot_synthesize` also routes through `GLKResultsPackager` internally (mode=auto,
composed_answer=summary). Its output shape (summary/patterns/recommendations/
keyInsights) is UNCHANGED. The packager result is discarded.

### 1.1.0 -- 2026-06-17
Additive + correction (#8 Track 1 — Brain harness, Rust side). §17.1
standing-signal activation now specifies BOTH ports: the Rust
`AutonomicGovernor` owns and ticks the estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and the resident HTTP bootstrap
registers the §11.2 default signals once at startup — corrects the prior text
that claimed "Rust has no standing-signal scheduler by design", which is no
longer true. Documents WHY the Rust scheduler lives in the governor (dispatcher
reference-cycle avoidance) and that the registration methods are the producer
seam for the graph-centrality / Bradley-Terry tracks. Swift behavior unchanged.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

## Re-homed from develop/1.1.x (2026-08-26)

These entries were minted by the develop/1.1.x stream while this
document was reorganized to 2.x on the benchmark stream. Their version
labels collide with labels this ladder already used for different
changes; they are preserved verbatim as historical text and are not
index entries for this ladder.

### 1.48.0 -- 2026-08-21

Changelog ladder repair (merge of develop/1.1.x, 2026-08-21): the
moot_recall_temporal notes below were previously mis-filed as bullet
lines inside the 1.28.0 entry, self-labeled with version numbers
that the develop stream legitimately minted for unrelated changes.
They are re-homed here verbatim with their original self-labels
preserved as historical text; the labels do NOT refer to entries in
this ladder. No behavioral change in this entry.

- **v1.41.0 (2026-08-20)** — moot_recall_temporal: date-seeking questions with no stated date rank real-dated memories first; narration line `temporal: <mode> date-seeking — …read the answer from each row's event_time`; description carries the steering sentence.
- **v1.40.0 (2026-08-19)** — moot_recall_temporal v2: new `grab` argument (pool default | dated — unions a date-indexed store fetch into the candidate pool); sliding-window widening ±1..±10 days when the stated window holds fewer than limit matches, rows ranked date-proximity-first then text affinity; the temporal: narration line now names the grab arm and any applied widening (±Nd).
- **v1.39.0 (2026-08-19)** — Added moot_recall_temporal (recipe tier): reads the absolute date stated in the query — or an explicit from/to window, which wins — and matches it against drawer event_time; window=loose ranks in-window first keeping everything, window=tight returns in-window only and errors without a window. Dense-row reply plus a temporal: narration line. Tool counts: Swift 79 (14 recipe tools), Rust 75 vault-on / 68 vault-off.

### 1.47.0 -- 2026-08-21
Additive (D10 — walk_recall escalation ladder): `moot_recall_walk` tool exposes
`WalkRecall.run` to the MCP surface. Cheap Stage 1 (ShapedRecall /
`session_hybrid` preset, pool 20) runs first; if the top-gap confidence margin
`(s0 - s1) / max(|s0|, ε) ≥ 0.25` is met, results are returned immediately
(`stoppedEarly=true`). Otherwise Stage 2 (PreciseRecall / `hamming+text`
composition) runs and its results are returned. Empty pool after Stage 1 also
escalates. Arguments: `query` (required string), `limit` (int, default 5,
clamped 1–50), `filter` (string, default "unconfirmed"), `wing` (string,
optional), `now` (ISO8601 string, optional), `estateID` (string, optional).
Response: structured-text dense rows with discrimination line on Low/Medium,
plus `walk:` metadata line with `stage` and `stoppedEarly`. Both Swift and Rust
ports. Registered in `RecipeCatalog` / `catalog.rs` as entry 30. Tool counts:
vault-on 76, vault-off 69. Conformance: `WalkRecallTests.swift` (Swift CK, 7
tests) + Rust in-module tests (5); `RecipeToolsTests.swift` (3 new ARIA tests).

### 1.46.0 -- 2026-08-20
Additive (WIRE 1 — P4 study gap): `moot_memory_search` and `moot_recall_shaped`
gain an optional integer argument `frontier_k`. When present it overrides the
per-call candidate-pool depth in `GLKRecallRequest.frontierK` /
`frontier_k` — the same engine field that `RecallShape` presets can set, but
overridable at call time without changing the preset or shape. The engine clamps
the value to `[RecallShape.frontierKFloor, RecallShape.frontierKCeiling]` ([64,
256]). Absent or null → engine formula `min(max(limit × 4, 64), 256)`,
byte-identical to prior releases. Non-integer value → fail-closed
invalid-params error naming the argument. Both Swift and Rust ports. Swift
dispatch: `ToolDispatch.swift` (`runMemorySearch`) and
`RecipeTools.swift` (`runShapedRecall`) via `optionalInt`; Rust: `interface_tools.rs`
(`run_memory_search`) and `recipe_tools.rs` (`run_shaped_recall_tool`) via
`optional_integer`, threading through updated `shaped_recall.run` /
`CognitionKit::shaped_recall::run`. Schema exposed in `ToolProjection.swift`
/ `tool_list.rs` so the MCP tool list reflects the argument. Conformance:
`FrontierKArgumentTests.swift` (8 tests: schema × 2, absent × 2, integer × 2,
non-integer × 2).

### 1.45.0 -- 2026-08-20

- `moot_json_import` seed schema v1.2 (mission P2a). Each record in the
  `records[]` array may carry an optional `"capture_date"` key (UTC ISO8601,
  REQUIRED trailing `Z`; same two accepted shapes as `event_time`; offset
  forms are rejected for cross-port parity). When present, that record's
  drawer receives the given instant as its `filedAt` ingest clock (the CRDT
  ordering stamp, audit HLC physical time, and the capture-spread benchmark
  seam). Absent records use the batch wall-clock — byte-identical legacy
  behavior. Unknown-key guard error message updated from "schema v1.1" to
  "schema v1.2". Golden pin: `capture_date "2026-01-15T10:00:00Z"` →
  `filedAt = 1 768 471 200 000 ms` (both ports). New tests: 10 Swift
  (`JsonImportBridgeTests`) + 6 Rust (`json_import_bridge.rs`) covering
  parse, pipeline wiring, legacy bracket, and golden pin.

### 1.44.0 -- 2026-08-20
M3: `moot_memory_search` `scoring` parameter gains a fourth valid value `discriminative`. The mode computes RRF fusion and scales the composite score by the dense-lane saturation discount (factor ∈ [0, 1]) with no matrix steer. Decode remains fail-closed — the accepted value list is now `raw`, `rrf`, `matrixAware`, `discriminative`.

### 1.43.0 -- 2026-08-20

- `moot_memory_search` gains optional boolean argument `anomalous_filter`:
  `null`/absent = no filter (passthrough), `true` = surface only drawers
  whose `isAnomalous` bit (bit 26) is set (low-cohesion outliers), `false` =
  exclude anomalous drawers. Decoded in both Swift and Rust `ToolDispatch`;
  maps to `GLKRecallRequest.anomalousFilter` / `anomalous_filter`. Both
  ports decode the argument via `optionalBool` / `optional_bool` helpers
  (same helpers already in use for other optional boolean args). Additive:
  consumers that omit the argument get passthrough behaviour identical to
  prior releases.

### 1.42.0 -- 2026-08-20

- `moot_memory_get` is now a B-10a dereference verb (W1 mission). When it
  successfully returns a drawer body that was previously surfaced by
  `moot_memory_search` in the same session, it calls `noteUsage` /
  `note_usage` → `markRecallUsed` / `mark_recall_used` to flip the
  `used` bit on the corresponding recall-trace rows. The dreaming daemon's
  reward sweep subsequently assigns `reward=1.0` for those rows.
  Applies to the single-id depth:full path AND the batch/shallow-depth path.
  Both ports (Swift and Rust). Conformance-gated by new tests:
  `memoryGetAfterTracedSearchSetsUsedBit` (Swift) and
  `memory_get_after_search_sets_used_bit` (Rust).
- Bug fix (also B-10a): `moot_memory_search` now records ALL surfaced hit ids
  in the session ledger using `hit.id` (always non-optional) rather than
  `hit.drawer?.id` / `hit.drawer.as_ref().map(|d| d.id)`. Previously,
  unhydrated hits (drawer == nil / None) were silently dropped from the ledger,
  making the dereference reward path unreachable for those rows. Both ports.
### 1.49.0 -- 2026-08-26

- **Durable provider preference contract (MACD-3B2, dark Wave 1).** The
  self-report's `digestInput()` gains additive tail entries after the
  MACD-3B1 schema-3 entries: the preference MAC domain constant
  `"MOOTX01-PROVIDER-PREFERENCE-v1"` followed by each of the 7
  `ProviderPreference.macTranscriptFields` names, so a transcript-field rename
  changes the module digest.  `canonicalReport()` gains the corresponding
  `"preferenceDomain"` and `"preferenceTranscriptFields"` JSON keys
  (ordered by `.sortedKeys`).  The
  module digest changes by construction; both shells emit the same new digest.
  No new `ProviderArbiterState` wire encoding — the twelve frozen states are
  sufficient; the preference influences the policy layer above the arbiter
  rather than producing a 13th state.

#### Descriptor schema 3 (MACD-3B1)

- **Descriptor schema 3 (MACD-3B1, dark Wave 1).** `descriptorSchemaVersion`
  advances from 2 to 3. The published record gains 7 new wire keys alongside
  the existing 16 (total 23): `providerReleaseGeneration` (decimal string
  UInt64), `managementRevisionMinimum`, `managementRevisionMaximum`,
  `dataPlaneRevisionMinimum`, `dataPlaneRevisionMaximum`,
  `estateSchemaMinimum`, `estateSchemaMaximum` (all UInt integers).
  These encode the four compatibility axes required for coexistence
  arbitration.  The `descriptorMAC` now covers all 23 fields: the schema-2
  `macInput()` bytes followed by the 7 new scalar fields in fixed frozen
  order.  Schema-2 records decode as nil (exact-set check against 23-key
  `fieldNames` fails) — fail-closed behaviour.  App-side
  `DaemonContract.schemaVersion` remains 2 (dark); Wave 2 will flip it.
  The `ProviderVersionVector` companion type also carries
  `migrationTargetSchema` (optional) and `capabilityRevisions` ([String:UInt64])
  for the Wave 2 MAC extension and evaluator, but these are not Wave 1 wire
  fields.  `CanonicalEncoder.appendSortedMap` added for the Wave 2 MAC
  encoding of `capabilityRevisions`.
### 1.41.0 -- 2026-08-17

- **Descriptor v2 FILE format (MACD-2c2).** The published first-party
  descriptor is a single canonical JSON object at
  `<App Group container>/Library/Application Support/MOOTx01/daemon-descriptor.v2.json`
  (beside — not inside — the provider directory; its readers are clients).
  Exactly sixteen keys: `schemaVersion`, `providerIdentifier`,
  `serviceIdentifier`, `endpoint`, `authProtocol`, `authKeyIdentifier`,
  `publishedAt`, `instanceIdentifier`, `estateIdentifier`, `binaryVersion`,
  `contractRevision`, `mcpProtocolVersion`, `capabilities`,
  `credentialGeneration`, `descriptorGeneration`, `descriptorMAC`. Sorted
  keys; UUIDs canonical-string; generations DECIMAL STRINGS; `descriptorMAC`
  base64url without padding; capabilities sorted. A reader refuses any record
  with a different key set, non-canonical spellings, or >64 KiB.

- **Attended migration grant (MACD-2c2), first-party lane.** Cross-process
  contract for converging a legacy default estate onto the canonical App
  Group estate. The provider (holding the exclusive provider lock, census
  showing exactly one otherwise-valid candidate) writes a CHALLENGE file
  `migration-challenge.v1.json` beside the descriptor: exactly nine keys —
  `challengeIdentifier`, `providerInstance`, `candidateClass`, `nonce`
  (base64url, 32 bytes), `issuedAt`, `expiresAt`, `credentialGeneration`,
  `providerGeneration`, `descriptorGeneration` (decimal strings). The signed
  first-party app answers with a GRANT ENVELOPE `migration-grant.v1.json`
  (the ONE place opaque bookmark bytes exist): exactly thirteen keys —
  `grantIdentifier`, `providerInstance`, `candidateClass`,
  `challengeIdentifier`, the three generations copied from the challenge,
  `issuedAt`, `expiresAt`, `bookmarkDigest`, `bookmark` (both base64url),
  `escrowMarker` (`none`|`escrowed`), `grantMAC`. Envelope cap 16384 bytes,
  judged before parsing.

- **Grant MAC domains.** `K_grant = HKDF-SHA256(K_install,
  salt = SHA-256(challenge transcript), info = "MOOTX01-MIGRATION-GRANT-v1")`;
  the challenge transcript is CanonicalEncoder length-prefixed under
  `"MOOTX01-MIGRATION-CHALLENGE-v1"` over all nine fields, so an envelope
  verifies only against the exact outstanding challenge and the exact
  generations it named. The MAC input covers every envelope field except the
  raw bookmark bytes, which participate via `bookmarkDigest`. Bookmarks are
  created with `bookmarkData(options: [])` exactly — no security scope.
  Possession of K_install (read via the READ-ONLY data-protection Keychain
  root provider) is the provenance proof; a nonce never authenticates.
  Consumption is one-use, journal-first (durable record fsynced before the
  bookmark resolves), refusing replay, expiry, wrong
  instance/candidate/challenge, and any non-current credential generation.
  The migration receipt domain is `"MOOTX01-MIGRATION-RECEIPT-v1"`.

- **Census dispositions and migration steps in the self-report.** The
  provider module digest gains an additive tail: the grant and receipt
  domains, the five census disposition encodings (`none-found`, `one-valid`,
  `already-converged`, `byte-identical-duplicates`,
  `multiple-estates-hard-stop`), and the thirteen migration step encodings
  (`migration-census` … `migration-recovery-required`, with
  `awaiting-migration-grant` carrying the mission name). The TWELVE arbiter
  wire encodings are unchanged and remain frozen; migration state is a
  separate vocabulary, never an arbiter state.

- **First-party lane posture unchanged.** The authenticated first-party lane
  remains dark: no shipping GUI consumes the transport, and no production
  build opens the canonical estate through it. The daemon provider bundle
  registers DISABLED; its `resident` mode refuses honestly (exit 4) until
  estate routing lands (MACD-3).

### 1.40.0 -- 2026-08-16

Corrections to 1.39.0, from independent review. Each fixes a statement the
implementation did not honour.

- **`serverInfo` generations are DECIMAL STRINGS.**
  `descriptorGeneration` and `credentialGeneration` are `UInt64`; a JSON
  number cannot carry that range (the encoder's integer is `Int64`, and
  double-typed numbers lose exactness above 2^53). A decimal string is
  exact for every value and cannot trap.

- **The identity reported on the first-party lane is derived from the
  live authenticator**, never configured alongside it. Two independent
  settings that had to agree could disagree — and did, in both
  directions: an unauthenticated `initialize` advertising the capability
  and publishing daemon identifiers, or an authenticated one omitting
  them. It also tracks descriptor republication, so a stale generation
  cannot be advertised after the descriptor moves.

- **The public lane's grammar is frozen and independent of the
  first-party lane.** Public requests are parsed with the legacy
  loopback grammar whether or not the authenticated lane is configured;
  the strict grammar applies only under `/mcp/first-party`, and the
  routing decision is taken from the legacy parse so lane selection never
  depends on strictness.

- **`Content-Type` is compared for EXACT equality**, after trimming and
  lowercasing, on the request lane and both handshake steps. A prefix
  comparison accepted `application/json-evil` and parameterized forms
  the specification already forbade.

- **Both peers apply the same strict JSON object shape** to handshake
  payloads before authentication: exact key set, no unknown keys, no
  duplicate keys, and a hard size cap. Duplicate keys matter because
  permissive parsers silently keep the last occurrence, so two
  implementations can disagree about a value while both believing they
  parsed the same document.

- **Handshake bodies are size-capped at 8 KiB, enforced at the read.**
  Previously the client buffered whatever a peer sent before any proof or
  parsing, which an unauthenticated port squatter could exploit.

- **Every integer conversion on the untrusted path is total.** Descriptor
  version fields are signed on the decoded record and unsigned on the
  wire, and canonicalization runs before the MAC verifies; a negative
  value previously trapped. Such descriptors now have no canonical
  encoding and are refused.

### 1.39.0 -- 2026-08-16

- **Authenticated first-party wire (MACD-2b), dark.** Adds a second HTTP
  lane on the resident server at the exact endpoint
  `http://127.0.0.1:4242/mcp/first-party`, alongside the existing
  third-party lane, whose behaviour is unchanged. The lane is
  UNAVAILABLE unless a first-party authenticator is explicitly
  configured; no shipping build configures one. MACD-2c supplies the
  signed provider, the provider lock, and descriptor publication;
  MACD-3 performs production routing.

- **Descriptor schema 2, contract revision 2.** The descriptor gains
  `authProtocol` (`hmac-sha256-hkdf-v1`), `authKeyIdentifier`
  (`installation-root-v1`), `publishedAt`, `credentialGeneration`,
  `descriptorGeneration`, and `descriptorMAC`. It still carries no
  estate path, estate key, authentication root, session key, nonce,
  bearer token, install path, or PID. Schema 1 records are refused
  rather than upgraded: a schema-1 descriptor carries no MAC, so
  nothing can verify it.

- **Canonical bytes.** All MAC and digest inputs use a fixed-order,
  length-prefixed binary encoding: UTF-8 strings preceded by a UInt32
  big-endian byte length, UInt64/UInt32/UInt16 big-endian, UUIDs as
  their 16 RFC 4122 bytes, byte arrays length-prefixed, capability
  sets sorted by wire spelling then counted. Delimiter concatenation,
  JSON key order, locale-dependent formatting, and platform-native
  integer encoding are all prohibited — `"a" || "bc"` and
  `"ab" || "c"` concatenate identically, so a MAC over a delimited
  concatenation authenticates neither field.

- **Derivation ladder.** `K_install` is 32 random bytes in the macOS
  data-protection Keychain (service
  `com.codedaptive.mootx01.daemon-auth`, account
  `installation-root-v1`, `kSecUseDataProtectionKeychain` true,
  non-synchronizable, fully expanded access group). It is never used
  directly as a request key. Three derivations, each with a distinct
  HKDF-SHA256 `info` domain:
  `K_descriptor` (salt = 32 zero octets, the RFC 5869 omitted-salt
  value), `K_auth` (salt = descriptor digest), and `K_session`
  (salt = SHA-256 of the session transcript).

- **Mutual handshake.** `POST /mcp/first-party/session/challenge` and
  `POST /mcp/first-party/session/establish`. A 19-field canonical
  transcript binds the descriptor digest, both identities, the exact
  endpoint, both generations, both nonces, the session identifier,
  and all three timestamps. Server and client proofs use distinct
  domains so a reflected server proof cannot satisfy the client
  check; the establishment proof is taken under `K_session`.

- **Request and response authentication.** Every request carries
  `Authorization: Mootx01Session <base64url>`, `Mootx01-Sequence`
  (canonical unsigned decimal, no leading zero, never 0), and
  `Mootx01-Request-MAC`. The request MAC covers the protocol domain,
  session identifier, sequence, uppercase method, exact path, exact
  content type, and SHA-256 of the exact body — not the body alone.
  Every response carries `Mootx01-Response-MAC` over the domain,
  session identifier, request sequence, HTTP status, content type,
  and SHA-256 of the body, including the empty 204 a notification
  receives.

- **Bounded state.** At most 128 outstanding challenges (single-use,
  30-second lifetime) and 64 live sessions (15-minute idle, 8-hour
  absolute). Expired entries are removed before capacity is judged,
  and at capacity the server refuses rather than evicting a live
  entry. Replay protection is a highest-seen sequence plus a 128-bit
  bitmap, so genuine out-of-order arrivals are admitted while
  duplicates and too-old sequences are refused. Replay state is
  committed only after the request MAC verifies.

- **Fail-closed compatibility.** Schema, auth protocol, contract
  revision, and MCP version must match exactly and are never
  negotiated down. The daemon binary version must lie in
  `[1.0.0, 2.0.0)` and must equal the authenticated
  `serverInfo.version`; below the range yields Update Daemon, at or
  above yields Update App. Descriptor and credential generations are
  monotonic.

- **Truthful capability.** `authenticated-first-party` is advertised,
  and the extra `serverInfo` fields (`instanceIdentifier`,
  `estateIdentifier`, `descriptorGeneration`, `credentialGeneration`,
  `contractRevision`, `mcpProtocolVersion`) emitted, ONLY when a
  validated root, an active descriptor, a bounded session store, and
  the request/response MAC middleware are all present. With the lane
  unconfigured the whole subtree 404s and `initialize` is
  byte-identical to before this revision.

- **Golden vectors.** `docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json`
  is the language-neutral source of truth, verified independently by
  the Swift and Rust test suites. The Rust port implements the
  verifier only; per the parity boundary it must not advertise or
  partially implement the runtime protocol.

### 1.38.0 -- 2026-08-15

- `moot_timing_report` gains a call-level collection bound (AT-01):
  at most 262,144 audit events per call, clamp-not-reject, with the
  clamp reported in the result text and the `watermark_ms` paging
  contract continuing the scan. Removes a caller-triggerable resource
  exhaustion (any connected client could force the entire audit log
  into daemon memory with `since_ms: 0`). Both ports; the Rust port's
  paging cursor is now seeded from `since_ms` like Swift's.
- Hint injection contract sharpened (AT-01): hints append to the FIRST
  content block's text and never drop trailing blocks, so multi-block
  results (`moot_json_import` with `return_id_map`) survive coaching
  and unrecognized-argument hints intact. This was already the Rust
  behavior; Swift previously collapsed to a single block.

### 1.37.3 -- 2026-08-14

- §12 tier decomposition now reconciles to the stated totals: Tier 7 is
  9 (recipe is thirteen tools, not twelve — `moot_recall_connected` was
  missing from the §2 enumeration and from the remaining-recipe count),
  and the four non-tier FAB5-I2 packet tools are named with an explicit
  reconciliation line (74 + 4 packet = 78). Found by Bob's audit: the
  corrected Tier-5 line still summed to 73 against a stated 78.

### 1.37.2 -- 2026-08-14

- §12 Tier 5 breakdown corrected: "(7 always + 1 vault-gated)" →
  "(8 always + 2 vault-gated)" — `moot_timing_report` (+1 always) and
  `moot_json_import` (+1 vault-gated) had landed since the text was
  set. Found by the pinned-model Adams re-run of rounds 3–4.

### 1.37.1 -- 2026-08-13

- Tool-count corrections: the total-surface figures had drifted across
  several tool additions (packet tools, `moot_json_import`,
  `moot_recall_connected`, `moot_timing_report`). Current truth: 78 tools
  vault-on / 71 vault-off on the Swift surface; the teachme live counts
  match.

### 1.37.0 -- 2026-08-13

- New maintenance tool `moot_timing_report` (C3+A6, benchmark reset):
  derives INGEST and CYCLE timing metrics from the estate's audit markers
  via NeuronKit's single derivation engine — the same derivation the
  performance-health duty will consume (§6b one-derivation-two-consumers).
  Read-only and stateless server-side: the caller keeps the returned
  `watermark_ms` and passes it back as `since_ms` for incremental scans.
  Rows with no subsequent retrain or dream are reported as unbounded
  counts, never dropped. Both ports; no orientation block (pollable, like
  `moot_drain_status`).

### 1.36.0 -- 2026-08-11

- Bridge input limits (pc stream, security findings 012/036). §5 gains the bridge input limits subsection documenting the two admission caps enforced by both ports: 4 MB per frame (oversized frames dropped with a stderr diagnostic, no synthesized error) and 16 frames in flight maximum (17th frame waits, never dropped). Both limits are byte-identical across the Swift `ProxyCommand` and Rust `proxy.rs` implementations.

### 1.35.0 -- 2026-08-11

- Bridge failure-response invariant (px stream). §5 gains the stdio→HTTP bridge subsection documenting the proxy adapter, the per-frame id-echoing error contract, the four conditions that trigger a synthesized error frame, and the stateless-per-frame session model. Root cause documented: `id: null` synthesized errors caused "Server disconnected" failures in Claude Desktop (MCP client schema-rejects `id: null` at parse time, poisoning the whole stream). Fix: all failure paths on id-bearing frames now echo the original request id via a -32603 synthesized error; notifications and `id: null` frames produce no reply per spec.

### 1.34.0 -- 2026-08-07

- Tiered contradiction surface (MXE-CT3 P3). `moot_hunt_contradictions`
  gains optional `tier` (1|2|3|"all", default "all") and `top_k`
  (1...50, default 5): default mode appends a tiered synthesis digest
  after the unchanged legacy report; a single tier is a read-only
  purpose search. `moot_review_tunnel` gains `reviewed_by` (default
  "user") and the `endorse` verdict — the review ladder: accept is
  user-only, a model reject is an objection (withdraw or contest),
  endorse records a vote without activating. `moot_dream` files
  tier-labeled conflict-tunnel candidates (`proposeConflictTunnels`)
  after its hunt phase and appends the tiered digest via the shared
  renderer.

### 1.33.0 -- 2026-08-06

- New recipe tool `moot_recall_connected`: multi-hop retrieval by graph
  diffusion — a scored anchor search seeds a deterministic
  walk-with-restart over tunnels (validated) ∪ dream-produced pending
  associations (Bob's 2026-08-06 ruling: pending edges are walkable,
  ~2–3% less confident; the discount is recorded, not applied — below
  Monte Carlo visit-count resolution). RRF fusion with the anchor
  ranking; memory_search output shape + a `connected:` lane-provenance
  line. The EXPENSIVE recall path; escalation is caller-side. Tool
  totals: 76 vault-on / 70 vault-off (Swift), 72 / 66 (Rust surface).

### 1.32.0 -- 2026-08-06

- `moot_synthesize` grounding contract extended to HYBRID pool
  acquisition: the raw query drives a scored BM25+vector lane beside the
  lexical term lane; ranking-rule paragraph updated (fusion only while
  the scored lane bears scoring evidence; lexical-dominant otherwise;
  zero-term-match rows never outrank term matches).

### 1.31.0 -- 2026-08-06
Cue-ranking grounding contract extension for `moot_synthesize`:

- When `query` is present, the recall frame is widened to
  `max(limit, groundedSynthesisCuePoolBound=200)` so the full matched pool
  is available for ranking. The user's `limit` is applied as a post-rank cap so
  only the top-N cue-ranked drawers feed synthesis.
- The dispatch layer extracts `cueTerms` from the grounding terms and passes
  them through to `GroundedSynthesis.Input` so the HybridRecallEngine's
  cue-term lane can rank the pool before the cap is applied.
- Empty `cueTerms` (no query) preserves previous output exactly — no change
  to the whole-estate digest path.

### 1.30.0 -- 2026-08-06

- `moot_synthesize` grounding contract: optional `query` scopes the
  recalled pool via deterministic grounding-term extraction (port-identical
  pure function) into OR'd case-insensitive content predicates, AND-composed
  with `filter`; the response names the cue; all-stopword queries are
  invalidParams. Query omitted = whole-estate digest, unchanged.

### 1.29.0 -- 2026-08-05

- moot_dream gains the association sweep (step 3.5): `associates`
  argument `all` (full-estate coverage, for post-import runs) /
  `recent` (default, the standing-signal window) / `off`. Report line
  appends `associationsWritten: N (probed: P, deduplicated: D)` —
  additive and zero-gated (silent when nothing was probed or written).
  Dreaming now triggers every cognition layer: matrix, proposals,
  contradiction hunt, associations, subject backfill.

### 1.28.0 -- 2026-08-04

- **Structured recall results (MXE-SS).** New § 11 subsection: the recall
  family (`moot_memory_search`, `moot_memory_get`, `moot_recall_shaped`,
  `moot_recall_precise`) declares an `outputSchema` and returns
  `structuredContent` (`results[]` of `id`/`room`/`content`/`subject`)
  alongside a byte-identical text block, with redaction parity as an
  invariant: no structured field ever carries what the text withheld.
  Both ports, one shared schema. No consumer changed (that is MXE-DF).


### 1.27.0 -- 2026-08-04

- **Partial-erase honesty (MXE-FA).** New § documenting the
  `moot_erase_memory` response contract: full erasure keeps
  `erased memory <id>` byte-identical; a lineage expunge the audit gate
  refused for accepted siblings responds
  `partially erased memory <id>: <N> accepted lineage sibling(s) refused
  erasure and remain readable: <ids>` (`isError: false`). No response ever
  claims a plain success for an expunge that refused a sibling. Both ports;
  teachme guides document both shapes.

### 1.26.0 -- 2026-08-03
Every drawer-derived aggregate in the `moot_estate_status` response now reads
the sensitivity-filtered set. `subjects: N/M (K missing)` and
`memories: N active (M total)` previously counted the raw cluster-A and
non-tombstoned sets, so an ungranted caller learned how many live rows were
hidden from it and how many of those carried content and a subject — on a
surface whose neighbouring `wings:` line was already filtered for exactly that
reason, and whose sibling `moot_memory_list filter:missing_subject` enumerator
already filtered before listing. The counter and that enumerator now describe
one population. On an estate holding restricted/secret rows these numbers drop;
that is the correction, not a regression. No sensitivity-grant plumbing is
added — `moot_estate_status` has none, and a grant-lifted true count remains a
feature request. Non-drawer aggregates on the same surface (`kg facts:`,
`trace_rows:`, `sync:`, `fdc_recalculation*`, `shared_content_migration:`) are
unchanged: they count no drawer set. Both ports, with the ceiling rule stated
in-code so aggregates added later inherit it.

### 1.25.0 -- 2026-08-03
The sensitivity advisory on `moot_memory_search` and `moot_memory_get` is now
emitted on grant state alone. Its previous second condition — an estate-contents
check for `restricted`/`secret` rows — made advisory presence an estate-wide
existence oracle for those rows, readable by a caller with no grant, and the
check itself defeated the sensitivity ceiling to run (an explicit sensitivity
filter suppresses `BitmapEvaluator`'s `sensitivityAtMost(elevated)` default).
The probe is deleted in both ports rather than narrowed, which also removes its
untraced `origin: internal` recall. Both advisory strings are reworded so they
are true regardless of estate contents and no longer assert that results are
being hidden; search and get keep distinct phrasings and each is byte-identical
across ports. Advisory absence under a live grant is unchanged. Adds the
contents-independence invariant above and its two-estate conformance test in
both ports.

### 1.24.0 -- 2026-08-03

- Typed conflict projection (DCP M4). moot_hunt_contradictions,
  moot_dream, and moot_lens_contradiction APPEND one shared additive
  section: `proven:`, `historical:`, `compatible:`, `candidates:`
  (lexical lane, hunt/dream only), `unknown_or_invalid:`,
  `coverage: projected/scanned`, `truncated_buckets:` (deviation-only).
  Per-proven block: result id, rule@version, coordinate, value digests,
  temporal bases, reason codes, and the two source ids as dense rows.
  Redaction ceiling = MAX endpoint sensitivity: restricted collapses to
  a coordinate-digest line, secret is counted with no block. Every
  existing line is unchanged; the lens's legacy grouped-objects view
  remains decodable. Retrieval proposes; typed constraints prove.

### 1.23.0 -- 2026-08-02

- Lens evidence addresses (PR-05): lens findings that name memories cite
  them as dense rows via the shared renderer (7 memory-listing arms,
  golden-tested byte-identical both ports); concepts extent ids capped
  at 20, association exemplar ids capped at 5 — every lens claim is
  hydratable via moot_memory_get.

### 1.22.0 -- 2026-08-02

- Utility tier (progressive recall PR-04). moot_estate_status gains the
  subject-debt counter line `subjects: N/M (K missing)` (presence debt
  over the live cluster-A non-empty-content set) with a STANDING
  BEHAVIOR contract in its teachme: when K > 0 the AI offers a
  consent-gated interactive backfill (missing_subject walk →
  setSubject), never a silent one. moot_drain_status reserves the
  `subject_backfill` lane name (constants both ports; the PR-09/10
  rider registers the live lane, and the benchmarker's non-gating
  denylist must gain the name in that same mission). moot_list_lenses
  and moot_list_recipes default to a terse catalogue (name +
  first-sentence one-liner) with the full catalogue behind
  `verbose: true`.

### 1.21.0 -- 2026-08-02

- Recall surface (progressive recall PR-03). The DEFAULT reply row for
  every recall-family hit and citation is the DENSE ROW:
  `uuid · subject · fdc:<code> · qid:<QID> · <event_time ISO8601>` —
  adopted by moot_memory_search, moot_recall_precise, moot_recall_shaped,
  moot_recall_vague (hits and originals), moot_recall_distilled (row then
  distilled text), moot_federated_search, moot_memory_list, and
  moot_connection_search/map citations. Absence markers are uniform and
  fixed ("(no subject)", "-"); redaction markers replace the subject on
  provenance restricted/secret rows. Narration is DEVIATION-ONLY: the
  "found N memory(s)" header stays (fail-loud harness contract); the
  [distilled] tag and per-hit tokens:/source: metadata lines are removed
  ("source: content (not yet distilled)" appears on fallback hits ONLY);
  the discrimination line appears only at effective low/medium; the
  recall_provenance line appears only when the dense lane is dark or
  stages degraded — absence means nominal.
- Anchor pivot: moot_memory_search and moot_recall_shaped accept
  `near:<uuid>` as an alternative to `query:` (exactly one required,
  runtime-enforced) — the anchor's content re-queries the same scored
  pipeline, the anchor is excluded from its own neighbors, and a gated
  anchor reads as not-found (oracle-free, no grant lift).
- Hydration depth: moot_memory_get gains `ids:[...]` batch and
  `depth: subject|distilled|full` (default full — the single-id full
  record keeps its original shape, now with a `subject:` line when
  present). Batch gate failures render as per-row "not found:" lines.
- BitmapOnly hydration now strips the distilled quad and subject trio in
  BOTH ports (the Rust leg previously cleared only `content` — a
  pre-existing parity divergence surfaced by the dense row on federated
  bitmapOnly reads).

### 1.20.0 -- 2026-08-02

- Subject surface (progressive recall PR-02): `moot_file_memory` now REQUIRES
  a `subject` argument (one sentence ≤120 chars, AI-facing register —
  returned in recall rows, never searched; LocusKit SPEC § 14).
  `moot_update_memory` gains `mutation=setSubject` with a dedicated `subject`
  argument (the backfill/correction path). `moot_memory_list` gains
  `filter=missing_subject` (id-only subject-debt enumerator). Intake verbs
  (palace_import, vault_import, file_dataset, file_packet) deliberately file
  NULL subjects — absence flows to the debt counter. The consolidation
  vague-tier writer emits its own deterministic subject at creation
  (pipeline `consolidation-v1`). Session protocol line updated.

### 1.19.0 -- 2026-07-20

- Aligned the ARIA projection with GLK 1.1 shared content: writes store one
  canonical Drawer, CorpusKit indexes that Drawer ID, and every recall lens
  returns the same object identity.
- Made standalone Corpus passage/chunk compatibility explicitly unreachable
  from MOOTx01.

### 1.18.0 -- 2026-07-16
Upstream-release advisory: `moot_estate_ping` / `moot_estate_status` gain an
opt-in `update_available:` line when a newer product release exists on the
release feed than the running binary. Sibling of the 1.10.0 `version_skew:`
line (that one reports local plugin/binary skew; this one reports "the world
has moved past this install"), and deliberately confined to the same two
session-orientation tools so MCP clients are informed once at orientation
time, never nagged per call. Unlike `version_skew` the value is NOT computed
at startup: the resident daemon outlives releases, so the host injects a
PROVIDER (Swift `ToolDispatcher.updateAdvisoryProvider` closure; Rust
`Dispatcher.update_advisory` via `with_update_advisory`) that the two tools
evaluate lazily behind a host-owned 24h-TTL cache (Swift
`MootInstallerCore.UpdateAdvisor`; Rust `mootx01-cli::core::update_advisor`).
Probe bounded (4s) and failure-cached; resident daemons only (stdio
one-shots and aria-mcp dev never probe); disabled by
`MOOTX01_NO_UPDATE_CHECK` — the same kill switch as the Claude Code plugin's
SessionStart update hook. Line text: ``v<latest> is available (installed
<current>) — upgrade with `mootx01 upgrade` ``. Both ports at parity. New
tests: `testUpdateAdvisorySurfacesInPingAndStatus`,
`testNilUpdateAdvisoryOmitsField` (Swift `ServerTests.swift`);
`update_advisory_surfaces_when_wired_and_omitted_when_none` (Rust
`dispatch_tests.rs`); `UpdateAdvisorTests` (Swift, 8) and
`core::update_advisor::tests` (Rust, 6) unit-test the TTL/kill-switch cache.

### 1.17.0 -- 2026-07-16
Rust leg Anthropic memory_20250818 adapter parity (M-MEMTOOL-1): the `memory` tool
is now at full parity in both ports. `memory_adapter.rs` implements all six commands
(view, create, str_replace, insert, delete, rename), the `MOOTX01_MEMORY_TOOL=1`
opt-in gate (off by default — 71/65 baseline unchanged), the Normal-tier sensitivity
gate (Restricted/Secret drawers not visible), and sensitivity-tier carry-forward on
edit/rename so elevated drawers are not silently downgraded. Wire contract is
byte-identical to the Swift `MemoryToolAdapter.swift` adapter per the no-FFI law.

### 1.16.0 -- 2026-07-16
§12 teachme guide: corrects stale tier tallies (Tier 1: 7→9, Tier 2: 3→4,
Tier 6: 18→27, Tier 8: 4→5, Total: 56→71/65) and expands from nine to ten
tiers (adds Tier 8 Dataset, Tier 7 Extended Cognition, renumbers Vault→Tier 9
and Federation→Tier 10). The guide is now a computed var deriving all counts
from ToolProjection.tools() at call time — it can never silently drift from
the shipped surface. Adds moot_memory_list to Tier 1 listing and its teachme
guide. Adds moot_review_tunnel to Tier 2 listing. Adds moot_vault_job to the
vault generic guide. New test (sp-3b) pins that the guide's count matches the
live registry.

### 1.15.0 -- 2026-07-16
Dataset tools (MX-TAB-7, §11): corrects the stale "44 tools / 19 interface /
16 lens / 4 vault / 4 recipe" figures throughout §11 to reflect the current
shipped surface (71 vault-on / 65 vault-off; 22 five-tier interface tools;
23 lens tools; 5 vault tools; 12 recipe tools; 3 new dataset tools
`moot_file_dataset`, `moot_dataset_query`, `moot_dataset_stats`). Updates
§12 moot_list_lenses cognition-menu count from 18 to 27 (23 lens + 4 recipe
tier-6 tools). Corrects the guide's stated total from the wrong "44 tools"
(written when the guide code said 44; the code now says "56 tools") to "56
tools", pointing to ARIA_MCP_INTERFACE.md §2 as the authoritative live count.

### 1.14.0 -- 2026-07-12
Contradiction hunter surface (§11): `moot_hunt_contradictions` (recipe,
on-demand bounded content sweep), `moot_review_tunnel` (Tier 2 review verb
over `Estate.respondToTunnel`), `moot_link_memories` optional
`proposed: bool`, `moot_dream` third phase (hunt sweep + contradiction
counts), `moot_lens_contradiction` lifecycle tiers (proposed shown by
default, flagged). Total tool count: 68 (was 66). Permission tier `ask`
for both new tools. Both Swift and Rust ports at parity.

### 1.13.0 -- 2026-07-05
the sensitivity-grant contract wave 8.2: adds `moot_monitoring_status` to the interface-tool surface.
Reifies the ARIA `read` verb on the monitoring object (estate-scoped, daemon
daemon-global flag). Args: absent `enabled` → read current state; present
`enabled: bool` → write flag + echo new state with `monitoring_source: user`.
When no telemetry store is wired (stdio, test harnesses, provision-less
contexts), reports `monitoring: unavailable` — never fabricates enabled/disabled.
Permission tier: `ask` in both `mcp__mootx01__` and `mcp__plugin_mootx01_mootx01__`
namespaces. Total tool count: 64 (was 63). Both Swift and Rust ports at parity.

### 1.12.0 -- 2026-07-05
the sensitivity-grant contract: sensitivity unlock/lock control endpoints (§19). Adds
`POST /api/control/unlock` and `POST /api/control/lock` — loopback-only
endpoints for out-of-band sensitivity-tier grants and revocations. Grant
TTLs: restricted → next local midnight; secret → 30 minutes. Proof
freshness gate ±10s. Platform identity: macOS/Swift via LocalAuthentication;
Linux/Windows/Rust via PBKDF2-HMAC-SHA256 (260,000 iterations) against
the `sensitivity_hashes.json` sidecar. CLI surface: `mootx01 unlock
private|secret` and `mootx01 lock`. Both ports at parity. Also adds
redaction advisory (`sensitivity_advisory:` trailing line) to
`moot_memory_search` and `moot_memory_get` when no grant is active and
the estate has restricted/secret rows.

### 1.11.0 -- 2026-07-04
Added `moot_memory_get` (§11) — fetch-drawer-by-ID, build-now per Bob's
ruling on the parking-lot gap ("no verb to fetch a full drawer by UUID on
the MCP surface — recollect covers distilled factoids only"). Reifies the
`recall` verb, named as a `moot_memory_search` sibling per the lexicon's
`<noun>_<verb>` query-tool naming discipline. Routes through the existing
frame-faithful by-id load (`Estate.getDrawers(ids:matchingFrame:
hydrationLevel:)` / Rust `Estate::get_drawers_matching_frame`) with an
empty filter chain, so it inherits `moot_memory_search`'s default
containment gate unchanged — a drawer that exists but fails the gate is
reported not-found identically to a genuinely absent id, closing off the
by-id door as a gate-bypass vector. Returns verbatim content plus the full
adjective-axis metadata and a linked-tunnel summary. Tool surface: 19 -> 20
interface tools (Tier 1: 7 -> 8). Both ports at parity; teachme guide
added on both. New tests: `MemoryGetTests.swift` (10 tests, AriaMcpKit);
`memory_get_*` (7 tests) + 1 teachme test in Rust `dispatch_tests.rs`.

### 1.10.0 -- 2026-07-04
the connection-ownership contract §5 (MCP connection ownership, plugin transport, and install-moment
dedupe): `moot_estate_ping` / `moot_estate_status` gain an opt-in
`version_skew:` line when the host has detected a mismatch between an
installed plugin (currently Claude Code's `mootx01@mootx01`) and this
running binary's version. Runtime detection (rather than only at install
time) catches skew regardless of install order — plugin-then-binary or
binary-then-plugin both leave a point-in-time version pinned in
`~/.claude/plugins/installed_plugins.json` that can drift as either side
upgrades independently. Computed once at server startup (Swift
`ServeCommand`; Rust `commands::serve::run`), never per-call, and threaded
through the dispatcher (`ToolDispatcher.versionSkewAdvisory` / Rust
`Dispatcher.version_skew`) exactly like the existing build-serial pattern
(§ 14). Empty/`nil` when no plugin is detected or versions match — the
common case, which leaves the response shape byte-identical to before this
change. Both ports at parity. New tests:
`testVersionSkewAdvisorySurfacesInPingAndStatus`,
`testNoVersionSkewAdvisoryOmitsField` (Swift, AriaMcpKit `ServerTests.swift`);
`version_skew_advisory_surfaces_when_present_and_omitted_when_absent` (Rust,
`dispatch_tests.rs`); `VersionSkewAdvisory` / `version_skew_advisory` unit
tests in `MootInstallerCore` (Swift) and `mootx01-cli::core::mcp_ownership`
(Rust).

### 1.9.0 -- 2026-06-28
Security hardening — three ARIA tool gate changes (secfix/batch2-aria). Framed as
planned hardening to lock down prompt-injection attack surfaces.

(1) **`moot_erase_memory` gate** — the `confirmed=true` + `reason` requirement is
now enforced at the AriaMcpKit boundary BEFORE calling the substrate. A prompt-injected
agent that receives `confirmed=false` (or omits `confirmed`) cannot trigger irreversible
erasure regardless of any other argument. Tool stays on the surface; gate is the defense.
Both ports updated. Schema unchanged; field was already present.

(2) **Federated-search requester anti-spoof** — `requesterEstateID` in
`moot_federated_search` is now OPTIONAL. When omitted the requester is bound to the
default (authenticated caller) estate. When supplied it must match the default estate's
UUID exactly; a different UUID is refused (anti-spoof gate). This prevents a prompt-injected
agent from spoofing another estate's identity to escalate cross-estate read scope.
`required` array changed from `["requesterEstateID"]` to `[]`. Both ports updated.

(3) **Direct estate routing restricted to default estate** — `estateID` in direct MCP
tool calls (all Tier 1–5 interface tools, recipe tools, vault tools, lens primary estate)
is restricted to the default estate. A present `estateID` that names any registered
non-default estate is refused with `invalidParams`. Callers must use `moot_federated_search`
for grant-authorized cross-estate reads. Lens comparison tools (`moot_lens_overlap`,
`moot_lens_divergence`) are explicitly exempted for their `estateIDB` argument. Both ports
updated.

### 1.8.1 -- 2026-06-28
Security (HTTP transport — both ports, both surfaces):

(1) **Origin-check hardening** — `HTTPServer.isOriginAllowed` and `HTTPReadAPI.isOriginAllowed`
now validate the suffix after the loopback scheme+host prefix (must be empty or `:PORT`) instead
of a bare prefix check. A bare prefix check accepted attacker-owned names like `localhost.evil`
or `127.0.0.1.evil` DNS-resolved to loopback (the DNS-rebinding prefix-spoof vector). Both
ports (Swift + Rust) updated in lockstep: AriaMcpKit `HTTPServer`, moot-mgr `HTTPReadAPI`.
Tests added in `HTTPServerTests`, `HTTPReadAPITests`, `http_transport_tests.rs`,
`http_control_tests.rs`.

(2) **`moot_palace_import` vault gate** — `moot_palace_import` is now hidden from `tools/list`
and refused at dispatch when `MOOTX01_VAULT=0` (installed with `--vault-off`). The tool opens
arbitrary SQLite files from the local filesystem; gating it under the vault surface matches the
security posture of vault import/export and mitigates an arbitrary-path-traversal vector
(a caller could pass any filesystem path). Vault-off tool count: 57 → 56. Both ports updated.

### 1.8.0 -- 2026-06-25
Changed (T5 — drain lifecycle): (1) **daemon resume-on-restart** — opening an
estate now EAGER-mounts the corpus's lease-gated drain worker, so a restarted
resident drains a non-empty persisted queue immediately instead of waiting for a
fresh capture. (Swift already eager-mounted via `wireSubstores`; Rust now mounts
in `wire_sqlite_semantic_recall` rather than lazily on first capture — a fixed
Swift/Rust parity gap.) (2) **detached stdio finisher** — a direct-open stdio
`serve`, on exit with encode work still queued, spawns a detached `mootx01 drain`
that takes the T3 lease and drains to empty, so a client SIGKILL on disconnect no
longer abandons the queue. The finisher detaches via `setsid` (unix) /
`DETACHED_PROCESS` (windows) and is gated on the maildir actually having pending
work. Both ports.

### 1.7.0 -- 2026-06-25
Changed (T4 — serve lease-aware transport): an stdio `serve` now **forwards** to a
live resident that serves the same estate instead of opening a second direct
writer. On start it checks a resident-written estate marker (`mootx01.estate`)
against its own estate and, on match, probes the resident port (`daemon.port`);
if the resident answers it runs the stdin→loopback-HTTP bridge (the `proxy`
path), so all traffic funnels through the one resident writer and the resident's
in-RAM derived state stays coherent. If no resident answers (stale marker) it
opens the estate directly. Detection is a port probe + estate-marker match
(uniform Swift↔Rust, dep-free) — not PID-liveness. Both ports.

### 1.6.0 -- 2026-06-25
Changed (T1 — encode mode): `moot_palace_import`'s caller-facing knob is now
`mode` (foreground/background encode SPEED), not `batch`. Contract: the caller
declares SPEED only; the server chooses the WRITE strategy automatically by
source size. Foreground/background select the drain's embed concurrency (all
cores vs ~a quarter) and never change the encoded output — byte-identical either
way. Unknown `mode` is a fail-closed invalid-params error. Both ports conform.

### 1.5.0 -- 2026-06-25
Additive (T6 — drain status): new maintenance tool `moot_drain_status` joins the
behavioral surface. It is a read-only observer of the estate's long-running
background drains (today only `corpus_encode`, the encode/ingest queue): it reads
each drain's pending + in-flight frontiers and reports a draining/idle state plus
optional detail, never claiming or draining. Contract guarantees: (1) read-only —
polling it has no effect on drain progress and is safe from any process; (2)
honest empties — `drains: none` (no drain registered, e.g. a bare estate) is
distinct from a drain listed at `pending: 0, in_flight: 0` (idle); (3) no
session-protocol block, so it is cheap to poll. Both ports conform.

### 1.4.0 -- 2026-06-19
`moot_estate_ping` now surfaces the build serial in its response:
`pong: estate <name> [<uuid>] is live — build <serial>`. § 14 updated with the
full derivation contract: mtime+size fingerprint (`<yyyyMMddHHmmss>/<8-hex>`)
computed once at server construction, `MOOTX01_BUILD_SERIAL` env override
honored verbatim. Both Swift and Rust ports at parity. Tests asserting the
exact `estate_ping` text updated to assert the stable prefix/shape rather than
a specific serial. New unit and dispatch tests added for serial threading and
the env override path.

### 1.3.0 -- 2026-06-17
Additive (mission BRAIN-PREF-PRODUCER — Bradley-Terry preference producer, both
ports). Documents the new preference PRODUCER DUTY on the `AutonomicGovernor`, the
sibling of the graph-centrality producer: on a cadence (default 10 min) it reads
the estate's recall-trace reward history (`RecallTraceItem` target+used), shapes it
into per-drawer `(endorsements, dismissals)` curation records (surfaced-and-used →
endorsement, surfaced-and-passed → dismissal), fits per-drawer Bradley-Terry
preference strengths via the NeuronKit `learnedPreference` / `learned_preference`
anchor-reduction fitter (I-17, no math reinvented), and registers a
`PreferenceStore` — taking the `unionBest`/`matrixAware` recall `preference` column
from dark to live on BOTH ports. `GovernorReport` gains `preferenceFired` /
`preference_fired`. The outcome source is the existing recall reward cycle; no new
substrate data was required. Both recall-cache producer boundaries (graph +
preference) are now closed. Swift + Rust at parity; conformance
`PreferenceProducerTests.swift` / `preference_producer_parity.rs`.

### 1.2.0 -- 2026-06-17
Additive (mission BRAIN-GRAPH-PRODUCER — graph-centrality producer, both ports).
Documents the new graph-centrality PRODUCER DUTY on the `AutonomicGovernor`: on a
cadence (default 10 min) it reads the estate structure graph (drawers + tunnels +
kg_facts), computes per-drawer eigenvalue centrality via the NeuronKit `keystones`
oracle, and registers a `GraphCache` — taking the `unionBest`/`matrixAware` recall
`graph` column from dark to live on BOTH ports. `GovernorReport` gains
`graphCentralityFired` / `graph_centrality_fired`. Corrects the prior text that
implied the recall-cache producers plug into the standing-signal registration
seam: the producers are governor DUTIES (the scheduler emission model cannot
register a cache, and its synchronous emit closure has no `&mut` coordinator). The
Bradley-Terry preference producer remains a separate future duty. Swift + Rust at
parity; conformance `GraphCentralityProducerTests.swift` /
`graph_centrality_parity.rs`.

### 1.1.0 -- 2026-06-17
Additive + correction (#8 Track 1 — Brain harness, Rust side). §17.1
standing-signal activation now specifies BOTH ports: the Rust
`AutonomicGovernor` owns and ticks the estate's standing-signal scheduler (a GLK
`SerialLaneScheduler<CoordinatorDispatcher>`) and the resident HTTP bootstrap
registers the §11.2 default signals once at startup — corrects the prior text
that claimed "Rust has no standing-signal scheduler by design", which is no
longer true. Documents WHY the Rust scheduler lives in the governor (dispatcher
reference-cycle avoidance) and that the registration methods are the producer
seam for the graph-centrality / Bradley-Terry tracks. Swift behavior unchanged.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

## Changelog

### 3.0.0 -- 2026-09-06

Removed stale adornment and stored-distillation contracts from the living
document. Aligned candidate rows and hydration with the schema-19 source.
The earlier entries remain historical records.
