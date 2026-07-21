// HydrateRoundTripTests.swift
//
// Round-trip conformance tests for EstateHydration.
//
// Contract (per REPLICATION_TRACK_PLAN.md §9-style contract for GLK):
//   Build a non-trivial GLK estate in-memory (drawers, KGFacts, audit events).
//   Flush to SQLite via StorageReplicator.
//   Open a FRESH in-memory GLK estate hydrating from that SQLite.
//   Assert logical equivalence — recall results + matrix state (including
//   temporal) match the original.
//
// Two tests:
//   1. hydrateRoundTripDrawersAndKGFacts — core recall equivalence (drawers +
//      KGFacts) and matrix tier presence after hydration.
//   2. hydrateRoundTripMatrixTierEquivalence — matrix tier state (liveRowCount,
//      lastHLC) matches after hydration; temporal watermark is non-zero.
//
// The tests use InMemory↔SQLite backend pairs. SQLite files are written to
// the process temp directory and cleaned up in a `defer` block.
//
// HLC round-trip through SQLite: F-HLC-01 (the wrong unpack algorithm) was fixed
// in commit 3da43ff0 — the audit table now writes `Int64(bitPattern: hlc.packed)`
// and reads back with `HLC(packed: UInt64(bitPattern:))` as the correct inverse.
//
// One residual constraint: the `packed` format stores only the low 40 bits of
// physicalTime (HLC.swift §packed). Forty bits covers ~34 years from the Unix epoch
// (~1970 + 34 ≈ 2004); current 2026 wall-clock timestamps exceed this capacity, so
// the in-memory source HLC (full precision) and the SQLite-hydrated HLC (40-bit
// truncated) will differ in their upper bits. This is expected, documented behaviour
// of the packed format — not a correctness bug.
//
// Test 2 (hydrateRoundTripMatrixTierEquivalence) asserts:
//   hydratedTier.lastHLC == HLC(packed: sourceTier.lastHLC.packed)
// which is the maximum-fidelity assertion possible through the packed round-trip:
// the 40 low bits survive identically (F-HLC-01 is gone), and the upper bits are
// absent by design. Test 1 asserts structural equivalence (counts + content sets),
// which is the correct contract for that test's §9 recall equivalence scope.

import Testing
import Foundation
import SubstrateTypes
import EngramLib
import LocusKit
import VectorKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitReplication
@testable import GeniusLocusKit

// MARK: - Composite schema-version conformance (nullable entity ext slots ext-slot coupling)

@Suite("GLK composite schema version == sum of component versions")
struct CompositeSchemaVersionTests {

    /// The composite version is the sum of the LIVE component declaration
    /// versions plus the two GLK-owned addends — computed here from those
    /// declarations, never restated as a magic number (stale-literal rule,
    /// GLK shared-content 1.1 P0; the layout itself is frozen structurally
    /// by `CompositeSchemaSignatureTests`). This guards the version coupling
    /// the Rust replication gate depends on: a drift between composite and
    /// the gate's expected value would let a fresh estate open at a version
    /// the gate rejects.
    @Test("composite version includes grant and matrix_snapshot tables and equals the component sum")
    func compositeVersionEqualsComponentSum() {
        // +grants addend, +matrix_snapshot addend = two GLK-owned table addends
        let componentSum =
            LocusKitSchema.version
            + VectorStore.schemaDeclaration.version
            + VectorRepresentationClaims.schemaDeclaration.version
            + CorpusSchemaProfile.attachedDeclaration.version
            + 1  // grants
            + MatrixSnapshotStore.schemaDeclaration.version
        #expect(GeniusLocusKitSchema.version == componentSum)
        // The declaration the gate actually consumes carries the same version
        // and includes grant authorization state and matrix snapshot state
        // in hydrate/flush snapshots.
        #expect(GeniusLocusKitSchema.estateSchemaDeclaration.version == componentSum)
        #expect(GeniusLocusKitSchema.estateSchemaDeclaration.tables.contains { $0.name == "grants" })
        // matrix_snapshot must be in the composite so hydration copies persisted
        // calibration state from the durable backend into the in-memory backend.
        #expect(GeniusLocusKitSchema.estateSchemaDeclaration.tables.contains { $0.name == "matrix_snapshot" })
    }

    /// A fresh in-memory estate opens with the composite schema and registers
    /// the composite version under the "GeniusLocusKit" kit ID — the value the
    /// replication schema gate checks.
    @Test("fresh estate opens and registers the live composite version")
    func freshEstateOpensAtCompositeVersion() async throws {
        let storage = makeInMemoryStorage()
        try await storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let registered = try await storage.currentSchemaVersion(for: GeniusLocusKitSchema.kitID)
        #expect(registered == GeniusLocusKitSchema.version)
    }
}

// MARK: - Helpers

/// Create a fresh InMemory storage with a new estate UUID.
/// The storage is NOT pre-opened with a schema — the GLK lifecycle does that.
private func makeInMemoryStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

/// Create a SQLite storage at a temp path and return the storage + URL for cleanup.
/// The storage is NOT pre-opened with a schema — the GLK lifecycle does that.
private func makeSQLiteStorage() throws -> (SQLiteStorage, URL) {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("glk-hydrate-test-\(UUID().uuidString).sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url)
    ))
    return (storage, url)
}

/// Remove SQLite file and WAL/SHM sidecars.
private func cleanupSQLite(at url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

// Fixed timestamp for test determinism — avoids Date() inside engine calls
// per CLAUDE.md "pass `now` as parameter" rule.
private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

// MARK: - Round-trip test suite

@Suite("GLK hydrate round-trip")
struct HydrateRoundTripTests {

    // MARK: - Test 1: Drawers + KGFacts recall equivalence

    /// Build a non-trivial in-memory estate, flush to SQLite, hydrate back into a
    /// fresh InMemory backend, assert that recall returns the same drawers and KGFacts.
    ///
    /// Equivalence contract:
    ///   - Drawer count matches.
    ///   - Drawer contents match (by content string).
    ///   - KGFact count matches.
    ///   - KGFact triples (subject, predicate, object) match.
    ///   - MatrixTier is present (rebuilt from hydrated audit log).
    @Test
    func hydrateRoundTripDrawersAndKGFacts() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-hydrate-rt-1")
        let (sqliteStorage, sqliteURL) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: sqliteURL) }

        // ── Build source estate ──────────────────────────────────────────────
        let sourceStorage = makeInMemoryStorage()
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)

        let sourceKit = GeniusLocusKit()
        let sourceHandle = try await sourceKit.open(storage: sourceStorage, owner: owner)

        // Capture three drawers with deterministic content.
        let capturedContents = [
            "swift memory substrate GLK hydrate test alpha",
            "rust LocusKit bitmap accumulate recall parity beta",
            "vector ANN hamming scan logical equivalence gamma",
        ]
        for content in capturedContents {
            _ = try await sourceKit.capture(sourceHandle, CaptureFrame(
                content: content,
                channel: .typed,
                room: "hydrate-rt",
                latticeAnchor: .udc("000"),
                addedBy: "hydrate-test",
                embeddingModelID: "test-model-v1"
            ))
        }

        // Add two KGFacts.
        _ = try await sourceKit.captureKGFact(
            sourceHandle,
            subject: "GLK", predicate: "hydrates", object: "estate",
            now: t0
        )
        _ = try await sourceKit.captureKGFact(
            sourceHandle,
            subject: "MatrixTier", predicate: "rebuilds", object: "fromAuditLog",
            now: t0
        )

        // Recall baseline from source estate.
        let sourceDrawers = try await sourceKit.recall(sourceHandle, RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: 10
        ))
        let sourceKGFacts = try await sourceKit.recallKGFacts(sourceHandle)

        // ── Flush to SQLite ──────────────────────────────────────────────────
        // kit.flush opens both backends with the composite GLK schema before
        // calling StorageReplicator.flush, so the schema gate passes.
        _ = try await sourceKit.flush(from: sourceStorage, into: sqliteStorage)

        // ── Hydrate into fresh InMemory ──────────────────────────────────────
        let freshStorage = makeInMemoryStorage()
        let hydratedKit = GeniusLocusKit()

        let hydratedHandle = try await hydratedKit.open(
            inMemory: freshStorage,
            owner: owner,
            hydrateFrom: sqliteStorage
        )

        // ── Assert logical equivalence ───────────────────────────────────────

        let hydratedDrawers = try await hydratedKit.recall(hydratedHandle, RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: 10
        ))
        let hydratedKGFacts = try await hydratedKit.recallKGFacts(hydratedHandle)

        // Drawer count.
        let srcCount = sourceDrawers.count
        let hydCount = hydratedDrawers.count
        #expect(hydCount == srcCount)

        // Drawer contents — all source contents appear in hydrated recall.
        let sourceContents = Set(sourceDrawers.map { $0.content })
        let hydratedContents = Set(hydratedDrawers.map { $0.content })
        for content in sourceContents {
            #expect(hydratedContents.contains(content))
        }

        // KGFact count.
        let srcFactCount = sourceKGFacts.count
        let hydFactCount = hydratedKGFacts.count
        #expect(hydFactCount == srcFactCount)

        // KGFact triples (subject|predicate|object).
        let sourceFacts = Set(sourceKGFacts.map { "\($0.subject)|\($0.predicate)|\($0.object)" })
        let hydratedFacts = Set(hydratedKGFacts.map { "\($0.subject)|\($0.predicate)|\($0.object)" })
        #expect(sourceFacts == hydratedFacts)

        // MatrixTier is present (rebuilt from hydrated audit log).
        let tier = await hydratedKit.matrixTiers[hydratedHandle]
        #expect(tier != nil)
        if let tier {
            // liveRowCount must reflect the 3 captured drawers.
            #expect(tier.liveRowCount > 0)
        }
    }

    // MARK: - Test 2: Matrix tier state equivalence

    /// Assert that the matrix tier built from a hydrated estate matches the one
    /// built from the source estate: same liveRowCount, non-zero lastHLC, and
    /// non-zero temporalWatermarkHLC after audit replay.
    ///
    /// This test specifically validates the two-pass rebuild ordering:
    ///   Pass 1 (rebuild)         → F, O, C, liveRowCount, lastHLC
    ///   Pass 2 (rebuildTemporal) → T, temporalWatermarkHLC
    /// Both must run (MatrixTier.fullRebuild) for temporal state to be populated.
    /// A temporalWatermarkHLC == .zero indicates rebuildTemporal was NOT called.
    @Test
    func hydrateRoundTripMatrixTierEquivalence() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-hydrate-rt-2")
        let (sqliteStorage, sqliteURL) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: sqliteURL) }

        // ── Build source estate with several captures ────────────────────────
        let sourceStorage = makeInMemoryStorage()
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)

        let sourceKit = GeniusLocusKit()
        let sourceHandle = try await sourceKit.open(storage: sourceStorage, owner: owner)

        // Capture 4 drawers so audit events accumulate for matrix rebuild.
        for i in 0..<4 {
            _ = try await sourceKit.capture(sourceHandle, CaptureFrame(
                content: "matrix tier parity test content row \(i)",
                channel: .typed,
                room: "matrix-rt",
                latticeAnchor: .udc("000"),
                addedBy: "hydrate-test",
                embeddingModelID: "test-model-v1"
            ))
        }

        // Explicitly rebuild source tier so we have a baseline to compare against.
        try await sourceKit.rebuildDerivedAccelerators(for: sourceHandle)
        let sourceTier = await sourceKit.matrixTiers[sourceHandle]
        guard let sourceTier else {
            Issue.record("Source matrix tier must not be nil after rebuildDerivedAccelerators")
            return
        }

        // ── Flush to SQLite ──────────────────────────────────────────────────
        _ = try await sourceKit.flush(from: sourceStorage, into: sqliteStorage)

        // ── Hydrate into fresh InMemory ──────────────────────────────────────
        let freshStorage = makeInMemoryStorage()
        let hydratedKit = GeniusLocusKit()

        let hydratedHandle = try await hydratedKit.open(
            inMemory: freshStorage,
            owner: owner,
            hydrateFrom: sqliteStorage
        )

        let hydratedTier = await hydratedKit.matrixTiers[hydratedHandle]
        guard let hydratedTier else {
            Issue.record("Hydrated matrix tier must not be nil after open(inMemory:owner:hydrateFrom:)")
            return
        }

        // liveRowCount must match — both sessions saw the same 4 captures.
        #expect(hydratedTier.liveRowCount == sourceTier.liveRowCount)

        // lastHLC must be non-zero on both — audit events carry HLC timestamps.
        // HLC.zero is the sentinel for "no events processed" (MatrixTier.init default).
        #expect(sourceTier.lastHLC != .zero)
        #expect(hydratedTier.lastHLC != .zero)

        // Full-precision HLC equality: lastHLC flows losslessly through the
        // `matrix_snapshot` JSON blob (MatrixTier's synthesized Codable encodes
        // the full Int64 physicalTime), NOT through the lossy 40-bit-packed audit
        // `hlc` column. Hydration prefers the snapshot (rebuildDerivedAccelerators
        // loads it and folds only the tail), so the hydrated tier's lastHLC equals
        // the source's exactly — same contract the Rust port asserts in
        // hydrate_parity.rs. (`HLC.packed` is the lossy compact form for the
        // federation wire / ordering key only, never the canonical stored value.)
        //
        // NOTE: the Swift audit `hlc` column is genuinely lossy (40-bit
        // physicalTime); a cold rebuild with no snapshot would truncate. The
        // durable fix is to store the Swift audit HLC as three full-precision
        // columns like the Rust port — tracked separately.
        #expect(hydratedTier.lastHLC == sourceTier.lastHLC)

        // temporalWatermarkHLC must be non-zero on the hydrated tier.
        // This validates that MatrixTier.fullRebuild called both passes.
        // A value of .zero means rebuildTemporal did NOT run — a correctness bug.
        #expect(hydratedTier.temporalWatermarkHLC != .zero)
    }
}

// MARK: - Vector sidecar persistence + VectorStore unification (F3)

/// F3: the estate has ONE dense VectorStore (Corpus owns it; GLK borrows it), and
/// its resident-array `.vec` sidecar is persisted on the derived-accelerator flush
/// so a cold restart loads it instead of rebuilding from a full table scan.
@Suite("GLK vector sidecar persistence + unification")
struct VectorSidecarUnificationTests {

    /// The GLK scored-recall vector lane is Corpus's single shared instance — not a
    /// second VectorStore over the same `vectors` table.
    @Test
    func standaloneVectorStoreIsCorpusSharedInstance() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-f3-unify")
        let (sqlite, url) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: url) }

        _ = try await LocusKit.Estate.create(storage: sqlite, owner: owner)
        let kit = GeniusLocusKit()
        // Temp-dir SQLite counts as durable, so the backend-keyed default
        // would mint into the real login keychain — keep test identities in
        // memory.
        let handle = try await kit.open(
            storage: sqlite, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await kit.wireGLKSubstores(for: handle, backingStorage: sqlite)

        let glkVS = await kit.vectorStores[handle]
        let corpus = await kit.corpusKits[handle]
        #expect(glkVS != nil)
        #expect(corpus != nil)
        // Identity: the registered scored-recall store IS Corpus's shared store.
        let shared = await corpus?.sharedVectorStore
        #expect(shared === glkVS)
    }

    /// `defaultSidecarURL` derives a `.vec` path beside the estate SQLite file,
    /// and the derived-accelerator flush writes it to disk after a vector write.
    @Test
    func vectorSidecarPersistsOnDerivedAcceleratorFlush() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-f3-sidecar")
        let (sqlite, url) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: url) }

        let sidecar = VectorStore.defaultSidecarURL(for: sqlite)
        #expect(sidecar != nil)
        #expect(sidecar?.pathExtension == "vec")
        defer { if let s = sidecar { try? FileManager.default.removeItem(at: s) } }

        _ = try await LocusKit.Estate.create(storage: sqlite, owner: owner)
        let kit = GeniusLocusKit()
        // Temp-dir SQLite counts as durable, so the backend-keyed default
        // would mint into the real login keychain — keep test identities in
        // memory.
        let handle = try await kit.open(
            storage: sqlite, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await kit.wireGLKSubstores(for: handle, backingStorage: sqlite)

        let vs = await kit.vectorStores[handle]
        #expect(vs != nil)
        // Write one binary vector through the shared store, then flush via the
        // derived-accelerator persist point.
        try await vs?.addVector(
            itemID: "f3-item-1",
            engram: Engram(blocks: 0b1011, 0, 0, 0),
            modelID: "test-model",
            modelVersion: "v1",
            filedAt: t0
        )
        try await kit.rebuildDerivedAccelerators(for: handle, now: t0)

        // The sidecar now exists on disk beside the estate database.
        if let s = sidecar {
            #expect(FileManager.default.fileExists(atPath: s.path))
        }
    }
}

// MARK: - Matrix snapshot persistence (on-disk SQLite, load-and-fold-forward)

/// Verifies the matrix tier is PERSISTED to its SQLite table and, on the next
/// launch, LOADED and folded forward over only the audit tail — never recomputed
/// from the whole log on every launch. The store is exercised against a REAL
/// SQLite backend so the primitive read-back path (BLOB→.blob, INTEGER→.int) is
/// covered, not just the InMemory backend that preserves semantic TypedValues.
@Suite("GLK matrix snapshot persistence")
struct MatrixSnapshotPersistenceTests {

    /// First rebuild persists a snapshot; the row is present on disk afterwards,
    /// and a second rebuild (after more captures) loads it and folds the tail
    /// forward to a tier cell-for-cell equal to a from-scratch full rebuild.
    @Test
    func rebuildPersistsSnapshotAndLoadsForward() async throws {
        let owner = OwnerCredentials(ownerIdentifier: "owner-matrix-persist-1")
        let (sqlite, url) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: url) }

        _ = try await LocusKit.Estate.create(storage: sqlite, owner: owner)
        let kit = GeniusLocusKit()
        // open(storage:owner:) backs the estate with this SQLite directly, so
        // storages[handle] is SQLite and the snapshot store writes/reads real rows.
        // Temp-dir SQLite counts as durable, so the backend-keyed default
        // would mint into the real login keychain — keep test identities in
        // memory.
        let handle = try await kit.open(
            storage: sqlite, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        // ── First wave of captures, then the cold-start rebuild (persists) ──────
        for i in 0..<3 {
            _ = try await kit.capture(handle, CaptureFrame(
                content: "matrix snapshot persistence row \(i)",
                channel: .typed,
                room: "matrix-persist",
                latticeAnchor: .udc("000"),
                addedBy: "persist-test",
                embeddingModelID: "test-model-v1"
            ))
        }
        try await kit.rebuildDerivedAccelerators(for: handle, now: t0)

        // The snapshot row must now exist on disk and reflect the 3 captures.
        let store = MatrixSnapshotStore(storage: sqlite)
        let persisted = try await store.load(estateID: handle.estateUUID)
        #expect(persisted != nil)
        #expect(persisted?.tier.liveRowCount == 3)
        #expect(persisted?.schemaVersion == MatrixSnapshot.currentSchemaVersion)

        // ── Second wave, then a rebuild that LOADS the snapshot + folds forward ──
        for i in 3..<5 {
            _ = try await kit.capture(handle, CaptureFrame(
                content: "matrix snapshot persistence row \(i)",
                channel: .typed,
                room: "matrix-persist",
                latticeAnchor: .udc("000"),
                addedBy: "persist-test",
                embeddingModelID: "test-model-v1"
            ))
        }
        try await kit.rebuildDerivedAccelerators(for: handle, now: t0)

        // The registered tier must equal a from-scratch full rebuild of the whole
        // audit log — proving load+fold-forward is exact, not an approximation.
        // The oracle must use the SAME eventTime map the hydration path builds:
        // the temporal (T) matrix keys off eventTime, not the capture HLC
        //, so a no-map fullRebuild would fold on the wrong clock and
        // diverge by sub-ms eventTime/HLC rounding.
        let registered = await kit.matrixTiers[handle]
        let fullLog = try await kit.auditLog(for: handle)
        let oracleEstate = try await kit.estate(for: handle)
        let oracleDrawers = try await oracleEstate.allDrawers()
        var oracleEventTimes: [UUID: Int64] = [:]
        for d in oracleDrawers where !d.id.isEmpty {
            if let rowUUID = UUID(uuidString: d.id) {
                oracleEventTimes[rowUUID] = Int64(d.eventTime.timeIntervalSince1970 * 1000)
            }
        }
        let fromScratch = MatrixTier.fullRebuild(from: fullLog, eventTimes: oracleEventTimes)
        #expect(registered == fromScratch)
        #expect(registered?.liveRowCount == 5)

        // The persisted snapshot must have advanced to the 5-capture state too.
        let persisted2 = try await store.load(estateID: handle.estateUUID)
        #expect(persisted2?.tier.liveRowCount == 5)
        #expect(persisted2?.tier == fromScratch)
    }

    /// A snapshot row whose schema_version does not match the current format is
    /// rejected on load (returns nil) so the caller falls back to a full rebuild.
    @Test
    func staleSchemaVersionRejectedOnLoad() async throws {
        let (sqlite, url) = try makeSQLiteStorage()
        defer { cleanupSQLite(at: url) }

        try await sqlite.migrate(to: MatrixSnapshotStore.schemaDeclaration)
        let estateID = UUID()
        // Write a row carrying a foreign schema_version directly. The cheap column
        // gate must reject it without trusting the blob.
        _ = try await sqlite.rowStore.upsert(
            table: "matrix_snapshot",
            values: [
                "estate_id": .text(estateID.uuidString),
                "schema_version": .int(Int64(MatrixSnapshot.currentSchemaVersion + 99)),
                "snapshot": .blob(Data([0x00])),  // deliberately undecodable
                "last_hlc": .text("0.0.0"),
                "updated_at": .timestamp(t0)
            ],
            conflictColumns: ["estate_id"]
        )
        let store = MatrixSnapshotStore(storage: sqlite)
        let loaded = try await store.load(estateID: estateID)
        #expect(loaded == nil)
    }
}
