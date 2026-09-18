---
title: GeniusLocusKit Interface
status: accepted-1.1-target
authors: MOOTx01 maintainers
date: 2026-09-15
version: 3.40.0
spec_type: kit
description: "Interface contract for GENIUSLOCUSKIT. 3.22.0: retireKGFact / withdraw_kg_fact signature widened — changedBy/changed_by and reason added; both ports route through AuditGate.admit (verb Retract) and emit a sealed audit row. 3.23.0: sensitivity ceiling enforced on expunge and retireKGFact/withdraw_kg_fact — rows and facts at .restricted/.secret are refused with the absent-row error; no caller-visible signature change. 3.24.0: adds the public fact-extraction duty surface in Swift and Rust. 3.25.0: adds withheldBySensitivity / withheld_by_sensitivity to every GLK recall carrier and the counted endpoint hydration API. 3.26.0: adds FactExtractionSetting, the fact_extraction meta key constant, and the provisionFactExtraction / provisionedFactExtraction accessor pair in both ports (I-27). 3.27.0: retires the fact-first recall surface; the fact layer moves to its own door. 3.31.0: adds the 1.8→1.9 preference-seed capsule, runPreferenceSeedMigration / run_preference_seed_migration, trait MigrationV1_8ToV1_9 / feature migration-v1-8-to-v1-9, and EstateFormatVersion.v1_9 / V1_9 as current; both ports. 3.32.0: registerDefaultStandingSignals / default_standing_signal_specs documented with every optional preference-gated cycle, the default/preference-gated name lists, the adaptive-recall trio (runTemporalCausalityFold, runTrainingTick, endOfDayTournament) and similarRecall / similar_recall in both ports. 3.33.0: Route 1 of the recall router sets the degradable apply directive (reason route:cross_encoder_routing); the strict transcript directive is the transcript operation's own. 3.34.0: every migration capsule trait is in the package's default trait set, so a bare `swift test` runs each capsule test target; consumers still select a floor. 3.35.0: adds EstatePreferenceKey.factExtractor / FactExtractor and EstatePreferenceValue.nuextract, .apple / Nuextract, Apple; per-key allowedValues / allowed_values and defaultValue / default_value on EstatePreferenceKey; provisionedPreference and provisioned_preference use key.defaultValue / key.default_value(); provision_preference / provisioned_preference validate against allowedValues; both ports. 3.37.0: drainStatuses / drain_statuses always report the fact_extraction lane (DrainStatus.factExtractionName / FACT_EXTRACTION_NAME): pending = countFactExtractionDebt / count_fact_extraction_debt (drawers whose bit 28 is clear for the active recipe), in-flight 0, detail names a missing extractor; both ports. 3.38.0: adds the handle-scoped estate reads (allDrawers(in:hydrationLevel:limit:), getDrawers(in:ids:hydrationLevel:), getDrawers(in:ids:matchingFrame:hydrationLevel:), getTunnel(in:id:), activeTunnels(in:from:), activeTunnels(in:to:), kgFacts(in:subjectEq:sourceDrawerIDEq:), meta(in:key:), resolveActiveDatasetHandle(in:datasetId:), countSubjectDebt(in:)) beside the existing allDrawers(in:), allDrawers(in:limit:), allTunnels(in:) and resolveNodeNames(_:parentNodeIds:). 3.39.0: completes the handle-scoped contract with listRooms, auditTrail, setMeta, setSSCFacts, and setSubjectRepresentation; estate resolution is internal to GLK."
package: GeniusLocusKit
languages: [swift, rust]
relates_to:
  - GENIUSLOCUSKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of GeniusLocusKit in both ports, in two tiers within
  § 2. Tier 1 is the CONSUMED CONTRACT — the types NeuronKit and aria-mcp
  actually import (the GeniusLocusKit actor, the unified verb surface and
  its frames, the recall results, the fan-out and grant-gated federated
  read, the grant model, COW branching, the unified audit log, and the
  migration API) — documented with bilingual signatures. Tier 2 (§ 2's
  closing subsection) is the BROADER SURFACE — the Brain-layer scheduler,
  the six standing-signal specs, the matrix tier, the training daemon, the
  scope-key/decay-key internals, and the audit projection/recovery
  machinery that are public for intra-kit and conformance use, consumed
  by the kit's own pipeline rather than another package; a table of
  contents (name + role + source
  file). The companion SPEC carries the behavioral contracts (invariants
  I-1…I-19, conformance C-1…C-13).
---

# GeniusLocusKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/GeniusLocusKit/`

- `Sources/GeniusLocusKit/` — 71 files. The `GeniusLocusKit` actor and
  its registry (`GeniusLocusKit.swift`), the coordinator/verb/fan-out/
  federation/grant/branch/migration extensions, and the Brain layer under
  `Brain/`, `Matrix/`, `Training/`, `Audit/`.
- `Tests/GeniusLocusKitTests/`
- `Package.swift`

**Rust:** `packages/kits/GeniusLocusKit/rust/`

- `src/` — one module per surface (`coordinator.rs`, `handle.rs`,
  `fan_out.rs`, `verbs/`, `audit/`, `brain/`, `matrix/`, `training/`);
  crate `genius-locus-kit`, lib `genius_locus_kit`.

Naming differs by port convention (Swift `glkDeriveBranch` /
`registerStandingSignal`; Rust `snake_case`). The two versions also differ
in *shape* — Swift is the `GeniusLocusKit` actor with `async` methods; the
Rust version is synchronous (`EstateCoordinator` struct, a stateless verb
`Surface`, `SerialLaneScheduler`). Value-level results agree across the
whole surface (SPEC § 8, I-15).

### Shared-content composition surface (1.1 target)

GLK owns the adapter and the operating-mode selection between the standalone
kits:

```swift
// GeniusLocusKit-owned implementation; not a LocusKit or CorpusKit dependency.
struct LocusDrawerCorpusContentSource: CorpusContentSource { /* Estate-backed */ }
```

```rust
pub(crate) struct LocusDrawerCorpusContentSource { /* Estate-backed */ }
impl CorpusContentSource for LocusDrawerCorpusContentSource { /* ... */ }
```

For each `.glk` or `.corpusOnly` estate, `open`/`provision` constructs this
adapter and opens CorpusKit in attached `.wholeContent` mode. The adapter
projects Drawer id, content, revision/digest, and change cursor. CorpusKit
persists only derived Drawer-keyed state. GLK rejects a standalone Corpus or a
passage-enabled policy at `registerCorpus`; LocusKit and CorpusKit remain
independently usable because neither imports the other.

Legacy pre-1.1 layouts are prepared by the optional
`GeniusLocusKitMigrations` catalog before Corpus registration. The current GLK
product exposes only opaque storage/Corpus host seams and contains no concrete
historical step. Swift consumers select `MigrationFloor1_0` (the 1.0→1.1,
1.4→1.5, 1.5→1.6, 1.6→1.7, 1.7→1.8 and 1.8→1.9 capsules), any of
`MigrationFloor1_1` through `MigrationFloor1_4` (the 1.4→1.5, 1.5→1.6,
1.6→1.7, 1.7→1.8 and 1.8→1.9 capsules; nothing separates those stamps any
more), `MigrationFloor1_5` (the 1.5→1.6, 1.6→1.7, 1.7→1.8 and 1.8→1.9
capsules), `MigrationFloor1_6` (the 1.6→1.7, 1.7→1.8 and 1.8→1.9 capsules),
or `MigrationFloor1_7` (the 1.7→1.8 and 1.8→1.9 capsules); every
floor also enables the flat-layout capsule (`MigrationFlatLayoutToCatalog`,
target `GLKMigrationFlatLayoutToCatalog`), a filesystem step rather than a
format step: `FlatLayoutMigration.pending(configurationDirectory:record:)`
reports whether a pre-catalog estate sits flat at the configuration
directory while `record` is the registered default, and
`FlatLayoutMigration.run(configurationDirectory:into:)` renames its files
into the record's directory (siblings first, `estate.sqlite` last, so an
interrupted run resumes) and returns `.nothingToMove`, `.moved(files:)` or
`.refused(flat:catalog:)` when both layouts hold a database. The caller
stops the daemon around it; the capsule never opens the database. Every
capsule trait — both layout traits and every `MigrationV1_x` step — is also
the package's default trait set, so a consumer that selects no floor compiles
every capsule and a bare `swift test` runs every capsule test target with a
non-zero count; a consumer that names traits replaces that set with its floor. The
1.8→1.9 step is `runPreferenceSeedMigration(handle:now:)` (target
`GLKMigrationV1_8ToV1_9`), Rust
`PreferenceSeedMigrationExt::run_preference_seed_migration(&self, &EstateHandle, now_millis) -> Result<(), PreferenceSeedMigrationError>`;
it seeds the five non-fact-extraction preferences `"on"` where absent,
creates `recall_ratings` and stamps `v1_9` / `V1_9` as the chain's last
write (spec I-28). Rust consumers enable the matching
`genius-locus-kit-migrations/migration-floor-1-0` through `-1-7` feature
(`migration-v1-8-to-v1-9` is a default feature so a plain `cargo test` runs
its test binary); the
Rust port never wrote the flat layout and has no such capsule, but it does
carry one capsule Swift has no twin of, the Windows base-directory adoption
step (its own section below).
With no floor selected, fresh/current SDK builds compile no capsule. The Corpus lane
stays dark until redundant content/chunk rows are removed, derived state is
rebuilt from Drawers, and verification succeeds. This is a lifecycle gate, not
a new public migration verb.

> **Two-tier surface.** GeniusLocusKit declares 118 top-level public
> nominal types (plus 18 public typealiases) in the Swift version, of
> which 36 are referenced by another package (NeuronKit, aria-mcp). One
> of those 36 (`Key`, i.e.
> `UnifiedProjection.Key`) is a common-word coincidence; the genuinely
> consumed contract is the ~35 types in Tier 1 below — the actor, the verb
> frames, the recall results, the fan-out/federation/grant/branch/audit/
> migration types. § 2 Tier 1 documents that contract in full. The Tier 2
> subsection at the end of § 2 is a table of contents for the rest: the
> Brain-layer scheduler, signal specs, matrix tier, training daemon, and
> grant/audit internals, public for intra-kit and conformance use but not
> yet a cross-package dependency.

## § 2 — Public types

### Tier 1 — consumed contract

#### `GeniusLocusKit`

The composition actor that coordinates N estates and runs the Brain layer
(SPEC § 1, I-1…I-5). Its verb, fan-out, federation, grant, branch, signal,
and migration methods are declared across sibling extensions.

```swift
public actor GeniusLocusKit {
    public init()
    public var openEstateCount: Int { get }
    public var handles: [EstateHandle] { get }

    // Lifecycle (EstateCoordinator.swift) — SPEC B-1:
    public func open(storage: any Storage, owner: OwnerCredentials) async throws -> EstateHandle
    public func close(_ handle: EstateHandle) async throws

    // Composition-aware provisioning and lifecycle (EstateLifecycle.swift):
    // provision() is the GLK-owned create+open+wire path. It seeds the manifest with the
    // kind-prefixed framework profile and zoom window, then wires sub-stores based
    // on EstateKind. Corpus is always attached to a LocusKit-backed content source
    // with .wholeContent; no Corpus content/chunk table is opened.
    // Idempotent re-provision raises .duplicateEstate.
    // quiesce/drain update EstateMountState; destroy closes the estate and tears down all
    // derived sub-stores using ownership-scoped deletion. Canonical Drawers are
    // unaffected by Corpus cleanup; broad destroyAllVectors is forbidden.
    // embeddingModels defaults to the canonical 1.0 five-signal recall ensemble
    // (CorpusEnsemble.defaultEnsemble(): random indexing). Every provisioned
    // estate gets the production multi-signal default; the trainable signals train and
    // persist on first ingest/reindex. Pass an explicit single-element list (e.g.
    // [.deterministic]) only when one signal is specifically wanted. The Rust
    // `provision` takes `embedding_models: Vec<EmbeddingModelConfig>` (no default
    // arg in Rust — the app caller supplies `default_ensemble()`).
    public func provision(
        storage: any Storage,
        // Optional physical store for Corpus DERIVED state only; never Drawer text.
        corpusStorage: (any Storage)? = nil,
        owner: OwnerCredentials,
        params: EstateProvisionParams,
        embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()
    ) async throws -> EstateHandle
    public func mountState(for handle: EstateHandle) -> EstateMountState?
    public func quiesce(_ handle: EstateHandle) async throws
    public func drain(_ handle: EstateHandle) async throws
    public func destroy(
        storage: any Storage,
        // Optional physical store for Corpus DERIVED state only.
        corpusStorage: (any Storage)? = nil,
        handle: EstateHandle
    ) async throws

    // Unified nine-verb surface (VerbSurface.swift) — SPEC B-2/B-3:
    public func capture(_ handle: EstateHandle, _ frame: CaptureFrame) async throws -> Drawer
    // captureBatch: delegates to Estate.captureBatch — all frames in ONE
    // storage.transaction() via DrawerStore.insertFreshBatch (fresh) or per-item
    // addDrawerCovered (supersession). Avoids nested-transaction conflict that
    // arises when per-item capture() is called inside a rowStore.beginTransaction()
    // block on a SQLite backend. BM25/vector lanes remain dark until callers invoke
    // moot_reindex / moot_dream.
    @discardableResult
    public func captureBatch(_ handle: EstateHandle, _ frames: [CaptureFrame]) async throws -> [Drawer]
    // Dual-Path Intake — mode-aware capture (EncodeIntake.swift). Stores the
    // Drawer row (same as the verb above) then indexes that canonical object in
    // Corpus per `mode`: .regular enqueues a revision/digest source change onto
    // the Corpus's own queue (Corpus.enqueueSourceChange); .impatient resolves
    // the Drawer through CorpusContentSource and indexes inline before
    // returning. The write mode is a verb execution option, NOT a CaptureFrame
    // field. A no-op encode when no Corpus is registered (.locusOnly).
    //
    // LAYERING: the encode queue + drain + worker pool live in CorpusKit (a
    // Corpus self-drains — see CORPUSKIT_INTERFACE). GeniusLocusKit is the
    // orchestrator: at provision it mounts the Corpus ingest queue and sets the
    // Corpus `onEncoded` callback to roll up the touched LocusKit rooms; it
    // never owns the queue or performs the encode. The CorpusKit-internal payload
    // contains Drawer identity/revision/cursor only, never verbatim content.
    @discardableResult
    public func capture(_ handle: EstateHandle, _ frame: CaptureFrame, mode: WriteMode) async throws -> Drawer
    // Dual-Path Intake — await-empty barrier (EncodeIntake.swift):
    //   awaitEncodeDrain  — block until the estate's Corpus ingest queue has
    //                       fully drained (every enqueued drawer ingested +
    //                       replied). Thin delegator to Corpus.awaitIngestDrain.
    //                       Returns promptly when empty; no-op when no Corpus is
    //                       registered. The authoritative "encoding finished"
    //                       barrier for bulk callers; throws QueueError.drainTimeout
    //                       past the timeout (the queue does not wedge under burst).
    //   (mountEncodeQueue was removed: the queue is mounted on the Corpus at
    //    provision via Corpus.mountIngestQueue, not on GLK. The Corpus runs a
    //    foreground ~15 ms poll drain worker on both ports.)
    public func awaitEncodeDrain(for handle: EstateHandle, timeout: Duration = .seconds(30)) async throws
    public func recall(_ handle: EstateHandle, _ frame: RecallFrame) async throws -> [Drawer]
    public func mutate(_ handle: EstateHandle, _ frame: MutateFrame) async throws
    public func withdraw(_ handle: EstateHandle, _ frame: WithdrawFrame) async throws
    public func expunge(_ handle: EstateHandle, _ frame: ExpungeFrame, now: Date = Date()) async throws -> ExpungeVerbOutcome
        // Throws: .expungeNotConfirmed | .crossKitVectorDeleteFailed (fail-closed, three-step).
        // §B-2a audit-seal ordering: success audit seals ONLY after Step 2
        // (cross-kit vector delete) succeeds. On Step-2 failure an
        // "expungeOrphan" substrate event is sealed and the throw fires —
        // the audit records the actual outcome, never a false success. If the orphan-seal
        // also fails, the seal error is logged at .fault level (Swift) or
        // folded into the CrossKitVectorDeleteFailed.reason string (Rust).
        //
        // Partial outcome (SPEC B-8b, MXE-FA): the storage expunge refuses
        // accepted lineage siblings (S-3) and preserves them byte-identical.
        // Step 2 deletes vectors ONLY for members that were actually
        // scrubbed (lineage chain minus refused ids) — a refused sibling
        // keeps its content AND its vector. The returned outcome names the
        // refused members; NOT @discardableResult: an expunge that refused
        // a sibling is not a success, and a caller that summarises it as
        // one is the defect. defragVagueItem / defrag_vague_item consume
        // this and raise .underlyingEstateFailure on a partial cascade.
        // Rust: EstateCoordinator::expunge(...) -> Result<ExpungeVerbOutcome, VerbDispatchError>.

    // ExpungeVerbOutcome: partial-expunge outcome carrier (SPEC B-8b, MXE-FA).
    public struct ExpungeVerbOutcome: Sendable, Equatable {       // Rust: genius_locus_kit::ExpungeVerbOutcome
        public let refusedSiblingIDs: [String]                    // Rust: refused_sibling_ids: Vec<String>, walk order
    }

    // Expunge integrity sweep (VerbSurface.swift) — SPEC B-2b:
    // Maintenance function (NOT a verb). Call AFTER all Corpus / VectorStore
    // instances have been registered for the estate. Detects tombstoned rows
    // with no "tombstone" or "expungeOrphan" audit (crash-window state),
    // re-attempts the cross-kit delete, and seals a synthetic "expungeOrphan"
    // audit for each. Returns partial-success result — per-row errors do not
    // abort the sweep.
    public func runExpungeIntegritySweep(_ handle: EstateHandle, now: Date = Date()) async throws
        -> ExpungeIntegritySweepResult
        // Throws: .underlyingEstateFailure when the orphan-set query fails.

    // ExpungeIntegritySweepResult: aggregate outcome of one sweep call.
    public struct ExpungeIntegritySweepResult: Sendable, Equatable {
        public var remediatedCount: Int     // re-delete + seal both succeeded
        public var orphanedCount: Int       // re-delete failed; seal succeeded
        public var perRowErrors: [String]   // rows where seal also failed
    }

    public func reanchor(_ handle: EstateHandle, _ frame: ReanchorFrame) async throws    // .emptyReanchor
    public func captureTunnel(_ handle: EstateHandle, _ frame: TunnelCaptureFrame) async throws -> Tunnel
    public func settleTunnel(_ handle: EstateHandle, tunnelID: String, accept: Bool,
                             changedBy: String, reason: String? = nil, now: Date = Date()) async throws
    public func captureDatasetHandle(_ handle: EstateHandle, datasetId: UUID,
        columns: [DatasetColumnSummary], rowCount: Int, sourceDescription: String,
        wing: String? = nil, room: String, addedBy: String,
        sensitivity: AdjectiveSensitivity = .normal, udcCode: String) async throws -> Drawer
    public func stampFDCRecalculationFloor(_ handle: EstateHandle, value: String) async throws
    public func reanchorAnchor(_ handle: EstateHandle, rowID: RowID, toLattice: LatticeAnchor,
        changedBy: String, reason: String = "anchor Q-ID resolved via enrichment-proposal acceptance",
        now: Date) async throws
    public func learn(_ handle: EstateHandle, _ frame: LearnFrame) async throws
    public func propose(_ handle: EstateHandle, _ frame: ProposeFrame) async throws
    public func associate(_ handle: EstateHandle, _ frame: AssociateFrame) async throws

    // Association-graph read (VerbSurface.swift) — the edges the structural
    // reasoning-lens recipes read; parallels `recall`, read-only. The default
    // keeps the Normal-tier sensitivity ceiling; includingRestricted is the
    // one sanctioned widening (the vault export's private-scope opt-in) and
    // secret-tier edges are excluded unconditionally either way:
    public func recallTunnels(_ handle: EstateHandle, wing: String,
                              includingRestricted: Bool = false) async throws -> [Tunnel]

    // KGFact verb surface (VerbSurface.swift):
    // captureKGFact files a triple into the estate; sourceDrawerID = "" is the
    // unanchored-fact sentinel for agent-asserted triples. A NON-EMPTY
    // sourceDrawerID must name a drawer in this estate: the fact inherits that
    // drawer's adjective and provenance bitmaps, and an id naming no drawer
    // throws GeniusLocusKitError.sourceDrawerNotFound rather than filing at the
    // Normal default. addedBy / foreignSourceKey / foreignRecordID carry the
    // filing host and any foreign-palace origin. retireKGFact
    // transitions the row to State.withdrawn so it exits the active-recall filter.
    // recallKGFacts returns active facts only (state cluster < 7).
    // recallKGFactTimeline returns ALL facts — active and retired — for the
    //   full lifecycle history; optional entity filter narrows by subject/object
    //   substring (case-insensitive). Peer of Rust recall_kg_fact_timeline.
    func captureKGFact(_ handle: EstateHandle, id: String = UUID().uuidString,
                       subject: String, predicate: String, object: String,
                       sourceDrawerID: String = "", addedBy: String = "",
                       foreignSourceKey: String = "", foreignRecordID: String = "",
                       now: Date) async throws -> KGFact
    // Rust peer (no default arguments): add_kg_fact is the empty-origin entry
    // point, add_kg_fact_with_origin adds KGFactOrigin, and
    // add_kg_fact_with_id_and_origin additionally names the row. One
    // implementation reached through three spellings.
    func retireKGFact(_ handle: EstateHandle, rowID: String, changedBy: String, reason: String? = nil, now: Date) async throws
    func recallKGFacts(_ handle: EstateHandle) async throws -> [KGFact]
    func recallKGFactTimeline(_ handle: EstateHandle, entity: String?) async throws -> [KGFact]

    // Read fan-out (CrossEstateRead.swift) — SPEC B-4:
    public func estatesOverlapping(_ region: LatticeRegion) throws -> [EstateHandle]
    public func fanOutRecall(_ frame: RecallFrame, region: LatticeRegion) async throws -> [EstateRecallContribution]

    // Grant-gated federated read (CrossEstateFederation.swift) — SPEC B-7:
    public func federatedRecall(_ frame: RecallFrame, from source: EstateHandle,
                                requestedBy requester: EstateHandle, now: Date = Date()) async throws -> FederatedRecallResult

    // Grants (VerbSurface.swift grant extension) — SPEC B-8:
    public func issueGrant(_ handle: EstateHandle, _ options: GrantOptions, now: Date = Date()) async throws -> IssueGrantResult
    public func revokeGrant(_ handle: EstateHandle, grantID: UUID, now: Date = Date()) async throws

    // Sensitivity-unlock audit seam (SensitivityAuditVerbs.swift):
    // AriaMcpKit's SensitivityGrantLedger/ToolDispatcher calls these to record
    // sensitivity-unlock lifecycle events into the UnifiedAuditLog (SPEC B-8a).
    // All four are async throws and awaited (not fire-and-forget) — the write is
    // security-relevant; a failed durable append surfaces to the caller.
    // Callers that treat audit recording as best-effort suppress the throw
    // themselves via `try?` at the call site.
    // Throws: GeniusLocusKitError.estateNotOpen for a stale handle.
    public func recordSensitivityGrantIssued(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        grantID: UUID,
        expiresAt: Date,
        now: Date
    ) async throws
    public func recordSensitivityGrantDenied(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        now: Date
    ) async throws
    public func recordSensitivityGrantRevoked(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        grantID: UUID,
        now: Date
    ) async throws
    // drawerID: the drawer's UUID string (not a grant id). Malformed drawerID
    // is silently skipped (returns without appending) rather than throwing,
    // because audit recording is best-effort observability on the read path.
    public func recordSensitivityReadUnderGrant(
        _ handle: EstateHandle,
        tier: AdjectiveSensitivity,
        drawerID: String,
        now: Date
    ) async throws

    // Unified audit log (GeniusLocusKit.swift, VerbSurface.swift) — SPEC B-9/B-10:
    public func auditLog(for handle: EstateHandle) throws -> UnifiedAuditLog
    public func feedAuditLog(for handle: EstateHandle) async throws
    public func verifyAuditChain(_ handle: EstateHandle) async throws -> AuditChainReport

    // COW branching (VerbSurface.swift branch extension) — SPEC B-11:
    public func glkDeriveBranch(name: String, from handle: EstateHandle) async throws -> any BranchHandle
    public func glkDeriveBranch(name: String, fromBranch parentBranch: any BranchHandle) async throws -> any BranchHandle
    public func glkPromoteBranch(_ branch: any BranchHandle, replacing handle: EstateHandle) async throws
    @discardableResult
    public func glkMergeDrawers(_ drawerIDs: [RowID], from branch: any BranchHandle, into handle: EstateHandle) async throws -> MergeReport
    public func branchHandle(for branchID: BranchID) -> (any BranchHandle)?    // read accessor: resolve a tracked branch by id (stateless aria-mcp recipe callers)

    // Recall substrate registration (GeniusLocusKit.swift) — SPEC B-recall:
    // Wire the BM25/vector/matrix substrate lanes for a given estate. Call after
    // open(_:owner:) and before the first recall(_:GLKRecallRequest) that uses
    // corpusOnly, hybrid, or unionBest mode. Corpus must have been constructed
    // with this estate's LocusDrawerCorpusContentSource and .wholeContent policy;
    // standalone or passage-enabled Corpus values are rejected with modeViolation.
    // Re-registering replaces the existing entry for the handle.
    public func registerCorpus(_ corpus: Corpus, for handle: EstateHandle)
    public func registerVectorStore(_ store: VectorStore, for handle: EstateHandle)
    // Span rerank seams (SpanRerank.swift, 2.21.0 — Encoder Rerank Program, contract
    // sheet §7/§8): the query-side encoder for the active encoder_models row, the
    // span-row reader (the estate's SynapseKit store), and the head size
    // (encoder_head; default SpanRerankStage.defaultEncoderHead = 30). Register after
    // registerCorpus; absent ⇒ the unionBest lexical lane is unreranked. Dropped on
    // close. Rust: EstateCoordinator::register_span_rerank(handle, Arc<dyn
    // SpanRerankEncoding>, Arc<dyn SpanVectorReading>, head).
    public func registerSpanRerank(_ encoder: any SpanRerankEncoding, spanVectors: any SpanVectorReading, head: Int = SpanRerankStage.defaultEncoderHead, for handle: EstateHandle)
    public func registerMatrixTier(_ tier: MatrixTier, for handle: EstateHandle)
    public func registerGraphCache(_ cache: some GraphCache, for handle: EstateHandle)   // recall cold-path seam
    public func registerPreferenceStore(_ store: some PreferenceStore, for handle: EstateHandle) // recall cold-path seam

    // Sync engine registration (SyncEngineAPI.swift) — supplies the canonical
    // sync-state token read by moot_estate_status. Call after open(_:owner:).
    // Replaces any previously registered engine for the handle.
    // GLK imports only the base ConvergenceKit protocol module and does not drive
    // the engine's enable/disable/push/pull lifecycle; it reads engine.state lazily
    // on each syncStateToken call.
    // Callers that want local-only behaviour need NOT call registerSyncEngine;
    // syncStateToken returns "local-only" when no engine is registered.
    // Throws: GeniusLocusKitError.estateNotOpen for a stale handle.
    public func registerSyncEngine(
        _ engine: some SyncEngine,
        backendName: String,      // "none" | "cloudkit" | "federation"
        for handle: EstateHandle
    ) throws
    // Return the canonical sync-status token for moot_estate_status.
    // Reads the registered engine's state asynchronously and formats it.
    // Vocabulary (parity with Rust format_sync_state_token; the token "connected"
    // is NEVER returned):
    //   "local-only"                              — no engine registered
    //   "none (idle)"                             — NoSyncEngine, disabled
    //   "none (enabled, zone: <zone>)"            — NoSyncEngine, enabled
    //   "cloudkit (idle)"                         — CloudKit, disabled
    //   "cloudkit (enabled, zone: <zone>)"        — CloudKit, enabled
    //   "cloudkit (syncing, direction: <d>)"      — CloudKit, mid-sync
    //   "cloudkit (error: <e>)"                   — CloudKit, error
    //   "federation (idle)"                       — Federation, disabled
    //   "federation (in-process, zone: <zone>)"   — Federation enabled (v1.0 in-process)
    //   "federation (syncing, direction: <d>)"    — Federation, mid-sync
    //   "federation (error: <e>)"                 — Federation, error
    // Throws: GeniusLocusKitError.estateNotOpen for a stale handle.
    public func syncStateToken(for handle: EstateHandle) async throws -> String

    // Standing-signals API (SignalAPI.swift / DefaultStandingSignals.swift) — SPEC B-5/B-6:
    public func registerStandingSignal(_ spec: SignalSpec, in handle: EstateHandle, now: Date) async throws -> SignalID
    @discardableResult
    // The six always-on signals register unconditionally (their closures default to
    // no-ops). Each optional closure below registers its signal ONLY when non-nil; the
    // host passes it only while the named estate preference is on (absent = on).
    public func registerDefaultStandingSignals(
        in handle: EstateHandle,
        vectorStore: VectorStore,
        dreamingCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        huntCycle: @escaping @Sendable (Date) async throws -> (proposed: Int, borderline: Int) = { _ in (0, 0) },
        anomalyCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        spanEncodeCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        factExtractionCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        consolidationCycle: (@Sendable (Date) async throws -> ConsolidationSweepReport)? = nil,          // `consolidation`
        contradictionSweepCycle: (@Sendable (Date) async throws -> ConflictTunnelProposalReport)? = nil, // `contradiction_sweep`
        maintenanceCycle: (@Sendable (Date) async throws -> Int)? = nil,   // `maintenance` — tombstone grace ([.tombstone])
        decayCycle: (@Sendable (Date) async throws -> Int)? = nil,         // `maintenance` — quiet-row decay ([.decay])
        byReferenceCycle: (@Sendable (Date) async throws -> Int)? = nil,   // `maintenance` — by-reference drift ([.byReference])
        foldCycle: (@Sendable (Date) async throws -> Void)? = nil,         // `adaptive_recall` — runTemporalCausalityFold
        trainingCycle: (@Sendable (Date) async throws -> String)? = nil,   // `adaptive_recall` — runTrainingTick
        tournamentCycle: (@Sendable (Date) async throws -> TournamentReport)? = nil, // `adaptive_recall` — endOfDayTournament
        modelID: String = "minilm-v6",
        now: Date
    ) async throws -> [String: SignalID]
    public static var defaultStandingSignalNames: [String]           // the six always-on names, registration order
    public static var preferenceGatedStandingSignalNames: [String]   // the eight preference-gated names
    public func signalStatus(in handle: EstateHandle) async throws -> [SignalReport]
    public func signalTick(in handle: EstateHandle, now: Date) async throws
    public func signalRequestFire(_ signalID: SignalID, in handle: EstateHandle, now: Date) async throws

    // Adaptive-recall cycles (Brain/AdaptiveRecallCycles.swift, Brain/EndOfDayTournament.swift):
    // the closures the host wraps for registerDefaultStandingSignals under `adaptive_recall`.
    public func runTemporalCausalityFold(_ handle: EstateHandle, now: Date) async throws                 // rebuilds the derived accelerators (T population)
    public func runTrainingTick(_ handle: EstateHandle, now: Date) async throws -> String                // one TrainingDaemon.runOnce over the audit log, matrix tier and calibration registry
    public func endOfDayTournament(_ handle: EstateHandle, now: Date) async throws -> TournamentReport   // folds the day's recall traces into recall_ratings
    public struct TournamentReport: Sendable, Equatable { public let contests: Int; public let ratedDrawers: Int }

    // The paraphrase door (Verbs/SimilarRecall.swift): nearest drawers by whole-record LSA
    // vector from the corpus engine's default float slot, lane order preserved, hydrated
    // through `filter`; score.final = raw cosine in [−1, 1], score.dense = (cos + 1) / 2.
    // No fusion, no rerank. Empty when no corpus engine is registered or the lane is dark.
    public func similarRecall(_ handle: EstateHandle, query: String, limit: Int, filter: LocusKit.Filter) async throws -> [RecallHit]
    @discardableResult
    public func signalSubscribe(_ signalID: SignalID, in handle: EstateHandle, callback: @escaping @Sendable (SignalEmission) -> Void) async throws -> SubscriptionID
    public func signalUnsubscribe(_ signalID: SignalID, subscription: SubscriptionID, in handle: EstateHandle) async throws
    public var openSchedulerCount: Int { get }
    // Read back a registered VectorStore. Swift: actor accessor (public).
    // Rust mirror: `EstateCoordinator::vector_store_for(&handle) -> Option<Arc<VectorStore>>`
    // is `pub` — the AriaMcpKit autonomic governor reads it to build the default
    // standing-signal specs at registration (mirrors the Swift resident's
    // `kit.registeredVectorStore(for:)` bootstrap; see ARIA_MCP_INTERFACE §2).
    public func registeredVectorStore(for handle: EstateHandle) -> VectorStore?

    // Hydration (EstateHydration.swift):
    // Open an in-memory estate hydrated from a durable (SQLite) backend.
    // Schema gate: opens both backends with the composite GLK SchemaDeclaration
    // (version derived from the live LocusKit + SynapseKit + attached-CorpusKit
    // profiles; standalone Corpus content schemas excluded) before calling
    // StorageReplicator.hydrate. Six-step sequence:
    //   1. Schema open both sides. 2. Row + audit snapshot. 3. Estate open.
    //   4. Audit log feed. 5. MatrixTier.fullRebuild (both passes).
    // flush reverses the direction: writes in-memory state to durable.
    public func open(inMemory: any Storage, owner: OwnerCredentials,
                     hydrateFrom durable: any Storage) async throws -> EstateHandle
    public func flush(from inMemory: any Storage, into durable: any Storage) async throws -> ReplicationCursor

    // Migration (MigrationAPI.swift) — SPEC B-14. Mass ingestion is NOT a
    // GLK verb: retired per the data-movement contract Decision 1, superseded by
    // VaultKit's ExchangeAdapter → VaultBridge.importVault path.
    public func runParallel(source: EstateHandle, target: EstateHandle, mode: ParallelCaptureMode) async throws -> ParallelRunHandle
    public func verifyMigration(estate: EstateHandle, against corpus: ExternalCorpus, now: Date) async throws -> MigrationVerification

    // FCA and implication engine (EstateFormalConcepts.swift) — SPEC § MX-3a:
    // Pure adapters; capability gating lives in CognitionKit recipes.
    public func mineFormalConcepts(estate: EstateHandle, miner: BoundedConceptMiner) async throws -> [FormalConcept]
    public func formalConceptCoverDeltas(estate: EstateHandle, miner: BoundedConceptMiner) async throws -> ConceptCoverDeltas
    public func conceptImplications(estate: EstateHandle, miner: BoundedConceptMiner,
                                    maxImplications: Int, maxPremiseSize: Int) async throws -> ConceptImplications

    // Association rule mining (EstateAssociationRuleMining.swift) — SPEC § EstateAssociationRuleMining:
    // Hard ceiling on audit entries materialized for Apriori. The public surface
    // always passes this value; the internal variant mineAprioriRules(estate:thresholds:entryLimit:)
    // exists for tests that exercise the cap at small scale.
    // Rationale: 50,000 × ~175 bytes ≈ 10 MB allocation budget; real human-driven
    // estates are well under this (1,000 drawers × 10 mutations ≈ 10,000 entries).
    // Rust mirrors this as EstateCoordinator::MAX_APRIORI_AUDIT_ENTRIES (private const).
    public static let maxAuditEntriesForMining: Int = 50_000

    // Pairwise ARM: reads the estate's registered MatrixTier and delegates to
    // SubstrateML.mineAssociationRules(matrix:activeRowCount:thresholds:).
    // Returns [] (no error) when no MatrixTier is registered for the estate.
    // See SPEC § EstateAssociationRuleMining for documented approximations
    // (single-item support upper-bound; multi-bit/string/bytes skipped).
    // Swift-only: no Rust parity (the Rust port exposes mineAprioriRules only).
    public func mineAssociationRules(
        estate: EstateHandle,
        thresholds: MiningThresholds
    ) -> [AssociationRule]

    // Apriori: calls currentAuditLog(in:), bounds to the most-recent
    // maxAuditEntriesForMining entries (HLC-ascending tail), converts each
    // UnifiedAuditEntry.afterValue to a RowAuditEntry, builds RowAttributeView
    // rows, and delegates to AprioriMining.mine(rows:thresholds:).
    // Throws: GeniusLocusKitError.estateNotOpen when estate is unregistered;
    // any error from currentAuditLog. Returns rules sorted by lift DESC,
    // confidence DESC, evidenceCount DESC.
    public func mineAprioriRules(
        estate: EstateHandle,
        thresholds: AprioriThresholds
    ) async throws -> [AprioriRule]
}
```
**Rust:** the surface is split across synchronous types — `EstateCoordinator`
(`open` / `close` / `handles` / `open_estate_count` / `state_for`, plus the
association-graph read `recall_tunnels(handle, wing) -> Result<Vec<Tunnel>, VerbDispatchError>`
and its `recall_tunnels_with_ceiling(handle, wing, including_restricted)` widening
(the vault export's private-scope opt-in; secret always excluded),
and the write-path methods):

`capture_tunnel(handle, frame, now) -> Result<Tunnel, VerbDispatchError>`,
`settle_tunnel(handle, tunnel_id, accept, changed_by, reason, now) -> Result<(), VerbDispatchError>`,
`capture_dataset_handle(handle, dataset_id, columns, row_count, source_description, wing, room, added_by, sensitivity_raw, udc_code, now) -> Result<Drawer, VerbDispatchError>`,
`stamp_fdc_recalculation_floor(handle, value) -> Result<(), VerbDispatchError>`, and
`reanchor_anchor(handle, row_id, to_lattice, changed_by, reason) -> Result<(), VerbDispatchError>`.
All five use the existing mounted/stale handle gate. The FDC stamp owns only the
literal `aria.fdc.recalced_data_version` key; GLK adds no generic metadata API.

Tunnel settlement delegates to LocusKit's atomic lifecycle-plus-canonical-ledger
write: `accept` selects Active and reject selects Withdrawn while `reviewedBy`
records the reviewer. `reason` and time remain caller inputs for compatibility
but are not persisted in the tunnel ledger.

`fileDataset(handle, DatasetFilingFrame)` / `file_dataset(handle, dataset_id,
schema, rows, columns, source_description, wing, room, added_by,
sensitivity_raw, udc_code, now)` is the governed dataset coordination seam:
it creates the raw table, appends its rows, then captures the typed handle and
drops the new table if append or handle capture fails. Its UDC-only common
contract is intentional. Swift's lower LocusKit capture can represent a richer
anchor, while the Rust lower primitive cannot preserve facets or QIDs. The
post-filing dataset-signature computation patches the durable handle through
its existing governed mutation; a signature failure is recoverable and does not
roll back the table or handle.

```rust
// EstateCoordinator — write-path surface
pub fn add_kg_fact(
    &self, handle: &EstateHandle,
    subject: &str, predicate: &str, object: &str,
    source_drawer_id: &str, now: i64,
) -> Result<locus_kit::kg_fact::KGFact, VerbDispatchError>

pub fn withdraw_kg_fact(
    &self, handle: &EstateHandle, id: &str,
    changed_by: &str, reason: Option<&str>, now: i64,
) -> Result<(), VerbDispatchError>

// recall_kg_facts returns active facts only (state cluster < 7).
pub fn recall_kg_facts(
    &self, handle: &EstateHandle,
) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError>

// recall_kg_fact_timeline returns ALL facts — active and retired — for the
// full lifecycle history; optional entity filter narrows by subject/object
// substring (case-sensitive at this layer — callers lower both sides).
// Peer of Swift recallKGFactTimeline(_:entity:).
pub fn recall_kg_fact_timeline(
    &self, handle: &EstateHandle, entity: Option<&str>,
) -> Result<Vec<locus_kit::kg_fact::KGFact>, VerbDispatchError>

pub fn add_diary_entry(
    &self, handle: &EstateHandle,
    agent_name: &str, entry_text: &str, topic: &str,
    embedding_model_id: &str, now: i64,
) -> Result<locus_kit::diary_entry::DiaryEntry, VerbDispatchError>

pub fn diary_entries(
    &self, handle: &EstateHandle, agent_name: &str, last_n: usize,
) -> Result<Vec<locus_kit::diary_entry::DiaryEntry>, VerbDispatchError>
```

`add_kg_fact` allocates a UUID v4 id and returns the stored fact.
`add_diary_entry` sets `wing = "wing_<agent_name>"` and `room = "diary"`;
an empty `embedding_model_id` is substituted with `"no-embedding"`.
`withdraw_kg_fact` routes through `audit_gate::admit` (verb `Retract`),
transitions the fact's `adjective_bitmap` bits 0-5 to `State::Withdrawn`
(raw 18) preserving upper bits, and appends a sealed audit row in the same
transaction. `changed_by` must be non-empty. The parity surfaces are
`VerbSurface.captureKGFact` / `.retireKGFact` and `DreamingWrites.addDiaryEntry`
/ `.readDiaryEntries` in Swift. The stateless verb `Surface` (the nine verbs
returning `Result<…, VerbError>`), `LatticeRegion` + `EstateRecallContribution`
fan-out, `SerialLaneScheduler`, and the grant, federation, branch, and
migration surfaces are documented in SPEC § 8.

**Rust — sync engine registration:** `EstateCoordinator::register_sync_engine(&mut self, handle, engine: Box<dyn SyncEngine>, backend_name: &str) -> Result<(), GeniusLocusKitError>` and `sync_state_token(&self, handle) -> Result<String, GeniusLocusKitError>` are the direct Rust parallels. The Rust token vocabulary is identical; the single formatting function is `format_sync_state_token(state, backend_name)` in `coordinator.rs`. The Rust method is synchronous (no `async`) because the Rust `SyncEngine` trait's `state()` method is also synchronous.

**Rust — sensitivity audit verbs:** `EstateCoordinator` exposes four parallel methods — `record_sensitivity_grant_issued(&mut self, handle, tier, grant_id: Uuid, expires_at_ms: i64, now_ms: i64)`, `record_sensitivity_grant_denied(&mut self, handle, tier, now_ms: i64)`, `record_sensitivity_grant_revoked(&mut self, handle, tier, grant_id: Uuid, now_ms: i64)`, `record_sensitivity_read_under_grant(&mut self, handle, tier, drawer_id: &str, now_ms: i64)` — all returning `Result<(), GeniusLocusKitError>`. Date is passed as epoch-milliseconds (`i64`) per the Rust synchronous convention rather than `Date`.

**Rust — association rule mining:** `EstateCoordinator::mine_apriori_rules(&self, handle, thresholds: AprioriThresholds) -> Result<Vec<AprioriRule>, VerbDispatchError>` is the Rust parity for `mineAprioriRules`; the cap constant is `EstateCoordinator::MAX_APRIORI_AUDIT_ENTRIES = 50_000` (private). Pairwise ARM (`mineAssociationRules`) has no Rust parity — the Rust port exposes `mine_apriori_rules` only.

#### Dataset store access: `datasetStore(for:)` and `computeDatasetSignatures(...)`

Two public extension methods expose the below-belief raw-table layer (MX-TAB
feature series). The `DatasetStore` operates directly on backend tables — not on
drawers, tunnels, or KG facts — so this surface is outside the nine-verb model
(SPEC B-2 scope does not apply).

```swift
// DatasetStoreAccess.swift — MX-TAB-7 coordinator seam.
// The coordinator holds the storage registry; this is the correct seam to vend
// a DatasetStore rather than surfacing it through Estate (which owns the belief
// layer, not raw backend tables).
public extension GeniusLocusKit {
    /// Return the DatasetStore backing the given estate.
    /// - Throws:
    ///   `.estateNotOpen` when `handle` is not in the coordinator registry.
    ///   `StorageError.featureGated("datasetStore")` when the estate's Storage
    ///   backend does not implement the DatasetStore surface.
    func datasetStore(for handle: EstateHandle) throws -> any DatasetStore
}

// DatasetSignatures.swift — MX-TAB-5 layered content fingerprints.
// Public constant — callers use it to size the DatasetStore.queryRows limit call:
public let datasetSignatureSampleSize: Int = 128      // max sampled rows for tier-1

public extension GeniusLocusKit {
    /// Compute and persist layered SHA-256 signatures for a dataset handle drawer.
    ///
    /// Tier 1 (table): SHA-256 over the column schema (sorted asc by name) +
    /// up to `datasetSignatureSampleSize` (128) sampled rows. Domain tag 0x10.
    /// Tier 2 (per-column): SHA-256 over (name, declared type, value-distribution
    /// sketch — distinctCount, nullCount, min, max, top-20 most-frequent values).
    /// Domain tag 0x11.
    /// Both tiers are written into the handle's DatasetHandleContent JSON payload
    /// via `Estate.patchDatasetHandleSignatures`.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `LocusKitError.drawerNotFound` when the drawer does not exist;
    ///   `LocusKitError.invalidContent` on malformed content JSON.
    func computeDatasetSignatures(
        handle: EstateHandle,
        drawerId: String,
        columns: [DatasetColumnSummary],
        columnStats: [String: ColumnStats],
        sampledRows: [StorageRow],
        now: Date
    ) async throws -> Drawer
}
```

**Rust:** `compute_dataset_signatures` is a free function in
`rust/src/dataset_signatures.rs` (not a method on `EstateCoordinator`). It takes
a `&Estate` reference directly — consistent with the Rust sync model, where the
tool layer can reach the estate without going through the coordinator. The preimage
format and SHA-256 output are byte-identical between ports: the tier-1 table
preimage and tier-2 per-column preimage layouts (domain tags 0x10/0x11,
big-endian length prefixes, canonical-value-bytes type encoding) are locked by
cross-leg anchor test vectors in both test suites. Constants mirror Swift:
`DATASET_SIGNATURE_SAMPLE_SIZE = 128` and `DATASET_SIGNATURE_TOP_K = 20`.
There is no `datasetStore(for:)` equivalent on `EstateCoordinator` — the Rust
tool layer reaches `DatasetStore` through the estate directly.

#### `EstateHandle`

The value-type ticket addressing one estate (SPEC § 1, I-1). Carries a
cached manifest snapshot; not the live estate.

```swift
public struct EstateHandle: Sendable, Hashable {
    public let estateUUID: UUID
    public let zoomWindowLow: Int
    public let zoomWindowHigh: Int
    public let estateName: String
    // internal init(manifest:) — only the coordinator issues handles
}
```
**Rust:** `pub struct EstateHandle { estate_uuid, zoom_window_low,
zoom_window_high, estate_name }` with `pub fn new(...)`.

#### `WriteMode` (Dual-Path Intake)

The write-mode execution option on the mode-aware capture verb.

```swift
// EncodeIntake.swift — the write verb's execution mode.
public enum WriteMode: String, Sendable, Codable, CaseIterable {
    case regular     // enqueue onto the Corpus ingest queue; the drain encodes async
    case impatient   // encode inline before the write returns
}
```

**Rust:** the `WriteMode` intake type is present in the Rust port
(`rust/src/intake.rs`); see the additional-types concordance below.

> **Note — `EncodeJob` was removed.** The encode-queue payload formerly lived on
> GeniusLocusKit (`EncodeJob`, in `EncodeIntake.swift` / `intake.rs`). The encode
> pipeline relocated into CorpusKit: the queue, drain worker pool, retry, and the
> payload are now CorpusKit-internal (`IngestJob`, not part of any public
> surface). GeniusLocusKit's intake is pure orchestration —
> `capture(_:_:mode:)`, `awaitEncodeDrain`, and `reindexMissing` delegate to the
> estate's `Corpus.enqueueSourceChange` / `Corpus.awaitIngestDrain`. See
> `CORPUSKIT_INTERFACE.md`.
>
> **Drain monitoring.** `drainStatuses(_ handle:) async throws -> [DrainStatus]`
> (Rust `EstateCoordinator::drain_statuses(&self, handle) -> Vec<DrainStatus>`)
> reports every long-running background drain the estate runs, for AI/operator
> monitoring (the `moot_drain_status` tool). Read-only: it OBSERVES each drain's
> frontiers (via `Corpus.ingestQueueDepth`), never claiming or draining. The
> return is a LIST so additional drains surface without a reshape. Lanes, in
> report order: `corpus_encode` (pending + in-flight counts, draining/idle, and
> the live encoded-chunk count as detail; present only when a Corpus is
> registered), `dreaming` (present only while the queue is mounted),
> `subject_backfill` and `span_encode` (row debt; present only while their
> rider is registered), and `fact_extraction` (`DrainStatus.factExtractionName`
> / `FACT_EXTRACTION_NAME`; ALWAYS present; pending =
> `countFactExtractionDebt` / `count_fact_extraction_debt`, the drawers whose
> bit 28 is clear for the active recipe; in-flight 0; detail
> `drawers awaiting fact extraction for the active recipe`, suffixed
> `; no extractor registered` when no extractor is registered). A caller
> settles an estate on the `fact_extraction` lane reaching idle rather than by
> running blind dreaming cycles. A bare estate with no Corpus reports only the
> always-present lane. `DrainStatus` is `Sendable`/`Equatable` (Swift) /
> `Clone+Debug+PartialEq` (Rust) with an `isDraining`/`is_draining` accessor.
>
> **Encode speed.** `setEncodeSpeed(_ speed: EncodeSpeed, for handle:) async`
> (Rust `EstateCoordinator::set_encode_speed(&self, handle, speed)`) sets the
> estate corpus drain's embedding QoS — `EncodeSpeed.foreground` (embed across
> all cores) or `.background` (cap to ~`cores / 4`). No-op when no Corpus is
> registered. `EncodeSpeed` is re-exported from GeniusLocusKit (Swift: a GLK
> enum mapping to CorpusKit's; Rust: `pub use corpus_kit::corpus::EncodeSpeed`)
> so PalaceBridge / AriaMcpKit name it without a direct CorpusKit dependency.
> The import `mode` arg maps onto this; write strategy is size-gated separately.

#### Verb frames: `CaptureFrame`, `RecallFrame`, `LearnFrame`, `MutationKind`, `WithdrawFrame`, `MutateFrame`, `ExpungeFrame`, `ReanchorFrame`, `ProposeFrame`, `AssociateFrame`

The named-slot inputs to the nine verbs (SPEC § 2, B-2). `CaptureFrame`,
`RecallFrame`, `LearnFrame`, `MutationKind`, `LatticeAnchor`, `RowID`,
`RoomID`, and `Drawer` are re-exported `typealias` of the LocusKit types so
callers need only `import GeniusLocusKit`. The remaining frames are
GLK-native (LocusKit's verb signatures for these are positional).

```swift
public typealias CaptureFrame = LocusKit.CaptureFrame
public typealias RecallFrame  = LocusKit.RecallFrame
public typealias LearnFrame   = LocusKit.LearnFrame
public typealias MutationKind = LocusKit.MutationKind
public typealias LatticeAnchor = LocusKit.LatticeAnchor
public typealias RowID = LocusKit.RowID          // String
public typealias RoomID = LocusKit.RoomID         // String
public typealias Drawer = LocusKit.Drawer

public struct WithdrawFrame: Sendable, Equatable {
    public let rowID: RowID; public let reason: String?
    public init(rowID: RowID, reason: String? = nil)
}
public struct MutateFrame: Sendable {
    public let rowID: RowID; public let kind: MutationKind; public let payload: String?
    public init(rowID: RowID, kind: MutationKind, payload: String? = nil)
}
public struct ExpungeFrame: Sendable, Equatable {
    public let rowID: RowID; public let reason: String; public let confirmation: Bool   // transient input, not a stored Bool (I-10)
    public init(rowID: RowID, reason: String, confirmation: Bool)
}
public struct ReanchorFrame: Sendable, Equatable {
    public let rowID: RowID; public let toRoom: RoomID?; public let toLattice: LatticeAnchor?
    public init(rowID: RowID, toRoom: RoomID? = nil, toLattice: LatticeAnchor? = nil)
}
public struct ProposeFrame: Sendable, Equatable {
    public let target: RowID; public let kind: ProposalKind; public let justification: String?
    public init(target: RowID, kind: ProposalKind, justification: String? = nil)
}
public struct AssociateFrame: Sendable, Equatable {
    public let a: RowID; public let b: RowID; public let weight: Double
    public init(a: RowID, b: RowID, weight: Double)
}
```
**Rust:** `pub struct CaptureFrame`, `RecallFrame`, `LearnFrame`,
`WithdrawFrame`, `MutateFrame`, `ExpungeFrame`, `ReanchorFrame`,
`ProposeFrame`, `AssociateFrame`, `pub enum MutationKind`, `LatticeAnchor`
mirror these in the `verbs` module.

#### `ProposalKind`

Typed taxonomy for a proposal's `kind`, replacing a stringly-typed field
(SPEC § 9). Round-trips through Codable as its `rawValue`; decode is total
(unknown strings → `.other`).

```swift
public enum ProposalKind: Sendable, Hashable, Codable {
    case byReferenceDrift, tournamentUpdate, miningPattern, disciplineViolation, mutateCandidate
    case amend, testPropose
    case other(String)
    public var rawValue: String { get }
    public init(rawValue: String)
}
```
**Rust:** `pub enum SchedulerProposalKind` (re-exported under the scheduler
prefix) with the same raw strings.

#### `VerbError`

The verb-dispatch error surface (SPEC § 6). Distinct from
`GeniusLocusKitError`, which passes through unchanged.

```swift
public enum VerbError: Error, Sendable, CustomStringConvertible {
    case underlyingEstateFailure(verb: String, reason: String)
    case notSupportedByEstate(verb: String)
    case rejectedByLexicon(verb: String, noun: String)
    case emptyReanchor(rowID: RowID)
    case expungeNotConfirmed(rowID: RowID)
    /// Raised when the LocusKit storage expunge succeeded but the cross-kit
    /// vector delete (Corpus.remove / VectorStore.deleteAllVectors) threw.
    /// Privacy contract: never swallow — a surviving vector embedding of content
    /// the user believed was irreversibly destroyed is a privacy breach.
    case crossKitVectorDeleteFailed(rowID: RowID, reason: String)
}
```
**Rust:** `pub enum VerbError` mirrors all six cases (`verbs/lexicon.rs`);
`CrossKitVectorDeleteFailed { row_id, reason }` is the Rust parallel.

#### `LatticeRegion` / `EstateRecallContribution`

The fan-out region and per-estate result (SPEC § 2, B-4).

```swift
public struct LatticeRegion: Sendable, Equatable {        // closed interval [low, high]
    public let low: Int; public let high: Int
    public init(low: Int, high: Int)
}
public struct EstateRecallContribution: Sendable {
    public let handle: EstateHandle; public let drawers: [Drawer]
}
```
**Rust:** `pub struct LatticeRegion`, `EstateRecallContribution` (`fan_out.rs`).
The Rust contribution carries `drawer_ids: Vec<String>` — the id projection of
the Swift `drawers: [Drawer]`. Both ports route the supplied `RecallFrame`
through each overlapping estate's live recall and return real recalled rows per
contribution; the conformance unit is the per-estate id SET (`fan_out_recall`
takes `(frame, region, now)` in Rust to thread the recall frame the Swift
`fanOutRecall(_:region:)` already takes).

#### `FederatedRecallResult` / `FederatedReadRefusalReason` / `IssueGrantResult`

The grant-gated read outcome and the refusal vocabulary (SPEC § 2, B-7),
plus the grant-issue result (B-8). The refusal reason is the payload of
`GeniusLocusKitError.crossEstateReadRefused`.

```swift
public struct FederatedRecallResult: Sendable {
    public let drawers: [Drawer]        // the SOURCE estate's rows only
    public let withheldBySensitivity: Int
    public let grant: Grant             // the authorizing grant (advisory scope)
    public let sourceHandle: EstateHandle; public let requesterHandle: EstateHandle
    public init(drawers: [Drawer], withheldBySensitivity: Int = 0, grant: Grant, sourceHandle: EstateHandle, requesterHandle: EstateHandle)
}
public enum FederatedReadRefusalReason: Sendable, Equatable {
    case noActiveGrant      // no active non-revoked grant names the requester
    case grantExpired       // matching grant exists but lifetime elapsed
    case grantRevoked       // grant was revoked (normally excluded from active())
    case budgetExhausted    // inferenceRemainingBudget <= 0.0; debit quantum = 0.01
    case custodyRefused     // mode-1: vault no longer holds key; mode-3: shares past threshold K; mode-4: decayed to floor 0
}
public struct IssueGrantResult: Sendable {
    public let grant: Grant; public let scopeKey: Data?   // non-nil for handed-over / decay-derived / time-aging custody
}
```
**Rust:** `FederatedRecallResult`, `FederatedReadRefusalReason`, and `IssueGrantResult`
are all present in the Rust port (`coordinator.rs` / `grants::grant`). See the
Swift/Rust Concordance — grant access-control surface section for the full
cross-port concordance.

#### Grant model: `Grant`, `GrantOptions`, `GrantScope`, `GrantLifetime`, `CustodyMode`, `ReSharePermission`, `DriftRate`, `GrantError`

The unit of sharing and its options (SPEC § 2, B-8). A `Grant` is signed,
audited, and persisted; `GrantOptions` is the issue-time input.

```swift
public struct Grant: Sendable, Codable, Equatable {
    public let id: UUID; public let granteeEstateID: UUID
    public let scope: GrantScope; public let contentLevel: Int
    public let lifetime: GrantLifetime; public let custodyMode: CustodyMode
    public let reSharePermission: ReSharePermission; public let inferenceRemainingBudget: Double
    public let issuedAt: Date; public let signature: Data
    public init(...); public var signingPayload: Data { get }
}
public struct GrantOptions: Sendable {
    public let granteeEstateID: UUID; public let scope: GrantScope
    public let custodyMode: CustodyMode; public let lifetime: GrantLifetime
    public let contentLevel: Int; public let reSharePermission: ReSharePermission
    public init(granteeEstateID: UUID, scope: GrantScope, custodyMode: CustodyMode = .mediated,
                lifetime: GrantLifetime = .permanent, contentLevel: Int = 0,
                reSharePermission: ReSharePermission = .none)
}
public enum GrantScope: Sendable, Codable, Equatable {
    case wholeEstate, wing(String), room(String), latticeSubtree(udcCode: String), singleRow(UUID)
}
public enum GrantLifetime: Sendable, Codable, Equatable {
    case permanent, until(Date), decayWindow(seconds: Int)
    // func expiry(issuedAt:) -> Date?
}
public enum CustodyMode: Sendable, Codable, Equatable {
    case mediated, handedOver                                   // production
    case decayDerived(threshold: Int, totalShares: Int, driftRatePerDay: DriftRate,
                      experimentalIPClearanceConfirmed: Bool)   // mode 3 (ENC-02, gated)
    case timeAging(DecayPolicy)                                 // mode 4 (software time-aging decay)
}
// Mode-4 decay policy. Effective content level decays as
//   effective = max(floor, round(contentLevel · 0.5^((now − startedAt) / halfLifeSeconds)))
// computed against the injected `now`. Persists in the decay_half_life,
// decay_started_at, decay_floor columns. The legacy "physicalDecay" token
// decodes into timeAging; a legacy row with no decay fields defaults to a
// 30-day half-life, startedAt = issuedAt, floor 0.
public struct DecayPolicy: Sendable, Codable, Equatable {
    public let halfLifeSeconds: Int; public let startedAt: Date; public let floor: Int
    public static let defaultHalfLifeSeconds: Int   // 30 days
    // func effectiveLevel(baseLevel: Int, now: Date) -> Int
}
public enum ReSharePermission: Sendable, Codable, Equatable { case none, withAudit, free }
public enum DriftRate: Sendable, Codable, Equatable { case slow, moderate, fast }
public enum GrantError: Error, Sendable, Equatable {
    case grantRevoked(id: UUID), grantExpired(id: UUID), experimentalModeNotActivated
    case grantNotFound(id: UUID), scopeKeyUnavailable(id: UUID), keyDecayed
}
```
**Rust:** `pub struct Grant`, `GrantOptions`, `pub enum GrantScope`,
`GrantLifetime`, `CustodyMode`, `ReSharePermission`, `DriftRate`,
`GrantError` mirror these in the `grants` module.

#### COW branching: `BranchHandle`, `BranchID`, `DrawerID`, `BranchStatus`, `MergeReport`, `BranchScore`, `DifferentialReport`

The branch surface (SPEC § 2, B-11; parent never modified, I-7). The handle
is a reference type; the kit tracks concrete branches internally.

```swift
public typealias BranchID = UUID
public typealias DrawerID = RowID
public protocol BranchHandle: Sendable, AnyObject {
    var branchID: BranchID { get }; var name: String { get }
    var status: BranchStatus { get }; var lineageDepth: Int { get }
    func capture(_ frame: CaptureFrame) async throws -> Drawer
    func recall(_ frame: RecallFrame) async throws -> [Drawer]
    func discard() async throws
    func compareToParent(over interval: DateInterval) async throws -> DifferentialReport
}
public enum BranchStatus: String, Sendable, Codable, Equatable { case active, won, merged, discarded }
public struct MergeReport: Sendable { public let merged, conflicts, skipped: [DrawerID]; public init(...) }
public struct BranchScore: Sendable { public let quality: Double; public let newDrawerCount: Int; public init(...) }
public struct DifferentialReport: Sendable {
    public let newInBranch, modifiedInBranch, withdrawnInBranch: [DrawerID]
    public let period: DateInterval; public init(...)
}
```
**Rust:** `pub trait BranchHandle`, `pub enum BranchStatus`, `pub struct
MergeReport`, `BranchScore`, `DifferentialReport` mirror these in the
`branch` module.

The coordinator also exposes a read accessor resolving a tracked branch by
id (branches are retained through every lifecycle state until the kit is
released, I-15):

```swift
public func branchHandle(for branchID: BranchID) -> (any BranchHandle)?
```
Returns nil when no branch with that id was derived by this kit instance.
Read-only — it neither mints nor mutates branch state; promotion / merge /
discard remain the write surface. Supports stateless callers (notably the
aria-mcp recipe surface, where a recipe's `run` and its human-confirmed
promotion arrive as two separate `tools/call` invocations against one
long-lived kit).
**Rust:** `EstateCoordinator::branch_handle_for(branch_id: BranchId) ->
Option<&EstateBranch>` (`branches.rs`).

#### Unified audit log: `UnifiedAuditLog`, `UnifiedAuditEntry`, `UnifiedHLC`, `UnifiedAuditValue`, `UnifiedAuditVerb`, `AuditTier`, `AuditChainReport`, `AuditChainVerifier`

The per-estate G-Set CRDT and its verifier (SPEC § 2, B-9/B-10; I-11/I-12).
`UnifiedHLC`/`UnifiedAuditLog` are local mirrors of the SubstrateLib shapes
(SPEC § 8).

```swift
public struct UnifiedAuditLog: Sendable, Codable, Equatable {
    public private(set) var entries: [UnifiedAuditEntryKey: UnifiedAuditEntry]
    // Count of entries rejected on THIS log's ingress (content-hash
    // mismatch) since construction. AUDIT-ALERT-RESTORE (2026-07-09):
    // monotonic, excluded from `==` (structural equality compares
    // `entries` only — see SPEC C-4/C-12). Rust mirror: `rejected_count()`.
    public private(set) var rejectedEntryCount: Int
    public init(entries: [UnifiedAuditEntry] = [])
    public var count: Int { get }; public var isEmpty: Bool { get }
    public mutating func add(_ entry: UnifiedAuditEntry)
    public mutating func add<S: Sequence>(contentsOf seq: S) where S.Element == UnifiedAuditEntry
    public mutating func merge(_ other: UnifiedAuditLog)
    public var orderedEntries: [UnifiedAuditEntry] { get }
    public func entries(tier: AuditTier) -> [UnifiedAuditEntry]
    public func entries(forRow rowID: UUID, tier: AuditTier) -> [UnifiedAuditEntry]
    public func entries(since cutoff: UnifiedHLC) -> [UnifiedAuditEntry]
    public func entries(asOf cutoff: UnifiedHLC) -> [UnifiedAuditEntry]
}
public struct UnifiedAuditEntry: Hashable, Sendable, Codable {
    public let id: [UInt8]                 // 32-byte SHA-256 content hash
    public let tier: AuditTier; public let hlc: UnifiedHLC; public let verb: UnifiedAuditVerb
    public let rowID: UUID; public let fieldPath: String
    public let beforeValue, afterValue: UnifiedAuditValue; public let originRowID: UUID?
    public init(tier:hlc:verb:rowID:fieldPath:beforeValue:afterValue:originRowID:)        // computes id
    public init(id:tier:hlc:verb:rowID:fieldPath:beforeValue:afterValue:originRowID:)     // trusts wire id
}
public struct UnifiedHLC: Hashable, Sendable, Codable, Comparable {
    public let physicalTime: Int64; public let logicalCount: Int32; public let nodeID: Int32
    public init(physicalTime:logicalCount:nodeID:); public static let zero: UnifiedHLC
    public var wireBytes: [UInt8] { get }
}
public enum UnifiedAuditValue: Hashable, Sendable, Codable { case null, bitmap(UInt64), integer(Int64), string(String), bytes([UInt8]) }
public enum UnifiedAuditVerb: String, Sendable, Codable, Hashable {
    case capture, recall, mutate, withdraw, expunge, reanchor, learn, propose, associate, migrate, dreamCompact
    case grantIssued, grantRevoked, keyDecayed, physicalKeyDecayed
}
public enum AuditTier: String, Sendable, Codable, Hashable, CaseIterable { case locus, rag }
public struct AuditChainReport: Sendable, Equatable {
    public let valid: Bool; public let entryCount: Int
    public let firstEntryAt, lastEntryAt: Date; public let firstBrokenAt: Date?
    public init(...)
}
public enum AuditChainVerifier { public static func verify(_ log: UnifiedAuditLog) -> AuditChainReport }
```
**Rust:** `pub struct UnifiedAuditLog`, `UnifiedAuditEntry`, `UnifiedHLC`,
`pub enum UnifiedAuditValue`, `UnifiedAuditVerb`, `AuditTier` mirror these in
the `audit` module; the chain verifier is the audit module's `verify`.

#### Migration: `ExternalCorpus`, `ExternalEntry`, `MigrationReport`, `MigrationVerification`, `MigrationDivergence`, `MigrationError`, `UnmappedConcept`, `MigrationWarning`, `ParallelCaptureMode`, `ParallelRunHandle`

The MemPalace migration API DTOs and the parallel-run handle (SPEC § 2,
B-14). `ParallelRunHandle` is an actor.

```swift
public struct ExternalEntry: Sendable, Codable, Equatable { public let id, content: String; public let tags: [String]; public init(...) }
public struct ExternalCorpus: Sendable, Codable, Equatable {
    public let name: String; public let entries: [ExternalEntry]; public init(...)
    // Construction: programmatic only — VaultKit's CorpusProjection ([NoteIR] → ExternalCorpus)
    // or inline (aria-mcp wire args). Export-JSON decode lives in VaultKit's ExchangeAdapter
    // (the data-movement contract Decision 1); the former load(from:) is retired.
    public func asRecallFrames() -> [LocusKit.RecallFrame]   // LocusKit content-match path; used by verifyMigration
    public func hybridRecall(via corpus: CorpusKit.Corpus, limit: Int = 10, now: Date) async throws -> [[CorpusKit.CorpusHit]]  // canonical Drawer-keyed hybrid BM25+vector results
}
public struct MigrationReport: Sendable, Codable {
    public let rowsByNoun: [String: Int]; public let unmappedConcepts: [UnmappedConcept]; public let warnings: [MigrationWarning]
    public init(...)
}
public enum MigrationVerification: Sendable { case identical, diverged([MigrationDivergence]) }
public struct MigrationDivergence: Sendable { public let entryID, reason: String; public init(...) }
public struct UnmappedConcept: Sendable, Codable { public let entryID, reason: String; public init(...) }
public struct MigrationWarning: Sendable, Codable { public let message: String; public init(...) }
public enum ParallelCaptureMode: Sendable, Codable { case writeToTarget, readFromSource, mirrorBoth }
public actor ParallelRunHandle {
    public let source, target: EstateHandle; public let mode: ParallelCaptureMode
    public func capture(_ frame: CaptureFrame) async throws -> Drawer    // throws MigrationError.parallelRunStopped after stop()
    public func stop()
}
public enum MigrationError: Error, Sendable, Equatable, CustomStringConvertible {
    case corpusUnreadable(reason: String), parallelRunStopped, targetEstateNotOpen
}
```
**Rust:** `pub struct ExternalCorpus` (+ `hybrid_recall`), `ExternalEntry`,
`MigrationReport`, `pub enum MigrationVerification`, `MigrationError`,
`pub struct ParallelRunHandle` mirror these in the `migration` module.

#### `GeniusLocusKitError`

The coordinator/lifecycle error surface (SPEC § 6). Carries the federated-
read refusal reason and the branch-promotion guards.

```swift
public enum GeniusLocusKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidManifest(key: String, detail: String)
    case estateNotOpen(estateUUID: UUID)
    case duplicateEstate(estateUUID: UUID)
    case underlyingEstateFailure(reason: String)
    case invalidLatticeRegion(low: Int, high: Int)
    case schedulerSignalNotRegistered(SignalID)
    case schedulerNotStarted(estateUUID: UUID)
    case branchNotTracked(branchID: BranchID)
    case invalidPromotionTarget(branchID: BranchID, expectedEstateUUID: UUID, actualEstateUUID: UUID)
    case crossEstateReadRefused(source: UUID, requester: UUID, reason: FederatedReadRefusalReason)
}
```
**Rust:** `pub enum GeniusLocusKitError` (`coordinator.rs`) covers the
lifecycle, fan-out, and federation-refusal (`CrossEstateReadRefused`) cases.
Scheduler, branch, and grant failures are surfaced through module-specific
error types (`VerbDispatchError`, `BranchError`) rather than this single enum.
Meaning: SPEC § 6.

### Tier 2 — broader surface (table of contents)

The following public types are part of the kit's surface, consumed by its
own pipeline and the cross-version conformance harness rather than another
package. They are public for intra-kit use, or are
Brain-layer machinery a consumer reaches only indirectly through the
`GeniusLocusKit` actor's methods. Recorded as a navigable index — name,
role, source file. Full signatures live in the cited file.

- **Standing-signal scheduler:** `StandingSignalScheduler` (actor, one per
  estate, owns the QueueKit serial lane — SPEC I-4/I-5), `SignalDispatcher`
  (the routing protocol the scheduler calls back through) —
  `Brain/StandingSignalScheduler.swift`. (Consumers drive it through the
  `GeniusLocusKit` signal methods in Tier 1, not directly.)
- **Signal model:** `SignalSpec`, `SignalTrigger`, `ConditionPredicate`,
  `SignalContext`, `SignalEmission`, `SignalReport`, `SignalState`,
  `SignalRouteOutcome`, `ConcurrencyPolicy`, `ResourceCostEstimate`,
  `DiagnosticReport`, `ProposalFrame`, `AssociationFrame`, `SignalID`,
  `SubscriptionID` — `Brain/SignalSchedule.swift`. (`SignalSpec`,
  `SignalEmission`, `SignalReport`, `SignalID`, `SubscriptionID` are
  threaded through the Tier-1 signal methods; the rest are the
  emission/report vocabulary.)
- **Fourteen standing signals (architecture § 11.2; inventory in
  GENIUSLOCUSKIT_SPEC.md):** `DreamingSignal`, `MaintenanceSignal`,
  `VectorSimilaritySignal`, `ContradictionScoutSignal`, `DecaySweepSignal`,
  `ByReferenceValiditySignal`, `EndOfDayTournamentSignal`,
  `TemporalCausalitySignal`, `SpanEncodeSignal`, `TrainingSignal`,
  `ConsolidationSignal`, `AnomalySweepSignal`, `ContradictionSweepSignal`,
  `FactExtractionSignal` — each `Brain/Signals/*.swift`; registered together
  by `registerDefaultStandingSignals` (Tier 1). Always-on names
  (`defaultStandingSignalNames`): `dreaming-daemon`, `vector-similarity`,
  `contradiction-scout`, `anomaly-flag-sweep`, `span-encode`,
  `fact-extraction`. Preference-gated names
  (`preferenceGatedStandingSignalNames`, registered only when the host passes
  a live cycle because the estate preference is on): `consolidation-sweep`
  (`consolidation`), `contradiction-sweep` (`contradiction_sweep`),
  `maintenance-daemon`, `decay-sweep`, `by-reference-validity`
  (`maintenance`), `temporal-causality-fold`, `training-daemon`,
  `end-of-day-tournament` (`adaptive_recall`).
  `VectorSimilaritySignal.spec(vectorStore:modelID:proximityThreshold:probeLimit:corpus:)` —
  production factory; captures `VectorStore` (and the estate's `Corpus`
  when registered), scans row embeddings via `findNearest` on each
  5-minute pass across two lanes — Drawer-keyed rows under `modelID`,
  and Corpus-derived rows already keyed by Drawer id (no chunk-owner map) —
  and emits `AssociateFrames` carrying Drawer ids for pairs within Hamming
  threshold (default 64). `probeLimit` (default 50 via `defaultProbeLimit`)
  controls how many item IDs are sampled from the VectorStore on each pass;
  the probe window is one-sided (recency-sampled probes, whole-estate neighbor
  search). Rust: `probe_limit: usize` (`DEFAULT_PROBE_LIMIT = 50`).
- **Recall cold-path signals:** `GraphCache`,
  `PreferenceStore` — public protocols defined in `GeniusLocusKit.swift`.
  Registered via `registerGraphCache(_:for:)` and `registerPreferenceStore(_:for:)`.
  Populate the `graph` and `preference` buffer columns in `RecallDirector`
  step 5.7 via candidate-frontier lookups (no synchronous estate-wide analytics).
- **Matrix tier (architecture § 12):** `MatrixTier`,
  `MatrixFieldCell`, `MatrixValueCoord`, `MatrixCoOccurKey`,
  `MatrixTemporalKey` (the F/C/O/T coordinate model), `MatrixCalibrationCurve`/
  `MatrixCalibrationBucket`/`MatrixCalibrationOutcome`/`MatrixCalibrationRegistry`,
  `MatrixNMF`/`MatrixNMFFactorization`, `MatrixSnapshot`/`MatrixPersistenceBackend`/
  `MatrixPersistenceMode`/`MatrixPersistenceError` — `Matrix/*.swift`.
- **Training daemon (architecture § 11):** `TrainingDaemon`,
  `TrainingThresholdGate`, `TrainingThresholdDecision`, `TrainingDaemonTick`,
  `TrainingDaemonReport`, `EnrichmentPipeline`, `EnrichmentPassResult` —
  `Training/*.swift`.
- **Audit projection / recovery:** `AuditProjectionFold`, `UnifiedProjection`
  (+ nested `Key`, the common-word measured hit), `UnifiedRowProjection`,
  `AuditRecovery`, `AuditRecoveryResult`, `AuditRecoveryDivergence`
  (+ nested `RowMismatch`), `UnifiedAuditEntryKey` — `Audit/*.swift`.
- **Grant custody internals:** `GrantStore` (actor, the `grants` table over
  the estate's storage; the table carries the the forward-compatible ext-slot contract `ext` JSON nullable
  forward-compat slot — the #11 custody-payload slot, inert in 1.0 and the
  migration-free home for any future federation/encryption custody metadata),
  `StoredGrant`, `ScopeKeyVault` (actor, mode-1 key
  custody and cryptographic clawback) — `Grants/GrantStore.swift`,
  `Grants/ScopeKeyVault.swift`. (The Lagrange-decay key math —
  `DecayFieldElement`, `LagrangeDecayKey`, `DecayShareProvider`,
  `ReferenceDecayShareProvider` — is `internal`, not public, in
  `Grants/LagrangeDecayKey.swift`.)
- **Lexicon conformance:** `AriaLexiconConformance` (the data-only
  verb↔`AriaLexiconLib.Verb` mapping and the § 7.2 acceptance-matrix
  helpers — SPEC I-13) — `Verbs/AriaLexiconConformance.swift`.

## § 3 — Public functions

The principal Tier-1 entry points are the `GeniusLocusKit` actor methods
(§ 2): the lifecycle trio, the nine verbs, `fanOutRecall`/`federatedRecall`,
the grant pair, the audit trio, the four branch methods, the signal API,
and the two migration verbs. Standalone helpers:

```swift
LatticeAnchor.udc(_ code: String) -> LatticeAnchor      // re-exported from LocusKit
AuditChainVerifier.verify(_ log: UnifiedAuditLog) -> AuditChainReport
AuditProjectionFold.project(_ log: UnifiedAuditLog) -> UnifiedProjection         // Tier 2
MatrixTier.rebuild(from log: UnifiedAuditLog) -> MatrixTier                       // Tier 2
MatrixTier.rebuildTemporal(from log: UnifiedAuditLog) -> MatrixTier               // Tier 2 — T matrix
MatrixTier.fullRebuild(from log: UnifiedAuditLog) -> MatrixTier                   // Tier 2 — both passes (F/O/C + T)
TrainingThresholdGate.transitionCount(in log: UnifiedAuditLog) -> Int            // Tier 2
GeniusLocusKit.defaultStandingSignalNames -> [String]                            // static — the six always-on signals
GeniusLocusKit.preferenceGatedStandingSignalNames -> [String]                    // static — the eight preference-gated signals
```

### Rust twins — default signal set, adaptive-recall cycles, similar recall

```rust
// brain/signals/default_set.rs
pub fn default_standing_signal_names() -> [&'static str; 6];            // mirrors defaultStandingSignalNames
pub fn preference_gated_standing_signal_names() -> [&'static str; 8];   // mirrors preferenceGatedStandingSignalNames
// Every Option closure pushes its signal spec only when Some; the resident passes
// Some only while the named estate preference is on (absent = on). None for the
// first four falls back to the diagnostic no-op default_spec().
pub fn default_standing_signal_specs(
    vector_store: Arc<VectorStore>,
    model_id: impl Into<String>,
    corpus: Option<Arc<corpus_kit::CorpusContentEngine>>,
    hunt_cycle: Option<Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync>>,
    anomaly_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    span_encode_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    fact_extraction_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    consolidation_cycle: Option<Arc<dyn Fn() -> Result<ConsolidationSweepReport, String> + Send + Sync>>,       // `consolidation`
    contradiction_sweep_cycle: Option<Arc<dyn Fn() -> Result<ConflictTunnelProposalReport, String> + Send + Sync>>, // `contradiction_sweep`
    maintenance_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,   // `maintenance` — tombstone grace
    decay_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,         // `maintenance` — quiet-row decay
    by_reference_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,  // `maintenance` — by-reference drift
    fold_cycle: Option<Arc<dyn Fn() -> Result<(), String> + Send + Sync>>,           // `adaptive_recall` — run_temporal_causality_fold
    training_cycle: Option<Arc<dyn Fn() -> Result<String, String> + Send + Sync>>,   // `adaptive_recall` — run_training_tick
    tournament_cycle: Option<Arc<dyn Fn() -> Result<TournamentReport, String> + Send + Sync>>, // `adaptive_recall` — end_of_day_tournament
) -> Vec<SignalSpec>;

// coordinator.rs — EstateCoordinator
pub fn run_temporal_causality_fold(&mut self, handle: &EstateHandle, now_millis: i64) -> Result<(), VerbDispatchError>;
pub fn run_training_tick(&mut self, handle: &EstateHandle, now_millis: i64) -> Result<String, VerbDispatchError>;
pub fn end_of_day_tournament(&self, handle: &EstateHandle, now_millis: i64) -> Result<TournamentReport, VerbDispatchError>;
// brain/end_of_day_tournament.rs
pub struct TournamentReport { pub contests: usize, pub rated_drawers: usize }

// similar_recall.rs — EstateCoordinator; twin of GeniusLocusKit.similarRecall
pub fn similar_recall(&self, handle: &EstateHandle, query: &str, limit: usize, filter: Filter, _now: i64)
    -> Result<Vec<RecallHit>, VerbDispatchError>;
```

## § 4 — Errors

The behavioral meaning of each case is in SPEC § 6. GLK has five error
types: the coordinator surface, the verb surface, and three additive
sub-surfaces (declared standalone because Swift cannot add enum cases by
extension).

```swift
public enum GeniusLocusKitError: Error, Sendable, Equatable, CustomStringConvertible { /* § 2 */ }
public enum VerbError: Error, Sendable, CustomStringConvertible { /* § 2 */ }
public enum GrantError: Error, Sendable, Equatable { /* § 2 */ }
public enum MigrationError: Error, Sendable, Equatable, CustomStringConvertible { /* § 2 */ }
public enum MatrixPersistenceError: Error, Equatable, Sendable    // snapshot load/save (Tier 2)
```
**Rust:** `pub enum GeniusLocusKitError`, `VerbError`, `GrantError`,
`MigrationError`, `MatrixPersistenceError`, and `SchedulerError` mirror the
full error surface. Meaning: SPEC § 6.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/GeniusLocusKit
```

(Target: `GeniusLocusKitTests`.)

**Rust:**

```
cargo test -p genius-locus-kit
```

(Targets include `verb_parity`, `audit_parity`, `scheduler_parity`,
`standing_signals_parity`, `matrix_parity`, `training_parity`,
`composition_conformance_tests`, and `theorems_tests` — the shared `glref`
vectors; SPEC § 8, C-12.)

## § 6 — Examples

```swift
import GeniusLocusKit
import LocusKit
import PersistenceKit

let kit = GeniusLocusKit()
let storage = try await SQLiteStorage(/* … */)          // caller builds the backend
let handle = try await kit.open(storage: storage,
                                owner: OwnerCredentials(ownerIdentifier: "icloud:user"))

// One verb applied to one estate (SPEC B-2).
let drawer = try await kit.capture(handle, CaptureFrame(
    content: "Carbon chemistry note.", channel: .typed, room: "chemistry",
    latticeAnchor: .udc("547"), addedBy: "user", embeddingModelID: "text-embedding-3-small"))
let rows = try await kit.recall(handle, RecallFrame(filterChain: [.inRoom("chemistry")]))

// Brain layer: register the six v1 signals and advance the serial lane (SPEC B-5).
// VectorSimilaritySignal requires an injected VectorStore.
let now = Date()
_ = try await kit.registerDefaultStandingSignals(in: handle, vectorStore: vectorStore, now: now)
try await kit.signalTick(in: handle, now: now)          // deterministic, FIFO, single lane (I-5)

// Verify the unified audit chain (SPEC B-10).
let report = try await kit.verifyAuditChain(handle)     // valid == true on a clean chain

// Grant-gated federated read between two locally-open estates (SPEC B-7).
let other = try await kit.open(storage: otherStorage, owner: OwnerCredentials(ownerIdentifier: "icloud:user"))
_ = try await kit.issueGrant(handle, GrantOptions(granteeEstateID: other.estateUUID, scope: .wing("chemistry")), now: now)
let federated = try await kit.federatedRecall(RecallFrame(filterChain: [.inWing("chemistry")]),
                                              from: handle, requestedBy: other, now: now)  // refuses absent a grant
```

---

## Swift/Rust Concordance — matrix rebuild surface

Both rebuild entry points exist in both languages. The Rust crate
depends on `substrate-ml` to access `temporal_causality_fold::fold`
(mirrors the Swift `import SubstrateML`, per
the temporal-matrix cadence).

| Swift | Rust | Notes |
|---|---|---|
| `MatrixTier.rebuild(from: UnifiedAuditLog) -> MatrixTier` | `MatrixTier::rebuild(log: &UnifiedAuditLog) -> MatrixTier` | Populates F, C, O; mirrors HLC-ordered bundle replay |
| `MatrixTier.rebuildTemporal(from: UnifiedAuditLog) -> MatrixTier` | `MatrixTier::rebuild_temporal(log: &UnifiedAuditLog) -> MatrixTier` | Populates T + temporal_watermark_hlc; delegates to TemporalCausalityFold |
| `MatrixTier.temporalWatermarkHLC: HLC` | `MatrixTier::temporal_watermark_hlc: HLC` | Persisted in both ports; Swift uses `decodeIfPresent ?? .zero`, Rust uses 16-byte trailer with fallback to `HLC::ZERO` for old snapshots |

**Conformance:** `matrix_parity` test target exercises both `rebuild` and
`rebuild_temporal` with the same canonical fixtures as the Swift `MatrixTierTests`
and `StandingSignalsTests`. The four new `rebuild_temporal_*` tests assert:
- T-matrix populated at correct lag bucket for intra-window pairs.
- `temporal_watermark_hlc` advances to the last entry's HLC.
- Idempotence: same log → same cells on second rebuild.
- Out-of-window entries produce no T pairs.
- Null after-value contributes no coordinate (watermark still advances).
- Non-capture/expunge verbs are filtered.

---

## Swift/Rust Concordance — scored recall type system

The twelve types below are present in the Rust port. They live in
`packages/kits/GeniusLocusKit/rust/src/recall.rs` and are re-exported from
the crate root. The Swift originals are in
`Sources/GeniusLocusKit/RecallDirector/`.

| Swift type | Rust type | Rust location | Notes |
|---|---|---|---|
| `GLKRecallMode` | `GLKRecallMode` | `recall::GLKRecallMode` | 5 variants (incl. `.nodeTreeNative` — see that concordance section below); `raw_value()` matches Swift rawValue strings |
| `GLKRecallScoring` | `GLKRecallScoring` | `recall::GLKRecallScoring` | 4 variants: `raw`, `rrf`, `matrixAware`, `discriminative` (M3) |
| `RecallEvidencePath` | `RecallEvidencePath` | `recall::RecallEvidencePath` | 10 variants; `raw_value()` matches Swift |
| `RecallFallbackPolicy` | `RecallFallbackPolicy` | `recall::RecallFallbackPolicy` | 2 variants |
| `RecallScoreVector` | `RecallScoreVector` | `recall::RecallScoreVector` | All 10 fields present; `locus(_:)` → `locus(v: f32)` factory; `ZERO` constant |
| `RecallWeights` | `RecallWeights` | `recall::RecallWeights` | 7 fields; `uniform` → `UNIFORM` constant |
| `RecallPlan` | `RecallPlan` | `recall::RecallPlan` | `effectiveMode` → `effective_mode`; `frontierK` → `frontier_k` |
| `RecallHit` | `RecallHit` | `recall::RecallHit` | `drawer: Drawer?` → `drawer: Option<Drawer>`; `sources: Set<RecallEvidencePath>` → `sources: Vec<RecallEvidencePath>`; `spanHit: SpanRerankHit?` → `span_hit: Option<SpanRerankHit>` (2.21.0: best span index, `bestSpanStart`/`bestSpanEnd` word bounds and cosine when the span rerank stage scored the hit; nil otherwise; 3.2.0 adds `bm25Rank` / `bm25_rank`, the item's 1-based lexical rank in the head the stage read) |
| `SpanRerankEncoding` / `SpanVectorReading` | `SpanRerankEncoding`, `SpanVectorReading` (protocols) | `span_rerank::SpanRerankEncoding`, `span_rerank::SpanVectorReading` (traits) | 2.21.0 seams the lifecycle registers: `modelID` + `encodeQuery(_:) async throws -> [Float]` → `model_id()` + `encode_query(&str) -> Result<Vec<f32>, SpanRerankError>`; `spanVectors(itemIDs:modelID:) async throws -> [String: [SpanRerankVector]]` → `span_vectors(&[String], &str) -> Result<HashMap<String, Vec<SpanRerankVector>>, SpanRerankError>` |
| `SpanRerankVector` / `SpanRerankInput` / `SpanRerankHit` | same | `span_rerank::{SpanRerankVector, SpanRerankInput, SpanRerankHit}` | 2.21.0 value types: `index: UInt32, int8: [Int8], scale: Float, startWord, endWord` → `index: u32, int8: Vec<i8>, scale: f32, start_word, end_word`; `itemID, bm25Rank` → `item_id, bm25_rank`; `itemID, bestSpanIndex: UInt32, bestSpanStart, bestSpanEnd, cosine: Float, bm25Rank: Int` → snake_case twins (3.2.0 adds `bm25Rank` / `bm25_rank`) |
| `SpanRerankStage` constants | `SpanRerankStage.lexicalDepth` (1000), `.defaultEncoderHead` (30), `.rrfK` (60) | `span_rerank::{LEXICAL_DEPTH, DEFAULT_ENCODER_HEAD, RRF_K}` | 2.21.0 |
| `RecallShape` additions | `RecallShape.defaultWeight(for:)`, `SignalKey.encoder` (`signal:encoder`), `DenseSignal.encoder` (`dense:minilm-l6-v2-w60`), `DenseSignal.key(forModelID:)`; `DenseSignal.randomIndexing` / `.all` only under `MOOTX01_WHOLE_RECORD_DENSE` (3.3.0); `DenseSignal.ppmi/lsa/nmf/fdc` only under `MOOTX01_DENSE_FAMILIES` | `RecallShape::default_weight`, `::weight_or_default`, `SIGNAL_ENCODER`, `DENSE_ENCODER`, `dense_key_for_model`; `DENSE_PPMI/LSA/NMF/FDC` only under `dense-families` | 2.21.0; `weight(for:)` / `weight` fall back to the default (0 for `signal:vector`, 1.0 otherwise) |
| `GLKRecallRequest` | `GLKRecallRequest` | `recall::GLKRecallRequest` | All five behaviour-selecting parameters (`mode`, `scoring`, `limit`, `fallback`, `origin`) are required constructor arguments in both ports — no defaults, no overriding builders. The nil-defaulted optionals (`queryText`/`query_text`, `traceLimit`/`trace_limit`, `recallShape`/`recall_shape`, `frontierK`/`frontier_k`, `anomalousFilter`/`anomalous_filter`) stay optional and are set via defaulted init params (Swift) or chained builder methods (Rust). Optional `recallShape`/`recall_shape` carries the signed per-lane fusion steering (6b-modifiers). Optional `frontierK`/`frontier_k` is a per-call candidate-pool depth override with highest precedence (request > shape > engine formula), clamped to `[64, 256]`; `nil`/`None` defers to shape or engine. Optional `anomalousFilter`/`anomalous_filter` (Swift `Bool?` / Rust `Option<bool>`) is an admission gate applied BEFORE scoring: `nil` = passthrough, `true` = anomalous-only, `false` = exclude-anomalous (§11.18). Rust builder: `with_anomalous_filter(filter: bool) -> Self`. `subSpanScoring`/`sub_span_scoring` (Swift `GLKSubSpanScoring` `.off`/`.on`, Rust `GLKSubSpanScoring::{Off, On}`) switches the unionBest step 5.8 sub-span dense refinement; the request default is `.off`/`Off` (Swift defaulted init param, Rust `new()`), every internal caller sets it explicitly, and the ARIA surface does not expose it. Rust builder: `with_sub_span_scoring(GLKSubSpanScoring) -> Self`. `rerankDirective`/`rerank_directive` (3.17.0; Swift `RerankDirective?` defaulted to nil, Rust `Option<RerankDirective>` set by `with_rerank_directive`) is the cross-encoder directive (`CROSSENCODER_INTERFACE.md`); nil and `bypass` are byte-identical to no field. |
| `RecallShape` | `RecallShape` | `recall::RecallShape` | Signed per-lane fusion weights (`laneWeights`/`lane_weights`, keys `locus`/`bm25`/`hamming`, the aggregate `dense`, `dense:<encoder modelID>` for the span stage and, under `MOOTX01_WHOLE_RECORD_DENSE` (3.3.0), `dense:<modelID>` per held whole-record signal with `antiSimilarLanes` and `floatMetric`, PLUS the matrix/graph/preference columns `fieldFit`/`coOccurrence`/`temporal`/`graph`/`preference`, PLUS the `signal:*` column-budget keys `signal:locus`/`signal:bm25`/`signal:vector`/`signal:fieldFit`/`signal:matrix`/`signal:graph`/`signal:preference`/`signal:agreement` (`SignalKey.*` / `SIGNAL_*`; 0 excludes the column AND redistributes its budget via `RecallSignalBudget`); missing key ⇒ 1.0) + `antiSimilarLanes`/`anti_similar_lanes` (dense lane keys that invert objective to FARTHEST) + optional clamped `frontierK`/`frontier_k`. `w>0` forward, `w==0` exclude, `w<0` suppress (demote). Steers the Hybrid + CorpusOnly RRF lanes AND the UnionBest lane (per-signal `dense:<modelID>` weights steer the dense consensus fold; `locus`/`bm25`/`hamming`/`dense` AND the five matrix/graph/preference keys steer the UnionBest `.matrixAware` weighted columns — the matrix keys are a no-op under `.raw`/`.rrf`, where those columns are dark). A `dense:<modelID>` key in `antiSimilarLanes` queries CorpusKit `floatFarthestPerSignal` for that lane — the dissimilar candidates become its voters (DISTINCT from a negative weight; the two compose). nil/absent ⇒ uniform nearest fusion (byte-identical to pre-6b-modifiers) |
| `GLKRecallResult` | `GLKRecallResult` | `recall::GLKRecallResult` | `.drawers()` convenience accessor; `withheldBySensitivity`/`withheld_by_sensitivity` is the count of primary rows excluded only by LocusKit's default sensitivity ceiling (zero when the request contains an explicit sensitivity filter; excluded rows never cross the LocusKit boundary); `degradedStages`/`degraded_stages` carries named stage failures, incl. the four `locus.*` recall internal-read stages merged from `RecallStream` (SPEC § degradedStages); `queryLatticeAnchor`/`query_lattice_anchor` — pre-computed §8.3 anchor, derived exactly once in the recall director (M4 single-derivation; `nil`/`None` for locusOnly and unanchorable queries) `crossEncoder`/`cross_encoder` (3.17.0; `CrossEncoderReport?` / `Option<CrossEncoderReport>`) reports what the cross-encoder stage did, nil when the request carried no directive; Swift `replacing(request:hits:degradedStages:withheldBySensitivity:crossEncoder:)`. |
| `FederatedRecallResult` | `FederatedRecallResult` | `coordinator::FederatedRecallResult` | `withheldBySensitivity`/`withheld_by_sensitivity` counts only primary candidates from the one source estate whose active grant, content level, and scope authorized the request, then applies the caller frame's default sensitivity ceiling; it never counts another or unauthorized estate. |
| `VagueRecallResult` | `VagueRecallResult` | `brain::consolidation_cycle::VagueRecallResult` | `withheldBySensitivity`/`withheld_by_sensitivity` counts only hop-1 primary vague candidates excluded by vague recall's default elevated sensitivity ceiling; hop-2 hydrated constituents do not contribute. |
| `RecallUnionProfile` | `RecallUnionProfile` | `recall::RecallUnionProfile` | 6 fields; `ZERO` constant |
| (implicit) `RecallLane` | `RecallLane` | `recall::RecallLane` | Not a separate Swift file; distilled from `RecallCandidateBuffer` source-bit constants |

**Coordinator entry point:**

| Swift | Rust |
|---|---|
| `func recall(_ handle: EstateHandle, _ request: GLKRecallRequest) async throws -> GLKRecallResult` | `fn recall_scored(&self, handle: &EstateHandle, request: GLKRecallRequest, now: i64) -> Result<GLKRecallResult, VerbDispatchError>` |

**Recall drop semantics (frame-faithful — GLK SPEC B-16):** the corpus/vector
hydration join honors the recall frame's state filter on BOTH ports. A
BM25/vector candidate the frame excludes (withdrawn under the default
`.currentlyBelieve`; tombstoned always) is DROPPED — never surfaced as a
`RecallHit` with `drawer == nil` — and SURFACES under a `.usedToBelieve` frame.
Rust derives the hydration `drawer_index` from a frame-filtered
`estate.recall(frame)` scan (`.filter(drawer_index.contains_key)`); Swift builds
the equivalent index via the LocusKit frame-aware by-id load
`getDrawers(ids:matchingFrame:hydrationLevel:)`. The drop is gated on by-id load
success so a not-yet-joined active drawer is degraded, not dropped.

**Scoring notes:**

The Rust `recall_scored` implements the locusOnly, hybrid, and matrixAware
scoring pipelines. BM25 and vector sub-lanes return empty candidate sets
until SynapseKit/CorpusKit are wired to the coordinator (a follow-up).

**`.rrf` scoring:** `score = 1 / (k + rank + 1)`, `k = 60`, tie-break by
`id` ascending. Matches Swift exactly.

**`.matrixAware` scoring (UnionBest mode):** Full Swift-parity weighted
pipeline. Consumes the registered `MatrixTier`
for the estate. Steps: query_coords from top locus candidate bitmap fields
(adjective, operational, provenance); fieldFit via `MatrixTier::correlation()`
per set bit; coOccurrence and temporal via `MatrixTier` lookups; all columns
min-max normalised (NaN→0, all-zero→0.0, uniform→0.5, varying→min-max);
`RecallUnionProfile::compute()` → adaptive weights via `RecallWeights::adaptive()`;
final score formula matches Swift step 9, with every weight read from the
`RecallSignalBudget` resolved at step 8.5 (locus+bm25+vector+dense+fieldFit+
matrix*(coOccurrence+temporal)*0.5+graph+preference+
budget.agreement*0.05*popcount(sourceMask)/5).
No tier registered → all matrix columns zero (documented fallback matching Swift).
Parity is confirmed: a seeded tier produces an order different from RRF; the
no-tier fallback zeroes all matrix columns; the dense column is consumed.

**aria-mcp wiring follow-up:**

The aria-mcp Rust `run_memory_search` function continues to use
`coordinator.recall` (plain path) and its `scoring` parameter is not yet
wired to `recall_scored`. Wiring the `scoring` arg through `recall_scored`
remains a follow-up.

---

## Swift/Rust Concordance — grant access-control surface

The grant subsystem is present in the Rust port. The Rust types live in
`packages/kits/GeniusLocusKit/rust/src/grants/` and are re-exported from
the crate root. The Swift originals are in
`Sources/GeniusLocusKit/Grants/`.

### Core grant types

| Swift type | Rust type | Rust module | Notes |
|---|---|---|---|
| `GrantScope` | `GrantScope` | `grants::grant` | 5 variants; `signing_token()` byte-identical to Swift `signingToken` |
| `GrantLifetime` | `GrantLifetime` | `grants::grant` | 3 variants; `Permanent`, `Until(f64)`, `DecayWindow { seconds: i64 }` |
| `CustodyMode` | `CustodyMode` | `grants::grant` | 4 variants; Rust `DecayDerived` carries same 4 fields as Swift; `TimeAging(DecayPolicy)` is mode 4 — `DecayPolicy { half_life_seconds: i64, started_at: f64, floor: i64 }`, `effective_level()` bit-identical to Swift `effectiveLevel` |
| `ReSharePermission` | `ReSharePermission` | `grants::grant` | 3 variants; `signing_token()` byte-identical |
| `DriftRate` | `DriftRate` | `grants::grant` | 3 variants: `Slow`, `Moderate`, `Fast` |
| `GrantOptions` | `GrantOptions` | `grants::grant` | All 6 fields present; field naming snake_case |
| `Grant` | `Grant` | `grants::grant` | `issued_at: f64` Apple reference seconds (matching `Date.timeIntervalSinceReferenceDate`) |
| `IssueGrantResult` | `IssueGrantResult` | `grants::grant` | `scopeKey: Data?` → `scope_key: Option<Vec<u8>>`; Debug manually implemented — `scope_key` field is redacted as `"<REDACTED>"` |
| `StoredGrant` | `StoredGrant` | `grants::grant` | `revokedAt: Date?` → `revoked_at: Option<f64>` Apple ref seconds |
| `GrantError` | `GrantError` | `grants::grant` | 7 variants, all with matching discriminants |

### Crypto primitive concordance

| Swift | Rust | Notes |
|---|---|---|
| `SubstrateKernel.SHA256.hash([UInt8])` | `substrate_kernel::sha256::hash(&[u8]) -> [u8;32]` | FIPS 180-4, in-repo, no CryptoKit |
| `SubstrateKernel.GrantHKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)` | `substrate_kernel::hkdf::derive_key(ikm:&[u8], salt:&str, info:&[u8], output_byte_count:usize)` | RFC 5869 HKDF-SHA256, in-repo |
| Fixed salt `"mootx01.grant.scope-key.v1"` | Same literal (`GRANT_SALT` constant) | Used for all grant scope-key and session-key derivations |
| `LagrangeDecayKey.key(fromSecret:) -> [UInt8]` | `LagrangeDecayKey::key_from_secret(secret: &DecayFieldElement) -> [u8;32]` | SHA-256 of the GF(p) secret's big-endian bytes |
| `LagrangeDecayKey.reconstruct(threshold:provider:now:) -> [UInt8]` | `LagrangeDecayKey::reconstruct(threshold:usize, provider:&dyn DecayShareProvider, now:f64) -> Result<[u8;32], GrantError>` | Lagrange at x=0 over GF(2^256-189); byte-identical |
| `LagrangeDecayKey.interpolateConstantTerm(points:) -> DecayFieldElement` | `LagrangeDecayKey::interpolate_constant_term(points:&[DecaySharePoint]) -> DecayFieldElement` | Schoolbook 4×4-limb GF(p) multiply, Fermat inverse |

### GF(p) field arithmetic concordance

Prime `p = 2^256 − 189` (largest prime below 2^256).
Limb layout: little-endian `[u64; 4]`, `limbs[0]` least significant.

| Swift | Rust | Notes |
|---|---|---|
| `DecayFieldElement` | `DecayFieldElement` | Identical limb layout and prime |
| `init(reducingBigEndian:)` | `DecayFieldElement::from_big_endian(&[u8])` | 32-byte BE input, reduces mod p |
| `bigEndianBytes()` | `DecayFieldElement::to_big_endian() -> [u8;32]` | 32 bytes, big-endian |
| `adding(_:)` | `add(&self, other: &DecayFieldElement)` | Carry-fold via 189 |
| `subtracting(_:)` | `sub(&self, other: &DecayFieldElement)` | Borrows p when needed |
| `negated()` | `neg(&self)` | `0 - self` |
| `multiplying(_:)` | `mul(&self, other: &DecayFieldElement)` | Schoolbook 4×4-limb, 8-limb product, then reduce |
| `inverse()` | `inv(&self)` | Fermat: `a^(p-2)` via 256-bit square-and-multiply |
| `DecaySharePoint` | `DecaySharePoint` | `x: DecayFieldElement`, `y: DecayFieldElement` |
| `ReferenceDecayShareProvider` | `ReferenceDecayShareProvider` | Seeded from SHA-256 coefficient derivation, same Horner evaluation |

### ScopeKeyVault / GrantStore concordance

| Swift | Rust | Notes |
|---|---|---|
| `ScopeKeyVault` actor | `ScopeKeyVault` struct | No async in Rust; coordinator serialises access; mediated keys stored as `Zeroizing<[u8;32]>` — zeroed on drop and revoke |
| `issue(grant:identityKeyRawBytes:[UInt8])` | `issue(grant:&Grant, identity_key_raw:&[u8]) -> Result<Option<Vec<u8>>, GrantError>` | Same 3-mode dispatch |
| `access(grant:now:)` | `access(grant:&Grant, now:f64) -> Result<Vec<u8>, GrantError>` | Session-key HKDF; `now` used for expiry only — NOT included in session info bytes |
| `revoke(grantID:)` | `revoke(grant_id:Uuid)` | Drops mediated key (Zeroizing ensures zero on remove), inserts into revoked set |
| `holdsScopeKey(for:)` | `holds_scope_key(id:Uuid) -> bool` | |
| `GrantStore` actor | `GrantStore` struct | In-memory HashMap; Swift side persists to SQLite |
| `insert(_:)` | `insert(grant:Grant)` | |
| `get(id:)` | `get(id:Uuid) -> Option<&StoredGrant>` | |
| `revoke(id:at:)` | `revoke(id:Uuid, now:f64) -> Result<(), GrantError>` | |
| `active(at:)` | `active(now:f64) -> Vec<&StoredGrant>` | |

### HKDF info-string format (cross-port byte-identity requirement)

These exact UTF-8 strings are the HKDF `info` parameter for each derivation.
Any deviation produces a completely different key. Both Swift and Rust use
uppercase hyphenated UUID strings (`UUID.uuidString` / `.to_string().to_uppercase()`).

| Derivation | info bytes | Swift source |
|---|---|---|
| Mode-1 scope key (mediated) | `"scope\|{grantID.uuidString}"` | `ScopeKeyVault.info(grantID:grantee:nil)` |
| Mode-2 scope key (handed-over) | `"scope\|{grantID.uuidString}\|{granteeEstateID.uuidString}"` | `ScopeKeyVault.info(grantID:grantee:granteeEstateID)` |
| Session key (mode-1 access) | `"session\|{grant.id.uuidString}"` | `ScopeKeyVault.access(grant:now:)` info line |

**Mode-3 seed:** `Data(identityKeyRawBytes) + Data(grant.id.uuidString.utf8)` (68 bytes for a 32-byte key + 36-char UUID string). Passed **directly** to `ReferenceDecayShareProvider` — NOT hashed. The provider hashes it internally when deriving coefficients.

**`EstateEncryptionConfig` (PersistenceKit):** Debug manually implemented — `key` field is redacted as `"<REDACTED>"`. Protects against accidental key exposure in log output.

### EstateCoordinator grant entry points

| Swift | Rust |
|---|---|
| `func issueGrant(_ handle: EstateHandle, _ options: GrantOptions, now: Date) async throws -> IssueGrantResult` | `fn issue_grant(&mut self, handle:&EstateHandle, options:GrantOptions, identity_key_raw:&[u8], now:f64) -> Result<IssueGrantResult, GrantError>` |
| `func revokeGrant(_ handle: EstateHandle, grantID: UUID, now: Date) async throws` | `fn revoke_grant(&mut self, handle:&EstateHandle, grant_id:Uuid, now:f64) -> Result<(), GrantError>` |
| `func grantStore(for handle: EstateHandle) async -> GrantStore?` | `fn grant_store(&self, handle:&EstateHandle) -> Option<&GrantStore>` |
| `func scopeVault(for handle: EstateHandle) async -> ScopeKeyVault?` | `fn scope_vault(&self, handle:&EstateHandle) -> Option<&ScopeKeyVault>` |

**Deviation note:** The Rust `issue_grant` takes `identity_key_raw: &[u8]` (raw key bytes)
instead of a `Curve25519.Signing.PrivateKey` type. The Swift `VerbSurface.swift` caller
extracts `.rawRepresentation` before delegating to the vault; the Rust coordinator
receives raw bytes directly, with no CryptoKit dependency.

**Conformance gate:** `tests/grants_parity.rs` verifies bit-identical output for
GF(p) reconstruction, HKDF scope-key derivation, coordinator grant round-trips,
and Swift-pinned cross-port vectors.

Cross-port byte-identity vector inputs: `IKM=[0xAB;32]`, grant UUID
`12345678-1234-1234-1234-123456789ABC`, grantee UUID
`ABCDEF01-2345-6789-ABCD-EF0123456789`.

| Derivation | info / seed | Expected (hex) |
|---|---|---|
| Mode-1 scope key | `scope\|12345678-1234-1234-1234-123456789ABC` | `fd23318310153a0ce2d588d1d226a612b45eec75e50d71515472eb333075d8e8` |
| Mode-2 scope key | `scope\|12345678-...\|ABCDEF01-...` | `59daa03098c8d321ce970692bc4039c79f760a087c4c3746baac70bf098f4b8a` |
| Mode-3 scope key | seed=IKM++"12345678-...", NO SHA-256 | `910badf250681ddcd0be0c4e07126ad611d0658417f8b6ff2e1799552a1cc62b` |
| Session key | `session\|12345678-1234-1234-1234-123456789ABC` | `23d5883ce49e29115fd6ab209aeb1253d2863d8beff92308dce93952b4317d94` |

Cross-port byte-identity holds for all three custody modes and the session key.
The session key is invariant with respect to `now` (the timestamp does not
appear in the HKDF info string).

---

## Swift/Rust Concordance — `.nodeTreeNative` recall mode + `GLKNodeTopologyProvider` seam

The `GLKNodeTopologyProvider` protocol/trait, `registerNodeTopology`, the fifth
`GLKRecallMode` case, and the read-once-freeze seam in `recallTunnels` are
present in both ports.

### Asymmetry declaration

The Swift protocol is `async` (actor-friendly); the Rust trait is synchronous
(no async runtime in the Rust port). This asymmetry is sanctioned per the
NeuronKit policy-store precedent. Conformance is proved by edge-output equality
against a canonical fixed-edge test double — the call-shape difference does not
affect result correctness.

### `GLKNodeTopologyProvider` protocol / trait

The Swift protocol is async; the Rust trait is synchronous.

| Swift | Rust | Notes |
|---|---|---|
| `public protocol GLKNodeTopologyProvider: Sendable` | `pub trait NodeTopologyProvider: Send + Sync` | Swift async, Rust sync; GLK prefix resolves LocusKit naming collision |
| `func parentID(of nodeID: String) async -> String?` | `fn parent_id(&self, node_id: &str) -> Option<String>` | Non-recall use only — NOT called inside any deterministic recall path |
| `func childIDs(of nodeID: String) async -> [String]` | `fn child_ids(&self, node_id: &str) -> Vec<String>` | Non-recall use only — NOT called inside any deterministic recall path |
| `func treeEdges(scope: [String]?) async -> [(parent: String, child: String)]` | `fn tree_edges(&self, scope: Option<&[String]>) -> Vec<(String, String)>` | Called EXACTLY ONCE per `recallTunnels` call, result frozen |

**Boundary invariant (LOCKED):** The protocol/trait declares EXACTLY these
3 methods. No content accessor will ever be added. Node content routes through
CorpusKit, not this seam.

**Induced edge contract (LOCKED):** A pair `(parent, child)` is included in
`treeEdges(scope:)` if and only if BOTH parent and child are members of `scope`.
When `scope == nil` (Swift) / `scope == None` (Rust), the full forest is returned.

### Test doubles

| Swift | Rust | Purpose |
|---|---|---|
| `InstrumentedTopologyProvider` | `MemoryTopologyProvider` | Fixed-edge in-memory test double; canonical conformance |

The canonical test tree used by both ports:

```
root → A, root → B, A → C, B → D
```

Induced scope `{root, A, C}` → edges `{root→A, A→C}` only (B∉scope).

### `registerNodeTopology` — registration seam

```swift
// Swift (GeniusLocusKit actor extension)
func registerNodeTopology(_ provider: any GLKNodeTopologyProvider, for handle: EstateHandle)
```

```rust
// Rust (EstateCoordinator)
pub fn register_node_topology(
    &mut self,
    handle: &EstateHandle,
    provider: Arc<dyn NodeTopologyProvider>,
)
// Stored in coordinator.node_topology_providers: HashMap<EstateHandle, Arc<dyn NodeTopologyProvider>> (Rust retains the unprefixed trait name).
// Dropped on close. recall_tunnels reads tree_edges(None) EXACTLY ONCE and
// unions the frozen containment edges with stored tunnel edges.
```

**Rust parity status:** `register_node_topology` is wired to `EstateCoordinator`.
The `node_topology_providers` map is a field parallel to
`corpus_kits` / `vector_stores`; it is initialised empty in `new()` and dropped in
`close()`. `recall_tunnels` performs the read-once-freeze and union identical
to the Swift `recallTunnels(_:wing:)`. Synthetic containment tunnel `filed_at` uses
`i64::MIN` (Rust parity of Swift `Date.distantPast`).

### `SubstrateNodeTopologyProvider` — auto-registered default adapter

| Swift | Rust |
|---|---|
| `public final class SubstrateNodeTopologyProvider: GLKNodeTopologyProvider, @unchecked Sendable` | `pub struct SubstrateNodeTopologyProvider` (implements `NodeTopologyProvider`) |

The substrate-native adapter (the node-integrity contract §10) bridges LocusKit's `NodeStore`
(UUID ids, async throws / `Result`) to `GLKNodeTopologyProvider` (String ids,
infallible). It constructs a separate read-only `NodeStore` from the estate's
`Storage` instance — the same database, different handle. All operations are
read-only; the adapter never writes to the nodes table.

**Auto-registration:** `EstateCoordinator.open` (Swift) and `Coordinator::open`
(Rust) automatically create and register a `SubstrateNodeTopologyProvider` for
every opened estate. Host callers of `.nodeTreeNative` recall mode get
substrate-native topology without supplying a provider.

**String↔UUID boundary:** incoming String ids are parsed to UUID; outgoing
UUIDs are formatted via `.uuidString` / `.to_string()`. Invalid strings return
`nil` / `None` / empty (the protocol is non-throwing).

**Tree walk:** BFS from root, collecting all active parent→child pairs. The
tree is fixed-depth (max depth 2: estate→wing→room per I-NT-2), so the walk
is bounded.

### `registerGraphCache` / `registerPreferenceStore` — recall-scoring seam

```swift
// Swift (GeniusLocusKit actor extension)
func registerGraphCache(_ cache: some GraphCache, for handle: EstateHandle)
func registerPreferenceStore(_ store: some PreferenceStore, for handle: EstateHandle)

protocol GraphCache: Sendable      { func graphScore(for drawerID: String) -> Float }
protocol PreferenceStore: Sendable { func preferenceScore(for drawerID: String) -> Float }
```

```rust
// Rust (EstateCoordinator + recall.rs traits)
pub trait GraphCache: Send + Sync      { fn graph_score(&self, drawer_id: &str) -> f32; }
pub trait PreferenceStore: Send + Sync { fn preference_score(&self, drawer_id: &str) -> f32; }

pub fn register_graph_cache(
    &mut self, handle: &EstateHandle, cache: Arc<dyn GraphCache>,
)
pub fn register_preference_store(
    &mut self, handle: &EstateHandle, store: Arc<dyn PreferenceStore>,
)
// Stored in coordinator.graph_caches / preference_stores:
//   HashMap<EstateHandle, Arc<dyn GraphCache | PreferenceStore>>.
// Initialised empty in new(), dropped on close(). The unionBest .matrixAware
// score loop reads them per candidate (col_graph[i] / col_preference[i]); both
// columns share the weights.graph budget slice (Swift parity). Absent ⇒ 0.0.
```

**Rust parity status:** the recall-CONSUMPTION surface is wired in both ports
(mission glk-recall-graphpref-rust, 2026-06-17, closing the recall-shape contract D-4). Trait,
registration, per-candidate lookup, and live `RecallScoreVector` columns mirror
Swift exactly. A constant cache (0.8 / 0.9) normalizes to `0.5` cross-port
(`recall_shape_matrix_steer_parity.rs` / `RecallShapeMatrixSteerTests.swift`).
The cache PRODUCERS (dreaming-cycle graph-centrality; Bradley-Terry preference
training) are absent in BOTH ports — a separate future mission.

### `GLKRecallMode.nodeTreeNative` — 5th case

| Swift raw value | Rust variant | Notes |
|---|---|---|
| `"nodeTreeNative"` | `GLKRecallMode::NodeTreeNative` | 5th case; `raw_value()` → `"nodeTreeNative"` |

**Behaviour:** `.nodeTreeNative` delegates to the `locusOnly` recall lane for
drawer retrieval. Tree-edge injection happens separately in `recallTunnels`
(the structural-lens path), not in the scored recall path. This preserves
B-1 layer discipline — CognitionKit recipes call `recallTunnels` and receive
the enriched edge set without importing `GLKNodeTopologyProvider`.

### Read-once-freeze in `recallTunnels`

`GeniusLocusKit.recallTunnels(_ handle:, wing:)` calls `provider.treeEdges(scope: nil)`
EXACTLY ONCE at the top of the method. The result is frozen into a local constant
before the estate tunnel read begins. No provider method is called again during
this `recallTunnels` call or by any consumer of the returned array.

**G5 — Wing-scoped topology privacy (secfix/c-glk-remaining):** After freezing the
full edge forest, the method resolves child node IDs via `estate.resolveNodeNames` and
retains only edges whose child maps to the queried `wing`. Root→wing structural nodes
are excluded (they resolve to the estate root, not the queried wing); only room-level
containment edges for the requested wing are emitted. This prevents foreign-wing node
IDs from appearing in another wing's tunnel stream. `resolveNodeNames` is a separate
NodeStore read — G1 (treeEdges called exactly once) remains satisfied.

When no provider is registered, the method returns only stored tunnels —
identical to pre-`.nodeTreeNative` behaviour. The no-provider path is the
zero-cost baseline.

### Synthetic containment tunnel shape

Tree edges are surfaced as `Tunnel` values with:

| Field | Value |
|---|---|
| `id` | `"containment:<parent>:<child>"` |
| `label` | `"containment"` |
| `kind` | `.references` (TunnelKind has no `.containment` case; `label` is the discriminator) |
| `sourceDrawerId` | parent node id |
| `targetDrawerId` | child node id |
| `addedBy` | `"nodeTopologyProvider"` |
| `filedAt` | `.distantPast` (synthetic, not a real capture time) |

### Conformance gate

| Port | Test file | Coverage |
|---|---|---|
| Swift | `NodeTopologyProviderTests.swift` | auto-registered substrate adapter produces containment edges, registered provider adds containment edges, read-once enforcement, mode decode, recall delegation, scope-induced subset, call-count exactly one; `SubstrateNodeTopologyProviderTests` — parent/child/treeEdges/scope/invalid-UUID |
| Rust (trait) | `tests/node_topology_parity.rs` | parent_id, child_ids, full forest, induced scope, root/leaf behavior, empty scope |
| Rust (coordinator) | `src/coordinator.rs` (unit tests) | no-provider unchanged, containment edges added, call-count exactly one per recall, close drops provider, unregistered estate unchanged, synthetic tunnel field values |
| Rust (existing) | `tests/recall_scored_parity.rs` | Asserts `GLKRecallMode::NodeTreeNative.raw_value() == "nodeTreeNative"` (5th raw value) |

---

## Swift/Rust Concordance — full public-surface table

This section gives the per-concept concordance for the entire top-level
public surface of GeniusLocusKit in both ports, one row per public concept.
Earlier sections above cover the matrix-rebuild, scored-recall, grant, and
node-topology sub-surfaces in depth; this table is the inventory of the
remaining concepts and re-anchors the ones already covered so there is a
single complete index. Shape rule states the sanctioned port difference, if
any. Test/vector binding names the conformance/parity test that proves
Swift==Rust (the `*_parity.rs` targets and their Swift twins; SPEC § 8,
C-12). "N/A (structural)" marks a pure shape with no independent behavior.

Idiom note (applies fleet-wide): Swift uppercases acronym suffixes
(`RowID`, `RoomID`, `BranchID`, `SubscriptionID`) while Rust uses
PascalCase (`RowId`, `RoomId`, `BranchId`); both are `String`/`Uuid`
aliases. Foundation `UUID` on the Swift side is a `[u8;16]` newtype alias
(`EstateUuid`) or a 16-byte newtype (`EntryUUID`) on the Rust side — same
128-bit value, different host type. These are sanctioned idiom, not drift.

### Verb surface, frames, and lexicon

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Capture frame | `CaptureFrame` (`Verbs/Frames.swift`, typealias of LocusKit) | `CaptureFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Recall frame | `RecallFrame` (`Verbs/Frames.swift`) | `RecallFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Learn frame | `LearnFrame` (`Verbs/Frames.swift`) | `LearnFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Mutate frame | `MutateFrame` (`Verbs/Frames.swift`) | `MutateFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Withdraw frame | `WithdrawFrame` (`Verbs/Frames.swift`) | `WithdrawFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Expunge frame | `ExpungeFrame` (`Verbs/Frames.swift`) | `ExpungeFrame` (`rust/src/verbs/frames.rs`) | public / pub | `confirmation: Bool` is transient input, not stored (I-10) | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Reanchor frame | `ReanchorFrame` (`Verbs/Frames.swift`) | `ReanchorFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Propose frame | `ProposeFrame` (`Verbs/Frames.swift`) | `ProposeFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Associate frame | `AssociateFrame` (`Verbs/Frames.swift`) | `AssociateFrame` (`rust/src/verbs/frames.rs`) | public / pub | identical fields | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Mutation kind | `MutationKind` (`Verbs/Frames.swift`, typealias of LocusKit) | `MutationKind` (`rust/src/brain/scheduler/api.rs`) | public / pub | same variants; Rust `CorrectSensitivity(i64)` etc. | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Lattice anchor | `LatticeAnchor` (`Verbs/Frames.swift`, typealias of LocusKit) | `LatticeAnchor` (`rust/src/verbs/frames.rs`) | public / pub | identical | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Row id | `RowID` (`Verbs/Frames.swift`, `= String`) | `RowId` (`rust/src/verbs/frames.rs`, `= String`); also `RowID` alias (`rust/src/brain/scheduler/api.rs`) | public / pub | idiom `RowID`/`RowId` | N/A (structural) | Confirmed |
| Room id | `RoomID` (`Verbs/Frames.swift`, `= String`) | `RoomId` (`rust/src/verbs/frames.rs`, `= String`) | public / pub | idiom `RoomID`/`RoomId` | N/A (structural) | Confirmed |
| Hydration level | `LocusKit.HydrationLevel` (re-exported via frames) | `HydrationLevel` (`rust/src/verbs/frames.rs`) | public / pub | mirrors `LocusKit.HydrationLevel` | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Result ordering | `LocusKit.Ordering` (re-exported via frames) | `Ordering` (`rust/src/verbs/frames.rs`) | public / pub | mirrors `LocusKit.Ordering` | `verb_parity.rs` / `VerbSurfaceTests.swift` | Confirmed |
| Learned reference | `LearnedReference` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit `LearnedReference`, re-exported) | public / pub | LocusKit-owned noun; GLK re-exports the Swift alias only | `verb_parity.rs` learn case / `VerbSurfaceTests.swift` | Confirmed |
| Recall trace item | `RecallTraceItem` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit `RecallTraceItem`, re-exported) | public / pub | LocusKit-owned; GLK re-exports the Swift alias only | `RecallDirectorTests.swift` | Confirmed |
| Diary entry | `DiaryEntry` (`Verbs/Frames.swift`, typealias of LocusKit) | `locus_kit::diary_entry::DiaryEntry` (re-exported via write-path) | public / pub | LocusKit-owned noun; GLK re-exports the Swift alias only | `coordinator_write_path_test.rs` / `KGFactVerbTests.swift` | Confirmed |
| Adjective: sensitivity | `AdjectiveSensitivity` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit adjective; lexicon `Adjective`) | public / pub | LocusKit-owned adjective; Swift alias re-export | `parity.rs` lexicon / `VerbSurfaceTests.swift` | Confirmed |
| Adjective: exportability | `AdjectiveExportability` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit adjective; lexicon `Adjective`) | public / pub | LocusKit-owned adjective; Swift alias re-export | `parity.rs` lexicon / `VerbSurfaceTests.swift` | Confirmed |
| Proposal noun | `Proposal` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit `Proposal`; lexicon `Noun::Proposal`) | public / pub | LocusKit-owned noun; Swift alias re-export | `parity.rs` lexicon | Confirmed |
| Association noun | `Association` (`Verbs/Frames.swift`, typealias of LocusKit) | (LocusKit `Association`; lexicon `Noun::Association`) | public / pub | LocusKit-owned noun; Swift alias re-export | `parity.rs` lexicon | Confirmed |
| Verb dispatch error | `VerbError` (`Verbs/VerbError.swift`) | `VerbError` (`rust/src/verbs/lexicon.rs`) | public / pub | same 6 cases (added `crossKitVectorDeleteFailed` / `CrossKitVectorDeleteFailed`) | `verb_parity.rs` / `VerbSurfaceTests.swift` / `ExpungeVectorOrphanTests.swift` | Confirmed |
| Proposal taxonomy | `ProposalKind` (`Brain/ProposalKind.swift`) | `ProposalKind` (`rust/src/brain/scheduler/api.rs`) | public / pub | same raw strings; Rust re-exported as scheduler `SchedulerProposalKind` | `scheduler_parity.rs` / `StandingSignalSchedulerTests.swift` | Confirmed |
| ARIA lexicon conformance | `AriaLexiconConformance` (`Verbs/AriaLexiconConformance.swift`) | `verbs::lexicon` (`Verb`/`Noun`/`Adjective`/`Acceptance`) (`rust/src/verbs/lexicon.rs`) | public enum / pub mod | Swift: one `enum` namespace of data-only maps; Rust: discrete `pub enum`s + `Acceptance` matrix helper (I-13) | `parity.rs` lexicon acceptance matrix / `VerbSurfaceTests.swift` | Confirmed |
| Lexicon verb | (Swift uses `AriaLexiconLib.Verb` directly) | `Verb` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust mirrors `AriaLexiconLib.Verb` in-crate (no cross-crate enum re-export) | `parity.rs` lexicon | Confirmed |
| Lexicon verb flow | (Swift `AriaLexiconLib` flow data) | `VerbFlow` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust mirrors AriaLexiconLib flow classification | `parity.rs` lexicon | Confirmed |
| Lexicon noun | (Swift `AriaLexiconLib.Noun`) | `Noun` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust mirrors `AriaLexiconLib.Noun` in-crate | `parity.rs` lexicon | Confirmed |
| Lexicon noun role | (Swift `AriaLexiconLib` role data) | `NounRole` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust mirrors AriaLexiconLib noun-role classification | `parity.rs` lexicon | Confirmed |
| Lexicon adjective | (Swift `AriaLexiconLib.Adjective`) | `Adjective` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust mirrors `AriaLexiconLib.Adjective` in-crate | `parity.rs` lexicon | Confirmed |
| Lexicon acceptance matrix | (Swift `AriaLexiconConformance` § 7.2 helpers) | `Acceptance` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust: stateless helper struct over the verb↔noun matrix | `parity.rs` lexicon acceptance | Confirmed |
| Lexicon surface target | (Swift `AriaLexiconConformance` mapping result) | `SurfaceTarget` (`rust/src/verbs/lexicon.rs`) | n/a / pub | Rust: routing target struct for a (verb,noun) pair | `parity.rs` lexicon | Confirmed |

### Coordinator, handle, fan-out, federation

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Composition coordinator | `GeniusLocusKit` (actor, `GeniusLocusKit.swift`) | `EstateCoordinator` (`rust/src/coordinator.rs`) | public actor / pub struct | Swift async actor / Rust sync struct (no async runtime — sanctioned, cf. NeuronKit policy-store seam) | `composition_conformance_tests.rs` / `CompositionConformanceTests.swift` | Confirmed |
| Estate handle | `EstateHandle` (`EstateHandle.swift`) | `EstateHandle` (`rust/src/handle.rs`) | public / pub | identical fields | `composition_conformance_tests.rs` / `CoordinatorLifecycleTests.swift` | Confirmed |
| Estate uuid | Foundation `UUID` (`EstateHandle.estateUUID`) | `EstateUuid = [u8;16]` (`rust/src/handle.rs`) | (platform) / pub | Swift uses Foundation `UUID`; Rust uses a 16-byte alias — same 128-bit value, idiom | `composition_conformance_tests.rs` | Confirmed |
| Estate-handle id (scheduler) | (Swift `EstateHandle` used as key) | `EstateHandleID = String` (`rust/src/brain/scheduler/api.rs`) | n/a / pub | Rust: string key for per-estate scheduler maps; Swift keys on `EstateHandle` directly | `scheduler_parity.rs` | Confirmed |
| Lattice region | `LatticeRegion` (`CrossEstateRead.swift`) | `LatticeRegion` (`rust/src/fan_out.rs`) | public / pub | identical closed interval | `composition_conformance_tests.rs` / `CrossEstateOverlapTests.swift` | Confirmed |
| Per-estate recall contribution | `EstateRecallContribution` (`CrossEstateRead.swift`, `drawers: [Drawer]`) | `EstateRecallContribution` (`rust/src/fan_out.rs`, `drawer_ids: Vec<String>` — id projection) | public / pub | both carry real recalled rows from live per-estate recall; Rust projects to ids; conformance unit is the per-estate id SET | `parity.rs` (`fan_out_carries_real_drawer_ids_per_estate`) / `CrossEstateOverlapTests.swift` | Confirmed |
| Coordinator/lifecycle error | `GeniusLocusKitError` (`GeniusLocusKitError.swift`) | `GeniusLocusKitError` (`rust/src/coordinator.rs`) | public / pub | same case set | `composition_conformance_tests.rs` / `GeniusLocusKitErrorTests.swift` | Confirmed |
| Federated read result | `FederatedRecallResult` (`Federation/FederatedRecallResult.swift`) | `FederatedRecallResult` (`rust/src/coordinator.rs`) | public / pub | Swift: async actor surface; Rust: sync struct. Custody gate + budget debit both enforced | `CrossEstateFederationTests.swift` / `grants_parity.rs` | Confirmed |
| Federated read refusal reason | `FederatedReadRefusalReason` (`Federation/FederatedRecallResult.swift`) | `FederatedReadRefusalReason` (`rust/src/coordinator.rs`) | public / pub | 5 cases: noActiveGrant, grantExpired, grantRevoked, budgetExhausted, custodyRefused — parity across both ports | `CrossEstateFederationTests.swift` / `grants_parity.rs` | Confirmed |
| Estate kind (provision) | `EstateKind` (`EstateProvision.swift`) | `EstateKind` (`rust/src/coordinator.rs`) | public / pub | same variants (`glk`/`corpusOnly`/`locusOnly` → `Glk`/`CorpusOnly`/`LocusOnly`); same raw-value strings via `rawValue`/`raw_value` | `provision_lifecycle_parity.rs` / `EstateProvisionLifecycleTests.swift` | Confirmed |
| Provision params | `EstateProvisionParams` (`EstateProvision.swift`) | `EstateProvisionParams` (`rust/src/coordinator.rs`) | public / pub | identical fields (Swift `Int` → Rust `i64`; snake_case) | `provision_lifecycle_parity.rs` / `EstateProvisionLifecycleTests.swift` | Confirmed |
| Sync mode (provision) | `SyncMode` (`EstateProvision.swift`) | `SyncMode` (`rust/src/coordinator.rs`) | public / pub | same variants (`none`/`cloudKit`/`federation` → `None`/`CloudKit`/`Federation`); same 0/1/2 storage-mode encoding | `provision_lifecycle_parity.rs` / `EstateProvisionLifecycleTests.swift` | Confirmed |
| Estate mount state | `EstateMountState` (`EstateProvision.swift`) | `EstateMountState` (`rust/src/coordinator.rs`) | public / pub | same variants (`mounted`/`quiesced`/`draining`/`unmounted` → `Mounted`/`Quiesced`/`Draining`/`Unmounted`) | `provision_lifecycle_parity.rs` / `EstateProvisionLifecycleTests.swift` | Confirmed |

### Grants (see also "grant access-control surface" above)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Issue-grant result | `IssueGrantResult` (`Grants/Grant.swift`) | `IssueGrantResult` (`grants::grant`) | public / pub | `scopeKey: Data?` → `scope_key: Option<Vec<u8>>`; Debug redacts | `grants_parity.rs` / `GrantTests.swift` | Confirmed |

### COW branching

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Branch handle | `BranchHandle` (protocol, `Branches/BranchHandle.swift`) | `EstateBranch` (`rust/src/branches.rs`) + `branch_handle_for` accessor | public protocol / pub struct | Swift: protocol with async methods / Rust: concrete struct, sync (no async runtime — sanctioned) | `composition_conformance_tests.rs` branch / `BranchTests.swift` | Confirmed |
| Branch id | `BranchID = UUID` (`Branches/BranchTypes.swift`) | `BranchId = Uuid` (`rust/src/branches.rs`) | public / pub | idiom `BranchID`/`BranchId` | N/A (structural) | Confirmed |
| Drawer id (branch alias) | `DrawerID = RowID` (`Branches/BranchTypes.swift`) | (Rust uses `RowId` directly in branch APIs) | public / pub | Swift convenience alias of `RowID`; Rust uses `RowId` inline | N/A (structural) | Confirmed |
| Branch status | `BranchStatus` (`Branches/BranchTypes.swift`) | `BranchStatus` (`rust/src/branches.rs`) | public / pub | same 4 variants | `BranchTests.swift` | Confirmed |
| Branch score | `BranchScore` (`Branches/BranchTypes.swift`) | `BranchScore` (`rust/src/branches.rs`) | public / pub | identical fields | `BranchTests.swift` | Confirmed |
| Differential report | `DifferentialReport` (`Branches/BranchTypes.swift`) | `DifferentialReport` (`rust/src/branches.rs`) | public / pub | identical fields | `BranchTests.swift` | Confirmed |
| Merge report | `MergeReport` (`Branches/BranchTypes.swift`) | `MergeReport` (`rust/src/branches.rs`) | public / pub | identical fields | `BranchTests.swift` | Confirmed |
| Branch error | (folded into `GeniusLocusKitError` cases on Swift side) | `BranchError` (`rust/src/branches.rs`) | n/a / pub | Rust splits branch failures into a dedicated enum; Swift carries them as `GeniusLocusKitError.branchNotTracked` / `.invalidPromotionTarget` | `BranchTests.swift` (Swift) / branch parity (Rust) | Confirmed |

### Unified audit log, projection, recovery

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Audit entry | `UnifiedAuditEntry` (`Audit/UnifiedAuditLog.swift`) | `UnifiedAuditEntry` (`rust/src/audit/log.rs`) | public / pub | byte-identical wire encoding | `audit_parity.rs` / `UnifiedAuditLogTests.swift` | Confirmed |
| Audit entry map key | `UnifiedAuditEntryKey` (`Audit/UnifiedAuditLog.swift`) | (Rust keys `BTreeMap<[u8;32], …>` directly) | public / n/a | Swift needs a named `Hashable` dictionary key wrapping the 32-byte id; Rust uses the `[u8;32]` array as the map key directly — structural idiom | `audit_parity.rs` (entry dedup) / `UnifiedAuditLogTests.swift` | Confirmed |
| Audit value | `UnifiedAuditValue` (`Audit/UnifiedAuditLog.swift`) | `UnifiedAuditValue` (`rust/src/audit/log.rs`) | public / pub | same 5 cases; byte-identical `wireBytes`/`wire_bytes` | `audit_parity.rs` / `UnifiedAuditLogTests.swift` | Confirmed |
| Audit verb | `UnifiedAuditVerb` (`Audit/UnifiedAuditLog.swift`) | `UnifiedAuditVerb` (`rust/src/audit/log.rs`) | public / pub | same raw strings | `audit_parity.rs` / `UnifiedAuditLogTests.swift` | Confirmed |
| Audit tier | `AuditTier` (`Audit/UnifiedAuditLog.swift`) | `AuditTier` (`rust/src/audit/log.rs`) | public / pub | `{locus, rag}` | `audit_parity.rs` / `UnifiedAuditLogTests.swift` | Confirmed |
| Entry uuid (row id) | Foundation `UUID` (`UnifiedAuditEntry.rowID`) | `EntryUUID([u8;16])` (`rust/src/audit/log.rs`) | (platform) / pub | Swift Foundation `UUID`; Rust 16-byte newtype — same value, idiom | `audit_parity.rs` | Confirmed |
| Chain report | `AuditChainReport` (`Audit/AuditChainReport.swift`) | (audit module `verify` returns equivalent) | public / pub | Rust returns the report shape from the module `verify` fn | `audit_parity.rs` chain / `AuditIntegrationTests.swift` | Confirmed |
| Chain verifier | `AuditChainVerifier` (`Audit/AuditChainVerifier.swift`) | `audit::verify` (`rust/src/audit/mod.rs`) | public enum / pub fn | Swift: caseless `enum` namespace with `static verify`; Rust: free `verify` fn | `audit_parity.rs` chain / `AuditIntegrationTests.swift` | Confirmed |
| Projection fold | `AuditProjectionFold` (`Audit/AuditProjection.swift`) | `audit::projection` fold (`rust/src/audit/projection.rs`) | public / pub | Swift: caseless `enum` with `static project`; Rust: module fn | `audit_parity.rs` projection / `AuditIntegrationTests.swift` | Confirmed |
| Unified projection | `UnifiedProjection` (`Audit/AuditProjection.swift`) | `UnifiedProjection` (`rust/src/audit/projection.rs`) | public / pub | identical | `audit_parity.rs` projection / `AuditIntegrationTests.swift` | Confirmed |
| Projection key | `UnifiedProjection.Key` (nested, `Audit/AuditProjection.swift`) | `UnifiedProjectionKey` (`rust/src/audit/projection.rs`) | public / pub | Swift nested `UnifiedProjection.Key` / Rust flat `UnifiedProjectionKey` | `audit_parity.rs` projection | Confirmed |
| Row projection | `UnifiedRowProjection` (`Audit/AuditProjection.swift`) | `UnifiedRowProjection` (`rust/src/audit/projection.rs`) | public / pub | identical | `audit_parity.rs` projection | Confirmed |
| Audit recovery | `AuditRecovery` (`Audit/AuditRecovery.swift`) | `AuditRecovery` (`rust/src/audit/recovery.rs`) | public / pub | identical | `audit_parity.rs` recovery / `AuditIntegrationTests.swift` | Confirmed |
| Recovery result | `AuditRecoveryResult` (`Audit/AuditRecovery.swift`) | `AuditRecoveryResult` (`rust/src/audit/recovery.rs`) | public / pub | identical | `audit_parity.rs` recovery | Confirmed |
| Recovery divergence | `AuditRecoveryDivergence` (`Audit/AuditRecovery.swift`) | `AuditRecoveryDivergence` (`rust/src/audit/recovery.rs`) | public / pub | identical | `audit_parity.rs` recovery | Confirmed |
| Recovery row mismatch | `AuditRecoveryDivergence.RowMismatch` (nested) | `RowMismatch` (`rust/src/audit/recovery.rs`) | public / pub | Swift nested `…Divergence.RowMismatch` / Rust flat `RowMismatch` | `audit_parity.rs` recovery | Confirmed |

### Standing-signal scheduler and signal model

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Standing-signal scheduler | `StandingSignalScheduler` (actor, `Brain/StandingSignalScheduler.swift`) | `SerialLaneScheduler<D: Dispatcher>` (`rust/src/brain/scheduler/serial_lane.rs`) | public actor / pub struct | Swift async actor owning a QueueKit serial lane / Rust sync generic over a `Dispatcher` (no async runtime — sanctioned) | `scheduler_parity.rs` / `StandingSignalSchedulerTests.swift` | Confirmed |
| Signal routing callback | `SignalDispatcher` (protocol, `Brain/StandingSignalScheduler.swift`) | `Dispatcher` (trait, `rust/src/brain/scheduler/serial_lane.rs`) | public protocol / pub trait | same routing contract; idiom name `SignalDispatcher`/`Dispatcher` | `scheduler_parity.rs` / `StandingSignalSchedulerTests.swift` | Confirmed |
| No-op dispatcher | (Swift tests inject a closure dispatcher) | `NoopDispatcher` (`rust/src/brain/scheduler/serial_lane.rs`) | n/a / pub | Rust ships a concrete no-op `Dispatcher` for unsubscribed lanes; Swift uses an inline closure | `scheduler_parity.rs` | Confirmed |
| Scheduler error | (folded into `GeniusLocusKitError` scheduler cases) | `SchedulerError` (`rust/src/brain/scheduler/schedule.rs`) | n/a / pub | Rust dedicated enum; Swift carries as `GeniusLocusKitError.schedulerSignalNotRegistered` / `.schedulerNotStarted` | `scheduler_parity.rs` | Confirmed |
| Signal id | `SignalID` (`Brain/SignalSchedule.swift`) | `SignalID(String)` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical newtype | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Subscription id | `SubscriptionID` (`Brain/SignalSchedule.swift`) | `SubscriptionID(String)` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical newtype | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal trigger | `SignalTrigger` (`Brain/SignalSchedule.swift`) | `SignalTrigger` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical variants | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Condition predicate | `ConditionPredicate` (`Brain/SignalSchedule.swift`) | `ConditionPredicate` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Resource cost estimate | `ResourceCostEstimate` (`Brain/SignalSchedule.swift`) | `ResourceCostEstimate` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Concurrency policy | `ConcurrencyPolicy` (`Brain/SignalSchedule.swift`) | `ConcurrencyPolicy` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical variants | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal spec | `SignalSpec` (`Brain/SignalSchedule.swift`) | `SignalSpec` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical fields | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal context | `SignalContext` (`Brain/SignalSchedule.swift`) | `SignalContext` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal emission | `SignalEmission` (`Brain/SignalSchedule.swift`) | `SignalEmission` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical variants | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Proposal frame (signal) | `ProposalFrame` (`Brain/SignalSchedule.swift`) | `ProposalFrame` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical; carries typed `ProposalKind` | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Association frame (signal) | `AssociationFrame` (`Brain/SignalSchedule.swift`) | `AssociationFrame` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Diagnostic report | `DiagnosticReport` (`Brain/SignalSchedule.swift`) | `DiagnosticReport` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal state | `SignalState` (`Brain/SignalSchedule.swift`) | `SignalState` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical variants | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal route outcome | `SignalRouteOutcome` (`Brain/SignalSchedule.swift`) | `SignalRouteOutcome` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Signal report | `SignalReport` (`Brain/SignalSchedule.swift`) | `SignalReport` (`rust/src/brain/scheduler/api.rs`) | public / pub | identical | `scheduler_parity.rs` / `StandingSignalsTests.swift` | Confirmed |

### Fourteen standing signals

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Consolidation signal | `ConsolidationSignal` (`Brain/Signals/ConsolidationSignal.swift`) | `ConsolidationSignal` (`rust/src/brain/signals/consolidation.rs`) | public / pub | identical; daily; registered only with a live cycle (`consolidation` preference) | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Anomaly-flag-sweep signal | `AnomalySweepSignal` (`Brain/Signals/AnomalySweepSignal.swift`) | `AnomalySweepSignal` (`rust/src/brain/signals/anomaly_sweep.rs`) | public / pub | identical; hourly | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Span-encode signal | `SpanEncodeSignal` (`Brain/Signals/SpanEncodeSignal.swift`) | `SpanEncodeSignal` (`rust/src/brain/signals/span_encode.rs`) | public / pub | identical; 30 s | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Fact-extraction signal | `FactExtractionSignal` (`Brain/Signals/FactExtractionSignal.swift`) | `FactExtractionSignal` (`rust/src/brain/signals/fact_extraction.rs`) | public / pub | identical; 5 min; default closure inert | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Contradiction-sweep signal | `ContradictionSweepSignal` (`Brain/Signals/ContradictionSweepSignal.swift`) | `ContradictionSweepSignal` (`rust/src/brain/signals/contradiction_sweep.rs`) | public / pub | identical; hourly; registered only with a live cycle (`contradiction_sweep` preference) | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Dreaming signal | `DreamingSignal` (`Brain/Signals/DreamingSignal.swift`) | `DreamingSignal` (`rust/src/brain/signals/dreaming.rs`) | public / pub | identical spec factory | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Maintenance signal | `MaintenanceSignal` (`Brain/Signals/MaintenanceSignal.swift`) | `MaintenanceSignal` (`rust/src/brain/signals/maintenance.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Vector-similarity signal | `VectorSimilaritySignal` (`Brain/Signals/VectorSimilaritySignal.swift`) | `VectorSimilaritySignal` (`rust/src/brain/signals/vector_similarity.rs`) | public / pub | 1.1 target: identical; Hamming threshold default 64; both GLK and Corpus-derived lanes are keyed directly by Drawer id, so no chunk-owner translation exists | shared-content and standing-signal parity suites | Accepted target |
| Contradiction-scout signal | `ContradictionScoutSignal` (`Brain/Signals/ContradictionScoutSignal.swift`) | `ContradictionScoutSignal` (`rust/src/brain/signals/contradiction_scout.rs`) | public / pub | identical; hourly cadence, closure-injected hunt cycle (single-write invariant: the hunt persists, the signal emits one diagnostic) | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Decay-sweep signal | `DecaySweepSignal` (`Brain/Signals/DecaySweepSignal.swift`) | `DecaySweepSignal` (`rust/src/brain/signals/decay_sweep.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| By-reference validity signal | `ByReferenceValiditySignal` (`Brain/Signals/ByReferenceValiditySignal.swift`) | `ByReferenceValiditySignal` (`rust/src/brain/signals/by_reference_validity.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| End-of-day tournament signal | `EndOfDayTournamentSignal` (`Brain/Signals/EndOfDayTournamentSignal.swift`) | `EndOfDayTournamentSignal` (`rust/src/brain/signals/end_of_day_tournament.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Temporal-causality signal | `TemporalCausalitySignal` (`Brain/Signals/TemporalCausalitySignal.swift`) | `TemporalCausalitySignal` (`rust/src/brain/signals/temporal_causality.rs`) | public / pub | identical spec factory; the T-matrix fold math itself lives in `MatrixTier::rebuild_temporal` (see matrix-rebuild concordance above) | `matrix_parity.rs` rebuild_temporal / `MatrixTierTests.swift`, `StandingSignalsTests.swift` | Confirmed |
| Training signal | `TrainingSignal` (`Brain/Signals/TrainingSignal.swift`) | `TrainingSignal` (`rust/src/brain/signals/training.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |

### Matrix tier (F/C/O/T model, NMF, calibration, persistence)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Field cell | `MatrixFieldCell` (`Matrix/MatrixTier.swift`) | `MatrixFieldCell` (`rust/src/matrix/matrix.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Value coordinate | `MatrixValueCoord` (`Matrix/MatrixTier.swift`) | `MatrixValueCoord` (`rust/src/matrix/matrix.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Co-occurrence key | `MatrixCoOccurKey` (`Matrix/MatrixTier.swift`) | `MatrixCoOccurKey` (`rust/src/matrix/matrix.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Temporal key | `MatrixTemporalKey` (`Matrix/MatrixTier.swift`) | `MatrixTemporalKey` (`rust/src/matrix/matrix.rs`) | public / pub | identical | `matrix_parity.rs` rebuild_temporal / `MatrixTierTests.swift` | Confirmed |
| Calibration bucket | `MatrixCalibrationBucket` (`Matrix/Calibration.swift`) | `MatrixCalibrationBucket` (`rust/src/matrix/calibration.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Calibration outcome | `MatrixCalibrationOutcome` (`Matrix/Calibration.swift`) | `MatrixCalibrationOutcome` (`rust/src/matrix/calibration.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Calibration curve | `MatrixCalibrationCurve` (`Matrix/Calibration.swift`) | `MatrixCalibrationCurve` (`rust/src/matrix/calibration.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Calibration registry | `MatrixCalibrationRegistry` (`Matrix/Calibration.swift`) | `MatrixCalibrationRegistry` (`rust/src/matrix/calibration.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| NMF factorization | `MatrixNMFFactorization` (`Matrix/LatentFactors.swift`) — `w:[Float32]`, `h:[Float32]`, `reconstructionError:Float32` | `MatrixNMFFactorization` (`rust/src/matrix/nmf.rs`) — `w:Vec<f32>`, `h:Vec<f32>`, `reconstruction_error:f32` | public / pub | identical — f32 factors, RMS error metric; delegates to `SubstrateML.NMFAlternatingLeastSquares` | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| NMF engine | `MatrixNMF` (`Matrix/LatentFactors.swift`) — `factorize(o:[Double],…,tolerance:Float32)` | `MatrixNMF` (`rust/src/matrix/nmf.rs`) — `factorize(o:&[f64],…,tolerance:f32)` | public / pub | identical — accepts f64 input for caller compat; converts to f32 internally before delegation | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Persistence mode | `MatrixPersistenceMode` (`Matrix/MatrixPersistence.swift`) | `MatrixPersistenceMode` (`rust/src/matrix/persistence.rs`) | public / pub | identical variants | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Snapshot | `MatrixSnapshot` (`Matrix/MatrixPersistence.swift`) | `MatrixSnapshot` (`rust/src/matrix/persistence.rs`) | public / pub | Both ports persist `temporal_watermark_hlc`; Swift via JSON Codable (`decodeIfPresent ?? .zero`), Rust via 16-byte binary trailer with `HLC::ZERO` fallback for old snapshots | `matrix_parity.rs` (snapshot_persists_temporal_watermark_hlc_round_trip, snapshot_backward_compat_missing_watermark_falls_back_to_zero) / `MatrixTierTests.swift` | Confirmed |
| Persistence error | `MatrixPersistenceError` (`Matrix/MatrixPersistence.swift`) | `MatrixPersistenceError` (`rust/src/matrix/persistence.rs`) | public / pub | identical | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |
| Persistence backend | `MatrixPersistenceBackend` (protocol, `Matrix/MatrixPersistence.swift`) | `MatrixPersistenceBackend` (trait, `rust/src/matrix/persistence.rs`) | public protocol / pub trait | same backend contract | `matrix_parity.rs` / `MatrixTierTests.swift` | Confirmed |

### Training daemon and enrichment

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Threshold decision | `TrainingThresholdDecision` (`Training/ThresholdGate.swift`) | `TrainingThresholdDecision` (`rust/src/training/gate.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Threshold gate | `TrainingThresholdGate` (`Training/ThresholdGate.swift`) | `TrainingThresholdGate` (`rust/src/training/gate.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Daemon tick | `TrainingDaemonTick` (`Training/TrainingDaemon.swift`) | `TrainingDaemonTick` (`rust/src/training/daemon.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Daemon report | `TrainingDaemonReport` (`Training/TrainingDaemon.swift`) | `TrainingDaemonReport` (`rust/src/training/daemon.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Training daemon | `TrainingDaemon` (`Training/TrainingDaemon.swift`) | `TrainingDaemon` (`rust/src/training/daemon.rs`) | public / pub | Swift async tick / Rust sync (no async runtime — sanctioned) | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Enrichment pass result | `EnrichmentPassResult` (`Training/EnrichmentPipeline.swift`) | `EnrichmentPassResult` (`rust/src/training/pipeline.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |
| Enrichment pipeline | `EnrichmentPipeline` (`Training/EnrichmentPipeline.swift`) | `EnrichmentPipeline` (`rust/src/training/pipeline.rs`) | public / pub | identical | `training_parity.rs` / `TrainingDaemonTests.swift` | Confirmed |

### Migration (MemPalace import + parallel run)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| External entry | `ExternalEntry` (`Migration/ExternalCorpus.swift`) | `ExternalEntry` (`rust/src/migration/mod.rs`) | public / pub | identical | `MigrationTests.swift` (Swift) / migration parity (Rust) | Confirmed |
| External corpus | `ExternalCorpus` (`Migration/ExternalCorpus.swift`) | `ExternalCorpus` (`rust/src/migration/mod.rs`) | public / pub | identical (+ `hybrid_recall`) | `MigrationTests.swift` (Swift) / migration parity (Rust) | Confirmed |
| Migration report | `MigrationReport` (`Migration/MigrationTypes.swift`) | `MigrationReport` (`rust/src/migration/mod.rs`) | public / pub | identical | `MigrationTests.swift` (Swift) / migration parity (Rust) | Confirmed |
| Unmapped concept | `UnmappedConcept` (`Migration/MigrationTypes.swift`) | (carried as a field of Rust `MigrationReport`) | public / pub | Rust folds unmapped concepts into `MigrationReport`; Swift names the DTO | `MigrationTests.swift` | Confirmed |
| Migration warning | `MigrationWarning` (`Migration/MigrationTypes.swift`) | (carried as a field of Rust `MigrationReport`) | public / pub | Rust folds warnings into `MigrationReport`; Swift names the DTO | `MigrationTests.swift` | Confirmed |
| Parallel capture mode | `ParallelCaptureMode` (`Migration/MigrationTypes.swift`) | (Rust `ParallelRunHandle` ctor arg / enum in `migration` mod) | public / pub | Rust threads the mode through `ParallelRunHandle`; Swift names the standalone enum | `MigrationTests.swift` | Confirmed |
| Migration verification | `MigrationVerification` (`Migration/MigrationTypes.swift`) | (Rust `MigrationVerification` in `migration` mod) | public / pub | identical variants | `MigrationTests.swift` | Confirmed |
| Migration divergence | `MigrationDivergence` (`Migration/MigrationTypes.swift`) | (payload of Rust `MigrationVerification::Diverged`) | public / pub | Rust carries divergence as the verification payload; Swift names the DTO | `MigrationTests.swift` | Confirmed |
| Migration error | `MigrationError` (`Migration/MigrationTypes.swift`) | `MigrationError` (`rust/src/migration/mod.rs`) | public / pub | same cases | `MigrationTests.swift` | Confirmed |
| Parallel run handle | `ParallelRunHandle` (actor, `Migration/ParallelRunHandle.swift`) | `ParallelRunHandle` (`rust/src/migration/mod.rs`) | public actor / pub struct | Swift async actor / Rust sync struct (no async runtime — sanctioned) | `MigrationTests.swift` | Confirmed |

### Recall cold-path seams

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Graph cache | `GraphCache` (protocol) | none — Swift-only cold-path seam | public protocol / — | Cold-path candidate-frontier graph lookup; held in `GeniusLocusKit` actor state. Rust recall does not yet wire a graph cache (follow-up, parallels the node-topology register seam) | `RecallDirectorTests.swift`, `RecallAbsentSignalTests.swift` (Swift) | Swift-only |
| Preference store | `PreferenceStore` (protocol) | none — Swift-only cold-path seam | public protocol / — | Cold-path preference-buffer lookup; held in `GeniusLocusKit` actor state. Rust recall does not yet wire a preference store (same follow-up as `GraphCache`) | `RecallDirectorTests.swift` (Swift) | Swift-only |

**Swift-only surfaces.** Two public protocols are present in Swift but have no
Rust counterpart yet, by deliberate deferral:

- `GraphCache`, `PreferenceStore` — the recall cold-path seams. Swift-only
  protocols held in actor state; the Rust recall path (`recall_scored`)
  does not yet wire them. The `col_graph` and `col_preference` scoring columns
  read 0.0 in Rust (no cache registered).

The node-topology coordinator register seam (`register_node_topology` /
`recall_tunnels` merge) is now fully wired in both ports — see the
`registerNodeTopology` section above.

Every other public concept — on the audit, projection, recovery, scheduler,
signal, matrix, training, grant, branch, verb, frame, and lexicon surfaces —
has a confirmed, test-bound counterpart in both ports.

No Apple-platform-binding types (Metal/BNNS/CoreML/CloudKit/Keychain) are
exported at the top level of GeniusLocusKit; the grant crypto uses the
in-repo `SubstrateKernel` (no CryptoKit).

---

## Swift/Rust Concordance — hydrate-on-launch

Both ports expose estate hydration: open an in-memory estate rebuilt from
a durable (SQLite) backend at launch.

### GeniusLocusKitSchema / composite_schema

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| Composite schema declaration | `GeniusLocusKitSchema.estateSchemaDeclaration: SchemaDeclaration` (`GeniusLocusKitSchema.swift`) | `composite_schema() -> SchemaDeclaration` (`hydration.rs`) | kitID / kit_id = "GeniusLocusKit". Version is derived from the live LocusKit, SynapseKit, and CorpusKit **attached-profile** declarations in both ports. The current declaration excludes standalone Corpus document/passage/chunk tables. Historical v7 conversion lives only in the optional floor-selected migration capsule, not this declaration or the core runtime. Component and composite cannot drift; conformance-tested by `CompositeSchemaVersionTests` / `composite_version_tests`. |

### Hydrate-on-open surface

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| Open with hydration | `GeniusLocusKit.open(inMemory: any Storage, owner: OwnerCredentials, hydrateFrom: any Storage) async throws -> EstateHandle` (`EstateHydration.swift`) | `open_hydrating(in_memory: Arc<InMemoryStorage>, durable: &dyn Storage, owner: OwnerCredentials, now: i64) -> Result<HydratedEstate, HydrateError>` (`hydration.rs`) | Six-step sequence: schema open both sides → replication::hydrate → Estate::open → audit log feed → MatrixTier::full_rebuild. Swift returns the handle (matrix tier stored in actor state); Rust returns `HydratedEstate { estate, unified_log, matrix_tier }`. |
| Flush in-memory → durable | `GeniusLocusKit.flush(from: any Storage, into: any Storage) async throws -> ReplicationCursor` (`EstateHydration.swift`) | `glk_flush(in_memory: &dyn Storage, durable: &dyn Storage) -> Result<ReplicationCursor, ReplicationError>` (`hydration.rs`, re-exported as `glk_flush`) | Opens both backends with composite schema then calls replication::flush. |
| Hydrate result | `EstateHandle` (handle to actor-registered estate) | `pub struct HydratedEstate { pub estate: Estate, pub unified_log: UnifiedAuditLog, pub matrix_tier: MatrixTier }` (`hydration.rs`) | Swift actor stores tier in `matrixTiers[handle]`. Rust caller must register the estate via `EstateCoordinator::open_estate_directly`. |
| Hydrate error | `GeniusLocusKitError` (Swift bubbles native errors) | `pub enum HydrateError { Replication(String), Estate(String), AuditFeed(String), Coordinator(String) }` (`hydration.rs`) | Rust stores `ReplicationError` as formatted string — `ReplicationError` only derives `Debug+PartialEq` (not `Clone+Eq`); formatting at boundary preserves full diagnostic while allowing `HydrateError: Clone+Eq`. |
| Register hydrated estate | `open(inMemory:owner:hydrateFrom:)` registers into actor | `EstateCoordinator::open_estate_directly(estate: Estate, zoom_window_low: i64, zoom_window_high: i64) -> Result<EstateHandle, GeniusLocusKitError>` (`hydration.rs`) | Used by the hydration path to admit an already-opened `Estate` without a second `Estate::open` call. Also available to tests. |

### Matrix rebuild concordance (full_rebuild)

Both passes must run in sequence for a fully-populated `MatrixTier`:

| Pass | Swift | Rust | What it populates |
|---|---|---|---|
| Pass 1 | `MatrixTier.rebuild(from:)` | `MatrixTier::rebuild(log)` | F, O, C matrices; `liveRowCount` / `live_row_count`; `lastHLC` / `last_hlc` |
| Pass 2 | `MatrixTier.rebuildTemporal(from:)` | `MatrixTier::rebuild_temporal(log)` | T matrix; `temporalWatermarkHLC` / `temporal_watermark_hlc` |
| Both | `MatrixTier.fullRebuild(from:) -> MatrixTier` (added in `MatrixTier.swift`) | `MatrixTier::full_rebuild(log: &UnifiedAuditLog) -> MatrixTier` (added in `matrix.rs`) | Runs rebuild + rebuild_temporal and merges into one tier. Swift merges via `addT`/`temporalWatermarkHLC` (inside-type access). Rust merges via direct field assignment. |

A `temporalWatermarkHLC == .zero` / `temporal_watermark_hlc == HLC::ZERO` on
a hydrated tier is a correctness signal that `full_rebuild` skipped pass 2.
Both round-trip test suites assert this condition.

### Hydrate round-trip test coverage

| Test | Swift file | Rust file |
|---|---|---|
| Drawers + KGFacts recall equivalence | `HydrateRoundTripTests.hydrateRoundTripDrawersAndKGFacts` | `hydrate_parity::hydrate_round_trip_drawers_and_kg_facts` |
| Matrix tier state equivalence (two-pass rebuild) | `HydrateRoundTripTests.hydrateRoundTripMatrixTierEquivalence` | `hydrate_parity::hydrate_round_trip_matrix_tier_equivalence` |

### Hydrate sequence schema gate

The `replication::hydrate` / `StorageReplicator.hydrate` gate checks that
both source and destination report schema version ≥ `schema.version`. The
composite GLK schema (version 3) must be opened on BOTH backends before
calling hydrate or flush:

- **Swift**: `storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)` on both.
  For SQLite this is `CREATE TABLE IF NOT EXISTS` + version bump (idempotent).
  For InMemory this applies migrations only if `schema_version < schema.version`.
- **Rust**: `storage.open(&composite_schema())` on both (same idempotency rules).

---

---

## IntellectusLib Telemetry

### Dependency

GeniusLocusKit depends on `IntellectusLib` (the zero-dependency
telemetry leaf library). This dependency is additive and non-inverting:
`GeniusLocusKit` (composition layer) → `IntellectusLib` (floor).

- **Swift**: `Package.swift` target `GeniusLocusKit` declares
  `.product(name: "IntellectusLib", package: "IntellectusLib")` in both
  `target` and `testTarget` dependencies. Citation:
  `the package-dependency rule`.
- **Rust**: `Cargo.toml` declares
  `intellectus-lib = { path = "../../../libs/IntellectusLib/rust" }`.
  Citation: `the package-dependency rule` (Rust layering
  equivalent: no inversion rule).

### Swift surface

```swift
// In GeniusLocusKitTelemetry.swift:
enum GLKMetricName {
    static let mountStateTransition = "geniuslocus.estate.mount_state_transition"
    static let provision           = "geniuslocus.estate.provision"
    static let nounCount           = "geniuslocus.estate.noun_count"
    static let verbError           = "geniuslocus.estate.verb_error"
}

@inline(__always)
func glkEmit(name: String, value: Double, tags: [String: String], now: Date)

// EstateCoordinator.swift — extended remap with estate_id (default ""):
private func remap(verb: String, estateID: String = "", error: Error) -> Error
```

All emit sites inside `open`, `close`, `provision`, `quiesce`, `drain`,
and the nine ARIA verb `remap` call sites pass
`estateID: handle.estateUUID.uuidString`.

### Rust surface

```rust
// In telemetry.rs:
pub mod metric_names {
    pub const MOUNT_STATE_TRANSITION: &str = "geniuslocus.estate.mount_state_transition";
    pub const PROVISION:              &str = "geniuslocus.estate.provision";
    pub const NOUN_COUNT:             &str = "geniuslocus.estate.noun_count";
    pub const VERB_ERROR:             &str = "geniuslocus.estate.verb_error";
}
pub fn now_secs() -> f64;

// glk_emit! macro (coordinator.rs):
glk_emit!(metric_names::MOUNT_STATE_TRANSITION, 1.0, { /* HashMap */ });

// coordinator.rs — extended remap signature:
fn remap(verb: &str, estate_id: &str, error: LocusKitError) -> VerbError

// uuid_to_str helper:
fn uuid_to_str(bytes: &[u8; 16]) -> String
```

All nine ARIA verb `remap` call sites pass
`&uuid_to_str(&handle.estate_uuid)`. Utility method call sites (e.g.
`add_kg_fact`, `recall_kg_facts`) pass `""` (no metric emitted).

### Test isolation pattern

Both ports use a process-wide lock to prevent concurrent tests from
leaking metrics into each other's capturing sinks:

- **Swift**: `IntellectusTestMutex` (actor-based FIFO cooperative mutex)
  defined in `Tests/.../IntellectusTestLock.swift`. Every test that
  touches the singleton calls `withIntellectusLock { ... }`.
- **Rust**: `static GLOBAL_LOCK: OnceLock<Mutex<()>>` with `into_inner()`
  poison recovery. Every test calls `global_lock()` first.

---

## Swift/Rust Concordance — topology graph surface (relocated to NeuronKit)

`graphTopology` and the `GraphTopology*` types moved to NeuronKit — analysis
is the algorithms layer's lane, and GLK gained no replacement symbols (the
caller, aria-mcp, reads the estate through GLK's existing raw surface and
hands plain descriptors to NeuronKit). See
`NEURONKIT_INTERFACE.md` § topology-analysis for the current
signatures in both legs, and `NEURONKIT_SPEC.md` § TOPOLOGY_ANALYSIS
for the contract.

---

## Estate read surface for NeuronKit

### Swift interface

```swift
// Temporal fingerprint forwarding (TemporalReads.swift) — NeuronKit B-1:
// Forward DrawerStore temporal reads through the GLK estate surface so
// NeuronKit never imports LocusKit directly. Uses the DrawerStore
// lazy-cache pattern (storages[handle] → DrawerStore cached in
// fingerprintStores[handle]).

/// Returns fingerprints of all non-tombstoned drawers captured in `window`.
/// Forwards to DrawerStore.fingerprintsCaptured(in:).
/// - Throws: `.estateNotOpen` for a stale handle; SQLite errors on failure.
public func glkFingerprintsCaptured(
    in handle: EstateHandle,
    window: ClosedRange<Date>
) async throws -> [Fingerprint256]

/// Returns a time-bucketed bit series for one fingerprint bit position.
/// Forwards to DrawerStore.fingerprintBitSeries(bit:bucketSeconds:bucketCount:endingAt:).
/// Result is `bucketCount` Bools, index 0 = oldest.
/// - Throws: `.estateNotOpen`; `.invalidContent` on bad parameters.
public func glkFingerprintBitSeries(
    in handle: EstateHandle,
    bit: Int,
    bucketSeconds: Int,
    bucketCount: Int,
    endingAt: Date
) async throws -> [Bool]

// Lag-pair derivation (EventLagPairs.swift) — NeuronKit B-1:
// Reads UnifiedAuditLog and returns entries in the TemporalCausalityFold
// input shape. Caller passes the result to TemporalCausalityFold.fold.

/// Returns HLC-ascending TemporalAuditEntry values filtered to `window`.
/// Only Capture and Expunge verbs produce non-empty field coordinates.
/// Returns [] rather than throwing if no audit log exists for the handle.
/// - Throws: `.estateNotOpen` for a stale handle.
public func glkEventLagPairs(
    in handle: EstateHandle,
    window: ClosedRange<Date>,
    lagBuckets: [Int] = MatrixTier.lagBuckets
) async throws -> [TemporalAuditEntry]

// Calibration reads/writes (CalibrationReads.swift) — NeuronKit B-1:
// Per-model 20-bucket calibration curve. Lazy decay applied at write time.

/// Returns the 20-bucket calibration curve for `modelID`, or nil if unknown.
/// - Throws: `.estateNotOpen` for a stale handle.
public func glkCalibrationCurve(
    for handle: EstateHandle,
    modelID: String
) async throws -> MatrixCalibrationCurve?

/// Record one LLM prediction outcome. Applies 30-day-half-life lazy decay
/// before recording. Persists a MatrixSnapshot if a backend is registered.
/// - Throws: `.estateNotOpen`; underlying persistence errors.
public func glkRecordCalibrationOutcome(
    for handle: EstateHandle,
    modelID: String,
    claimedConfidence: Float,
    succeeded: Bool,
    at now: Date
) async throws

/// Wire a MatrixPersistenceBackend to the estate. Loads any existing snapshot
/// to seed calibrationRegistries[handle] and (if absent) matrixTiers[handle].
/// - Throws: `.estateNotOpen`; underlying persistence errors on load.
public func registerMatrixPersistence(
    _ backend: MatrixPersistenceBackend,
    for handle: EstateHandle
) async throws
```

**Source files:**
- `Sources/GeniusLocusKit/Brain/TemporalReads.swift`
- `Sources/GeniusLocusKit/Brain/EventLagPairs.swift`
- `Sources/GeniusLocusKit/Brain/CalibrationReads.swift`
- `Sources/GeniusLocusKit/Matrix/Calibration.swift` (decay methods)

### Rust interface

```rust
// Per-window fingerprint read — mirror of glkFingerprintsCaptured.
// Forwards EstateCoordinator → Estate::fingerprints_captured_in →
// DrawerStore::fingerprints_captured_in. Returns the fingerprints of every
// non-tombstoned drawer captured in the closed epoch-seconds window
// [start_epoch, end_epoch], HLC-ascending. The Moment lens (CognitionKit)
// reads both its windows through this surface so aria-mcp/NeuronKit never
// touch the LocusKit store directly (B-1).
impl EstateCoordinator {
    pub fn glk_fingerprints_captured(
        &self,
        handle: &EstateHandle,
        start_epoch: i64,
        end_epoch: i64,
    ) -> Result<Vec<Fingerprint256>, VerbDispatchError>;
}

// Pure function mirroring glkEventLagPairs (brain/event_lag_pairs.rs).
// Caller supplies a pre-sorted (ordered_entries()) slice and ms window bounds.
pub fn event_lag_pairs(
    entries: &[UnifiedAuditEntry],
    lower_ms: i64,
    upper_ms: i64,
) -> Vec<TemporalAuditEntry>

// Decay-aware calibration record (matrix/calibration.rs).
// now_unix_secs is seconds since Unix epoch.
impl MatrixCalibrationRegistry {
    pub fn record_with_decay(
        &mut self,
        model_id: &str,
        claimed_confidence: f32,
        outcome: MatrixCalibrationOutcome,
        now_unix_secs: f64,
        half_life_days: f64,
    );
}

// Bucket and curve decay helpers.
impl MatrixCalibrationBucket {
    pub fn apply_decay(&mut self, factor: f64);
}
impl MatrixCalibrationCurve {
    pub fn apply_decay(&mut self, elapsed_days: f64, half_life_days: f64);
}
```

**Rust source files:**
- `rust/src/brain/event_lag_pairs.rs`
- `rust/src/matrix/calibration.rs`

**Conformance gate:** `tests/dormant_surfaces.rs` — 14 tests covering all
coord encodings, window filter, ordering, calibration round-trip, and 30-day
decay math. Same fixture constants as `GLKDormantSurfacesTests.swift`.

---

## Swift/Rust Concordance — additional public types

Types present in the GLK source but not yet covered by a named concordance
section above.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Write execution mode | `WriteMode` (`Intake/EncodeIntake.swift`) | `WriteMode` (`rust/src/intake.rs`) | public enum / pub enum | identical 2-case enum (regular/Regular, impatient/Impatient) | `EncodeIntakeTests.swift` / `encode_intake_parity` | Confirmed |
| Expunge sweep result | `ExpungeIntegritySweepResult` (`Verbs/VerbSurface.swift`) | `ExpungeIntegritySweepResult` (`rust/src/coordinator.rs`) | public struct / pub struct | identical 3-field struct (remediatedCount/remediated_count, orphanedCount/orphaned_count, perRowErrors/per_row_errors) | `VerbSurfaceTests.swift` / `coordinator_tests` | Confirmed |
| Recall origin tag | `RecallOrigin` (`RecallDirector/GLKRecallRequest.swift`) | `RecallOrigin` (`rust/src/recall.rs`) | public enum / pub enum | identical 2-case enum (local/Local, crossEstate/CrossEstate) | `RecallDirectorTests.swift` / `recall_tests` | Confirmed |
| Recall fusion steering | `RecallShape` (`RecallDirector/RecallShape.swift`) | `RecallShape` (`rust/src/recall.rs`) | public struct / pub struct | signed `laneWeights`/`lane_weights` (retrieval keys `locus`/`bm25`/`hamming`/`dense`/`dense:<modelID>` + matrix/graph/preference keys `fieldFit`/`coOccurrence`/`temporal`/`graph`/`preference` + column-budget keys `signal:*` (`RecallShape.SignalKey` / `RecallShape::SIGNAL_*`), missing ⇒ 1.0) + `antiSimilarLanes`/`anti_similar_lanes` (FARTHEST dense lanes) + optional clamped `frontierK`/`frontier_k`; `weight(for:)`/`weight()`, `isAntiSimilar(_:)`/`is_anti_similar()`, and `effectiveFrontierK`/`effective_frontier_k` accessors; `[64,256]` frontier envelope | `RecallShapeSignedWeightTests.swift` + `RecallShapeAntiSimilarTests.swift` + `RecallShapeMatrixSteerTests.swift` / `recall_shape_signed_weight_parity` + `recall_shape_anti_similar_parity` + `recall_shape_matrix_steer_parity` | Confirmed |
| Serial-lane dispatcher | — | `CoordinatorDispatcher` (`rust/src/brain/scheduler/serial_lane.rs`) | — / pub struct | Rust-only internal dispatcher for the serial scheduling lane; no Swift parity (Brain scheduling is async actor lanes in Swift) | `scheduler_tests` | Confirmed (Rust-only) |
| Serial-lane noop dispatcher | — | `NoopDispatcher` (`rust/src/brain/scheduler/serial_lane.rs`) | — / test-only | Rust test stub gated `#[cfg(any(test, feature = "test-seams"))]` — compiled OUT of the production binary (not a shipped public symbol). Integration tests reach it via the `test-seams` feature. No Swift equivalent | scheduler/standing-signals/rag-wiring/coordinator-dispatcher parity tests | Confirmed (test-only) |
| Grant-store error | — | `GrantStoreError` (`rust/src/grants/grant_store.rs`) | — / pub enum | Rust-only error enum for the grants persistence layer; Swift errors bubble as `GeniusLocusKitError` (no distinct grant-store type) | grant tests | Confirmed (Rust-only) |
| Sync-engine entry | — | `SyncEngineEntry` (`rust/src/coordinator.rs`) | — / pub struct | Rust-only coordinator state record for the sync engine; no Swift parallel (sync lifecycle managed via actor state) | coordinator tests | Confirmed (Rust-only) |
| Training brain signal | `TrainingSignal` (`Brain/Signals/TrainingSignal.swift:42`, `public enum`) | `TrainingSignal` (`rust/src/brain/signals/training.rs:24`, `pub struct`) | public / pub | Swift enum namespace and Rust unit-struct namespace. Both expose `spec(trainingCycle:)`/`spec(training_cycle)` and `defaultSpec()`/`default_spec()`. Signal name `"training-daemon"`, hourly cadence (3 600 s). Wired per the brain-layer ownership contract F1. NT-DOC-1. | `StandingSignalsTests.swift` ↔ `distillation_signal_tests.rs` (covers both brain signals) | Confirmed |
| Contradiction hunt pass | `GeniusLocusKit.huntContradictions(in:modelID:probeLimit:filedAfter:proximityThreshold:now:)` (`Brain/ContradictionHunt.swift`) | `EstateCoordinator::hunt_contradictions(handle, model_id, probe_limit, filed_after, proximity_threshold, now)` (`rust/src/coordinator.rs`) | public / pub | identical pass: candidates from `recentItemIDs` newest-first probes mined on TWO lanes — Lane 1 drawer-keyed binary Hamming kNN under the caller's modelID (`getVector` → `findNearest` limit 5, proximity ≤ 64) for bespoke/test-planted vectors; Lane 2 (when a Corpus is registered — the ONLY lane production estates populate) LEXICAL via the corpus's persistent BM25 inverted index (`Corpus.bm25TopKBySource(query:limit:)`, `huntBM25CandidateK` = 20 per probe, query capped to `huntBM25QueryCharLimit` = 240 chars), which returns SOURCE drawer IDs directly. BM25 not vectors on the corpus lane: contradictions are lexically similar (the shared-term notion ConflictCue screens on), and the binary SimHash space is degenerate at estate scale (109k estate buried a true twin at rank #399) while a whole-partition float scan is ~3 s/probe. Both lanes dedupe on drawer-pair keys, then SubstrateML conflict-cue screen; strong cue (≥ 0.70) → `capture(TunnelCaptureFrame(kind: .contradicts, lifecycle: .proposed, originClass: .derived))`, borderline (≥ 0.45) → returned with ≤ 160-char snippets, never persisted; durable dedup vs ALL contradicts tunnels incl. withdrawn; `filedAfter` watermark; `vectorStoreAvailable` status flag | `ContradictionHuntTests.swift` (incl. corpus-lane test) ↔ `coordinator.rs` hunt tests | Confirmed |
| Contradiction hunt report | `ContradictionHuntReport` / `ProposedContradiction` / `BorderlineContradiction` (`Brain/ContradictionHunt.swift`) | `ContradictionHuntReport` / `ProposedContradiction` / `BorderlineContradiction` (`rust/src/coordinator.rs`) | public / pub | identical field sets (vectorStoreAvailable/probesScanned/pairsScreened/proposed/borderline/deduplicated; borderline adds sourceSnippet/targetSnippet) | `ContradictionHuntTests.swift` ↔ `coordinator.rs` hunt tests | Confirmed |
| Contradiction-scout brain signal | `ContradictionScoutSignal` (`Brain/Signals/ContradictionScoutSignal.swift`, `public enum`) | `ContradictionScoutSignal` (`rust/src/brain/signals/contradiction_scout.rs:19`, `pub struct`) | public / pub | Swift enum namespace and Rust unit-struct namespace. Both expose `spec(huntCycle:)`/`spec(hunt_cycle)` (production wiring; the hunt persists its own writes, the signal emits one summary diagnostic) and `defaultSpec()`/`default_spec()`. Signal name `"contradiction-scout"`, hourly cadence (3 600 s). Registered 4th in `registerDefaultStandingSignals`. | `StandingSignalsTests.swift` ↔ `standing_signals_parity.rs` | Confirmed |
| Tiered contradiction search | `GeniusLocusKit.tieredContradictionSearch(in:tier:topK:modelID:probeLimit:now:)` (`Brain/TieredContradictionSearch.swift`) | `EstateCoordinator::tiered_contradiction_search(handle, tier: Option<ContradictionTier>, top_k, model_id, probe_limit, now)` (`rust/src/coordinator.rs`) | public / pub | one search verb, two modes: `tier` nil/None runs SYNTHESIS (all three lanes, promote-to-highest-tier dedup on the case-canonical pair key, over-fetch backfill K/2K/3K, sections always in tier order 1-2-3, never interleaved); a specific tier runs ONLY that lane with no cross-tier dedup (purpose-run answers its own question). Tier 1 = typed proving sweep (`conflictProjectionSweep`), ranked by endpoint-event recency (no lexical score — the absence is load-bearing); tiers 2/3 share ONE lexical retrieval pass (`lexicalTierScan` / `lexical_tier_scan`, the hunter's retrieval + ConflictCue screen factored out). `topK` clamped to `TieredContradictionCore.topKCeiling` / `TIERED_TOP_K_CEILING` = 50; non-positive → deterministic empty report. Tier-1 findings above the Elevated raw sensitivity ceiling are filtered and counted (`tier1CeilingFiltered`). Read-and-report ONLY: no writes. `now` unconsumed (signature stability). | `TieredContradictionSearchTests.swift` ↔ `tiered_contradiction_search.rs` tests | Confirmed |
| Tiered search report | `TieredContradictionReport` / `TierFinding` / `TierLaneCounts` / `TieredSearchDiagnostics` / `TieredSearchMode` / `ContradictionTier` (`Brain/TieredContradictionSearch.swift`) | same names (`rust/src/brain/tiered_contradiction_search.rs`) | public / pub | identical shapes: per-tier sections tier1/tier2/tier3 + per-lane counts (fetched/returned/promotedAway/backfilled) + diagnostics (vectorStoreAvailable, probesScanned, sweepTruncatedBuckets, per-tier candidates, tier1CeilingFiltered). `ContradictionTier` raw values 1/2/3 = typedProven / lexicalStructural / lexicalValue (P1 `ConflictCueKind.contradictionTier` mapping: tier 2 = negation_asymmetry, marker_revision, word_exclusion; tier 3 = value_divergence). `TierFinding` is a flat tagged union: tiers 2/3 carry cueKind/score/snippets, tier 1 carries ruleID/resultID/coordinateDigest/sensitivityCeilingRaw. | `TieredContradictionSearchTests.swift` ↔ `tiered_contradiction_search.rs` tests | Confirmed |
| Conflict-tunnel proposal pass | `GeniusLocusKit.proposeConflictTunnels(in:registry:modelID:probeLimit:lexicalTopK:now:)` (`Brain/ConflictTunnelLifecycle.swift`) | `EstateCoordinator::propose_conflict_tunnels(handle, model_id, probe_limit, lexical_top_k, now)` (`rust/src/coordinator.rs`) | public / pub | files PROPOSED `contradicts` tunnels at ALL tiers that survive the decline matrix: tier 1 from the typed sweep (label `dcp: <rule>@<version> result=<id>`), tiers 2/3 from the shared lexical pass (labels `tier2:<cue>@<cueVersion>` / `tier3:<cue>@<cueVersion>`, `conflictCueVersion` = 1 is the rejection-renewal key). Decline matrix: a rejection at a HIGHER tier class suppresses re-filing regardless of label; same tier suppresses only the same renewal key; a LOWER tier never suppresses. Live pairs (any label family) dedupe; `hunter:` labels sit outside the matrix. Report adds `proposedTier2IDs`/`proposedTier3IDs` + aggregated `suppressed` + `ceilingSkipped` (typed findings above Elevated, counted apart). Rust exposes `rejection_tier_of_label` pub; Swift keeps the mapping internal. | `TunnelReviewLadderTests.swift` + `ConflictTunnelLifecycle` tests ↔ `conflict_projection_sweep.rs` tests | Confirmed |
| Tunnel review ladder verbs | `GeniusLocusKit.endorseTunnel(in:tunnelID:endorserID:tierLens:now:)` / `objectToTunnel(in:tunnelID:reviewerID:tierLens:now:)` (`Brain/TunnelReviewLadder.swift`) → `TunnelEndorsementOutcome` / `TunnelObjectionOutcome` | `EstateCoordinator::endorse_tunnel(handle, tunnel_id, endorser_id, tier_lens, now) -> (new_endorser, distinct_endorsers, contested)` / `object_to_tunnel(...) -> (withdrawn, contested)` (`rust/src/coordinator.rs`) | public / pub | model-reviewer half of the Rejected/Proposed/Endorsed/Accepted ladder. Endorse: one vote per distinct endorser (idempotent re-endorsement refreshes its timestamp), sets endorsed bit 14, contested bit 15 when the ledger also holds a model objection; lifecycle NEVER touched — there is deliberately no path from endorsements to `.active`; only the user activates via `Estate.respondToTunnel(accept: true)`. Object: no model endorsement → lifecycle `.withdrawn` (AI-rejected, reopenable — the ledger's objection entry is the record); endorsement exists → stays `.proposed`, contested bit set. Both throw/`Err` on not-found, not-proposed, empty reviewer id, corrupt ext ledger (fail-loud). | `TunnelReviewLadderTests.swift` ↔ `coordinator.rs` ladder tests | Confirmed |
| Review-queue ranking | `ReviewQueueRanking` (`Brain/ReviewQueueRanking.swift`) | `review_queue` (`rust/src/brain/review_queue.rs`) | public / pub | deterministic ordering for proposed-tunnel review queues: tier class first (1 before 2 before 3), contested-first within a tier band, endorser-diversity weight (model-family prefix before the first `-`/`:`), then recency. Endorsement weight feeds THIS ranking only — no vote total activates anything. | `TunnelReviewLadderTests.swift` ↔ `review_queue.rs` tests | Confirmed |
| Dataset store accessor | `GeniusLocusKit.datasetStore(for:)` (`DatasetStoreAccess.swift`) | — | public func / (none) | Swift-only coordinator seam added by MX-TAB-7. Returns `any DatasetStore` for an open estate handle; throws `.estateNotOpen` or `StorageError.featureGated("datasetStore")`. No counterpart on `EstateCoordinator` — raw-table access in Rust goes directly to the estate's storage backend. | `DatasetStoreAccessTests.swift` | Swift-only |
| Dataset signature compute | `computeDatasetSignatures(handle:drawerId:columns:columnStats:sampledRows:now:)` (`Intake/DatasetSignatures.swift`) | `compute_dataset_signatures(estate, drawer_id, columns, column_stats, sampled_rows)` (`rust/src/dataset_signatures.rs`) | public func (GLK extension) / pub fn (free function) | Both ports: SHA-256 table signature (domain tag 0x10, sample size 128) + per-column signatures (domain tag 0x11). Rust is a free function taking `&Estate` directly (not on `EstateCoordinator`), matching the Rust sync model. Byte-identical preimage format; cross-leg anchor hashes locked in both test suites. Constants: `datasetSignatureSampleSize`/`DATASET_SIGNATURE_SAMPLE_SIZE` = 128; Rust additionally exports `DATASET_SIGNATURE_TOP_K` = 20. | `DatasetSignaturesTests.swift` ↔ `dataset_signatures_tests.rs` | Confirmed |

---

## Retired adornment orchestration

The active-minter registry and adornment pass are removed from the product.
The current span-encode duty uses the former REM-ALPHA slot. See
[the retirement ledger](../decisions/DECISION_RETIRED_TECHNIQUES_LEDGER.md).

## Span encoder activation (`embedding_provider = "encoder"`)

The `embedding_provider` manifest key accepts the value `"encoder"` on both
ports. At wire time (`wireSubstores` / `wire_substores` + `provision`) the
lifecycle leaves the Corpus ensemble exactly as configured and activates the
span encoder instead: it seeds the active `encoder_models` row from
`EncoderModelSeed` when the registry holds none (3.2.0), reads that row (the
floor spec `minilm-l6-v2-w60` only for a stale handle), resolves the
model directory through the installed `ModelDirectoryResolving`, and builds
the encoder with `SpanEncoderFactory` at the estate's `encoder_batch`.

**Failure contract (both ports):** a `nil` / `None` directory, a vocabulary
hash mismatch or a load failure leaves the estate with no encoder for the
session, emits ONE log line (OSLog `GeniusLocusKit` category / stderr
`mootx01 encoder:`), and raises nothing to the caller. Recall runs
lexical-only.

```swift
public protocol ModelDirectoryResolving: Sendable {
    func encoderModelDirectory(for modelID: String) -> URL?
}
public struct NilModelDirectoryResolver: ModelDirectoryResolving   // default: nil for every id

extension GeniusLocusKit {
    static var encoderProviderID: String     // "encoder"
    static var encoderHeadMetaKey: String    // "encoder_head"   (Int, default 30)
    static var encoderBatchMetaKey: String   // "encoder_batch"  (Int, default 16 on iOS, 64 elsewhere)
    static var defaultEncoderHead: Int
    static var defaultEncoderBatch: Int
    func registerSpanEncoder(_ encoder: any SpanEncoder, for handle: EstateHandle)
    func registeredSpanEncoder(for handle: EstateHandle) -> (any SpanEncoder)?
    /// True while the span rerank stage is registered (encoder loaded and the
    /// estate's VectorStore registered); the ARIA discrimination cap reads it.
    func isSpanRerankRegistered(for handle: EstateHandle) -> Bool
    func setModelDirectoryResolver(_ resolver: any ModelDirectoryResolving)
    func provisionEncoderHead(_ head: Int, for handle: EstateHandle) async throws
    func provisionedEncoderHead(for handle: EstateHandle) async -> Int
    func provisionEncoderBatch(_ batch: Int, for handle: EstateHandle) async throws
    func provisionedEncoderBatch(for handle: EstateHandle) async -> Int
    func activeEncoderModelSpec(for handle: EstateHandle) async -> EncoderModelSpec
    func activateSpanEncoder(for handle: EstateHandle) async
    /// The bundled encoder (`EncoderModelSeed`) as an `encoder_models` row; the
    /// one construction site for the seed row.
    static func defaultEncoderModelRow(isActive: Bool) -> EncoderModelRow
    /// Seed the bundled encoder as the active row when `registry` holds none;
    /// true when written. `activateSpanEncoder` calls the handle form at open;
    /// the upgrade backfill calls this form over a closed estate's storage.
    static func seedDefaultEncoderModel(in registry: EncoderModelStore) async throws -> Bool
    @discardableResult
    func seedDefaultEncoderModelIfAbsent(for handle: EstateHandle) async throws -> Bool
    /// Write `embedding_provider = "encoder"` when the estate names no provider;
    /// true when written. Called by `provision`, the product create paths and
    /// the upgrade span-encode step — never by a serve-time open.
    @discardableResult
    func provisionDefaultEncoderIfAbsent(for handle: EstateHandle) async throws -> Bool
}
```

```rust
pub trait ModelDirectoryResolving: Send + Sync { fn model_dir_for(&self, model_id: &str) -> Option<PathBuf>; }
pub struct NilModelDirectoryResolver;

impl EstateCoordinator {
    pub const ENCODER_PROVIDER_ID: &str = "encoder";
    pub const ENCODER_HEAD_META_KEY: &str = "encoder_head";
    pub const ENCODER_BATCH_META_KEY: &str = "encoder_batch";
    pub const DEFAULT_ENCODER_HEAD: usize = 30;
    pub const DEFAULT_ENCODER_BATCH: usize = 64;
    pub fn register_span_encoder(&mut self, handle: &EstateHandle, encoder: Arc<dyn SpanEncoder>);
    pub fn registered_span_encoder(&self, handle: &EstateHandle) -> Option<Arc<dyn SpanEncoder>>;
    pub fn is_span_rerank_registered(&self, handle: &EstateHandle) -> bool;
    pub fn set_model_directory_resolver(&mut self, resolver: Box<dyn ModelDirectoryResolving>);
    pub fn provision_encoder_head(&self, handle: &EstateHandle, head: usize) -> Result<(), VerbDispatchError>;
    pub fn provisioned_encoder_head(&self, handle: &EstateHandle) -> usize;
    pub fn provision_encoder_batch(&self, handle: &EstateHandle, batch: usize) -> Result<(), VerbDispatchError>;
    pub fn provisioned_encoder_batch(&self, handle: &EstateHandle) -> usize;
    pub fn active_encoder_model_spec(&self, handle: &EstateHandle) -> EncoderModelSpec;
    pub fn activate_span_encoder(&mut self, handle: &EstateHandle);
    pub fn default_encoder_model_row(is_active: bool) -> EncoderModelRow;
    pub fn seed_default_encoder_model_in(registry: &EncoderModelStore) -> Result<bool, LocusKitError>;
    pub fn seed_default_encoder_model_if_absent(&self, handle: &EstateHandle) -> Result<bool, VerbDispatchError>;
    pub fn apply_provisioned_embedding_provider(&mut self, handle: &EstateHandle);   // now &mut self
    /// Twin of provisionDefaultEncoderIfAbsent(for:).
    pub fn provision_default_encoder_if_absent(&self, handle: &EstateHandle) -> Result<bool, VerbDispatchError>;
}
```

Manifest values are plain decimal text; an absent, malformed or non-positive
value reads as the default and never breaks an open. `close` drops the
encoder registration with the Corpus and VectorStore registrations. The Rust
kit compiles the candle runtime only under the `encoder` Cargo feature
(`corpus-kit-providers/candle`); the product crate `apps/mootx01/rust`
enables it by default, and a build without it still honours the contract
(model unavailable, lexical-only).

*End of GeniusLocusKit Interface.*


## Cross-encoder activation (`rerankDirective: .apply`, 3.17.0)

The cross-encoder stage has no open-time activation: the first `apply` on
an estate resolves `ms-marco-minilm-l6-cross-v1` through the installed
`ModelDirectoryResolving`, builds the scorer with `PairScorerFactory` once
and keeps it until `close`; a failed load is remembered. The manifest keys
`cross_encoder_pool`, `cross_encoder_head`, `cross_encoder_spans` (positive
integers as text) lower the profile's maxima; `cross_encoder_profile` is
informational. Compile gate: Swift trait `CrossEncoder`
(`MOOTX01_CROSS_ENCODER`), Rust feature `cross-encoder`; off, an apply
degrades with `capability_off`. Full signatures, the stage's pure
functions and the report: `CROSSENCODER_INTERFACE.md`.

```swift
extension GeniusLocusKit {
    static var crossEncoderPoolMetaKey / crossEncoderHeadMetaKey / crossEncoderSpansMetaKey / crossEncoderProfileMetaKey: String
    static var packagedCrossEncoderProfiles: [String: CrossEncoderProfile]
    func registerPairScorer(_ scorer: any PairScorer, for handle: EstateHandle)
    func isPairScorerRegistered(for handle: EstateHandle) -> Bool
    func provisionCrossEncoderLimits(pool: Int, head: Int, spans: Int, for handle: EstateHandle) async throws
    func provisionedCrossEncoderLimits(profile: CrossEncoderProfile, for handle: EstateHandle) async -> CrossEncoderLimits
}
```

```rust
impl EstateCoordinator {
    pub const CROSS_ENCODER_POOL_META_KEY / CROSS_ENCODER_HEAD_META_KEY / CROSS_ENCODER_SPANS_META_KEY / CROSS_ENCODER_PROFILE_META_KEY: &str;
    pub fn packaged_cross_encoder_profile(profile_id: &str) -> Option<CrossEncoderProfile>;
    pub fn register_pair_scorer(&mut self, handle: &EstateHandle, scorer: Arc<dyn PairScorer>);
    pub fn is_pair_scorer_registered(&self, handle: &EstateHandle) -> bool;
    pub fn provision_cross_encoder_limits(&self, handle: &EstateHandle, pool: usize, head: usize, spans: usize) -> Result<(), VerbDispatchError>;
    pub fn provisioned_cross_encoder_limits(&self, handle: &EstateHandle, profile: &CrossEncoderProfile) -> CrossEncoderLimits;
    pub fn pair_scorer_for(&self, handle: &EstateHandle, profile: &CrossEncoderProfile) -> Result<(Arc<dyn PairScorer>, bool), String>;
}
```

## Estate catalog (`EstateCatalog.swift`; Rust `estate_catalog.rs`)

The catalog surface every mootx01 command and daemon uses to find an
estate. Spec § ESTATE_CATALOG.

**Rust twin** (`genius_locus_kit::{EstateCatalog, EstateRecord,
EstateRecordKind, EstateBackend, EstateManifest, EstateManifestEncryption,
EstateCatalogError, EstateSelector, EstateCatalogNames}`): the same names in
snake case — `EstateCatalogNames::{CATALOG_FILE, DATABASES_FOLDER,
DEFAULT_ESTATE, MANIFEST, PID, DATABASE, …, LEGACY_ENCRYPTION_OPT_OUT}`;
`EstateRecord::{new(name, directory), with(name, directory, kind, backend),
manifest_path, pid_path, database_path, …, legacy_encryption_opt_out_path,
selector_argument, owned_file_paths}`; `EstateManifest::new(name,
schema_version, format_version, encryption, created)` with
`CURRENT_FILE_VERSION` and `ALLOWED_KEYS`; `EstateSelector::parse(value)`
with `name`, `path: Option<PathBuf>`, `directory()`;
`EstateCatalog::{configuration_directory, catalog_path,
initial_default_location, records, active, directory_for_bare_name, create,
load, open, open_selecting(value), record_named, record_at_directory(&Path),
registered_record_selecting(value) -> Result<Option<&EstateRecord>, _>,
register(name, directory, backend), register_value(value), move_default,
relocate, rename, activate, remove, read_manifest, verify_files_stay_inside,
write_manifest, is_valid_name}` and the `default_location` field. Under the `test-seams`
feature, `EstateCatalog::set_configuration_directory_override(Option<PathBuf>)`
redirects the configuration directory for a dependant's tests. The
configuration directory comes from the `moot-product-identity` crate
(`packages/libs/MootProductIdentity/rust`), which reads the same
`product_identity.json` fixture as the Swift module.

- `public enum EstateCatalogNames` — the fixed file names: `catalogFile`
  (`estatecatalog.json`), `databasesFolder` (`databases`), `defaultEstate`
  (`default`), `manifest` (`estate.json`), `pid` (`estate.pid`), `database`
  / `databaseWAL` / `databaseSHM` (`estate.sqlite`, `-wal`, `-shm`),
  `queue` / `queueWAL` / `queueSHM` (`estate.queue.sqlite`, `-wal`, `-shm`),
  `vectors` (`estate.vectors.vec`), `drainLease` (`encode.drain.lease`),
  `legacyEncryptionOptOut` (`no-encrypt`).
- `public enum EstateRecordKind: String, Sendable, Codable, Equatable { case
  registered, transient }`.
- `public enum EstateBackend: Sendable, Codable, Equatable { case sqlite,
  postgresql(connectionString: String) }` — `kindName: String` (`sqlite` /
  `postgresql`); encodes as `{"kind": ...}` plus `connectionString` for
  PostgreSQL, and decoding refuses a PostgreSQL entry without a non-empty
  connection string, a SQLite entry with one, or an unknown kind.
- `public struct EstateRecord: Sendable, Codable, Equatable` — `name`,
  `directory: URL`, `kind`, `backend: EstateBackend`
  (`init(name:directory:kind: = .registered, backend: = .sqlite)`);
  derived `manifestURL`, `pidURL`, `databaseURL`, `databaseWALURL`,
  `databaseSHMURL`, `queueURL`, `queueWALURL`, `queueSHMURL`, `vectorsURL`,
  `drainLeaseURL`, `legacyEncryptionOptOutURL`; `selectorArgument: String`
  (the name when registered, the directory path when transient);
  `ownedFileURLs: [URL]` (manifest, pid, database and its WAL/SHM, queue and
  its WAL/SHM, vectors, drain lease, in that order; the legacy marker is not
  an owned file).
- `public struct EstateManifest: Sendable, Codable, Equatable` —
  `currentFileVersion = 1`; `enum Encryption: String { encrypted, plaintext }`;
  `allowedKeys: Set<String>` (`fileVersion`, `name`, `schemaVersion`,
  `formatVersion`, `encryption`, `created`); stored `fileVersion`, `name`,
  `schemaVersion: Int`, `formatVersion: EstateFormatVersion`, `encryption`,
  `created: String`; `init(name:schemaVersion:formatVersion:encryption:created:)`.
- `public enum EstateCatalogError: Error, Sendable, Equatable,
  CustomStringConvertible` — `unreadableCatalog(url:detail:)`,
  `unwritableCatalog(url:detail:)`, `emptyCatalog(url:)`, `invalidName(_:)`,
  `duplicateName(_:)`, `unknownName(_:)`, `cannotRemoveActive(_:)`,
  `unregisteredWithoutPath(_:)`, `notAvailableInThisVersion(operation:)`,
  `unreadableEstateManifest(url:detail:)`.
- `public struct EstateCatalog: Sendable, Equatable` — statics `fileName`,
  `productIdentifier`, `defaultName`, `configurationDirectory: URL`,
  `catalogURL: URL`, `initialDefaultLocation: URL`; stored `defaultLocation:
  URL`, `records: [EstateRecord]` (read-only outside the type), `active:
  EstateRecord` (index zero); `directory(forBareName:) -> URL`;
  `static create() throws`, `static load() throws`, `static open() throws`,
  `static open(selecting: String) throws`; `record(named:) -> EstateRecord?`;
  `record(atDirectory: URL) -> EstateRecord?` (the registered record whose
  directory has the same canonical path, symbolic links resolved; never a
  transient); `registeredRecord(selecting: String) throws -> EstateRecord?`
  (the registered record a `--db <value>` names, by name or by canonical
  directory; nil when none; throws `invalidName` only; selects and attaches
  nothing);
  mutating `register(name:directory:backend: = .sqlite)`, `register(_ value: String)`,
  `moveDefault(to:)` (refuses with `notAvailableInThisVersion`),
  `relocate(name:to:)`, `rename(_:to:)`, `activate(name:)`, `remove(name:)`;
  `static readManifest(of:) throws -> EstateManifest`,
  `static verifyFilesStayInside(_:) throws`,
  `static writeManifest(_:to:) throws`, `static isValidName(_:) -> Bool`.
- `public struct EstateCatalog.EstateSelector: Sendable, Equatable` —
  `init(_ value: String) throws`, `name`, `path: URL?`, `directory: URL?`.
  A bare `~` or a leading `~/` expands to the process home; `~user` is a
  literal component (both ports).

## Estate open posture (`EstateOpenPosture.swift`; Rust `estate_open_posture.rs`)

Spec § ESTATE_OPEN_POSTURE.

**Rust twin** (`genius_locus_kit::{EstateOpenPosture, EstateOpenPostureKind,
EstateOpenPostureError}`): `EstateOpenPosture::resolve(&EstateRecord)` and
`resolve_file(database, registered, declares_plaintext)` return the posture
(`kind: EstateOpenPostureKind::{NewEncrypted, NewPlaintextDeclared,
ExistingEncrypted, ExistingPlaintext}`, `is_plaintext()`,
`manifest_encryption()`); `manifest_declares_plaintext(&EstateRecord) ->
Result<bool, EstateOpenPostureError>` is the manifest gate the record form
runs; errors are `EncryptedEstateKeyMissing`, `KeyFileUnavailable`,
`BackendHasNoDatabaseFile` and `ManifestRefused(EstateCatalogError)`. Key
custody is the Rust port's `db.key` beside the database
(`persistence_kit::ensure_install_key` mints it, `SqliteStorage` adopts it on
open), minted and consulted for a registered record only; there is no
Keychain, so the Swift `provideKey` / `existingKey` / `relocateKey` /
`disposeKey` surface has no Rust form — the key file is created with the
estate and removed with its directory. The cargo feature `harness-keyfile`
(twin of `MOOTX01_HARNESS_KEYFILE`) consults the key file before the record's
kind for every record; off by default and enabled by no product crate. The
decision table is `Tests/Conformance/estate_open_posture_fixture.json`, read
by both ports' tests.

- `public enum EstateOpenPosture` — `enum Posture: Equatable, Sendable {
  newEncrypted, newPlaintextDeclared, existingEncrypted, existingPlaintext }`;
  `enum Error: Swift.Error, CustomStringConvertible {
  encryptedEstateKeyMissing(databaseURL: URL, underlying: String),
  keychainUnavailable(String), malformedKey(count: Int), unsupportedPlatform,
  backendHasNoDatabaseFile(name: String, backend: String),
  manifestRefused(EstateCatalogError) }`;
  `static let keyByteCount = 32`; `static var isKeyCustodyAvailable: Bool`;
  `typealias FileState = EstateEncryptionMigrator.EstateFileState`
  (`absent`, `plaintext`, `ciphertext`); `static var plaintextSQLiteMagic: [UInt8]`;
  `static func fileState(at: URL) -> FileState`;
  `static func resolve(for: EstateRecord) throws -> (encryption: EstateEncryptionConfig, posture: Posture)`
  (reads the record's manifest for the plaintext declaration and throws
  `manifestRefused` when the catalog refuses it or a symbolic link sits among
  the estate files; an absent manifest declares nothing; the record's kind
  decides whether a key may exist; a PostgreSQL record throws
  `backendHasNoDatabaseFile`);
  `static func resolve(databaseURL: URL, registered: Bool, declaresPlaintext: Bool) throws -> (encryption:, posture:)`
  for estates that are not catalog records;
  `static func provideKey(for: EstateRecord) throws -> Data`,
  `static func provideKey(databaseURL: URL) throws -> Data` (existing key or a
  new one), `static func existingKey(databaseURL: URL) throws -> Data` (never
  mints), `@discardableResult static func relocateKey(from: URL, to: URL) throws -> Bool`
  (moves the item to the new path's account; false when already there or no
  key; never overwrites), `@discardableResult static func disposeKey(databaseURL: URL) -> [Swift.Error]`
  (both access groups, best effort, failures returned);
  under `MOOTX01_HARNESS_KEYFILE`, `static func harnessInstallKey(for: URL) throws -> Data?`
  (consulted before the record's kind for every record; honours the plaintext
  declaration on an absent file).
- `MootProductIdentity.Keychain.estateKeyService` and `.sharedAccessGroup`
  (packages/libs/MootProductIdentity) are the strings every call uses.
- Package: GeniusLocusKit depends on `EstateEncryption` (packages/libs) for
  the header classification and the harness key file.

## Estate storage backend (`GeniusLocusKit.swift`; Rust `aria_mcp::EstateStorageBackend`)

- `public enum EstateStorageBackend: String, Sendable, Equatable { case sqlite
  = "SQLite", postgresql = "PostgreSQL", inMemory = "InMemory" }` — the raw
  values are the labels status surfaces print (moot-mgr's estate table).
- `GeniusLocusKit.storageBackend(for: EstateHandle) -> EstateStorageBackend?`
  — the PersistenceKit backend the open estate runs on; nil for a handle that
  is not open. AriaMcpKit's `/api/admin/estates` reads it.

## Estate manifest refresh (`GeniusLocusKitMigrations/EstateManifestRefresh.swift`; Rust `rust-migrations/src/estate_manifest_refresh.rs`)

**Rust twin** (`genius_locus_kit_migrations::{refresh_after_chain(record,
encryption, now_millis), refresh(record, format, encryption, now_millis),
declares_plaintext(record), composite_schema_version(),
iso8601_utc(epoch_millis)}`): the same writes through the catalog; the wall
clock is passed in as epoch milliseconds.

- `public enum EstateManifestRefresh` —
  `afterPrepare(_: GLKMigrationPreparation, estate: EstateRecord, encryption: EstateEncryptionConfig, now: Date) throws -> Bool`,
  `refresh(estate: EstateRecord, format: EstateFormatVersion, encryption: EstateManifest.Encryption, now: Date) throws -> Bool`,
  `declaresPlaintext(_: EstateRecord) -> Bool`. Writes `estate.json` through
  the catalog when it is missing or its recorded versions differ; `created` is
  preserved. A manifest that is present but refused by the catalog is never
  overwritten: `refresh` throws the catalog's `unreadableEstateManifest`
  (Rust returns it) and the file is untouched; `declaresPlaintext` reads such a
  manifest as no declaration. Called by every opener after
  `GLKMigrationCatalog.prepare`. Rust `refresh_after_chain` records
  `EstateFormatVersion::CURRENT`, the postcondition of every `Ok` from
  `run_migration_chain` (pinned by `migration_chain_tests`); Swift
  `afterPrepare` reads the same fact from `preparation.format`.

## App-container layout capsule (`GLKMigrationAppContainerToCatalog`, Swift only)

Trait `MigrationAppContainerToCatalog` (define
`GLK_MIGRATION_APP_CONTAINER_TO_CATALOG`), enabled by `MigrationFloor1_0`
through `MigrationFloor1_6`; re-exported by `GeniusLocusKitMigrations`.

- `public enum AppContainerLayoutMigration` — `legacyFolder` (`mootx01`),
  `legacyDatabase` (`mootx01.sqlite`); `Outcome { nothingToMove, moved(files:
  [String]), refused(legacy: URL, catalog: URL) }`;
  `legacyDatabaseURL(applicationSupportDirectory:) -> URL`;
  `pending(applicationSupportDirectory:record:fileManager:) -> Bool`;
  `run(applicationSupportDirectory:into:fileManager:relocateKey:) throws -> Outcome`
  (`relocateKey: (URL, URL) throws -> Bool`, `EstateOpenPosture.relocateKey`
  by default). Move order: `mootx01.sqlite-wal` → `estate.sqlite-wal`,
  `mootx01.sqlite-shm` → `estate.sqlite-shm`, `mootx01.sqlite` →
  `estate.sqlite`; the emptied legacy folder is removed.

## Windows base-directory adoption capsule (`windows_base_directory_adoption`, Rust only)

No feature gate: compiled by every build of `genius-locus-kit-migrations`, as
geometry normalization is. The old base can hold an estate of any format, so a
migration floor is the wrong gate; it also runs before the catalog opens
rather than inside `run_migration_chain`.

Why it has no Swift twin: the Swift base directory is
`<Application Support>/com.mootx01.ce` before the estate catalog and after it.
The Rust base directory on Windows moved, from `%LOCALAPPDATA%\MOOTx01` (the
retired `core::paths::data_dir()`) to `%LOCALAPPDATA%\com.mootx01.ce`
(`APPLICATION_SUPPORT_FOLDER`). Linux is unaffected, both sides resolving
`${XDG_DATA_HOME:-~/.local/share}/mootx01` (`UNIX_DATA_FOLDER`).

- `pub const LEGACY_WINDOWS_BASE_FOLDER: &str` — `"MOOTx01"`.
- `pub enum WindowsBaseAdoptionOutcome { NothingToMove, Moved { entries:
  Vec<String> }, Refused { legacy: PathBuf, current: PathBuf } }`.
- `legacy_windows_base_directory_from(home: PathBuf, platform_variable: impl
  Fn(&str) -> Option<String>) -> PathBuf` — the path rule
  (`%LOCALAPPDATA%\MOOTx01`, `<home>\AppData\Local\MOOTx01` when
  `LOCALAPPDATA` is unset), computed on any host so it can be pinned.
- `legacy_windows_base_directory() -> Option<PathBuf>` — `Some` on Windows,
  `None` on every other host.
- `windows_base_adoption_pending(legacy_base: &Path) -> bool` — the old base
  holds at least one child.
- `run_windows_base_adoption(legacy_base: &Path, configuration_directory:
  &Path) -> Result<WindowsBaseAdoptionOutcome, std::io::Error>` — moves EVERY child of the old
  base into the new one, not a named subset: the estate root `databases`, the
  LatticeLib pool and merged table `lattice`, the moot-mgr store and the
  daemon port file all belong at the base. Refuses, touching nothing, when any
  child's destination already exists. Removes the emptied old base. Idempotent,
  and resumable between renames because each child is one atomic rename.

`mootx01` calls it through `core::estate_adoption::adopt_before_catalog_open()`,
which every command runs before its first catalog open: `install`, `upgrade`,
`db` (through its one `open_catalog`), `query`, `drain`, `dream` and
`codex-memory doctor`. Every command, not just the two that install software,
because on Windows the first run after an upgrade is a Scheduled Task firing
`serve` at logon, not a command the operator typed.

## Fact-extraction duty public surface

Swift (`Brain/FactExtractionDuty.swift`):

```swift
public struct FactExtractionBatchResult: Sendable, Equatable {
    public let completedSources: Int
    public let factsFiled: Int
    public let candidatesRejected: Int
    public let skippedSources: Int
    public let failedSources: Int

    public init(
        completedSources: Int, factsFiled: Int, candidatesRejected: Int,
        skippedSources: Int, failedSources: Int
    )
}

public extension GeniusLocusKit {
    @discardableResult
    func activateFactExtractor(
        _ extractor: any FactExtractor,
        recipeID: String,
        for handle: EstateHandle
    ) async throws -> Int

    func unregisterFactExtractor(for handle: EstateHandle)

    func registeredFactExtractor(for handle: EstateHandle) -> (any FactExtractor)?

    func runFactExtractionBatch(
        _ handle: EstateHandle,
        limit: Int = 16,
        now: Date
    ) async throws -> FactExtractionBatchResult
}
```

Rust twin (`rust/src/brain/fact_extraction_duty.rs`):

```rust
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FactExtractionBatchResult {
    pub completed_sources: usize,
    pub facts_filed: usize,
    pub candidates_rejected: usize,
    pub skipped_sources: usize,
    pub failed_sources: usize,
}

impl EstateCoordinator {
    pub fn activate_fact_extractor(
        &mut self,
        extractor: Arc<dyn FactExtractor>,
        recipe_id: &str,
        handle: &EstateHandle,
    ) -> Result<usize, GeniusLocusKitError>

    pub fn unregister_fact_extractor(&mut self, handle: &EstateHandle)

    pub fn registered_fact_extractor(
        &self,
        handle: &EstateHandle,
    ) -> Option<Arc<dyn FactExtractor>>

    pub fn run_fact_extraction_batch(
        &self,
        handle: &EstateHandle,
        limit: usize,
        now: i64,
    ) -> Result<FactExtractionBatchResult, GeniusLocusKitError>
}
```

The Swift batch is asynchronous, accepts `Date`, and defaults `limit` to 16.
The Rust twin is synchronous, accepts an `i64` time value, and requires the
caller to pass `limit`.

## Counted endpoint hydration

Swift: `GeniusLocusKit.hydrateWithSensitivityCount(_:ids:frame:hydrationLevel:)`
returns `GLKHydrationResult`. Rust:
`EstateCoordinator::hydrate_with_sensitivity_count(handle, ids, frame)` returns
`Result<GLKHydrationResult, VerbDispatchError>` (carrier in `coordinator`).
The carrier exposes `drawers` and `withheldBySensitivity: Int` /
`withheld_by_sensitivity: usize`, with no loaded or rejected IDs. It preserves
LocusKit's exact candidate-ID and frame semantics, including zero count for an
explicit sensitivity predicate. Only admitted hydration rows leave LocusKit.

## Handle-scoped estate reads

Consumers and tests outside GLK address an estate only by `EstateHandle` and
use these verbs. `estate(for:)` is an internal GLK lifecycle and composition
implementation detail, not a consumer API. Each read resolves the handle,
delegates to the named lower operation, and returns its result. Argument labels
match the lower operation, with the handle as the leading `in:` argument, so a
drawer lookup uses `kit.getDrawers(in: handle, ids:hydrationLevel:)`. These
reads reject a stale handle with `GeniusLocusKitError.estateNotOpen`; they do
not impose a mounted-state write gate or remap lower-operation errors. (Swift;
`Verbs/HandleReads.swift`, `Brain/DreamingReads.swift`, `Verbs/VerbSurface.swift`.)

```swift
public extension GeniusLocusKit {
    func listRooms(in handle: EstateHandle, wing: String? = nil) async throws -> [RoomSummary]
    func auditTrail(in handle: EstateHandle, rowID: RowID) async throws -> [AuditEvent]
    func allDrawers(in handle: EstateHandle) async throws -> [Drawer]
    func allDrawers(in handle: EstateHandle, limit: Int?) async throws -> [Drawer]
    func allDrawers(in handle: EstateHandle, hydrationLevel: HydrationLevel, limit: Int?) async throws -> [Drawer]
    func allTunnels(in handle: EstateHandle) async throws -> [Tunnel]
    func getDrawers(in handle: EstateHandle, ids: [String], hydrationLevel: HydrationLevel) async throws -> [Drawer]
    func getDrawers(in handle: EstateHandle, ids: [String], matchingFrame frame: RecallFrame,
                    hydrationLevel: HydrationLevel, preservePhysicalUUIDSpellings: Bool = false) async throws -> FrameFilteredDrawers
    func getTunnel(in handle: EstateHandle, id: String) async throws -> Tunnel?
    func activeTunnels(in handle: EstateHandle, from drawerId: String) async throws -> [Tunnel]
    func activeTunnels(in handle: EstateHandle, to drawerId: String) async throws -> [Tunnel]
    func kgFacts(in handle: EstateHandle, subjectEq: String? = nil, sourceDrawerIDEq: String? = nil) async throws -> [KGFact]
    func meta(in handle: EstateHandle, key: String) async throws -> String?
    func resolveActiveDatasetHandle(in handle: EstateHandle, datasetId: UUID) async throws -> Drawer
    func countSubjectDebt(in handle: EstateHandle) async throws -> Int
    func resolveNodeNames(_ handle: EstateHandle, parentNodeIds: [String],
                          preservePhysicalUUIDSpellings: Bool = false) async throws -> [String: (wing: String, room: String)]
}
```

`listRooms`, `auditTrail`, `kgFacts`, `meta`, and the plain drawer/tunnel reads
do not add caller sensitivity filtering. The frame form of `getDrawers` is the
read that applies its frame's sensitivity admission; the plain form loads
exactly the ids it receives. `kgFacts(in:subjectEq:sourceDrawerIDEq:)` applies
no sensitivity ceiling; a caller that emits facts gates them itself.

## Handle-scoped estate writes

These writes first require a mounted handle, so stale, quiesced, and draining
handles are refused before any write reaches LocusKit. A lower-operation error
is remapped through the GLK verb boundary. They retain the lower operation's
semantics and do not provide a universal caller sensitivity filter.

```swift
public extension GeniusLocusKit {
    func setMeta(in handle: EstateHandle, key: String, value: String) async throws

    @discardableResult
    func setSSCFacts(in handle: EstateHandle, _ facts: String?, for drawerId: String) async throws -> Int

    @discardableResult
    func setSubjectRepresentation(
        in handle: EstateHandle,
        drawerId: String,
        subject: String,
        pipelineVersion: String,
        at generatedAt: Date
    ) async throws -> Int
}
```

## Recall router

The recall director runs an ordered route list once per scored recall, before
the lane request is built. A route is one value with three parts; the list is
module-level and ordered; the apply function walks it and fires the first
route whose preference is on and whose predicate is true. The router is a pure
function over the request: the director resolves each route's preference from
the estate and passes the resolved map in.

Route 1's transform sets the degradable directive —
`RerankDirective.apply(reason: "route:cross_encoder_routing")` (Swift) /
`RerankDirective::apply(Some("route:cross_encoder_routing"))` (Rust) — so the
cross-encoder stage reranks the head when it can run and otherwise reports its
degrade reason and leaves the lane order standing. The fail-closed
`.strictTranscript()` / `strict_transcript(..)` directive is built only by the
`moot_memory_recall_transcript` operation; the router never sets it.

**Swift:**
```swift
// RecallRouter.swift (internal):
struct RecallRoute: Sendable {
    let preferenceKey: String
    let predicate: @Sendable (String) -> Bool
    let transform: @Sendable (GLKRecallRequest) -> GLKRecallRequest
}
let crossEncoderRoute: RecallRoute          // Route 1, preferenceKey "cross_encoder_routing"
let recallRoutes: [RecallRoute]             // ordered; day one [crossEncoderRoute]
func applyRecallRoutes(
    _ request: GLKRecallRequest,
    preferences: [String: Bool]             // resolved on/off, keyed by preferenceKey
) -> (request: GLKRecallRequest, firedRouteKey: String?)

// Preference resolution on RecallDirector (internal):
static var crossEncoderRoutingMetaKey: String    // crossEncoderRoute.preferenceKey
func provisionedRecallRoutePreferences(estate: LocusKit.Estate) async -> [String: Bool]
```

**Rust:**
```rust
// recall_router.rs (pub):
pub struct RecallRoute {
    pub preference_key: &'static str,
    pub predicate: fn(&str) -> bool,
    pub transform: fn(GLKRecallRequest) -> GLKRecallRequest,
}
pub const CROSS_ENCODER_ROUTE: RecallRoute;      // Route 1, preference_key "cross_encoder_routing"
pub const RECALL_ROUTES: &[RecallRoute];         // ordered; day one &[CROSS_ENCODER_ROUTE]
pub fn apply_recall_routes(
    request: GLKRecallRequest,
    preferences: &BTreeMap<String, bool>,        // resolved on/off, keyed by preference_key
) -> (GLKRecallRequest, Option<String>)

// Preference resolution on EstateCoordinator (pub):
pub const CROSS_ENCODER_ROUTING_META_KEY: &str;  // CROSS_ENCODER_ROUTE.preference_key
pub fn provisioned_recall_route_preferences(&self, handle: &EstateHandle) -> BTreeMap<String, bool>
```

Adding a route is appending an entry to `recallRoutes` / `RECALL_ROUTES`; the
apply function and the preference resolver do not change.

**`GLKRecallResult.route` / `route`:** `String?` / `Option<String>`. The
preference key of the route that transformed this request (`"cross_encoder_routing"`
for Route 1), or nil / `None` when no route fired or the recall path is not
scored. Updated `replacing` (Swift): `route: String?? = nil` (nil = keep,
`.some(nil)` = clear, `.some("key")` = set).

**Concordance table row** (see § CONCORDANCE — scored recall):

| Swift field | Rust field | semantics |
|---|---|---|
| `GLKRecallResult.route: String?` | `GLKRecallResult.route: Option<String>` | preference key of fired route; nil / None when no route fired |

## Estate preference API

The USER-OWNED on/off switches of an estate share one generic accessor pair.
Each key is stored as the plain string `"on"` or `"off"` under its own
manifest key; an absent or unrecognised value reads as `.on`.

```swift
// EstatePreference.swift (GeniusLocusKit module)
public enum EstatePreferenceKey: String, CaseIterable, Sendable {
    case factExtraction = "fact_extraction"
    case consolidation
    case contradictionSweep = "contradiction_sweep"
    case crossEncoderRouting = "cross_encoder_routing"
    case maintenance
    case adaptiveRecall = "adaptive_recall"
    case factExtractor = "fact_extractor"   // engine choice for fact extraction

    public var allowedValues: [EstatePreferenceValue]  // on/off for switches; nuextract/apple for factExtractor
    public var defaultValue: EstatePreferenceValue     // .on for switches; .nuextract for factExtractor
}
public enum EstatePreferenceValue: String, Sendable, Equatable, CaseIterable {
    case on, off, nuextract, apple
}

// Verb-surface accessor pair
func provisionPreference(_ key: EstatePreferenceKey, _ value: EstatePreferenceValue, for handle: EstateHandle) async throws
// Throws GeniusLocusKitError.invalidManifest when value is outside key.allowedValues.
func provisionedPreference(_ key: EstatePreferenceKey, for handle: EstateHandle) async throws -> EstatePreferenceValue
// Absent key, unrecognised value, value outside key.allowedValues, or storage error returns key.defaultValue.
```

```rust
// estate_preference.rs (genius_locus_kit; re-exported at the crate root)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EstatePreferenceKey { FactExtraction, Consolidation, ContradictionSweep, CrossEncoderRouting, Maintenance, AdaptiveRecall, FactExtractor }
impl EstatePreferenceKey {
    pub const ALL: [Self; 7];
    pub fn as_str(self) -> &'static str;                             // the manifest key
    pub fn from_str(s: &str) -> Option<Self>;
    pub fn allowed_values(self) -> &'static [EstatePreferenceValue]; // On/Off for switches; Nuextract/Apple for FactExtractor
    pub fn default_value(self) -> EstatePreferenceValue;             // On for switches; Nuextract for FactExtractor
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EstatePreferenceValue { #[default] On, Off, Nuextract, Apple }
impl EstatePreferenceValue {
    pub fn as_str(self) -> &'static str;          // "on" / "off" / "nuextract" / "apple"
    pub fn from_str(s: &str) -> Option<Self>;
}

// Accessor pair on EstateCoordinator
pub fn provision_preference(&self, handle: &EstateHandle, key: EstatePreferenceKey, value: EstatePreferenceValue) -> Result<(), VerbDispatchError>;
pub fn provisioned_preference(&self, handle: &EstateHandle, key: EstatePreferenceKey) -> Result<EstatePreferenceValue, VerbDispatchError>;
// Absent key, unrecognised value, or storage error returns On (absent-means-on, opt-out model).
```

| `EstatePreferenceKey` case (Swift / Rust) | manifest key |
|---|---|
| `.factExtraction` / `FactExtraction` | `fact_extraction` |
| `.consolidation` / `Consolidation` | `consolidation` |
| `.contradictionSweep` / `ContradictionSweep` | `contradiction_sweep` |
| `.crossEncoderRouting` / `CrossEncoderRouting` | `cross_encoder_routing` |
| `.maintenance` / `Maintenance` | `maintenance` |
| `.adaptiveRecall` / `AdaptiveRecall` | `adaptive_recall` |

`provisionedRecallRoutePreferences(estate:)` reads `cross_encoder_routing`
through `crossEncoderRoutingMetaKey`, the same string as
`EstatePreferenceKey.crossEncoderRouting.rawValue`; the Rust recall router
reads the same string through the director's preference map.

## Security repair contract

Production `reindexCorpus` / `reindex_corpus` and the resident dreaming retrain boundary load `corpus.lsa_retraining` settings once per attempt: `max_documents` defaults to 2048, `max_sweeps` to 30, and `timeout_milliseconds` to 30000. The content source admits at most the document cap plus one through a storage-level limited ID query before reading training bodies. Skipped training preserves the previous model and does not advance the dreaming vocabulary baseline. Rust runs the bounded engine outside the coordinator mutex; Swift training uses asynchronous provider jobs.

### Candidate accounting and signal removal

Scored recall consumes the count from its existing primary candidate
evaluation: the bounded locus stream for locusOnly/hybrid/unionBest, and the
query-derived frame-filtered IDs for corpusOnly. It performs no count-only
estate scan and does not sum overlapping lane populations.

Swift `signalUnregister(_:in:) async throws -> Bool` removes a standing signal
and subscriptions, returning false for an unknown signal or absent scheduler.
The estate handle is validated. Rust scheduler `unregister(&SignalID) -> bool`
and governor `unregister_standing_signal(&SchedulerSignalID) -> bool` have the
same idempotent removal semantics.

## Changelog

### 3.40.0 — 2026-09-15

Updated the security repair contract and cross-port API guarantees above.


### 3.39.0 — 2026-09-15

Documented the complete handle-scoped access surface. Reads now include
`listRooms(in:wing:)` and `auditTrail(in:rowID:)` alongside the existing
handle reads; they reject stale handles only. Added the mounted write verbs
`setMeta(in:key:value:)`, `setSSCFacts(in:_:for:)`, and
`setSubjectRepresentation(in:drawerId:subject:pipelineVersion:at:)`, including
their stale/quiesced/draining refusal and lower-error remapping. The contract
now states that consumers and tests outside GLK use verbs and handles only;
`estate(for:)` is internal. `expunge` continues to return
`ExpungeVerbOutcome`; no archive-specific expunge API is introduced.

### 3.38.0 — 2026-09-15

Handle-scoped estate reads. The ten new methods in `Verbs/HandleReads.swift`
join `allDrawers(in:)`, `allDrawers(in:limit:)`, `allTunnels(in:)` and
`resolveNodeNames(_:parentNodeIds:)` as the read surface an access surface
uses instead of `estate(for:)`. AriaMcpKit's thirty `kit.estate(for:)` sites
now read through them and the kit holds no `LocusKit.Estate`. Additive; no
existing signature changes.

### 3.37.0 — 2026-09-15

`drainStatuses(_:)` / `drain_statuses` always report the `fact_extraction`
lane (`DrainStatus.factExtractionName` / `DrainStatus::FACT_EXTRACTION_NAME`):
`pending` is `Estate.countFactExtractionDebt()` /
`count_fact_extraction_debt()` (drawers whose bit 28 is clear for the active
recipe), `in_flight` is 0 (extraction is a bounded batch inside a dreaming
cycle, never a queued job), and the detail names a missing extractor. The
lane is non-gating for `encodeSettled` / `encode_settled` and for the
benchmarker's encode barrier; a caller settles an estate on it explicitly.
Both ports.

### 3.36.0 — 2026-09-15

Product hosts consume `factExtraction` / `FactExtraction` as the master gate
and `factExtractor` / `FactExtractor` as the provider selector at both resident
and one-shot dream activation points. The existing fact-extraction duty API is
unchanged: Apple hosts register the selected Apple Foundation Models or CoreAI
provider, while the Rust host registers the selected sibling Candle worker.
Both NuExtract adapters consume original source text through the same bounded
single-fact schema, and both duties emit deterministic UUID-form fact IDs.

### 3.35.0 — 2026-09-15

`EstatePreferenceKey` gains `factExtractor` / `FactExtractor` (manifest key `fact_extractor`) and two
new computed properties: `allowedValues` / `allowed_values` (on/off for the six switches; nuextract/apple
for `factExtractor`) and `defaultValue` / `default_value` (`on` for switches; `nuextract` for
`factExtractor`). `EstatePreferenceValue` / `EstatePreferenceValue` gains `nuextract` and `apple`. The
`EstatePreferenceValue.default` Swift static is removed; `provisionedPreference` /
`provisioned_preference` fall back to `key.defaultValue` / `key.default_value()`. `provisionPreference` /
`provision_preference` refuse a value outside `key.allowedValues` / `key.allowed_values()`. Both ports.

### 3.34.0 -- 2026-09-14

Package traits: every migration capsule trait (`MigrationV1_0ToV1_1` through
`MigrationV1_8ToV1_9` and both layout traits) is the package's default trait
set, so a bare `swift test` runs each `GLKMigration*Tests` target. Consumers
that select a floor are unchanged. Swift package manifest only.

### 3.33.0 -- 2026-09-14

Recall router: Route 1's transform documented as the degradable `apply`
directive (reason `route:cross_encoder_routing`); the fail-closed strict
transcript directive stays with the transcript operation. Both ports.

### 3.32.0 -- 2026-09-14

Standing-signal registration documented as it is in both ports:
`registerDefaultStandingSignals` / `default_standing_signal_specs` with
every optional cycle (`consolidationCycle`, `contradictionSweepCycle`,
`maintenanceCycle`, `decayCycle`, `byReferenceCycle`, `foldCycle`,
`trainingCycle`, `tournamentCycle` and their snake_case twins), each
registering its signal only when passed and each named to the estate
preference that gates it; `defaultStandingSignalNames` (six) versus
`preferenceGatedStandingSignalNames` (eight) and the Rust
`default_standing_signal_names` / `preference_gated_standing_signal_names`.
Added the adaptive-recall trio `runTemporalCausalityFold` / `runTrainingTick`
/ `endOfDayTournament` (`TournamentReport`) with Rust twins
`run_temporal_causality_fold` / `run_training_tick` /
`end_of_day_tournament`, and `similarRecall` / `similar_recall` (the
paraphrase door). Concordance table extended to the fourteen signals. The
`EstatePreferenceKey` list of six is unchanged.

### 3.31.0 -- 2026-09-14

Both ports: the 1.8→1.9 preference-seed capsule. Swift
`GeniusLocusKit.runPreferenceSeedMigration(handle:now:)`,
`GeniusLocusKit.preferenceSeedKeys`, `RecallRatingsSchema.schemaDeclaration`
and `PreferenceSeedMigrationError` in target `GLKMigrationV1_8ToV1_9` (trait
`MigrationV1_8ToV1_9`, enabled by every floor and by default); Rust
`PreferenceSeedMigrationExt::run_preference_seed_migration`,
`preference_seed_keys()`, `recall_ratings_schema_declaration()` and
`PreferenceSeedMigrationError` behind feature `migration-v1-8-to-v1-9`
(enabled by every floor and by default). `EstateFormatVersion.v1_9` / `V1_9`
is current; `GLKMigrationCatalog.prepare` / `run_migration_chain` run the
capsule last.

### 3.30.0 -- 2026-09-14

Rust: `EstatePreferenceKey` (six keys) and `EstatePreferenceValue` in the new
`estate_preference` module replace `coordinator::FactExtractionSetting`;
`EstateCoordinator::provision_preference(handle, key, value)` /
`provisioned_preference(handle, key)` replace the `provision_fact_extraction` /
`provisioned_fact_extraction` pair; `EstateCoordinator::FACT_EXTRACTION_META_KEY`
is removed (the key is `EstatePreferenceKey::FactExtraction.as_str()`). Both
ports now carry the same generic surface.

### 3.29.0 -- 2026-09-14

Swift: `EstatePreferenceKey` (six keys) and `EstatePreferenceValue` replace
`FactExtractionSetting`; `provisionPreference(_:_:for:)` /
`provisionedPreference(_:for:)` replace the `provisionFactExtraction` /
`provisionedFactExtraction` pair; `factExtractionMetaKey` is removed (the key
is `EstatePreferenceKey.factExtraction.rawValue`). Rust surface unchanged.

### 3.27.0 -- 2026-09-14

Recall router surface reshaped to the route list: `RecallRoute` value
(preference key, predicate, transform), Route 1 as `crossEncoderRoute` /
`CROSS_ENCODER_ROUTE`, the ordered `recallRoutes` / `RECALL_ROUTES` list, and
`applyRecallRoutes(_:preferences:)` / `apply_recall_routes(request,
&preferences)` taking the director's resolved preference map keyed by
preference key. `provisionedRecallRoutePreferences(estate:)` /
`provisioned_recall_route_preferences` replace the single-key Bool reader;
`crossEncoderRoutingMetaKey` / `CROSS_ENCODER_ROUTING_META_KEY` derive from
Route 1's preference key. No behaviour change.

### 3.26.0 -- 2026-09-14

Added the recall router: `applyRecallRoutes` / `apply_recall_routes` (free
function, both ports), the `cross_encoder_routing` preference reader, and
`GLKRecallResult.route` / `route: Option<String>` carrying the key of the
fired route or nil / None. Route 1 fires the cross-encoder strict-transcript
stage when the `cross_encoder_routing` preference is `"on"` (the default) and
the question reads as being about a conversation (`isConversationQuestion`: quoted speech, a speaker cue, or a conversation reference).

### 3.25.0 -- 2026-09-13

Added the counted endpoint hydration API and admitted-rows-only result contract
for ranked topK keystones hydration.

Added `withheldBySensitivity` / `withheld_by_sensitivity` to every GLK recall
carrier (`GLKRecallResult`, `FederatedRecallResult`, and `VagueRecallResult`):
the count of rows excluded only by LocusKit's default sensitivity ceiling.


### 3.24.0 -- 2026-09-13

Adds the public Swift and Rust signatures for fact-extractor activation,
registration, bounded duty batches, fact-first thresholds, decision families,
the pure decision stage, and the explicit coordinator recall entry point.

### 3.23.0 -- 2026-09-13

Sensitivity ceiling enforced on `expunge` and `retireKGFact` /
`withdraw_kg_fact`. Both verbs now refuse targets at `.restricted` or
`.secret` sensitivity with an error byte-identical to the absent-row
error, providing no existence oracle to the caller. No caller-visible
signature change. The ceiling is hardcoded at `.elevated`; the check
uses an explicit switch against `.restricted, .secret` so future
bulk-export tier changes cannot silently move the security boundary.

### 3.22.0 -- 2026-09-12

`retireKGFact` / `withdraw_kg_fact` signature widened. Both ports now
require `changedBy` / `changed_by` (non-empty string) and accept
`reason` (optional string). `now` (Swift `Date`, Rust `i64` millis)
was already present. Both delegate to the widened `DrawerStore` call
which routes through `AuditGate.admit` / `audit_gate::admit` (verb
`Retract`) and emits a sealed audit row.

### 3.21.0 -- 2026-09-10

Corrected the shared dataset-handle signature from `latticeAnchor` to the
actual UDC-only `udcCode` / `udc_code` contract and documented governed
`fileDataset` / `file_dataset` with its nonfatal signature patch. Capture and
settlement cross the mounted/stale gate for the typed callers; reason/time
remain forwarded but non-persisted.

### 3.20.0 -- 2026-09-10

Added the typed write operations in Swift and Rust: tunnel capture and
settlement, dataset-handle capture, the fixed FDC recalculation-floor stamp,
and explicit audit-provenance anchor reanchoring. The floor operation owns only
`aria.fdc.recalced_data_version`; settlement preserves atomic lifecycle plus
`reviewedBy`, while reason/time remain compatibility inputs and are not ledger
fields.

- 3.19.1 (2026-09-08): the capsule's command-layer entry point is
  `core::estate_adoption::adopt_before_catalog_open()` and every `mootx01`
  command calls it before its first catalog open, not only `install` and
  `upgrade`. No kit surface changed.
- 3.19.0 (2026-09-08): the Windows base-directory adoption capsule (above),
  Rust only. The package enables `MigrationFlatLayoutToCatalog` and
  `MigrationAppContainerToCatalog` by default, so a bare `swift test` in
  GeniusLocusKit runs both layout capsules' test targets; every product
  manifest already enabled them through `MigrationFloor1_0` and none changes.
  Spec 3.21.0.
- 3.18.0 (2026-09-08): `EstateCatalog.record(atDirectory:)` and
  `registeredRecord(selecting:)` (Rust `record_at_directory`,
  `registered_record_selecting`): the registered record a `--db <value>`
  names, by canonical directory. `EstateOpenPosture.Error.manifestRefused`
  (Rust `ManifestRefused`, `manifest_declares_plaintext`): the record form
  refuses a refused manifest. The Rust feature `harness-keyfile`. The
  selector expands a bare `~` only, both ports. `EstateManifestRefresh`
  refuses to overwrite a manifest it could not read, both ports. Spec 3.20.0.
- 3.17.0 (2026-09-08): the cross-encoder stage surface, both ports:
  `GLKRecallRequest.rerankDirective` / `rerank_directive`,
  `GLKRecallResult.crossEncoder` / `cross_encoder`, the "Cross-encoder
  activation" section (registry, manifest limits, lazy load) and
  `cross_encoder_stage` / `CrossEncoderStage`. Full surface in
  `CROSSENCODER_INTERFACE.md`.
- 3.16.0 (2026-09-08): Rust twins documented for the estate catalog
  (`estate_catalog.rs`), the open posture (`estate_open_posture.rs`), the
  manifest refresh (`rust-migrations/src/estate_manifest_refresh.rs`) and
  the storage backend label (`aria_mcp::EstateStorageBackend`); the
  `test-seams` configuration-directory override. No Swift change.
- 3.15.0 (2026-09-08): `EstateCatalogNames.catalogFile`, `databasesFolder`,
  `defaultEstate` and `database` read `MootProductIdentity.Storage`
  (`catalogFile`, `databasesFolder`, `defaultEstateName`,
  `estateDatabaseFile`), so a consumer that cannot depend on the kit (the
  daemon provider's census) spells the same on-disk names.
- 3.14.0 (2026-09-08): `EstateCatalog.configurationDirectory` is
  `MootProductIdentity.Storage.configurationDirectory`, whose home is
  `Storage.processHome(environment:entitledGroups:groupContainer:)` (the
  user's home unsandboxed, the entitled group container sandboxed, the own
  container otherwise); `Storage.signedApplicationGroups()` reads the
  process's signed app-group entitlement.
- 3.13.0 (2026-09-08): the app-container layout capsule (above).
- 3.12.0 (2026-09-08): `EstateOpenPosture.relocateKey(from:to:)`;
  `FlatLayoutMigration.run` gains the `relocateKey` hook and calls it before
  the rename; `EstateCatalog.configurationDirectory` derives its home from
  `NSHomeDirectory()` (iOS-available; the container inside a sandbox).
- 3.11.0 (2026-09-08): `EstateManifestRefresh` moves into the
  `GeniusLocusKitMigrations` umbrella from the mootx01 command target, public,
  so aria-mcp and the mootx01 commands share one manifest writer.
- 3.10.0 (2026-09-08): `EstateBackend` and `EstateRecord.backend`
  (`register(name:directory:backend:)`; rename and relocate preserve it);
  `EstateOpenPosture.Error.backendHasNoDatabaseFile` thrown by
  `resolve(for:)` on a PostgreSQL record; `EstateStorageBackend` and
  `GeniusLocusKit.storageBackend(for:)`. Swift only.
- 3.9.0 (2026-09-08): `EstateOpenPosture` (above), Swift only, moved into the
  kit from the mootx01 installer library; `GeniusLocusKit.disposeEstateKeys`
  disposes the database key through `EstateOpenPosture.disposeKey`.
  `MootProductIdentity.Keychain` gains `estateKeyService` and
  `sharedAccessGroup`, pinned by `Fixtures/product_identity.json`. Package
  dependency: GeniusLocusKit → EstateEncryption.
- 3.8.0 (2026-09-08): the estate catalog surface, Swift only, documented in
  full under "Estate catalog": `EstateCatalogNames`, `EstateRecordKind`,
  `EstateRecord`, `EstateManifest`, `EstateCatalogError`, `EstateCatalog`
  and `EstateCatalog.EstateSelector`. Spec § ESTATE_CATALOG. The types
  shipped with the catalog commits on this line without an interface entry.
- 3.7.0 (2026-09-08): flat-layout capsule, Swift only. Trait
  `MigrationFlatLayoutToCatalog` (define
  `GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG`), enabled by `MigrationFloor1_0`
  through `MigrationFloor1_6`; target `GLKMigrationFlatLayoutToCatalog`,
  re-exported by `GeniusLocusKitMigrations`. `public enum
  FlatLayoutMigration` with `Outcome { nothingToMove, moved(files: [String]),
  refused(flat: URL, catalog: URL) }`,
  `pending(configurationDirectory:record:fileManager:) -> Bool` and
  `run(configurationDirectory:into:fileManager:relocateKey:) throws -> Outcome`
  (`relocateKey: (URL, URL) throws -> Bool`, `EstateOpenPosture.relocateKey`
  by default, called before any file moves). The
  move order is the queue database and its WAL/SHM, the vectors sidecar, the
  drain lease, the manifest, the PID marker, the legacy `no-encrypt` marker,
  the database WAL and SHM, then `estate.sqlite`. No format version change.
  No Rust twin: the Rust port never wrote the flat layout.
- 3.6.0 (2026-09-07): sub-span scoring switch on the recall request, both
  ports. Swift: `public enum GLKSubSpanScoring: Sendable, Equatable { case off,
  on }` and `GLKRecallRequest.subSpanScoring: GLKSubSpanScoring`, set by the
  trailing defaulted init parameter `subSpanScoring: GLKSubSpanScoring = .off`.
  Rust: `recall::GLKSubSpanScoring { Off, On }` (re-exported from the crate
  root), `GLKRecallRequest.sub_span_scoring: GLKSubSpanScoring` (`new()` sets
  `Off`) and the builder `with_sub_span_scoring(GLKSubSpanScoring) -> Self`.
  Step 5.8 (`scoreSubSpans` / `score_sub_spans`) runs only with the switch on.
  No ARIA argument; CorpusKit surface unchanged.
- 3.5.0 (2026-09-07): unionBest work bounds and the Rust migration entry
  gate. Swift: `RecallExplainer.explain(hit:sketch:plan:scoring:agreement:subSpanUnscored:)`
  gains `subSpanUnscored: Bool = false` and renders the score-line token
  `subSpan:budget` when true; `GeniusLocusKit.unionBestMMRBodyCapScalars`
  (4,096), `GeniusLocusKit.unionBestMMRShingleBudgetScalars` (1,000,000) and
  `GeniusLocusKit.unionBestMMRShingles(bodies:)` (internal, in the
  RecallDirector extension; an even split of the budget over the bodies).
  Rust: `recall_explainer::explain` gains the trailing `sub_span_unscored: bool`;
  `recall::UNION_BEST_MMR_BODY_CAP_SCALARS`,
  `recall::UNION_BEST_MMR_SHINGLE_BUDGET_SCALARS` and
  `recall::union_best_mmr_shingles(bodies)` are public. Step 5.8
  calls `CorpusContentEngine.scoreSubSpans(query:candidateIDs:budget:)` /
  `score_sub_spans(query, ids, SubSpanBudget::DEFAULT)` in priority order.
  `GLKRecallResult.degradedStages` gains `subSpan.budget` and
  `unionBest.mmrBudget`. Rust migrations: `MigrationChainExt::run_migration_chain`
  returns `Result<(), MigrationChainError>` (`BelowCompiledFloor`,
  `UnsupportedFuture`, `NoHistoricalMigrationsCompiled`, `Storage`, `Capsule`;
  `Display`), reads the stamp first and stamps an unstamped estate current.
- 3.4.0 (2026-09-07): estate format V1_7 and the 1.6→1.7 whole-record float
  vacuum capsule (spec I-26), both ports. `EstateFormatVersion` gains `.v1_7`
  / `V1_7`; `current` / `CURRENT` is now `v1_7`. Swift, on `GeniusLocusKit`
  (target `GLKMigrationV1_6ToV1_7`):
  `runWholeRecordFloatVacuumMigration(handle:now:) ->
  WholeRecordFloatVacuumMigrationReport` deletes the `vectors` rows of kind 1
  and the `hnsw_graph` rows through
  `VectorStore.reclaimWholeRecordFloatRows()`, releases the `corpus`
  consumer's claims on `vectorIndex` 1 and stamps v1_7; the report carries
  `floatRows`, `graphRows`, `claimsReleased`, `vacuumed` (false when a
  `WholeRecordDense` build found a whole-record provider named in the
  manifest and kept the rows) and `format`; errors are
  `WholeRecordFloatVacuumMigrationError` (`storageUnavailable`,
  `vacuumFailed`, `claimReleaseFailed`, `stampFailed`). Traits:
  `MigrationV1_6ToV1_7`, `MigrationFloor1_6`; floors 1.0 through 1.5 gain
  the capsule. `GLKMigrationCatalog.prepare` runs it last in the chain.
  `provisionedEmbeddingProvider(for:)` and `encoderProviderID` are `package`
  visible so the capsule can read the manifest. Rust, on `EstateCoordinator`
  (`genius-locus-kit-migrations`, feature `migration-v1-6-to-v1-7`, floors
  `migration-floor-1-0` through `-1-6`; feature `whole-record-dense` on the
  migrations crate compiles the manifest check):
  `WholeRecordFloatVacuumMigrationExt::run_whole_record_float_vacuum_migration(&self, &EstateHandle, now_millis) -> Result<WholeRecordFloatVacuumMigrationReport, WholeRecordFloatVacuumMigrationError>`;
  `run_migration_chain` runs it last. LSA on its own switch: the
  GeniusLocusKit package gains trait `LSA` (`MOOTX01_LSA`, enables
  `DenseFamilies`, forwarded to CorpusKit) and the crate gains feature `lsa`
  (`= ["dense-families", "corpus-kit/lsa"]`); `DenseSignal.lsa` /
  `DENSE_LSA`, its `DenseSignal.all` / `DENSE_SIGNALS` membership and the
  presets `lsa_forward`, `anti_redundant_lsa` compile only under it.
  `presetNames` / `PRESET_NAMES` holds 26 names by default, 34 under
  `WholeRecordDense`, 37 under `DenseFamilies`, 39 under `LSA`.
- 3.3.0 (2026-09-07): the whole-record dense float lane becomes a
  `WholeRecordDense` trait (`MOOTX01_WHOLE_RECORD_DENSE`) / `whole-record-dense`
  feature, both ports; `DenseFamilies` / `dense-families` enables it. Compiled
  only under it: `RecallShape.antiSimilarLanes` + `isAntiSimilar(_:)` /
  `anti_similar_lanes` + `is_anti_similar` + `with_anti_similar_lanes`,
  `RecallShape.floatMetric` / `float_metric` + `with_float_metric`, the
  `antiSimilarLanes:` and `floatMetric:` init parameters,
  `DenseSignal.randomIndexing` / `DENSE_RANDOM_INDEXING`, `DenseSignal.all` /
  `DENSE_SIGNALS`, `GLKRecallResult.denseLaneStatus` / `dense_lane_status` (the
  init parameter defaults to nil under the trait and is absent otherwise),
  `GLKMetricName.denseLaneDark` / `DENSE_LANE_DARK`, and the presets
  `conceptual`, `associative`, `consensus`, `ri_forward`, `anti_redundant_ri`,
  `float-l2`, `float-dot` plus the new `whole_record_baseline`. `presetNames` /
  `PRESET_NAMES` holds 26 names by default, 34 under the trait, 39 with
  `DenseFamilies`. New in every build: `GLKRecallResult.replacing(hits:degradedStages:)`,
  which copies a result with the given fields replaced. `DenseSignal.encoder`,
  `key(forModelID:)`, the `"dense"` key and `RecallEvidencePath.vectorDense`
  are unchanged. The GeniusLocusKit package forwards its `DenseFamilies` and
  `WholeRecordDense` traits to CorpusKit and links `CorpusKitWholeRecordDense`
  under the trait.
- 3.2.0 (2026-09-06): the `answer:auto` gate reads the span rerank stage
  and the encoder row is seeded at open, both ports. `SpanRerankHit` gains
  `bm25Rank: Int` / `bm25_rank: usize` (the item's 1-based lexical rank in
  the head the stage read; every constructor supplies it).
  `GLKResultsPackager` computes m2 as the normalised Spearman footrule
  agreement between the lexical order and the span order of the span-scored
  hits in the top ten and m3 as the population standard deviation of their
  span cosines; `GLKConfidenceSignals` keeps its field names
  (`laneAgreement` / `denseSpread`, Rust `m2` / `m3`) and the wire labels do
  not change. `GeniusLocusKit` gains `isSpanRerankRegistered(for:) -> Bool`
  / `is_span_rerank_registered`, `defaultEncoderModelRow(isActive:)` /
  `default_encoder_model_row`, `seedDefaultEncoderModel(in:)` /
  `seed_default_encoder_model_in` and `seedDefaultEncoderModelIfAbsent(for:)`
  / `seed_default_encoder_model_if_absent`; `activateSpanEncoder` /
  `activate_span_encoder` seeds the active `encoder_models` row before it
  reads the registry. The packager twin fixture
  `packager_golden_pins.json` is at version 2: hits carry `span_cosine` and
  `lexical_rank`, pins G-J added.
- 3.1.0 (2026-09-06): estate format V1_6 and the 1.5→1.6 column-drop
  capsule (spec I-25), both ports. `EstateFormatVersion` gains `.v1_6` /
  `V1_6`; `current`/`CURRENT` is now `v1_6`. Swift, on `GeniusLocusKit`
  (target `GLKMigrationV1_5ToV1_6`):
  `runIndexCompositionColumnDropMigration(handle:now:) ->
  IndexCompositionColumnDropMigrationReport` replays CorpusKit's checkpoint
  ladder (v4 drops `corpus_index_state.composition_policy`) on the estate
  storage and stamps v1_6; the report carries `checkpointSchemaVersion` and
  `format`; errors are `IndexCompositionColumnDropMigrationError`
  (`storageUnavailable`, `ladderFailed`, `stampFailed`). Traits:
  `MigrationV1_5ToV1_6`, `MigrationFloor1_5`; floors 1.0 through 1.4 gain the
  capsule. `GLKMigrationCatalog.prepare` runs it last in the chain. Rust, on
  `EstateCoordinator` (`genius-locus-kit-migrations`, feature
  `migration-v1-5-to-v1-6`, floors `migration-floor-1-0` through `-1-5`):
  `IndexCompositionColumnDropMigrationExt::run_index_composition_column_drop_migration(&self, &EstateHandle, now_millis) -> Result<IndexCompositionColumnDropMigrationReport, IndexCompositionColumnDropMigrationError>`;
  `run_migration_chain` runs it last. Rust `GLKAnswerBlock` loses
  `confidence_label` (the ARIA boundary renders `confidence:` from
  `confidence_level`, the Swift way) and its `citation_ids` are the first
  five hydrated drawer ids (Swift `citationIDs`); `compute_signals` reads m4
  as false with no composed answer or no top content, the Swift rule.

- 3.0.0 (2026-09-06): Removed the obsolete distillation signal and parameter. Documented the span-encode callback and removed stale adornment-orchestration claims.
- 2.26.0 (2026-09-06): default encoder provisioning (spec 2.25.0), both ports.
  Adds `provisionDefaultEncoderIfAbsent(for:) async throws -> Bool` /
  `provision_default_encoder_if_absent(&self, &EstateHandle) -> Result<bool, VerbDispatchError>`:
  writes `embedding_provider = "encoder"` when the manifest names no provider
  (absent or empty) and returns true; a named provider is never overwritten.
  `provision` calls it after the open and before `wireSubstores` for every
  kind except LocusOnly, so a fresh estate activates the encoder on its first
  open. Product create paths (Swift ServeCommand first run, AriaMCPMain,
  MootBridge, CommunityResidentMain; Rust EstateRegistry in-memory, SQLite
  first run, PostgreSQL) call it the same way; the `mootx01 upgrade`
  span-encode step writes the key for migrated estates. Serve-time opens of
  an existing estate never write it.

- 2.25.0 (2026-09-06): span encoder activation order (spec 2.24.0), Swift.
  `applyProvisionedEmbeddingProvider` no longer activates the encoder for
  `"encoder"`; the private `activateSpanEncoderIfProvisioned(for:)` runs in
  `wireSubstores` after `registerVectorStore` (`.glk`) / `registerCorpus`
  (`.corpusOnly`), so `activateSpanEncoder` finds the store and registers the
  rerank stage. Public surface unchanged; Rust already wired in this order.

- 2.24.0 (2026-09-05): one index composition (spec 2.23.0). Removed, Swift:
  `GeniusLocusKit.indexCompositionPolicy(for:)`, `storedIndexCompositionPolicy(for:)`,
  `storedIndexCompositionPolicyID(for:)`, `setIndexCompositionPolicy(_:for:)`,
  `setIndexCompositionPolicy(id:for:)`, `seedIndexCompositionPolicyIfAbsent(for:environment:)`,
  `activeIndexCompositionPolicy(for:)`, `indexCompositionPolicyRowCounts(for:)`,
  the statics `indexCompositionPolicyMetaKey`, `indexCompositionPolicyEnvironmentKey`,
  `indexCompositionPolicyCreationSeed(environment:)`, `indexCompositionPolicyID(parsing:)`;
  the `reindexPending:` parameter of `wireSubstores` / `wireGLKSubstores`; the
  `compositionPolicy` field and init parameter of `LocusDrawerCorpusContentSource`;
  `runIndexCompositionColumnMigration`, `runIndexCompositionSettingMigration`
  and their capsule modules; traits `MigrationV1_1ToV1_2`, `MigrationV1_3ToV1_4`.
  Removed, Rust: the `EstateCoordinator` stored-setting block
  (`stored_index_composition_policy`, `stored_index_composition_policy_id`,
  `set_index_composition_policy`, `set_index_composition_policy_id`,
  `seed_index_composition_policy_if_absent`, `active_index_composition_policy`,
  `index_composition_policy`, `index_composition_policy_row_counts`,
  `index_composition_policy_meta_key`, `index_composition_policy_creation_seed`,
  `index_composition_policy_id_parsing`, `INDEX_COMPOSITION_POLICY_ENV_KEY`);
  the `reindex_pending` parameter of `wire_substores` / `wire_glk_substores`;
  `LocusDrawerContentSource::new_with_policy` and `composition_policy()`;
  `run_index_composition_column_migration`, `run_index_composition_setting_migration`;
  features `migration-v1-1-to-v1-2`, `migration-v1-3-to-v1-4`. Floors 1.1
  through 1.4 compile only the 1.4→1.5 capsule; `compiledFloor` /
  `compiled_floor` report 1.1 when only that capsule is compiled.
- 2.23.0 (2026-09-05): ENC-W6B doc sweep. The "Active-minter adornment
  orchestration" section is now marked DARK behind `MOOTX01_MINERS`. Schema 19
  removed the `adornments` / `adornment_minters` tables and the `adornment`
  column on `drawers`; the `spanEncode` duty occupies the REM-ALPHA slot
  `AdornmentPass` held. The API stubs are retained as a spec record for the
  gated path.

- 2.21.0 (2026-09-05): Encoder Rerank Program (both ports). `embedding_provider`
  gains the value `"encoder"`; `registerSpanEncoder` / `registeredSpanEncoder`,
  `setModelDirectoryResolver`, `ModelDirectoryResolving` + `NilModelDirectoryResolver`,
  manifest keys `encoder_head` (30) and `encoder_batch` (16 iOS / 64) with their
  provision / provisioned verbs, `activeEncoderModelSpec` (floor until the
  registry store is wired) and `activateSpanEncoder` with the one-log-line
  failure contract. Rust `apply_provisioned_embedding_provider` takes `&mut self`
  and activates the encoder for `"encoder"`; the §1.53 provenance-only path
  now covers the Apple-platform ids only. GLK Rust gains the `encoder` feature
  and a production dependency on `corpus-kit-providers`.

- 2.22.0 (2026-09-05): Encoder Rerank Program, span rerank stage (both ports). Adds
  `registerSpanRerank(_:spanVectors:head:for:)` / `register_span_rerank`; the
  `SpanRerankEncoding` / `SpanVectorReading` seams with `SpanRerankVector`,
  `SpanRerankInput`, `SpanRerankHit` (Swift `SpanRerank.swift`, Rust
  `span_rerank`); `RecallHit.spanHit` / `span_hit` (defaulted nil in the Swift
  init; a new field in the Rust struct literal); `RecallShape.defaultWeight(for:)`
  / `default_weight` (+ `weight_or_default`), `SignalKey.encoder` / `SIGNAL_ENCODER`,
  `DenseSignal.encoder` / `DENSE_ENCODER`, `DenseSignal.key(forModelID:)` /
  `dense_key_for_model`; the `no_encoder` preset; `SpanRerankStage` constants
  (`lexicalDepth` 1000, `defaultEncoderHead` 30, `rrfK` 60). The dense-family
  keys and presets compile only with the `DenseFamilies` trait / `dense-families`
  feature: `presetNames`/`PRESET_NAMES` 37 → 33 (38 with the families). The
  explainer's `score:` line gains a trailing `span:<index>:<cosine>` token for
  scored hits. `signal:vector` now defaults to 0 through `defaultWeight`.
- 2.20.0 (2026-09-05): NOVEC-1 (both ports). Two ablation presets added:
  `no_bm25` (`signal:bm25` = 0) and `no_vector` (`signal:vector` = 0). Candidates
  from the excluded lane still enter the pool; only the scoring column is excluded
  and its budget redistributed. `presetNames`/`PRESET_NAMES` 35 → 37. Parity gates:
  `RecallShapePresetTests.swift` / `recall_shape_presets.rs` (count now 37);
  `RecallShapeSignalExclusionTests.swift` / `recall_shape_signal_exclusion_parity.rs`
  (ablation roster extended with the two new presets).
- 2.19.0 (2026-09-04): COL-1 Part A. `RecallShape.SignalKey` (Swift) /
  `RecallShape::SIGNAL_LOCUS…SIGNAL_AGREEMENT` (Rust) spell the eight `signal:*`
  column-budget keys. New internal `RecallSignalBudget` (Swift,
  `RecallDirector/RecallSignalBudget.swift`) / `pub mod recall_signal_budget`
  with `RecallSignalBudget::resolve(&RecallWeights, impl Fn(&str)->f32,
  &HashSet<SignalColumn>)` and `SignalColumn` (Rust): a key at 0 excludes the
  column and redistributes its budget. Six presets added (`no_locus`,
  `no_field_fit`, `no_matrix`, `no_graph`, `no_preference`, `no_agreement`);
  `presetNames`/`PRESET_NAMES` 29 → 35. Swift `RecallExplainer.explain` gains
  `agreement: Float = 0` and the `score:` line renders every column plus
  `agreement=` and `final=`. Tests: `RecallSignalBudgetTests.swift` /
  `recall_signal_budget_parity.rs` (shared vectors),
  `RecallShapeSignalExclusionTests.swift` / `recall_shape_signal_exclusion_parity.rs`.
- 2.18.0 (2026-09-04): estate format V1_5 and the 1.4→1.5 storage-ledger
  kit-id capsule (spec I-24). `EstateFormatVersion` gains `.v1_5` / `V1_5`;
  `current`/`CURRENT` is now `v1_5`. Swift, on `GeniusLocusKit` (target
  `GLKMigrationV1_4ToV1_5`): `rewriteStorageLedgerKitIDs(handle:) ->
  StorageLedgerKitIDMigrationReport` moves the `VectorKit` and
  `VectorKitClaims` ledger rows to `SynapseKit` and `SynapseKitClaims` through
  `Storage.renameSchemaKit(from:to:)` and stamps nothing;
  `runStorageLedgerKitIDMigration(handle:now:) ->
  StorageLedgerKitIDMigrationReport` runs the rewrite and stamps v1_5; the
  report carries one `SchemaKitRenameOutcome` per pair
  (`vectorStore`, `representationClaims`); error
  `StorageLedgerKitIDMigrationError` (`storageUnavailable`, `renameFailed`,
  `stampFailed`). The pairs are the static
  `GeniusLocusKit.storageLedgerKitIDRenames`. New package traits
  `MigrationV1_4ToV1_5`, `MigrationFloor1_4`; floors 1.0, 1.1, 1.2, and 1.3
  now enable the 1.4→1.5 capsule. `GLKMigrationCatalog.prepare` runs the
  rewrite before every older capsule and the stamp after the 1.3→1.4 capsule;
  a fresh estate stamps v1_5. Rust, on `EstateCoordinator`
  (`StorageLedgerKitIdMigrationExt`): `rewrite_storage_ledger_kit_ids(handle)
  -> Result<StorageLedgerKitIdMigrationReport, StorageLedgerKitIdMigrationError>`
  and `run_storage_ledger_kit_id_migration(handle, now_millis)`; const
  `STORAGE_LEDGER_KIT_ID_RENAMES`. Rust features `migration-v1-4-to-v1-5`,
  `migration-floor-1-4`; `run_migration_chain` runs the rewrite first and ends
  at V1_5; `compiled_floor` reports `V1_4` when only that capsule is compiled.
  Both ports.
- 2.17.0 (2026-09-03): `mootx01 db composition --set` (both ports) drains the
  estate's encode queue to empty (`awaitEncodeDrain(for:)` /
  `await_encode_drain`) after wiring the Corpus and before `reindexCorpus` /
  `reindex_corpus`, so a job left pending by an earlier process is indexed
  under the stored setting before the rebuild rewrites every row, and it runs
  the rebuild with the resident daemon quiesced when the data directory is the
  resident estate (`ResidentDaemonQuiesce.run` / `with_resident_daemon_quiesced`,
  the `mootx01 upgrade` seam): a clone is rebuilt with the daemon untouched, a
  daemon that is down is never started, and a daemon that will not stop means
  nothing is written. The on_encoded rider (`wireCorpusRoomRollup` /
  `wire_corpus_on_encoded`) captures the engine weakly: the closure is stored on
  the engine, and a strong capture let a released coordinator's engine, and its
  drain worker, outlive every host reference and keep indexing under the
  composition policy that engine opened with.
- 2.16.0 (2026-09-03): Rust, on `EstateCoordinator`: `wire_substores(handle,
  kind, backing_storage, embedding_models, now_millis, reindex_pending)` and
  `wire_glk_substores(handle, backing_storage, embedding_models, now_millis,
  reindex_pending)`, twins of Swift `wireSubstores(for:kind:backingStorage:
  embeddingModels:reindexPending:)` / `wireGLKSubstores(...)`. The seam opens
  the ATTACHED-mode Corpus under the stored index composition setting,
  registers it (and, for `Glk`, its shared `VectorStore` plus the composite
  schema), installs the on_encoded rider, then mounts the ingest queue;
  `provision` calls it with `reindex_pending = false`. A serving wire refuses
  an estate whose index rows were built under another policy
  (`UnderlyingEstateFailure` carrying `CorpusKitError::CompositionPolicyMismatch`
  with detail `recorded=<id>;configured=<id>`); `mootx01 db composition --set`
  (Rust) opens through the kit and the migration chain and wires with
  `reindex_pending = true`, the same call tree as the Swift command.
- 2.15.0 (2026-09-03): the index composition policy is a stored estate
  setting (LocusKit manifest key `index_composition_policy`; spec I-23).
  Swift, on `GeniusLocusKit`: `storedIndexCompositionPolicy(for:) ->
  IndexCompositionPolicy?`, `storedIndexCompositionPolicyID(for:) -> String?`,
  `setIndexCompositionPolicy(_:for:)`, `setIndexCompositionPolicy(id:for:) ->
  String` (validates before writing), `seedIndexCompositionPolicyIfAbsent(for:
  environment:) -> IndexCompositionPolicy` (the only reader of
  `MOOT_INDEX_COMPOSITION`), `activeIndexCompositionPolicy(for:)`,
  `indexCompositionPolicyRowCounts(for:) -> [String: Int]`, and the statics
  `indexCompositionPolicyMetaKey`, `indexCompositionPolicyEnvironmentKey`,
  `indexCompositionPolicyCreationSeed(environment:)`,
  `indexCompositionPolicyID(parsing:)`. `wireSubstores(for:kind:backingStorage:
  embeddingModels:reindexPending:)` and `wireGLKSubstores(for:backingStorage:
  embeddingModels:reindexPending:)` gain `reindexPending: Bool = false`, the
  rebuild-committed open `mootx01 db composition --set` uses.
  `EstateFormatVersion` gains `.v1_4` / `V1_4`; `current`/`CURRENT` is now
  `v1_4`. New method `runIndexCompositionSettingMigration(handle:now:)` and
  error `IndexCompositionSettingMigrationError`; new package traits
  `MigrationV1_3ToV1_4`, `MigrationFloor1_3`; floors 1.0, 1.1, and 1.2 now
  enable the 1.3→1.4 capsule; `GLKMigrationCatalog.prepare` dispatches
  1.0/1.1/1.2/1.3 → 1.4 and seeds the setting on a fresh estate. Rust, on
  `EstateCoordinator`: `stored_index_composition_policy`,
  `stored_index_composition_policy_id`, `set_index_composition_policy`,
  `set_index_composition_policy_id`, `seed_index_composition_policy_if_absent`,
  `active_index_composition_policy`, `index_composition_policy` (the wired
  Corpus's policy), `index_composition_policy_row_counts`,
  `index_composition_policy_meta_key()`, `index_composition_policy_creation_seed`,
  `index_composition_policy_id_parsing`, const
  `INDEX_COMPOSITION_POLICY_ENV_KEY`; `provision` seeds the setting;
  `index_composition_policy_from_env` is gone. Rust features
  `migration-v1-3-to-v1-4`, `migration-floor-1-3`;
  `IndexCompositionSettingMigrationExt::run_index_composition_setting_migration`
  returns the policy; `run_migration_chain` ends at V1_4. Both ports.

- 2.14.0 (2026-09-03): the active converter is intent-span v23.2:
  `GeniusLocusKit.distillationConverter` returns `.intentSpanV23Attributed`
  (Rust `DISTILLATION_CONVERTER` is `IntentSpanV23Attributed`);
  `distillationConverterID` reads
  `intent-span-v23-attributed@intent-span-v23.2-attributed-prose`. New
  `GeniusLocusKit.distilledRepresentationIsCurrent(_ drawer: Drawer) -> Bool`
  (Rust `genius_locus_kit::distilled_representation_is_current(&Drawer) -> bool`):
  the one representation-currency rule (bit 19, converter ID, source digest).
  `distillItem` writes `Estate.setDistilledRepresentation(drawerId:distilled:pipelineVersion:sourceDigest:tokenCount:at:)`
  (LocusKit 2.3.0). `EstateFormatVersion` gains `.v1_3` / `V1_3`;
  `current`/`CURRENT` is now `v1_3`. New method
  `GeniusLocusKit.runDistilledSourceDigestColumnMigration(handle:now:)` (Swift) /
  `EstateCoordinator::run_distilled_source_digest_column_migration(handle, now_millis)`
  (Rust, via `DistilledSourceDigestColumnMigrationExt`); new error type
  `DistilledSourceDigestColumnMigrationError` (both ports). New Swift package
  traits `MigrationV1_2ToV1_3`, `MigrationFloor1_2`; `MigrationFloor1_0` and
  `MigrationFloor1_1` now enable the 1.2→1.3 capsule. Rust features mirror
  this. `GLKMigrationCatalog.prepare` / `run_migration_chain` dispatch
  1.0/1.1/1.2 → 1.3. Both ports.

- 2.12.0 (2026-09-02): estate format V1_2 and the 1.1→1.2 migration
  capsule. `EstateFormatVersion` gains `.v1_2` (Swift) /
  `V1_2` (Rust); `current`/`CURRENT` is now `v1_2`. New method:
  `GeniusLocusKit.runIndexCompositionColumnMigration(handle:now:)` (Swift) /
  `EstateCoordinator::run_index_composition_column_migration(handle, now_millis)`
  (Rust, via `IndexCompositionColumnMigrationExt`); Rust hosts run the whole
  compiled chain through `MigrationChainExt::run_migration_chain`, the twin of
  `GLKMigrationCatalog.prepare`. New error type:
  `IndexCompositionColumnMigrationError` (both ports). New Swift package
  traits: `MigrationV1_1ToV1_2`, `MigrationFloor1_1`. Rust features mirror
  this. Migration catalog updated for three-case dispatch (found 1.0, 1.1,
  1.2). `SharedContentMigration` stamps `.v1_1` explicitly so the 1.1→1.2
  capsule is not skipped on resume. Both ports.

- 2.11.0 (2026-09-02): CDL-02 — ContextDistillLib is the product distiller.
  New public `GeniusLocusKit.distillationConverter`,
  `distillationConverterID`, `distilledRepresentation(forContent:)`,
  `distilledTokenCount(_:)` (Rust: `DISTILLATION_CONVERTER`,
  `distillation_converter_id()`,
  `brain::distillation_cycle::{distilled_representation, distilled_token_count}`).
  `distillItem(handle:drawerID:content:distillFn:now:)` drops `corefPool:`
  (Rust `distill_item` drops the antecedent pool); `distillFn` now feeds the
  fingerprint lane only. `redistillItemsSweep(handle:distillFn:now:limit:)`
  and `reindexCorpus(handle:now:)` gain Rust twins
  (`EstateCoordinator::redistill_items_sweep`, `reindex_corpus`).
  `CorefStage` (Swift) and `brain::coref_stage` (Rust) are removed.
  `SubstrateML.DistillationPipelineVersion` is no longer read anywhere; see
  SUBSTRATEML_INTERFACE 1.7.0.
- 2.13.0 (2026-09-02): Crash-idempotent convergence (two-key eligibility gate).
  New GLK method `distilledRepresentationsAwaitingReindex(handle:) async throws -> Int`
  (Rust: `EstateCoordinator::distilled_representations_awaiting_reindex`): counts
  active, represented drawers whose corpus index row is missing or was last updated
  strictly before the drawer's `distilledAt`. Used by `runDistilledRepresentationConvergence`
  as a second eligibility key alongside the sweep's regeneration count; the reindex
  runs when either is non-zero, detecting the mid-run crash scenario.
  Supporting new APIs: `Estate.drawersWithRepresentations() async throws -> [(id: String, distilledAt: Date)]`
  in LocusKit (Rust: `Estate::drawers_with_representations() -> Result<Vec<(String, i64)>, LocusKitError>`);
  `CorpusContentEngine.allIndexStates() async throws -> [CorpusIndexState]`
  in CorpusKit (Rust: `CorpusContentEngine::all_index_states`).
- 2.10.0 (2026-09-02): Per-engine lanes (codex finding 21).
  `AdornmentPass.run` gains `laneEngineResolver` (default resolves
  through `GoldMiner.shared.servingEngineIdentity(for:)`, new on
  AdornmentLib's `GoldMiner`); concurrency lanes are keyed by the
  resolved engine's identity so minters sharing one engine share its
  `maxConcurrentMints` budget. Counters and stored rows are unchanged.
  No Rust change: `run_adornment_pass` is a serial loop over one engine.
- 2.9.0 (2026-09-02): Provenance guard (codex finding 17).
  `AdornmentPass.run` gains `engineIdentityResolver` (default resolves
  through `GoldMiner.shared.servingMinterIdentity(for:)`); pairs whose
  minter id is not the serving engine's identity count as `skippedPairs`
  and stay in debt. `skipped_pairs` / `skippedPairs` semantics widen
  accordingly in both ports. Rust `run_adornment_pass` signature is
  unchanged; it resolves `gold_miner::engine_identity()` once per pass.
- 2.8.0 (2026-09-02): Batch ceiling (codex finding 16). New public
  constant `ADORNMENT_PASS_MAX_BATCH_SIZE` = 5000 pairs and clamp helper
  `AdornmentPass.clampedBatchSize(_:)` / `clamped_batch_size` in both
  ports; `AdornmentPass.run` / `run_adornment_pass` clamp every caller's
  batch size at the entry point (clamped, never rejected). No signature
  changes.
- 2.6.0 (2026-08-31): `AdornmentPass` row grouping is per-minter and
  generation routes through the minter-scoped miner entry points
  (`mintOne(prompt:for:)` / `mintRows(_:maxLength:for:)`,
  ADORNMENTLIB_INTERFACE 0.12.0). No public GLK signature changes; the
  behavior contract is GENIUSLOCUSKIT_SPEC 2.4.0.
- 2.5.0 (2026-08-30): `AdornmentPass.run` gains `maxAdornmentLength` and
  `rowBatching` (nil = engine decides via supportsRowBatching). Short
  pairs mint in row batches through the resident engine's persistent
  session; engine-failed rows and long/empty pairs take the existing
  single-record path. Counters and stored rows are transport-invariant.

- 2.4.0 (2026-08-30): `AdornmentPass.run` gains an optional `width`
  override and mints its batch through a task group bounded by the
  resident engine's declared `maxConcurrentMints` (default nil = ask the
  engine). Stored results are width-invariant; only wall clock changes.

### 2.3.0 -- 2026-08-28

DEFAULT-MINT-01: `ensureDefaultAdornmentMinter(in:)` added (both open
paths call it — serve and ARIA_MCP). `runAdornmentPass` generation now
resolves through the resident GoldMiner (installed engine, else the
platform default — Apple's on-device model; else the MOOT_MINT_CMD
harness engine) instead of the command seam alone. Rust port gains the
pass itself (`genius_locus_kit::brain::adornment_pass::run_adornment_pass`
at DrawerStore level, `AdornmentPassResult` twin, DEFAULT_BATCH_SIZE 50),
driven once per dreaming cycle; the estate registry registers the Rust
default (candle quantized recipe) at open.

### 2.2.1 -- 2026-08-26

Hedging-vocabulary sweep (operator ruling 2026-08-25): normative prose now states facts as facts. No contract change.

### 2.2.0 -- 2026-08-26

RENAME-EMBED (#72): `wireSubstores` provisioned-provider selection gains
the engine-neutral id `neural-embed-v1` → `NeuralEmbedProvider` (Swift
only, opt-in, `#if canImport(NaturalLanguage)`; the Rust backend is the
standalone `tools/neural-embed` crate, renamed from `candle-spike`; the
Rust GLK provenance-only ruling is unchanged). Absent/unknown manifest
key remains byte-identical to the default ensemble.

### 2.0.0 -- 2026-08-25

Added minter registration and runtime activation, per-pair AdornmentPass
results, and the batched `activeAdornments` result-composition seam. Removed
the scalar Drawer adornment and bitmask-selected generator assumptions from
the target interface.

### 1.61.0 -- 2026-08-24

SCORE-ORDERING mission (Score-Transparent Ordering contract).

**`GLKRecallResult.degradedStages` gains a new sentinel value:**
- `"tie.nonDeterminate"` — appended when the 4N window contains a tie group
  at the presentation boundary and the pool has additional items beyond 4N.
  The caller (AriaMCP) renders this as a user-steering message.

**`recallUnionBest` now implements windowed tie-resolution:**
Both Swift and Rust ports implement `(score DESC, subject ASC)` presentation
ordering with the two-phase windowed algorithm (see GENIUSLOCUSKIT_SPEC.md
§ 1.50.0). The `limit` parameter is a relevance floor, not an exact count.

**`recallCorpusOnly` now applies `(score DESC, subject ASC)` sort:**
The corpusOnly lane's output is sorted in the same presentation order as
unionBest before being returned to the caller.

**`RecallHit.score.final` (Swift) / `RecallHit.score.final_score` (Rust):**
Both fields were already present; this mission ensures they are non-zero for
every hit from a scoring-enabled lane (BM25, vector, locus) and used as the
primary presentation sort key.

### 1.60.0 -- 2026-08-23

ADORNMENT mission.

**`registerDefaultStandingSignals` signature change (both ports):**
Now takes three Option closures: `huntCycle`, `anomalyCycle`,
`adornmentCycle`. The third closure re-adds the AdornmentPass signal 13
removed during the gold rollback. Rust: `register_default_standing_signals`
in `autonomic_governor.rs` gains `adornment_cycle: Option<...>` third param.
All call sites (ResidentDaemon.swift, runtime.rs, governor tests in both
ports) updated in the same commit.

**New GLK actor methods:**
- `runAdornmentPass(handle:now:) async throws -> Int` — production path,
  returns adorned count, uses `ADORNMENT_MAX_LENGTH` product constant.
- `runAdornmentPass(handle:batchSize:maxAdornmentLength?:now:) async throws -> AdornmentPass.Result`
  — harness-only overload; `maxAdornmentLength: Int?` threads a custom
  length ceiling through the minter closure (nil = product default).
  (Historical entry: retired with the adornment pass, see 2.22.0.)

**`AdornmentPass.run` static method (public):**
`AdornmentPass.run(estate:batchSize:minter:now:) async throws -> Result`.
`Result` carries `adorned`, `rejected`, `skipped` counts.
`AdornmentPass.defaultBatchSize` public constant.

### 1.57.0 -- 2026-08-22

Structural fix — one seam for `door_config` manifest reads:

`GeniusLocusKit.provisionedDoorConfig(for:)` (`VerbSurface.swift`) now
delegates to `RecallDirector.provisionedDoorConfig(estate:)` instead of
independently re-implementing the same six-line manifest-key decode. Call graph:

  `ToolDispatch.swift` → `kit.provisionedDoorConfig(for:)` → `provisionedDoorConfig(estate:)`

`RecallDirector.provisionedDoorConfig(estate:)` is now the single decode
implementation for the `door_config` key. The public surface and all call
signatures are unchanged; this is an internal structural fix only.

Also: `DoorManifestTests.swift` added to `GeniusLocusKitTests` covering
spec-default, round-trip, absent-key, partial JSON, unknown-scoring-string
fallback, golden pin, and estate verb round-trips. Rust: provisioned-config
test added to `dispatch_tests.rs` (`memory_search_door_guess_with_provisioned_config_uses_manifest_scoring`);
door-overrides-scoring gate test strengthened with a discriminating assertion
(`degraded_stages:[unionBest.rrf]` proves precedence); tool-description text
aligned between ports ("→ rrf or thorough (future);" restored in Rust).

### 1.56.0 -- 2026-08-22

Additive (front-door family — `DoorManifest` and `door_config` manifest key):

**Swift public surface (`GeniusLocusKit` actor, `VerbSurface.swift`):**
- `DoorManifest` struct: `Sendable`, `Equatable`, `Codable`; single field
  `scoring: GLKRecallScoring` (default `.matrixAware`); JSON key `"scoring"`;
  custom `init(from:)` for fail-quiet decode of unknown scoring strings;
  `static let default = DoorManifest(scoring: .matrixAware)`.
- `GeniusLocusKit.provisionDoorConfig(_ config: DoorManifest, for handle: EstateHandle) async throws`
- `GeniusLocusKit.provisionedDoorConfig(for handle: EstateHandle) async throws -> DoorManifest`

**Swift private surface (`RecallDirector`):**
- `RecallDirector.doorConfigMetaKey: String` (`"door_config"`)
- `RecallDirector.provisionedDoorConfig(estate:) async -> DoorManifest`

**Rust (`EstateCoordinator`, `coordinator.rs`):**
- `DoorManifest` struct with `serde::Serialize`/`Deserialize` (via custom
  `serialize_with`/`deserialize_with` helpers, since `GLKRecallScoring` has no
  serde derive; helpers use `raw_value()` and string-match round-trip).
- `EstateCoordinator::DOOR_CONFIG_META_KEY: &str` (`"door_config"`)
- `EstateCoordinator::provision_door_config(&self, handle, config: &DoorManifest) -> Result<(), VerbDispatchError>`
- `EstateCoordinator::provisioned_door_config(&self, handle) -> Result<DoorManifest, VerbDispatchError>`

All methods follow the fail-quiet pattern of `provisioned_recall_tuning` and
`provisioned_lane_weights`: absent key and malformed JSON both return the spec
default. No estate migration required.

### 1.55.0 -- 2026-08-21

Float-metric presets: `RecallShape.presetNames` / `RecallShape::PRESET_NAMES` gains
two new names — `"float-l2"` and `"float-dot"`. Both resolve to shapes identical to
`balanced` except `floatMetric` is set to `"l2"` or `"dot"` respectively. The
roster grows from 27 to 29 entries. No new struct fields or method signatures are
added — the change is entirely in the switch tables of `preset()` and
`presetDescription()` / `preset_description()`. `moot_recall_shaped` picks up the
two new names automatically.

### 1.54.0 -- 2026-08-21

W2.5 M1 float unlock: new and updated public API signatures for the float/dense
metric-selection surface.

**`RecallShape` (GeniusLocusKit)**

```swift
// New stored property (Codable-additive, absent key → "cosine")
public let floatMetric: String  // "cosine" | "l2" | "dot"; unknown → cosine at director
// New memberwise init parameter
init(..., floatMetric: String = "cosine")
```

Rust twin: `pub float_metric: String` on `RecallShape`; `pub fn with_float_metric(self, metric: &str) -> Self` builder.

**`CorpusContentEngine` (CorpusKit)**

```swift
// metric parameter added; default preserves existing behaviour byte-for-byte
func floatNearestPerSignal(query: String, limit: Int, metric: FloatMetric = .cosine) async throws -> [CorpusSignalResult]
func floatFarthestPerSignal(query: String, limit: Int, metric: FloatMetric = .cosine) async throws -> [CorpusSignalResult]
func floatNearestPerSignalWithDiscrimination(query: String, limit: Int, metric: FloatMetric = .cosine) async throws -> [CorpusSignalResult]
```

Rust: `float_nearest_per_signal`, `float_farthest_per_signal`,
`float_nearest_per_signal_with_discrimination` all gain `metric: FloatMetric`.

**`VectorStore` (SynapseKit)**

```swift
// metric parameter added; default preserves existing behaviour byte-for-byte
func findNearestFloat(probe: [Float], modelID: String, limit: Int, metric: FloatMetric = .cosine) throws -> [VectorMatch]
func findFarthestFloat(probe: [Float], modelID: String, limit: Int, metric: FloatMetric = .cosine) throws -> [VectorMatch]
```

Rust: same signatures with `metric: FloatMetric`. Both ramResident (via
`FloatBruteForceIndex.search(metric:)`) and diskBacked (`_floatScanFromTable`) paths
dispatch on the metric.

**`RecallDirector` (GeniusLocusKit, private)**

`floatMetric(for:) -> FloatMetric` added as a private mapping function beside the
existing `binaryMetric(for:)`. Called at the float-lane construction site and passes
the resolved metric through the CorpusContentEngine calls.

Additive on all call sites — default `.cosine` preserves pre-1.54.0 behaviour.

### 1.53.0 -- 2026-08-21

EMBED-PROV-E2: embedding_provider manifest key consumption in wireSubstores (Swift);
Rust provenance recording; `apply_provisioned_embedding_provider` (Rust).

**Swift consumption (new behavior in `wireSubstores`):**

`GeniusLocusKit.wireSubstores(for:kind:backingStorage:embeddingModels:)` now reads
the `embedding_provider` manifest key at wire time (the moment an estate's Corpus
is constructed — called by both `provision` and the serve entry points). The base
`embeddingModels` argument is augmented when a known provider ID is found:

- Absent key or empty string: `baseModels` returned unchanged. Byte-identical to
  pre-EMBED-PROV-E2 behavior for every existing estate. No side effects.
- `"apple-nl-v1"`: appends `.nlEmbedding(provider: AppleNLProvider())` to
  `baseModels`. Gated `#if canImport(NaturalLanguage)` — no-op on non-Apple platforms.
- Unknown ID: logs one `OSLog.warning` including the unrecognised ID and estate UUID,
  returns `baseModels` unchanged.

Private helper added to `GeniusLocusKit` (not public API):
```
private func applyProvisionedEmbeddingProvider(
    baseModels: [EmbeddingModel],
    for handle: EstateHandle
) async -> [EmbeddingModel]
```
Called from both `.glk` and `.corpusOnly` branches of `wireSubstores` before the
Corpus is built; for `"encoder"` it returns `baseModels` unchanged and the
activation runs later through `activateSpanEncoderIfProvisioned(for:)`. Not callable
by external consumers; documented here for completeness.

**Rust provenance recording (new method on `EstateCoordinator`):**

```rust
pub fn apply_provisioned_embedding_provider(&self, handle: &EstateHandle)
```

Reads `embedding_provider` from the estate manifest. If present and non-empty, emits
one stderr line per estate open:
```
mootx01 embed-prov: estate {uuid} provisioned embedding_provider '{model_id}' — Rust port records provenance but selects nothing …
```

Returns without modifying any ensemble. Called from `EstateCoordinator::provision`
after wiring (before wing seeding). Fail-quiet on estate lookup errors.

**Parity ruling (sanctioned divergence):**

Swift resolves `embedding_provider` to a concrete `EmbeddingProvider`
(`AppleNLProvider` for `"apple-nl-v1"`, `NeuralEmbedProvider` for
`"neural-embed-v1"`). For those ids Rust reads the key for provenance and
manifest consistency only — it instantiates no NaturalLanguage-backed
provider because that framework is Apple-only. The engine-neutral Rust
backend for `"neural-embed-v1"` is the standalone `tools/neural-embed` crate,
reached as an external subprocess seam; it is not linked into any product
crate. The `"encoder"` value is the exception on both ports: see "Span
encoder activation" (2.21.0).

### 1.52.0 -- 2026-08-21

EMBED-PROV-E1: optimizer-owned embedding-provider selection surface (both ports).

New estate manifest key constant `GeniusLocusKit.embeddingProviderMetaKey` /
`EstateCoordinator::EMBEDDING_PROVIDER_META_KEY` (`"embedding_provider"`). Follows
the same optimizer-owned, fail-quiet contract as `laneWeightsMetaKey` and
`recallTuningMetaKey`: the benchmarker/optimizer selects the provider ID; the
product only reads the selection.

New verb methods (purely additive; zero existing callers):
- Swift `provisionEmbeddingProvider(_ modelID: String, for handle: EstateHandle) async throws` on `GeniusLocusKit`
- Swift `provisionedEmbeddingProvider(for handle: EstateHandle) async throws -> String?` on `GeniusLocusKit`
  — returns `nil` when the key is absent (sentinel: use deterministic default ensemble)
- Rust `provision_embedding_provider(&self, &EstateHandle, &str) -> Result<(), VerbDispatchError>` on `EstateCoordinator`
- Rust `provisioned_embedding_provider(&self, &EstateHandle) -> Result<Option<String>, VerbDispatchError>` on `EstateCoordinator`

The value is a plain string (`EmbeddingProvider.modelID`, e.g. `"apple-nl-v1"`),
not JSON — no encode/decode step. Absent key → deterministic default ensemble
(RI/PPMI/LSA/NMF/FDC). No estate migration required.

Rust port note: ML embedding providers are a sanctioned Swift-only divergence
(`#if canImport(NaturalLanguage)`). The Rust twins exist so the manifest key is
consistent between ports and the provision/read surface is available to any future
Rust consumer (e.g. a federation relay reading estate config). ADDITIVE.

### 1.51.0 -- 2026-08-20

Rust resident live-closure wiring for standing signals 10 and 12 (Mission C):

- `default_standing_signal_specs` (Rust, `brain/signals/default_set.rs`) gains two
  optional parameters: `hunt_cycle: Option<Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync>>`
  and `anomaly_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>`.
  When `Some`, the live `ContradictionScoutSignal::spec(hunt_cycle)` /
  `AnomalySweepSignal::spec(anomaly_cycle)` factories are used; when `None`, the
  diagnostic-only `default_spec()` is used (unchanged behavior for callers passing `None, None`).
  Mirrors the Swift `registerDefaultStandingSignals(huntCycle:anomalyCycle:)` default-parameter
  pattern.

- `AutonomicGovernor::register_default_standing_signals` (Rust, NeuronKit) gains the same two
  optional parameters and forwards them to `default_standing_signal_specs`.

- `runtime.rs` (AriaMcpKit) now passes live closures wrapping
  `EstateCoordinator::hunt_contradictions` (four-hourly lookback window, probe_limit=50,
  proximity_threshold=64, model_id="minilm-v6") and `EstateCoordinator::anomaly_flag_sweep`
  (ANOMALY_SWEEP_DEFAULT_THRESHOLD=2.0) to the governor's registration call, completing
  Rust parity with the Swift resident's `huntCycle` and `anomalyCycle` wiring.

- Parity gate: two new tests in `standing_signals_parity.rs`
  (`live_hunt_closure_emits_complete_diagnostic_not_noop_fired`,
  `live_anomaly_closure_emits_complete_diagnostic_not_noop_fired`) assert that injecting live
  closures selects the `spec(…)` factory (emitting `.pass.complete` / `.complete` diagnostic titles)
  rather than `default_spec()` (emitting `.fired` no-op titles). Golden pin matches the Swift
  spec factory's diagnostic-title and detail-string format.

### 1.50.0 -- 2026-08-20

- P3a: `AnomalySweepSignal` wired as signal 12 in the default standing-signal
  set (both ports). `registerDefaultStandingSignals` signature gains an
  optional `anomalyCycle: @escaping @Sendable (Date) async throws -> Int`
  parameter (default no-op), forwarded to `AnomalySweepSignal.spec`. The
  prior §1.47.0 entry for `anomalyFlagSweep` no longer carries "Swift-only":
  the Rust port now has `EstateCoordinator::anomaly_flag_sweep` and the full
  signal factory (`AnomalySweepSignal::spec`/`default_spec`). Parity tested
  in `standing_signals_parity.rs` (4 new AnomalySweepSignal tests) and
  `AnomalySweepSignalTests.swift` (7 new cycle-level tests).

### 1.49.0 -- 2026-08-20

- M4 single-derivation: `GLKRecallResult` gains
  `queryLatticeAnchor: QueryLatticeAnchor.Anchor?` (Swift) /
  `query_lattice_anchor: Option<(String, String)>` (Rust).
  The recall director derives the §8.3 lattice anchor exactly once per
  request (corpus/hybrid/unionBest/locus-ranked paths call `query_anchor`;
  locusOnly carries `nil`/`None`). Callers MUST NOT call
  `QueryLatticeAnchor.derive(from:)` / `query_anchor()` on the same
  query text a second time. The field is `nil`/`None` when the query is
  empty, unanchorable (both udc_code and qid would be empty), or when the
  locusOnly lane ran (no sketch compiled). The anomalous-filter passthrough
  carries the anchor unchanged from the wrapped result.

### 1.47.0 -- 2026-08-20

- §11.18 anomalous-flag recall prefilter.
  1. `GLKRecallRequest.anomalousFilter: Bool?` / `anomalous_filter:
     Option<bool>` — additive optional field defaulting to `nil`/`None`
     (passthrough). Swift: `init` parameter after `frontierK:`. Rust:
     `with_anomalous_filter(filter: bool) -> Self` builder (struct field
     `anomalous_filter: Option<bool>`). Gate applied BEFORE scoring in
     `recall`/`recall_scored`.
  2. `GeniusLocusKit.anomalyFlagSweep(handle:threshold:now:) async throws -> Int`
     / `EstateCoordinator::anomaly_flag_sweep(handle, threshold, now)` —
     room-cohesion sweep (both ports, P3a): sets/clears bit 26 (`isAnomalous`)
     on each drawer based on char-3-shingle Jaccard z-score against room peers.
     Constants: `GeniusLocusKit.anomalySweepMinRoomSize: Int = 3` /
     `ANOMALY_SWEEP_MIN_ROOM_SIZE: usize = 3`;
     `GeniusLocusKit.anomalySweepDefaultThreshold: Float32 = 2.0` /
     `ANOMALY_SWEEP_DEFAULT_THRESHOLD: f32 = 2.0`. Returns count of changed
     drawers. Idempotent; skip-write when bit already correct. Wired as
     signal 12 (`AnomalySweepSignal`) in the default standing-signal set.

### 1.44.0 -- 2026-08-20

- W2.5 Track R(a): `GLKRecallRequest` gains optional `door` and
  `composition` (Swift init parameters defaulted to nil; Rust
  `with_door`/`with_composition` builders). `GLKRecallResult` gains
  `laneRanks` (`[String: [String: Int]]` / `HashMap<String,
  HashMap<String, i64>>`) — per-lane 1-based candidate ranks keyed by
  drawer id then lane key ("locus", "bm25", "hamming", "dense").
  Populated by every lane; consumed by the director's external-origin
  trace write (see SPEC 1.38.0).

### 1.35.0 -- 2026-08-14
`GLKRecallRequest.init` (Swift) and `GLKRecallRequest::new` (Rust): all five
behaviour-selecting parameters — `mode`, `scoring`, `limit`, `fallback`, and
`origin` — are now required constructor arguments in both ports. No default
values remain; builders for the five required parameters are removed from the
Rust port (`with_mode`, `with_scoring`, `with_limit`, `with_fallback`, the
`external()` origin setter). The three nil-defaulted optionals (`queryText` /
`query_text`, `traceLimit` / `trace_limit`, `recallShape` / `recall_shape`)
keep their nil defaults and remain settable via chained builder methods. Callers
that previously relied on defaults now state their lane and policy at the call
site; compile-time enforcement prevents omissions.

### 1.34.0 -- 2026-08-13
`AutonomicGovernor` wires `EstateThetaBasisRetrainHook(handle:kit:)` as the
`thetaRetrainHook` parameter of `DreamingDaemon.init` at production construction
time. The adapter calls `GeniusLocusKit.reindexCorpus(handle:now:)` — no new
public GLK surface added. This is the composition-layer wiring for the THETA
basis-retrain duty (NEURONKIT_SPEC § 12.6.1 / NEURONKIT_INTERFACE 1.11.0).

### 1.33.0 -- 2026-08-13

- `auditEvents(_ handle:after:limit:)` (Rust
  `EstateCoordinator::audit_events(handle, after, limit)`): estate-wide
  HLC-ordered audit page — handle validation plus the LocusKit
  `Estate.auditEvents` pass-through. The C3/A6 timing-derivation paging
  seam consumed by `moot_timing_report`.
- Reindex completion now seals a C3 `reindexComplete` marker at the
  chokepoint (Swift `EncodeIntake.reindexMissing` tail; Rust
  `EstateCoordinator::append_reindex_complete_marker` called from the
  `moot_reindex` tool tail), gated by `MOOTX01_ENCODE_MARKERS`.

### 1.32.0 -- 2026-08-13

- `appendDreamCycleMarker(in:phase:sessionID:now:)` (Rust
  `EstateCoordinator::append_dream_cycle_marker(handle, verb, session_id,
  marked_at_ms)`): dream-cycle bracket pass-through to the estate audit
  log, flag-gated with the A2 encode markers. Called by
  `EstateDreamingSink`'s A3 lifecycle hooks.
- Encode-completion markers (A2): `wireCorpusRoomRollup`'s onEncoded
  closure now also seals one `encodeComplete` audit marker per drain
  unit (first drawer anchor, row count, unit session id), flag-gated by
  `MOOTX01_ENCODE_MARKERS` (default ON). Because recording is
  flag-gated, "markers present" is a BUILD INPUT for benchmark artifacts
  (B2 provenance manifest).

### 1.31.0 -- 2026-08-07

- MXE-CT3 tiered contradiction surface (concordance rows added):
  `tieredContradictionSearch(in:tier:topK:modelID:probeLimit:now:)` ↔
  `tiered_contradiction_search` (synthesis + single-tier modes, topK
  clamp 50, report/finding/counts/diagnostics types, `ContradictionTier`
  1/2/3); `proposeConflictTunnels(in:registry:modelID:probeLimit:lexicalTopK:now:)`
  ↔ `propose_conflict_tunnels` (tier-labeled filing, decline matrix,
  `proposedTier2IDs`/`proposedTier3IDs`/`suppressed`/`ceilingSkipped`);
  review ladder verbs `endorseTunnel`/`objectToTunnel` ↔
  `endorse_tunnel`/`object_to_tunnel` (endorse never activates);
  `ReviewQueueRanking` ↔ `review_queue`.

### 2.1.0 -- 2026-08-26

- `AssociateSweepReport` gains `nonUniqueProbes: Int` ↔
  `non_unique_probes: usize` (SPEC 2.1.0 ladder cut; Swift init takes
  the new parameter with default 0). `ProximityScanCore.candidates` ↔
  `proximity_scan_candidates` return the pair list plus the
  non-unique-probe count.

### 1.30.0 -- 2026-08-05

- `associateSweep(in:probeLimit:now:)` ↔
  `associate_sweep(handle, probe_limit: Option<usize>, now)` — returns
  probed / candidatePairs / written / deduplicated / nonUniqueProbes
  (AssociateSweepReport both ports; SPEC 2.1.0 ladder cut — the
  nonUniqueProbes count is rung 4's zero-pair disclosure).

### 1.29.0 -- 2026-08-05

- **1.43.0 (2026-08-20)** — RecallShape preset roster gains "matrix_decayed" (22nd — matrixWeighting decayed; W2.5 S4-C arm), both ports; moot_recall_shaped roster enum follows automatically.

- **1.42.0 (2026-08-20)** — MatrixTier.coOccurrenceDecayed/temporalCausalityDecayed/decayedAsOfMs + decayedCoOccurrence(from:nowMs:) + rebuildTemporal(...decayNowMs:); RecallShape.matrixWeighting; RecallMatrixScorer.coOccurrenceDecayed/temporalDecayed (Rust: decayed_co_occurrence, rebuild_temporal_from_with_decay, with_matrix_weighting; apply_decay removed).

- **1.41.0 (2026-08-20)** — CorefStage (public): resolve(rendering:pool:), contributedEntities(from:), Antecedent, windowItems/windowMinutes; distillItem gains corefPool (Rust: brain::coref_stage, distill_item/render_distillation coref_pool param).

- **1.53.0 (2026-08-21)** — EMBED-PROV-E2: wireSubstores reads embedding_provider key at wire time; "apple-nl-v1" → appends AppleNLProvider to ensemble (Swift, #if canImport(NaturalLanguage)); absent/unknown key → byte-identical fallback; Rust apply_provisioned_embedding_provider records provenance to stderr, never selects (sanctioned divergence; see PART_E_RUST_SEAM_DESIGN.md).

- **1.52.0 (2026-08-21)** — EMBED-PROV-E1: embeddingProviderMetaKey / EMBEDDING_PROVIDER_META_KEY ("embedding_provider"); provisionEmbeddingProvider(_:for:) / provisionedEmbeddingProvider(for:) -> String? (Rust: provision_embedding_provider / provisioned_embedding_provider -> Option<String>). Absent key → nil (deterministic default ensemble). Plain string, no JSON. Purely additive.

- **1.46.0 (2026-08-20)** — RecallTuningManifest type (both ports; 4 optimizer knobs: rrf_k, mmr_lambda, rrf_bm25_weight, rrf_vector_weight); recallTuningMetaKey / RECALL_TUNING_META_KEY; provisionRecallTuning(_:for:) / provisionedRecallTuning(for:) (Rust: provision_recall_tuning / provisioned_recall_tuning). Fail-quiet on absent/malformed JSON.

- **1.40.0 (2026-08-20)** — provisionLaneWeights(_:for:) / provisionedLaneWeights(for:) (Rust: provision_lane_weights / provisioned_lane_weights, LANE_WEIGHTS_META_KEY); GeniusLocusKit.mergedLaneWeights precedence helper.

- **1.39.0 (2026-08-20)** — GeniusLocusKit.sentenceTimestamps(sentences:pieces:separator:combined:) internal helper (Rust EstateCoordinator::sentence_timestamps); DistillationInput.memoryTimestamps now populated on the consolidation path (Rust epoch-seconds f64 from event_time ms).

- **1.38.0 (2026-08-20)** — QueryLatticeAnchor.derive(from:) -> Anchor{udcCode, qid} (Rust: query_anchor(text) -> (String, String)).

- **1.37.0 (2026-08-20)** — `RecallShape.init(laneWeights:antiSimilarLanes:frontierK:binaryMetric:)`; preset "jaccard" + description; Rust `RecallShape.binary_metric` + `with_binary_metric`, PRESET_NAMES len 21.

- **v1.36.0 (2026-08-20)** — EnrichmentStage (Brain, internal): `trailer(forContent:) -> String` (Rust `brain::enrichment_stage::enrichment_trailer`), `maxFacts` = 6. No public API change; the p2-det contract is observable through distilled renderings and distilled_pipeline_version.

- **`VectorSimilaritySignal.spec` gains a `probeLimit` / `probe_limit`
  parameter (default 50).** Swift: `probeLimit: Int = defaultProbeLimit`
  added after `proximityThreshold`; `defaultProbeLimit` static constant
  replaces the former private `maxProbeCount`. Rust:
  `probe_limit: usize` added after `proximity_threshold`;
  `DEFAULT_PROBE_LIMIT: usize = 50` (pub const) replaces
  `MAX_PROBE_COUNT`. Resident behavior is byte-unchanged at the default.
  The probe window is one-sided (recency-sampled probes, whole-estate
  neighbor search); widening `probeLimit` relieves the constraint that
  two dormant old items never pair unless one was probed while recent.

### 1.28.0 -- 2026-08-04

- **`expunge` returns `ExpungeVerbOutcome` (MXE-FA).** Swift
  `GeniusLocusKit.expunge` returns the new public `ExpungeVerbOutcome`
  (`refusedSiblingIDs: [String]`, not `@discardableResult`); Rust
  `EstateCoordinator::expunge` returns
  `Result<ExpungeVerbOutcome, VerbDispatchError>` (re-exported at crate
  root). Step 2's cross-kit vector delete is scoped to the members the
  storage expunge actually scrubbed — gate-refused accepted siblings keep
  content AND vectors. `defragVagueItem` / `defrag_vague_item` raise
  `.underlyingEstateFailure` when the vague-cascade expunge was partial.
  Binding invariant (LOCUSKIT_SPEC B-8b): no layer reports success for an
  expunge that refused a sibling.

### 1.27.0 -- 2026-08-03

- **`captureKGFact` inherits the source drawer's sensitivity (MXE-KH).** A
  non-empty `sourceDrawerID` now loads that drawer and copies its adjective
  and provenance bitmaps onto the fact, so a fact extracted from a Secret
  drawer is itself Secret and is withheld by the fact-search disclosure
  ceiling. An id naming no drawer throws the new
  `GeniusLocusKitError.sourceDrawerNotFound` instead of filing at the Normal
  default. An empty `sourceDrawerID` keeps today's zero-bitmap behaviour.
- **New defaulted parameters** `id`, `addedBy`, `foreignSourceKey`, and
  `foreignRecordID`. Rust reaches the same implementation through
  `add_kg_fact`, `add_kg_fact_with_origin`, and
  `add_kg_fact_with_id_and_origin`, and adds
  `VerbDispatchError::SourceDrawerNotFound`.
- **The meeting-decision seam routes through `captureKGFact`** in both ports
  rather than writing the KG store directly, so decisions extracted from a
  Secret transcript carry that transcript's sensitivity.

### 1.26.0 -- 2026-08-03

- DCP M2-M6 surfaces (Swift ↔ Rust): ConflictProjector.project ↔
  brain::conflict_projection_pass::project; ConflictCoordinateIndex ↔
  ConflictCoordinateIndex (bucket cap 64, truncation diagnostics);
  conflictProjectionSweep ↔ conflict_projection_sweep;
  proposeConflictTunnels ↔ propose_conflict_tunnels;
  captureMeetingDecisions ↔ capture_meeting_decisions (+
  meetingDecisionFactID ↔ meeting_decision_fact_id, golden-pinned);
  fileSupersessions ↔ file_supersessions.

### 1.25.0 -- 2026-08-02

- Rider-default ruling: host-layer auto-enable documented
  (`ToolProjection.subjectRiderEnabled(environment:)`, env
  `MOOTX01_SUBJECT_RIDER`, install flag `--subject-rider-off`);
  dreaming triggers append a `subjectsBackfilled:` line when a sweep
  ran.

### 1.24.0 -- 2026-08-02

- PR-10: `MiniLLMSubjectProducer` (Apple-only, availability-gated),
  `enableAppleSubjectRider(for:)`,
  `SubjectProducer.regeneratesPipelines` ↔ `regenerates_pipelines`
  (default empty); sweep and drain-lane pending are tier-aware.

### 1.23.0 -- 2026-08-02

- PR-09: new coordinator surface — `SubjectProducer` (protocol/trait),
  `SubjectBackfillReport`, `registerSubjectProducer(_:for:)` ↔
  `register_subject_producer`, `subjectProducerPipeline(for:)` ↔
  `subject_producer_pipeline`, `subjectBackfillSweep(_:batchLimit:now:)`
  ↔ `subject_backfill_sweep`, and the rider-gated `subject_backfill`
  drain-lane row (`DrainStatus.subjectBackfillName` ↔
  `SUBJECT_BACKFILL_NAME`).

### 1.22.0 -- 2026-07-30

MXE-BB: three new migration-surface entries (both ports):

- `SharedContentMigrationError.migrationParked(atState:failureCount:error:parkedAt:)`
  — thrown by `runSharedContentMigration` when the circuit breaker has tripped.
  moot-mgr detects this case and idles its respawn loop.
- `sharedContentMigrationIsParked(handle:) async -> Bool` — queries whether the
  migration is currently parked; returns false when no record exists.
- `clearParkedSharedContentMigration(handle:now:) async throws` — operator reset;
  clears circuit-breaker state so the next call to `runSharedContentMigration`
  will attempt the migration again.

Circuit-breaker state is persisted as the optional `circuitBreaker` field of
`SharedContentMigrationRecord`; absent on records written before this version
(decodes as `nil` = no failure history).

### 1.21.0 -- 2026-07-20

- Added the GLK-owned `LocusDrawerCorpusContentSource` adapter contract and
  attached `.wholeContent` mode requirement.
- Changed encode queue payloads and hybrid recall identity to canonical Drawer
  changes/results; retired the chunk-to-Drawer translation from the GLK surface.
- Defined `corpusStorage` as derived-state-only and made Corpus/vector teardown
  ownership-scoped.
- Updated composite schema/hydration language for the pre-1.1 migration gate;
  standalone Corpus content/passage schemas are excluded from GLK.

### 1.19.0 -- 2026-07-16
Audit corrections and MX-TAB dataset surface (shipped 2026-07-11/12, not
previously documented):

**Dataset surface (MX-TAB-5 and MX-TAB-7):**
`datasetStore(for:)` public coordinator seam added (`DatasetStoreAccess.swift`)
— Swift-only; returns `any DatasetStore` for an open estate, throws
`.estateNotOpen` or `StorageError.featureGated("datasetStore")`.
`computeDatasetSignatures(handle:drawerId:columns:columnStats:sampledRows:now:)`
(`Intake/DatasetSignatures.swift`) and its Rust free-function counterpart
`compute_dataset_signatures` (`rust/src/dataset_signatures.rs`) added —
Tier 1 (table SHA-256, domain tag 0x10, 128-row sample) and Tier 2
(per-column SHA-256, domain tag 0x11) layered content fingerprints;
byte-identical cross-leg preimage format; anchor hashes locked in both test
suites. Dataset store access subsection and two concordance rows added.

**Parity corrections:**
`IssueGrantResult` Rust status corrected — was incorrectly documented as
missing; `pub struct IssueGrantResult` confirmed at `grants/grant.rs:354`.
`FederatedRecallResult` and `FederatedReadRefusalReason` removed from the
"Swift-only surfaces" paragraph — both ARE confirmed in the Rust port per
the concordance table.
`registerGraphCache`/`registerPreferenceStore` Rust note corrected — these
symbols are NOT in the Rust port; the prior claim "wired in both ports
(mission glk-recall-graphpref-rust)" was wrong.
`ExpungeIntegritySweepResult` concordance row field names corrected —
actual fields are `remediatedCount`/`remediated_count`,
`orphanedCount`/`orphaned_count`, `perRowErrors`/`per_row_errors` (not the
expungedCount/orphanCorpusEntriesRemoved/durationMs names the row showed).

### 1.18.0 -- 2026-07-12
VectorSimilaritySignal corpus lane (both ports): `spec` gains an optional
`corpus` parameter (Swift default `nil`; Rust `Option<Arc<Corpus>>` as a
required fourth argument). With a corpus supplied, the five-minute pass
also mines the chunk-keyed corpus vector lane and maps hits to owning
drawers — see GENIUSLOCUSKIT_SPEC.md 1.13.0 for the behavioral contract.
`registerDefaultStandingSignals` / `default_standing_signal_specs` forward
the estate's registered corpus; Rust `EstateCoordinator::corpus_for`
promoted `pub(crate)` → `pub` for the governor's cross-crate bootstrap.

### 1.17.0 -- 2026-07-12
Contradiction hunter (both ports at parity): new Tier-1 kit pass
`huntContradictions(in:modelID:probeLimit:filedAfter:proximityThreshold:now:)`
(Swift `Brain/ContradictionHunt.swift`) / `EstateCoordinator::hunt_contradictions`
(Rust `coordinator.rs`) with `ContradictionHuntReport` /
`ProposedContradiction` / `BorderlineContradiction` result types, and the
`ContradictionScoutSignal` standing signal (`"contradiction-scout"`, hourly,
closure-injected hunt cycle, registered 4th). Standing-signal inventory is
now ten; the interface concordance table renamed from "Six v1 standing
signals (+ temporal)" and gained scout/distillation/training rows, and the
temporal row now points at the standalone Rust `TemporalCausalitySignal`
type (`brain/signals/temporal_causality.rs`). Consumed by the ARIA
`moot_hunt_contradictions` / `moot_dream` / contradiction-scout surfaces
(ARIA_MCP_SPEC.md § contradiction hunter). The hunt mines TWO vector
lanes: drawer-keyed rows under the caller's modelID, and chunk-keyed
corpus rows mapped back to owning drawers via the new
`Corpus.sourceIDs(forChunkIDs:)` / `source_ids_for_chunks` accessor
(CORPUSKIT_INTERFACE.md 1.14.0) — the lane production estates actually
populate.

### 1.16.0 -- 2026-07-09
AUDIT-ALERT-RESTORE (the option-1 ruling): `UnifiedAuditLog` gained a
new public read-only property, `rejectedEntryCount: Int` (Swift) /
`rejected_count() -> usize` (Rust) — the count of entries rejected on
this log instance's ingress since construction. Additive only; every
other member of the `UnifiedAuditLog` surface is unchanged. See
GENIUSLOCUSKIT_SPEC.md § I-11/B-9/B-10 and NEURONKIT_SPEC.md § 9 C-4/C-12.

### 1.15.0 -- 2026-06-28
Security fixes (secfix/c-glk-remaining): two API behaviour clarifications.

**G5 — Wing-scoped topology privacy in `recallTunnels`**
`recallTunnels(_ handle:, wing:)` now filters the frozen edge forest through
`estate.resolveNodeNames`, retaining only edges whose child resolves to the queried
wing. Foreign-wing node IDs no longer appear in a wing's tunnel output. The G1
read-once invariant (treeEdges called exactly once) is unaffected. See
`Read-once-freeze in recallTunnels` section above.

**G6 — `reindexMissing` / `collect_reindex_jobs` fan-out cap**
New public constant: `GeniusLocusKit.reindexMaxJobs: Int` (Swift) /
`EstateCoordinator::REINDEX_MAX_JOBS: usize` (Rust) — value 10 000. A single
`reindexMissing` call enqueues at most this many ingest jobs; estates with more
unindexed drawers are handled by repeated calls (each call advances the backfill
frontier). The `enqueueChunk` constant (1 024) remains the per-fsync unit.

### 1.14.0 -- 2026-06-25
Additive (T1 — encode mode): new `setEncodeSpeed(_:for:)` accessor (Rust
`EstateCoordinator::set_encode_speed`) + re-export of `EncodeSpeed` from
GeniusLocusKit. Forwards the import `mode` (foreground/background) onto the
estate's corpus drain QoS; no-op when no Corpus is registered. No verb/contract
change. (Swift defines a GLK `EncodeSpeed` enum mapping to CorpusKit's because
Swift forbids an imported enum's cases in a default argument; Rust re-exports
CorpusKit's directly.)

### 1.13.0 -- 2026-06-25
Additive (T6 — drain status): new public `DrainStatus` type + accessor
`drainStatuses(_:)` (Swift) / `EstateCoordinator::drain_statuses` (Rust). The
accessor assembles a read-only, list-shaped report of every long-running
background drain the estate runs (today only `corpus_encode`), reading each
drain's frontiers via `Corpus.ingestQueueDepth` without claiming or draining. It
validates the handle up front (a stale handle surfaces `EstateNotOpen`, distinct
from an empty list = "no drains"). Backs the `moot_drain_status` MCP tool. No
change to the verb surface or byte-identity.

### 1.12.0 -- 2026-06-23
Encode-pipeline relocation: the encode queue + drain + worker pool + payload
moved out of GeniusLocusKit into CorpusKit (a Corpus self-drains). Removed the
public `mountEncodeQueue(for:)` and the `EncodeJob` type from the GLK surface
(EncodeJob.swift deleted; the payload is now CorpusKit-internal `IngestJob`).
`capture(_:_:mode:)`, `awaitEncodeDrain(for:)`, and `reindexMissing` are now thin
orchestration delegators to the estate's `Corpus.enqueueIngest` /
`Corpus.awaitIngestDrain`; at provision GLK mounts the Corpus ingest queue and
wires the Corpus `onEncoded` callback to roll up the touched LocusKit rooms.
Updated the intake docstrings, the `WriteMode` section (EncodeJob section
removed), and the type concordance (EncodeJob row dropped).

### 1.11.0 -- 2026-06-22
GLK_BATCH1: `GeniusLocusKit.captureBatch(_:_:)` added to § 2 Tier-1 consumed
contract. Delegates to `Estate.captureBatch` (LocusKit 1.9.0) which opens ONE
`storage.transaction()` via `DrawerStore.insertFreshBatch` for fresh drawers and
falls back to per-item `addDrawerCovered` for supersession cascade. Fixes the
nested-transaction conflict (`StorageError.transactionConflict`) that occurred
when the previous implementation called `rowStore.beginTransaction()` then invoked
`capture()` per-row on a SQLite backend. BM25/vector lanes remain dark until
`moot_reindex` / `moot_dream` is invoked after batch import.

### 1.10.0 -- 2026-06-21
NT-DOC-1: Added 2 concordance rows to `## Swift/Rust Concordance — additional
public types`. `DistillationSignal` (Swift `public enum` namespace / Rust
`pub struct` unit struct; signal name `"distillation-sweep"`, hourly cadence,
DG5) and `TrainingSignal` (same Swift-enum/Rust-struct idiom; signal name
`"training-daemon"`, hourly cadence, the brain-layer ownership contract F1). Both factories expose
`spec(…)` (production) and `defaultSpec()`/`default_spec()` (no-op diagnostic).

### 1.9.4 -- 2026-06-21
NT-G1: Added `SubstrateNodeTopologyProvider` section documenting the auto-registered
substrate-native adapter (the node-integrity contract §10). Updated Swift test coverage table: test #1
changed from "no-provider unchanged" to "auto-registered substrate adapter produces
containment edges"; added `SubstrateNodeTopologyProviderTests` coverage.

### 1.9.2 -- 2026-06-19
Behavioral change on `capture(_:_:mode:)` (Swift) / `capture_with_mode` (Rust):
the method now classifies the incoming frame's `latticeAnchor.udcCode` at the seam
before storing the drawer. When the frame carries the canonical unclassified sentinel
`"000"` and non-empty `content`, the seam runs `EideticLib.lookup` (Swift) /
`Fdc::encode_anchor` (Rust) to resolve a real UDC code and updates the frame's
`latticeAnchor` before capture. Non-sentinel anchors pass through unchanged. This is
the one-door refactor: all capture paths (file_memory, vault import, branch promotion)
pass `"000"` and receive classification from the seam; per-caller classification code
is removed. The canonical unclassified sentinel is `"000"` (three-digit UDC root);
the previous incorrect value `"000.000"` (a child node) is retired fleet-wide.

Callers that previously set an explicit FDC code per call should now set
`latticeAnchor = LatticeAnchor.udc("000")` / `LatticeAnchor::udc("000")` and let
the seam classify, unless they have a pre-classified anchor from an authoritative
source (vault frontmatter `udc`, promotion of an already-classified branch drawer)
— in which case the non-sentinel code passes through unchanged.

### 1.9.1 -- 2026-06-19
Additive (FINDING-1b cluster C): `tombstonedLineageIDs(_ handle: EstateHandle) async throws -> Set<UUID>` added to the GLK verb surface (Swift `public extension GeniusLocusKit`). Rust twin: `EstateCoordinator::tombstoned_lineage_ids(&self, handle: &EstateHandle) -> Result<HashSet<Uuid>, VerbDispatchError>`. Returns the lineage IDs of all cluster C (permanently erased, `tombstonedAt IS NOT NULL`) drawers. The storage-tier predicate path bypasses timestamp parsing — resilient to format differences between `ISO8601DateFormatter()` (used by `expungeGated`) and `LKISO8601` (fractional-seconds parser). B-1-compliant: VaultKit reaches tombstoned rows through this GLK method, never by importing LocusKit directly.

### 1.9.0 -- 2026-06-17
Additive (#8 Track 1 — Brain harness, Rust side). `EstateCoordinator::vector_store_for(&handle)
-> Option<Arc<VectorStore>>` promoted from `pub(crate)` to `pub`, mirroring the
already-public Swift `GeniusLocusKit.registeredVectorStore(for:)`. The AriaMcpKit
autonomic governor reads it to build the architecture-spec §11.2 default
standing-signal specs at registration time (the producer-seam bootstrap; the GLK
`SerialLaneScheduler` + `CoordinatorDispatcher` engine and the six v1 signals
were already ported — see `genius_locus_kit/tests/scheduler_parity.rs`). No
signature, body, or semantics change; no Swift change. See ARIA_MCP_INTERFACE
§2 (Rust governor — standing-signal harness) for the consumer surface.

### 1.8.0 -- 2026-06-17
the forward-compatible ext-slot contract `ext` forward-compat slot: the `grants` table gained a nullable `.json` `ext` column (the #11 custody-payload slot, inert in 1.0), both ports. Composite schema version 3 → 7 = LocusKit v2 + SynapseKit v3 + CorpusKit (BundleStore) v2 — now DERIVED from the live component declarations in both ports (Swift sums the component `.version` fields; Rust sums `lk/vk/ck.version`), guarded by a new conformance test on each port. Corrected the composite-schema concordance row (previously read "version 3 / 1+1+1", already stale vs SynapseKit v2). Also corrected the misleading GRT-01 custody comment: mode-3 (decay-derived) is no-vault BY DESIGN — the issuer retains nothing, so not persisting threshold/totalShares/driftRate is correct, not a defect.

### 1.7.0 -- 2026-06-17
Additive + surface-narrowing (parity-sweep-batch):
- Additive (#12 Moment GLK read): the Rust port gains
  `EstateCoordinator::glk_fingerprints_captured(handle, start_epoch, end_epoch)
  -> Result<Vec<Fingerprint256>, VerbDispatchError>`, the mirror of Swift
  `GeniusLocusKit.glkFingerprintsCaptured(in:window:)`. It forwards through the
  new `Estate::fingerprints_captured_in` pass-through to
  `DrawerStore::fingerprints_captured_in`. The Rust `Moment` recipe
  (`moment_recipe::run_moment`) now reads its primary and comparison windows
  through this surface (dropping the pre-fetched-fingerprint workaround), and
  aria-mcp's `moot_lens_moment` no longer reaches `estate.store` directly —
  both ports now share the Swift flow over the GLK surface (B-1).
- Surface-narrowing (#9): the Rust scheduler test stub `NoopDispatcher`
  (re-exported `SchedulerNoopDispatcher`) is gated
  `#[cfg(any(test, feature = "test-seams"))]` and is no longer part of the
  shipped public API. Integration tests reach it via the `test-seams` feature.
  Swift has no public noop equivalent. See the concordance row above.

### 1.6.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): `RecallShape` gains a NAMED PRESET ROSTER.
New static factory `RecallShape.preset(_:)` (Swift) / `RecallShape::preset` (Rust)
resolves a roster name to its documented signed-weight shape; `presetNames` /
`PRESET_NAMES` is the discoverable name list (19 entries) and `presetDescription`
/ `preset_description` is the one-line emphasis text. `"balanced"` (and any
unknown name) resolves to `nil`/`None` — the unsteered uniform fusion. The roster:
balanced · precise · conceptual · broad · lexical · not_lexical · associative ·
consensus · ri_forward · ppmi_forward · lsa_forward · nmf_forward · fast ·
structural · temporal · connection · field · preference · anti_redundant. Each
preset is a weight vector over the EXISTING fusion (no new engine math); every key
a preset sets is a key the engine reads, so no preset is a silent no-op. The dense
per-signal keys are surfaced as `RecallShape.DenseSignal.*` (Swift) /
`RecallShape::DENSE_*` (Rust) constants (`dense:random-indexing-v1`, `dense:ppmi-v1`,
`dense:lsa-v1`, `dense:nmf-v1`, `dense:fdc-v1`). Leave-one-out is reachable by
zeroing one `dense:<modelID>` key (no dedicated preset). Conformance:
`RecallShapePresetTests.swift` / `recall_shape_presets.rs`. No existing
`RecallShape` field, init, or accessor changed.

### 1.5.0 -- 2026-06-17
Additive (glk-recall-graphpref-rust): the Rust port now documents and ships the
`GraphCache` / `PreferenceStore` recall-consumption surface, at parity with Swift.
Adds the `registerGraphCache` / `registerPreferenceStore` registration seam
subsection with the Rust trait definitions (`GraphCache` / `PreferenceStore`:
`Send + Sync`, per-drawer score lookup), `EstateCoordinator.register_graph_cache`
/ `register_preference_store`, and the per-candidate `col_graph` / `col_preference`
lookup in the unionBest `.matrixAware` score loop (both columns share the
`weights.graph` budget, Swift parity). Closes the recall-shape contract D-4 (Rust columns were
hardcoded `0.0`). Cache producers remain absent in both ports (future mission).

### 1.4.0 -- 2026-06-17
Additive (6b-modifiers-matrix-steer): `RecallShape`'s lane-key surface now spans
the FULL set of recall scoring columns. Five matrix/graph/preference keys —
`fieldFit`, `coOccurrence`, `temporal`, `graph`, `preference` — join the retrieval
keys (`locus`/`bm25`/`hamming`/`dense`/`dense:<modelID>`). Each scales its column's
contribution in the UnionBest `.matrixAware` weighted score with the same signed
semantics (1.0 neutral, 0 excludes, <0 suppresses), composed ON TOP of the
adaptive `RecallWeights` budget. The combined matrix term is split so
`coOccurrence` and `temporal` steer independently; the neutral path preserves the
exact pre-steer expression, so a nil/all-ones shape is byte-identical (proven both
ports). The matrix keys are a NO-OP under `.raw`/`.rrf` (those paths do not run the
weighted matrix formula). On the Rust port `graph`/`preference` are 0.0 (no cache
wired), so steering them is a no-op there; the steering SURFACE is identical
cross-port. No type change — the keys read through the existing `weight(for:)` /
`weight()` lookup (default 1.0). See the recall-shape contract. ADDITIVE (MINOR).

### 1.3.0 -- 2026-06-17
Added `RecallShape.antiSimilarLanes` / `RecallShape.anti_similar_lanes`
(mission 6b-modifiers-antisim) — a set of dense lane keys (`dense:<modelID>`)
that invert their objective from nearest to FARTHEST (anti-similarity). A lane
in the set queries CorpusKit `floatFarthestPerSignal` in the UnionBest dense
lane and forwards the most DISSIMILAR sources into the same RRF/consensus fold.
DISTINCT from a negative weight (which demotes the NEAREST); the two compose (a
lane can be anti-similar AND signed). New accessors `isAntiSimilar(_:)` /
`is_anti_similar()`; the Rust `RecallShape::new` is preserved (2-arg, empty set)
with a `with_anti_similar_lanes` builder; the Swift init gains an
`antiSimilarLanes: Set<String> = []` parameter. Empty/absent ⇒ every lane
nearest ⇒ byte-identical to the pre-antisim fusion. ADDITIVE (MINOR).

### 1.2.0 -- 2026-06-17
Changed (6a-iii-wire): `provision`'s embedding parameter is now the recall
**ensemble**. Swift `embeddingModel: EmbeddingModel = .deterministic` →
`embeddingModels: [EmbeddingModel] = CorpusEnsemble.defaultEnsemble()`; Rust
`embedding_model: EmbeddingModelConfig` → `embedding_models: Vec<EmbeddingModelConfig>`
(no default arg in Rust — the app caller threads `default_ensemble()`). The new
default wires the five distributional signals (RI/PPMI/LSA/NMF/FDC) at every production
provision site, so recall is the multi-signal default rather than a single
deterministic hash lane. The trainable signals train and persist on first
ingest/reindex. Callers wanting one signal pass an explicit single-element list.

### 1.46.0 -- 2026-08-20
W4 optimizer-owned recall tuning surface (both ports). New public type
`RecallTuningManifest` (Swift struct / Rust pub struct) carrying four optimizer-
tunable recall knobs: `rrfK`/`rrf_k` (Int/u32, default 60), `mmrLambda`/`mmr_lambda`
(Float/f32, default 0.7), `rrfBm25Weight`/`rrf_bm25_weight` (Float/f32, default 0.3),
`rrfVectorWeight`/`rrf_vector_weight` (Float/f32, default 0.7). Conforms to
`Sendable + Equatable + Codable` / `Serialize + Deserialize + PartialEq`. JSON wire
format uses snake_case keys (`rrf_k`, `mmr_lambda`, `rrf_bm25_weight`,
`rrf_vector_weight`); partial JSON fills absent keys with spec defaults (custom
`Decodable` / `#[serde(default = …)]`). New estate manifest key constant
`GeniusLocusKit.recallTuningMetaKey` / `EstateCoordinator::RECALL_TUNING_META_KEY`
(`"recall_tuning"`). New verb methods: Swift `provisionRecallTuning(_:for:) async throws`
and `provisionedRecallTuning(for:) async throws -> RecallTuningManifest` on
`GeniusLocusKit`; Rust `provision_recall_tuning(&self, &EstateHandle, &RecallTuningManifest)
-> Result<(), VerbDispatchError>` and `provisioned_recall_tuning(&self, &EstateHandle)
-> Result<RecallTuningManifest, VerbDispatchError>` on `EstateCoordinator`. Absent or
malformed JSON returns `.default` / `RecallTuningManifest::default()` (fail-quiet,
same contract as provisioned lane weights). All changes are purely additive; no
existing callers change.

### 1.45.0 -- 2026-08-20
W3 additive selector registrations (both ports). (a) Five new named presets on
`RecallShape.preset(_:)` / `RecallShape::preset`: `anti_redundant_ri`,
`anti_redundant_lsa`, `anti_redundant_nmf` (per-signal anti-similarity variants
with same bm25/hamming suppression as `anti_redundant` but inverting RI/LSA/NMF
to FARTHEST); `temporal_connection` (temporal 1.5 + coOccurrence 1.5);
`field_preference` (fieldFit 1.5 + preference 1.5). `presetNames`/`PRESET_NAMES`
grows from 22 to 27 entries. (b) New optional `frontierK: Int?` field on Swift
`GLKRecallRequest` (defaulted `nil` in the existing init so all callers remain
source-compatible); new Rust `frontier_k: Option<usize>` on `GLKRecallRequest`
with `with_frontier_k(usize)` builder. Both ports apply three-level precedence:
request > shape > engine formula, clamped to `[64, 256]`. No existing call sites
change; all changes are purely additive.

### 1.1.1 -- 2026-06-17
Clarification (6b-modifiers-core-2): `RecallShape` now steers the **UnionBest**
lane too — the only lane where the per-signal dense float signals fuse. The
per-signal `dense:<modelID>` weights scale each signal's reciprocal-rank term in
the dense consensus fold (`w==0` excludes the signal — leave-one-out, withholding
both its rank mass AND its cosine from the aggregate `dense` column; `w<0`
subtracts its rank mass — demotion; only forwarding `w>0` signals raise the
aggregate cosine). The fixed lanes `locus`/`bm25`/`hamming` and the aggregate
`dense` key scale their columns in the UnionBest weighted-column score. An excluded
signal no longer claims per-hit `denseSignals:` provenance; a suppressed signal
still does (it contributed subtracted mass). A nil/all-ones shape is byte-identical
to the pre-steer UnionBest output. No public API change — `RecallShape` and the
`recallShape`/`recall_shape` field are unchanged; this revision wires the already-
public dense weights that 6b-modifiers-core left inert in UnionBest.

### 1.1.0 -- 2026-06-17
Additive (6b-modifiers-core): new public `RecallShape` type (both ports) carrying
signed per-lane fusion weights (`laneWeights`/`lane_weights`, lane keys
`locus`/`bm25`/`hamming`/`dense:<modelID>`, missing key ⇒ 1.0; `w>0` forward,
`w==0` exclude, `w<0` suppress/demote) plus an optional `frontierK`/`frontier_k`
pool-depth override clamped to `[64, 256]`. New optional `recallShape`/`recall_shape`
field on `GLKRecallRequest` (defaults `nil`/`None`). A nil/absent shape is
byte-identical to the pre-6b-modifiers uniform fusion. Steering applies to the
Hybrid and CorpusOnly RRF lanes; UnionBest remains unweighted this mission. The
anti-similarity (true farthest-K) selector is deferred to a follow-up
(`6b-modifiers-antisim`) that also adds the SynapseKit/CorpusKit store-direction API.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.

### 1.59.0 -- 2026-08-22
MODES-PREFS mission: estate-stored modes preferences (both ports).

**New type `ModesManifest`** (Swift: `public struct ModesManifest: Sendable, Equatable, Codable`; Rust: `pub struct ModesManifest` with `serde::Serialize, Deserialize`):
- `stickyEnabled: Bool` / `sticky_enabled: bool` — when false, mode declarations are accepted-and-hinted but not stored in sticky state. Wire key: `sticky_enabled`. Default: `true`.
- `coachingCalls: Int` / `coaching_calls: usize` — how many tool calls between coaching blocks; 0 = off. Wire key: `coaching_calls`. Default: `25`.
- Manifest JSON key: `"modes_config"`.
- Fail-quiet decode: absent key or malformed JSON returns `ModesManifest.default` (stickyEnabled=true, coachingCalls=25).

**New VerbSurface methods (Swift):**
```swift
public func provisionModesConfig(_ config: ModesManifest, for handle: EstateHandle) async throws
public func provisionedModesConfig(for handle: EstateHandle) async throws -> ModesManifest
```
Both delegate to `RecallDirector` (one seam, same pattern as `provisionedDoorConfig`).

**New `RecallDirector` internal methods (Swift):**
```swift
func provisionedModesConfig(estate: LocusKit.Estate) async -> ModesManifest
static var modesConfigMetaKey: String { "modes_config" }
```

**New `EstateCoordinator` methods (Rust):**
```rust
pub const MODES_CONFIG_META_KEY: &str = "modes_config";
pub fn provision_modes_config(&self, handle: &EstateHandle, config: &ModesManifest) -> Result<(), VerbDispatchError>
pub fn provisioned_modes_config(&self, handle: &EstateHandle) -> Result<ModesManifest, VerbDispatchError>
```

### 1.58.0 -- 2026-08-22
PACKAGER mission: new public types exported from GeniusLocusKit (both ports).

**New enums:**
- `PackagerAnswerMode` — `never` / `always` / `auto`. Rust: `PackagerAnswerMode::from_str(&str) -> Option<Self>`.
- `PackagerConfidenceLevel` — `Confident` / `Intermediate` / `Weak`.
- `GLKResponseLevel` — `L0AnswerOnly` / `L1Full` / `RowsOnly`.

**New structs:**
- `GLKConfidenceSignals` — `m1: Double`, `m2: Double`, `m3: Double`, `m4: Bool`.
- `GLKAnswerBlock` — `answer: String`, `confidenceLevel: PackagerConfidenceLevel`, `citationIds: [String]` (the first five hydrated drawer ids, rank order), `signals: GLKConfidenceSignals`.
- `GLKPackagedResult` — `level: GLKResponseLevel`, `answerBlock: GLKAnswerBlock?`, `rows: [RecallHit]`, `totalCount: Int`.
- `PackagerThresholds` — `t1: Double`, `t2: Double`, `t1Prime: Double`, `t3Prime: Double`, `c: Double`, `kMin: Int`, `kMax: Int`. Static `default` with spec constants.

**New type:**
- `GLKResultsPackager` — stateless packager. Entry point:
  ```swift
  func package(result: GLKRecallResult, mode: PackagerAnswerMode, composedAnswer: String?, thresholds: PackagerThresholds = .default) -> GLKPackagedResult
  ```

**`RecallTuningManifest` additions:**
`packagerThresholds: PackagerThresholds` computed property extracting the seven new threshold fields from the manifest JSON. Fields: `packager_t1`, `packager_t2`, `packager_t1_prime`, `packager_t3_prime`, `packager_c`, `packager_k_min`, `packager_k_max` — all fail-quiet with spec defaults.

**`GLKRecallResult` additions:**
Public memberwise init (Swift: all fields explicit; Rust: public struct fields already public) so AriaMcpKit can construct synthetic results without going through the Recall Director.

**`RecallPlan` additions:**
Public memberwise `init(effectiveMode:frontierK:weights:)` (Swift). Rust: struct fields already public.

### 1.48.0 -- 2026-08-20
M3: `GLKRecallScoring` gains a fourth variant `discriminative` (Swift) / `Discriminative` (Rust). The new mode computes RRF fusion identically to `.rrf`, then scales every composite score by `denseDiscriminationFactor` ∈ [0, 1] — the same dense-lane saturation discount used by `.matrixAware`, but without any matrix steer, fieldFit, graph, or preference signals. When no dense lane runs (corpus absent or empty query), the factor is 1.0 and the result is byte-identical to `.rrf`. Scoring-fallback stages `locusOnly.discriminative`, `corpusOnly.discriminative`, and `hybrid.discriminative` added; `unionBest + discriminative` is a real implementation with no fallback. Both ports updated. Concordance table variant count updated from 3 → 4.
### 2.7.0 -- 2026-09-02
CDL-03: `GeniusLocusKit.indexCompositionPolicy(for:) -> IndexCompositionPolicy?`
access added. `EstateLifecycle` env-var seam documented
(`MOOT_INDEX_COMPOSITION`, parsed via `IndexCompositionPolicy.fromEnvironmentValue(_:)`).
Coordinator Rust: `index_composition_policy_from_env()` reads the same variable.

### 3.27.0 -- 2026-09-14

FACT_EXTRACTION_WIRE: retires the fact-first recall public surface from both
ports. `FactFirstRecallThresholds`, `FactRecallFamily`, `FactFirstRecallDecision`,
`FactFirstRecallStage`, `recallFactFirst` / `recall_fact_first` are removed. The
fact layer moves to its own door; the extraction duty (§ Fact-extraction public
surface) is unchanged.

### 3.26.0 -- 2026-09-14

FACT_EXTRACTION_WIRE: `FactExtractionSetting` type, `factExtractionMetaKey` /
`FACT_EXTRACTION_META_KEY` constant, and `provisionFactExtraction`/`provisionedFactExtraction`
accessor pair added to both ports (I-27).

**Swift:**
```swift
// New type (GeniusLocusKit module)
public enum FactExtractionSetting: String, Sendable, Equatable, CaseIterable {
    case on = "on"; case off = "off"
    public static let `default`: FactExtractionSetting = .on
}

// New key constant (static var on GeniusLocusKit)
static var factExtractionMetaKey: String { "fact_extraction" }

// New verb-surface accessor pair
func provisionFactExtraction(_ setting: FactExtractionSetting, for handle: EstateHandle) async throws
func provisionedFactExtraction(for handle: EstateHandle) async throws -> FactExtractionSetting
// Absent key or unrecognised value returns .on (absent-means-on, opt-out model).
```

**Rust:**
```rust
// New type (genius_locus_kit::coordinator)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactExtractionSetting { On, Off }
impl Default for FactExtractionSetting { fn default() -> Self { Self::On } }
impl FactExtractionSetting {
    pub fn as_str(self) -> &'static str { ... }
    pub fn from_str(s: &str) -> Option<Self> { ... }
}

// New key constant on EstateCoordinator
pub const FACT_EXTRACTION_META_KEY: &str = "fact_extraction";

// New accessor pair on EstateCoordinator
pub fn provision_fact_extraction(&self, handle: &EstateHandle, setting: FactExtractionSetting) -> Result<(), VerbDispatchError>;
pub fn provisioned_fact_extraction(&self, handle: &EstateHandle) -> Result<FactExtractionSetting, VerbDispatchError>;
// Absent key or unrecognised value returns FactExtractionSetting::On (opt-out default).
```
