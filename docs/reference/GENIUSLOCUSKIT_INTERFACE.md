---
title: GeniusLocusKit Interface
status: accepted-1.1-target
authors: MOOTx01 maintainers
date: 2026-07-30
version: 1.24.0
spec_type: kit
description: Public API surface for GeniusLocusKit in both the Swift and Rust ports. 1.22.0: MXE-BB — circuit-breaker API (migrationParked, isParked, clearParked) on both ports.
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
historical step. Swift consumers select `MigrationFloor1_0`; Rust consumers
enable `genius-locus-kit-migrations/migration-floor-1-0`. With no floor selected,
fresh/current SDK builds do not compile the 1.0-to-1.1 capsule. The Corpus lane
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
    public func estate(for handle: EstateHandle) throws -> LocusKit.Estate

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
    // (CorpusEnsemble.defaultEnsemble(): RI/PPMI/LSA/NMF/FDC). Every provisioned
    // estate gets the honest multi-signal default; the trainable signals train and
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
    public func expunge(_ handle: EstateHandle, _ frame: ExpungeFrame, now: Date = Date()) async throws
        // Throws: .expungeNotConfirmed | .crossKitVectorDeleteFailed (fail-closed, three-step).
        // §B-2a audit-seal ordering: success audit seals ONLY after Step 2
        // (cross-kit vector delete) succeeds. On Step-2 failure an
        // "expungeOrphan" substrate event is sealed and the throw fires —
        // the audit is honest, never a false success. If the orphan-seal
        // also fails, the seal error is logged at .fault level (Swift) or
        // folded into the CrossKitVectorDeleteFailed.reason string (Rust).

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
    // unanchored-fact sentinel for agent-asserted triples. retireKGFact
    // transitions the row to State.withdrawn so it exits the active-recall filter.
    // recallKGFacts returns active facts only (state cluster < 7).
    // recallKGFactTimeline returns ALL facts — active and retired — for the
    //   full lifecycle history; optional entity filter narrows by subject/object
    //   substring (case-insensitive). Peer of Rust recall_kg_fact_timeline.
    func captureKGFact(_ handle: EstateHandle, subject: String, predicate: String,
                       object: String, sourceDrawerID: String, now: Date) async throws -> KGFact
    func retireKGFact(_ handle: EstateHandle, rowID: String) async throws
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
    public func registerDefaultStandingSignals(in handle: EstateHandle, vectorStore: VectorStore, modelID: String = "minilm-v6", now: Date) async throws -> [String: SignalID]
    public func signalStatus(in handle: EstateHandle) async throws -> [SignalReport]
    public func signalTick(in handle: EstateHandle, now: Date) async throws
    public func signalRequestFire(_ signalID: SignalID, in handle: EstateHandle, now: Date) async throws
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
    // (version derived from the live LocusKit + VectorKit + attached-CorpusKit
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

```rust
// EstateCoordinator — write-path surface
pub fn add_kg_fact(
    &self, handle: &EstateHandle,
    subject: &str, predicate: &str, object: &str,
    source_drawer_id: &str, now: i64,
) -> Result<locus_kit::kg_fact::KGFact, VerbDispatchError>

pub fn withdraw_kg_fact(
    &self, handle: &EstateHandle, id: &str, now: i64,
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
`withdraw_kg_fact` transitions the fact's `adjective_bitmap` bits 0–5 to
`State::Withdrawn` (raw 18); upper bits are preserved. The parity surfaces
are `VerbSurface.captureKGFact` / `.retireKGFact` and `DreamingWrites.addDiaryEntry`
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
> return is a LIST so additional drains surface without a reshape; today the only
> entry is `corpus_encode` (pending + in-flight counts, draining/idle, and the
> live encoded-chunk count as detail). A bare estate with no Corpus returns an
> empty list. `DrainStatus` is `Sendable`/`Equatable` (Swift) /
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
    public let grant: Grant             // the authorizing grant (advisory scope)
    public let sourceHandle: EstateHandle; public let requesterHandle: EstateHandle
    public init(drawers: [Drawer], grant: Grant, sourceHandle: EstateHandle, requesterHandle: EstateHandle)
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
- **Ten standing signals (architecture § 11.2; inventory in
  GENIUSLOCUSKIT_SPEC.md):** `DreamingSignal`, `MaintenanceSignal`,
  `VectorSimilaritySignal`, `ContradictionScoutSignal`, `DecaySweepSignal`,
  `ByReferenceValiditySignal`, `EndOfDayTournamentSignal`,
  `TemporalCausalitySignal`, `DistillationSignal`, `TrainingSignal` — each
  `Brain/Signals/*.swift`; registered together by
  `registerDefaultStandingSignals` (Tier 1). Names: `dreaming-daemon`,
  `maintenance-daemon`, `vector-similarity`, `contradiction-scout`,
  `decay-sweep`, `by-reference-validity`, `end-of-day-tournament`,
  `temporal-causality-fold`, `distillation-sweep`, `training-daemon`.
  `VectorSimilaritySignal.spec(vectorStore:modelID:proximityThreshold:corpus:)` —
  production factory; captures `VectorStore` (and the estate's `Corpus`
  when registered), scans row embeddings via `findNearest` on each
  5-minute pass across two lanes — Drawer-keyed rows under `modelID`,
  and Corpus-derived rows already keyed by Drawer id (no chunk-owner map) —
  and emits `AssociateFrames` carrying Drawer ids for pairs
  within Hamming threshold (default 64).
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
GeniusLocusKit.defaultStandingSignalNames -> [String]                            // static
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
| `GLKRecallScoring` | `GLKRecallScoring` | `recall::GLKRecallScoring` | 3 variants |
| `RecallEvidencePath` | `RecallEvidencePath` | `recall::RecallEvidencePath` | 10 variants; `raw_value()` matches Swift |
| `RecallFallbackPolicy` | `RecallFallbackPolicy` | `recall::RecallFallbackPolicy` | 2 variants |
| `RecallScoreVector` | `RecallScoreVector` | `recall::RecallScoreVector` | All 10 fields present; `locus(_:)` → `locus(v: f32)` factory; `ZERO` constant |
| `RecallWeights` | `RecallWeights` | `recall::RecallWeights` | 7 fields; `uniform` → `UNIFORM` constant |
| `RecallPlan` | `RecallPlan` | `recall::RecallPlan` | `effectiveMode` → `effective_mode`; `frontierK` → `frontier_k` |
| `RecallHit` | `RecallHit` | `recall::RecallHit` | `drawer: Drawer?` → `drawer: Option<Drawer>`; `sources: Set<RecallEvidencePath>` → `sources: Vec<RecallEvidencePath>` |
| `GLKRecallRequest` | `GLKRecallRequest` | `recall::GLKRecallRequest` | Builder API; defaults match Swift. Optional `recallShape`/`recall_shape` field (defaults `nil`/`None`) carries the signed per-lane fusion steering (6b-modifiers) |
| `RecallShape` | `RecallShape` | `recall::RecallShape` | Signed per-lane fusion weights (`laneWeights`/`lane_weights`, keys `locus`/`bm25`/`hamming`/`dense:<modelID>` and the aggregate `dense`, PLUS the matrix/graph/preference columns `fieldFit`/`coOccurrence`/`temporal`/`graph`/`preference`; missing key ⇒ 1.0) + `antiSimilarLanes`/`anti_similar_lanes` (dense lane keys that invert objective to FARTHEST) + optional clamped `frontierK`/`frontier_k`. `w>0` forward, `w==0` exclude, `w<0` suppress (demote). Steers the Hybrid + CorpusOnly RRF lanes AND the UnionBest lane (per-signal `dense:<modelID>` weights steer the dense consensus fold; `locus`/`bm25`/`hamming`/`dense` AND the five matrix/graph/preference keys steer the UnionBest `.matrixAware` weighted columns — the matrix keys are a no-op under `.raw`/`.rrf`, where those columns are dark). A `dense:<modelID>` key in `antiSimilarLanes` queries CorpusKit `floatFarthestPerSignal` for that lane — the dissimilar candidates become its voters (DISTINCT from a negative weight; the two compose). nil/absent ⇒ uniform nearest fusion (byte-identical to pre-6b-modifiers) |
| `GLKRecallResult` | `GLKRecallResult` | `recall::GLKRecallResult` | `.drawers()` convenience accessor; `degradedStages`/`degraded_stages` carries named stage failures, incl. the four `locus.*` recall internal-read stages merged from `RecallStream` (SPEC § degradedStages) |
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
until VectorKit/CorpusKit are wired to the coordinator (a follow-up).

**`.rrf` scoring:** `score = 1 / (k + rank + 1)`, `k = 60`, tie-break by
`id` ascending. Matches Swift exactly.

**`.matrixAware` scoring (UnionBest mode):** Full Swift-parity weighted
pipeline. Consumes the registered `MatrixTier`
for the estate. Steps: query_coords from top locus candidate bitmap fields
(adjective, operational, provenance); fieldFit via `MatrixTier::correlation()`
per set bit; coOccurrence and temporal via `MatrixTier` lookups; all columns
min-max normalised (NaN→0, all-zero→0.0, uniform→0.5, varying→min-max);
`RecallUnionProfile::compute()` → adaptive weights via `RecallWeights::adaptive()`;
final score formula matches Swift step 9 (locus+bm25+vector+dense+fieldFit+
matrix*(coOccurrence+temporal)*0.5+graph+preference+0.05*popcount(sourceMask)/4).
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

### Ten standing signals

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Dreaming signal | `DreamingSignal` (`Brain/Signals/DreamingSignal.swift`) | `DreamingSignal` (`rust/src/brain/signals/dreaming.rs`) | public / pub | identical spec factory | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Maintenance signal | `MaintenanceSignal` (`Brain/Signals/MaintenanceSignal.swift`) | `MaintenanceSignal` (`rust/src/brain/signals/maintenance.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Vector-similarity signal | `VectorSimilaritySignal` (`Brain/Signals/VectorSimilaritySignal.swift`) | `VectorSimilaritySignal` (`rust/src/brain/signals/vector_similarity.rs`) | public / pub | 1.1 target: identical; Hamming threshold default 64; both GLK and Corpus-derived lanes are keyed directly by Drawer id, so no chunk-owner translation exists | shared-content and standing-signal parity suites | Accepted target |
| Contradiction-scout signal | `ContradictionScoutSignal` (`Brain/Signals/ContradictionScoutSignal.swift`) | `ContradictionScoutSignal` (`rust/src/brain/signals/contradiction_scout.rs`) | public / pub | identical; hourly cadence, closure-injected hunt cycle (single-write invariant: the hunt persists, the signal emits one diagnostic) | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Decay-sweep signal | `DecaySweepSignal` (`Brain/Signals/DecaySweepSignal.swift`) | `DecaySweepSignal` (`rust/src/brain/signals/decay_sweep.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| By-reference validity signal | `ByReferenceValiditySignal` (`Brain/Signals/ByReferenceValiditySignal.swift`) | `ByReferenceValiditySignal` (`rust/src/brain/signals/by_reference_validity.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| End-of-day tournament signal | `EndOfDayTournamentSignal` (`Brain/Signals/EndOfDayTournamentSignal.swift`) | `EndOfDayTournamentSignal` (`rust/src/brain/signals/end_of_day_tournament.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
| Temporal-causality signal | `TemporalCausalitySignal` (`Brain/Signals/TemporalCausalitySignal.swift`) | `TemporalCausalitySignal` (`rust/src/brain/signals/temporal_causality.rs`) | public / pub | identical spec factory; the T-matrix fold math itself lives in `MatrixTier::rebuild_temporal` (see matrix-rebuild concordance above) | `matrix_parity.rs` rebuild_temporal / `MatrixTierTests.swift`, `StandingSignalsTests.swift` | Confirmed |
| Distillation signal | `DistillationSignal` (`Brain/Signals/DistillationSignal.swift`) | `DistillationSignal` (`rust/src/brain/signals/distillation.rs`) | public / pub | identical | `standing_signals_parity.rs` / `StandingSignalsTests.swift` | Confirmed |
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
| Composite schema declaration | `GeniusLocusKitSchema.estateSchemaDeclaration: SchemaDeclaration` (`GeniusLocusKitSchema.swift`) | `composite_schema() -> SchemaDeclaration` (`hydration.rs`) | kitID / kit_id = "GeniusLocusKit". Version is derived from the live LocusKit, VectorKit, and CorpusKit **attached-profile** declarations in both ports. The current declaration excludes standalone Corpus document/passage/chunk tables. Historical v7 conversion lives only in the optional floor-selected migration capsule, not this declaration or the core runtime. Component and composite cannot drift; conformance-tested by `CompositeSchemaVersionTests` / `composite_version_tests`. |

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
| Recall fusion steering | `RecallShape` (`RecallDirector/RecallShape.swift`) | `RecallShape` (`rust/src/recall.rs`) | public struct / pub struct | signed `laneWeights`/`lane_weights` (retrieval keys `locus`/`bm25`/`hamming`/`dense`/`dense:<modelID>` + matrix/graph/preference keys `fieldFit`/`coOccurrence`/`temporal`/`graph`/`preference`, missing ⇒ 1.0) + `antiSimilarLanes`/`anti_similar_lanes` (FARTHEST dense lanes) + optional clamped `frontierK`/`frontier_k`; `weight(for:)`/`weight()`, `isAntiSimilar(_:)`/`is_anti_similar()`, and `effectiveFrontierK`/`effective_frontier_k` accessors; `[64,256]` frontier envelope | `RecallShapeSignedWeightTests.swift` + `RecallShapeAntiSimilarTests.swift` + `RecallShapeMatrixSteerTests.swift` / `recall_shape_signed_weight_parity` + `recall_shape_anti_similar_parity` + `recall_shape_matrix_steer_parity` | Confirmed |
| Serial-lane dispatcher | — | `CoordinatorDispatcher` (`rust/src/brain/scheduler/serial_lane.rs`) | — / pub struct | Rust-only internal dispatcher for the serial scheduling lane; no Swift parity (Brain scheduling is async actor lanes in Swift) | `scheduler_tests` | Confirmed (Rust-only) |
| Serial-lane noop dispatcher | — | `NoopDispatcher` (`rust/src/brain/scheduler/serial_lane.rs`) | — / test-only | Rust test stub gated `#[cfg(any(test, feature = "test-seams"))]` — compiled OUT of the production binary (not a shipped public symbol). Integration tests reach it via the `test-seams` feature. No Swift equivalent | scheduler/standing-signals/rag-wiring/coordinator-dispatcher parity tests | Confirmed (test-only) |
| Grant-store error | — | `GrantStoreError` (`rust/src/grants/grant_store.rs`) | — / pub enum | Rust-only error enum for the grants persistence layer; Swift errors bubble as `GeniusLocusKitError` (no distinct grant-store type) | grant tests | Confirmed (Rust-only) |
| Sync-engine entry | — | `SyncEngineEntry` (`rust/src/coordinator.rs`) | — / pub struct | Rust-only coordinator state record for the sync engine; no Swift parallel (sync lifecycle managed via actor state) | coordinator tests | Confirmed (Rust-only) |
| Distillation brain signal | `DistillationSignal` (`Brain/Signals/DistillationSignal.swift:30`, `public enum`) | `DistillationSignal` (`rust/src/brain/signals/distillation.rs:18`, `pub struct`) | public / pub | Swift uses a caseless `public enum` as a namespace; Rust uses a zero-size `pub struct` — same idiom for a type that is only a factory for `SignalSpec`. Both expose `spec(distillationCycle:)`/`spec(distillation_cycle)` (production wiring) and `defaultSpec()`/`default_spec()` (no-op diagnostic variant). Signal name `"distillation-sweep"`, hourly cadence (3 600 s). Wired in DG5. NT-DOC-1. | `DistillationSignalTests.swift` ↔ `distillation_signal_tests.rs` | Confirmed |
| Training brain signal | `TrainingSignal` (`Brain/Signals/TrainingSignal.swift:42`, `public enum`) | `TrainingSignal` (`rust/src/brain/signals/training.rs:24`, `pub struct`) | public / pub | Same Swift-enum/Rust-struct namespace idiom as `DistillationSignal`. Both expose `spec(trainingCycle:)`/`spec(training_cycle)` and `defaultSpec()`/`default_spec()`. Signal name `"training-daemon"`, hourly cadence (3 600 s). Wired per the brain-layer ownership contract F1. NT-DOC-1. | `StandingSignalsTests.swift` ↔ `distillation_signal_tests.rs` (covers both brain signals) | Confirmed |
| Contradiction hunt pass | `GeniusLocusKit.huntContradictions(in:modelID:probeLimit:filedAfter:proximityThreshold:now:)` (`Brain/ContradictionHunt.swift`) | `EstateCoordinator::hunt_contradictions(handle, model_id, probe_limit, filed_after, proximity_threshold, now)` (`rust/src/coordinator.rs`) | public / pub | identical pass: candidates from `recentItemIDs` newest-first probes mined on TWO lanes — Lane 1 drawer-keyed binary Hamming kNN under the caller's modelID (`getVector` → `findNearest` limit 5, proximity ≤ 64) for bespoke/test-planted vectors; Lane 2 (when a Corpus is registered — the ONLY lane production estates populate) LEXICAL via the corpus's persistent BM25 inverted index (`Corpus.bm25TopKBySource(query:limit:)`, `huntBM25CandidateK` = 20 per probe, query capped to `huntBM25QueryCharLimit` = 240 chars), which returns SOURCE drawer IDs directly. BM25 not vectors on the corpus lane: contradictions are lexically similar (the shared-term notion ConflictCue screens on), and the binary SimHash space is degenerate at estate scale (109k estate buried a true twin at rank #399) while a whole-partition float scan is ~3 s/probe. Both lanes dedupe on drawer-pair keys, then SubstrateML conflict-cue screen; strong cue (≥ 0.70) → `capture(TunnelCaptureFrame(kind: .contradicts, lifecycle: .proposed, originClass: .derived))`, borderline (≥ 0.45) → returned with ≤ 160-char snippets, never persisted; durable dedup vs ALL contradicts tunnels incl. withdrawn; `filedAfter` watermark; `vectorStoreAvailable` honesty flag | `ContradictionHuntTests.swift` (incl. corpus-lane test) ↔ `coordinator.rs` hunt tests | Confirmed |
| Contradiction hunt report | `ContradictionHuntReport` / `ProposedContradiction` / `BorderlineContradiction` (`Brain/ContradictionHunt.swift`) | `ContradictionHuntReport` / `ProposedContradiction` / `BorderlineContradiction` (`rust/src/coordinator.rs`) | public / pub | identical field sets (vectorStoreAvailable/probesScanned/pairsScreened/proposed/borderline/deduplicated; borderline adds sourceSnippet/targetSnippet) | `ContradictionHuntTests.swift` ↔ `coordinator.rs` hunt tests | Confirmed |
| Contradiction-scout brain signal | `ContradictionScoutSignal` (`Brain/Signals/ContradictionScoutSignal.swift`, `public enum`) | `ContradictionScoutSignal` (`rust/src/brain/signals/contradiction_scout.rs:19`, `pub struct`) | public / pub | Same namespace idiom as `DistillationSignal`. Both expose `spec(huntCycle:)`/`spec(hunt_cycle)` (production wiring; the hunt persists its own writes, the signal emits one summary diagnostic) and `defaultSpec()`/`default_spec()`. Signal name `"contradiction-scout"`, hourly cadence (3 600 s). Registered 4th in `registerDefaultStandingSignals`. | `StandingSignalsTests.swift` ↔ `standing_signals_parity.rs` | Confirmed |
| Dataset store accessor | `GeniusLocusKit.datasetStore(for:)` (`DatasetStoreAccess.swift`) | — | public func / (none) | Swift-only coordinator seam added by MX-TAB-7. Returns `any DatasetStore` for an open estate handle; throws `.estateNotOpen` or `StorageError.featureGated("datasetStore")`. No counterpart on `EstateCoordinator` — raw-table access in Rust goes directly to the estate's storage backend. | `DatasetStoreAccessTests.swift` | Swift-only |
| Dataset signature compute | `computeDatasetSignatures(handle:drawerId:columns:columnStats:sampledRows:now:)` (`Intake/DatasetSignatures.swift`) | `compute_dataset_signatures(estate, drawer_id, columns, column_stats, sampled_rows)` (`rust/src/dataset_signatures.rs`) | public func (GLK extension) / pub fn (free function) | Both ports: SHA-256 table signature (domain tag 0x10, sample size 128) + per-column signatures (domain tag 0x11). Rust is a free function taking `&Estate` directly (not on `EstateCoordinator`), matching the Rust sync model. Byte-identical preimage format; cross-leg anchor hashes locked in both test suites. Constants: `datasetSignatureSampleSize`/`DATASET_SIGNATURE_SAMPLE_SIZE` = 128; Rust additionally exports `DATASET_SIGNATURE_TOP_K` = 20. | `DatasetSignaturesTests.swift` ↔ `dataset_signatures_tests.rs` | Confirmed |

---

*End of GeniusLocusKit Interface.*

## Changelog

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
AUDIT-ALERT-RESTORE (Bob's option-1 ruling): `UnifiedAuditLog` gained a
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
the forward-compatible ext-slot contract `ext` forward-compat slot: the `grants` table gained a nullable `.json` `ext` column (the #11 custody-payload slot, inert in 1.0), both ports. Composite schema version 3 → 7 = LocusKit v2 + VectorKit v3 + CorpusKit (BundleStore) v2 — now DERIVED from the live component declarations in both ports (Swift sums the component `.version` fields; Rust sums `lk/vk/ck.version`), guarded by a new conformance test on each port. Corrected the composite-schema concordance row (previously read "version 3 / 1+1+1", already stale vs VectorKit v2). Also corrected the misleading GRT-01 custody comment: mode-3 (decay-derived) is no-vault BY DESIGN — the issuer retains nothing, so not persisting threshold/totalShares/driftRate is correct, not a defect.

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
default wires the five honest signals (RI/PPMI/LSA/NMF/FDC) at every production
provision site, so recall is the multi-signal default rather than a single
deterministic hash lane. The trainable signals train and persist on first
ingest/reindex. Callers wanting one signal pass an explicit single-element list.

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
(`6b-modifiers-antisim`) that also adds the VectorKit/CorpusKit store-direction API.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
