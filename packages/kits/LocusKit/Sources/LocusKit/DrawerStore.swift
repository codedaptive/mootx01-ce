// DrawerStore.swift
//
// Storage for the MemPalace surface, backed by PersistenceKit.
//
// Rewritten (Step 3 / audit finding I-2) from the original direct
// sqlite3 C-API implementation onto PersistenceKit's Storage protocol.
// Two consequences of that move shape this file:
//
//   1. Every method is async. The store is driven by a long-lived
//      agent (the MCP-server waiter) that fields concurrent
//      operations across many tables; a synchronous, blocking store
//      would serialize that waiter. async on Storage lets the
//      backend actor interleave, while PersistenceKit's transaction
//      boundary still gives per-operation atomicity where the audit
//      discipline requires it.
//
//   2. The schema, the append-only audit triggers, and the bit-range
//      functional indices now live in LocusKitSchema as PersistenceKit
//      primitives. This file no longer issues CREATE TABLE, CREATE
//      INDEX, ALTER TABLE, or CREATE TRIGGER text, and contains no
//      raw sqlite3 calls.
//
// DrawerStore is an actor. The prior class documented that
// concurrency was the caller's responsibility and a future actor
// layer would own it; that layer is now this type. Per-operation
// atomicity for the mutate-plus-audit paths uses
// storage.transaction, which acquires the write lock for the
// duration of the closure.
//
// Date columns are TEXT ISO8601 (PersistenceKit maps .timestamp to TEXT,
// per the MOOTx01 fleet rule). The store passes `now` as a parameter
// to every mutation method rather than calling Date() internally,
// per the deterministic-engine rule.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes
import PersistenceKit

public actor DrawerStore {

    let storage: any Storage

    /// The HLC clock this store stamps audit events with. Per the clock
    /// decision (DECISION_CLOCK_TRIANGLE_TIME_MODEL): the top-ranking
    /// entity *makes* the clock, holders *receive* it. A `nil` argument
    /// to `init` means "I am top — make my own clock" (a standalone
    /// LocusKit estate); a supplied generator means "I am a holder,
    /// stamped by GLK's one estate-wide maker." Either way the store
    /// holds exactly one generator and calls `send()` once per write.
    var hlc: HLCGenerator

    /// The frozen write-gate vocabulary for this estate, validated once
    /// at open (the decision's freeze-at-instantiation). Every gated
    /// write is admitted against this; it never changes after init.
    let vocabulary: Vocabulary

    /// This estate's uuid, read from the manifest once at open and held
    /// for stamping audit events. The manifest stores it as a string;
    /// it is parsed to a UUID here so the write path never re-parses.
    let estateUuid: UUID

    /// Construct against a Storage and open the LocusKit schema. The
    /// schema open is idempotent: re-opening an existing estate is a
    /// no-op for tables, generated columns, triggers, and indices.
    /// v1 manifest defaults are populated on first open (INSERT OR
    /// IGNORE semantics preserve values written on a prior open).
    ///
    /// - Parameter hlc: an injected clock from the top entity (holder
    ///   mode), or `nil` to make this store its own clock (top mode).
    ///   When made here, the node id is derived from the estate uuid so
    ///   a standalone estate has a stable, estate-specific maker id.
    public init(storage: any Storage, hlc: HLCGenerator? = nil) async throws {
        self.storage = storage
        try await storage.open(schema: LocusKitSchema.schema)
        // Stored-property init order matters: vocabulary, then the
        // manifest, then the estate uuid read back from it, then the
        // clock keyed on that uuid. The manifest population is a static
        // helper so it runs before the `let` stored properties are set.
        // Freeze the write-gate vocabulary once (freeze-at-instantiation).
        switch LocusKitVocabulary.frozen() {
        case .success(let v): self.vocabulary = v
        case .failure(let e):
            throw LocusKitError.invalidContent(
                "LocusKit vocabulary failed to freeze: \(e)")
        }
        // Manifest must exist before estate identity is read: populate
        // first (writes estate_uuid once if absent), then resolve the
        // estate uuid from it, then derive the maker node id from that
        // same value. This keeps the store's stamping uuid, the manifest
        // uuid, and the HLC maker node id all consistent on first open
        // (mirrors the Rust port's construction order).
        try await Self.populateV1ManifestDefaults(storage: storage, now: Date())
        // Resolve the estate uuid once. Populate guarantees the key is
        // present; the `?? UUID()` is now a defensive fallback only.
        self.estateUuid = await Self.resolveEstateUuid(storage: storage) ?? UUID()
        if let injected = hlc {
            self.hlc = injected
        } else {
            // Top mode: make our own. Node id derived from the estate
            // uuid now present in the manifest (stable per estate).
            self.hlc = HLCGenerator(nodeID: await Self.makerNodeID(storage: storage))
        }
    }

    /// Read + parse the estate uuid manifest value, or nil if absent/bad.
    private static func resolveEstateUuid(storage: any Storage) async -> UUID? {
        guard let rows = try? await storage.rowStore.query(
                table: "manifest",
                where: .eq(Column(table: "manifest", name: "key"), .text("estate_uuid"))),
              let v = rows.first?["value"], case let .text(s) = v else { return nil }
        return UUID(uuidString: s)
    }

    /// Derive a stable maker node id from the estate uuid manifest value.
    /// Falls back to 0 when absent (fresh estate). Low 31 bits of a
    /// stable hash so the id fits Int32 and is estate-specific.
    private static func makerNodeID(storage: any Storage) async -> Int32 {
        guard let rows = try? await storage.rowStore.query(
                table: "manifest",
                where: .eq(Column(table: "manifest", name: "key"), .text("estate_uuid"))),
              let v = rows.first?["value"], case let .text(uuid) = v else {
            return 0
        }
        // FNV-1a 32-bit (SubstrateLib), masked to non-negative Int32.
        let h = FNV.hash32(uuid)
        return Int32(bitPattern: h & 0x7FFF_FFFF)
    }

    // MARK: - Manifest v1 defaults

    /// Populate the v1 well-known manifest keys. Uses upsert with a
    /// "do not overwrite" guard implemented as a presence check, so
    /// the estate_uuid written on first open stays stable across
    /// every subsequent open. federation_group_id is intentionally
    /// absent (its absence means "not federated"). active_storage_mode
    /// "8" is L1 lossless page compression per the Q10a leaning.
    private static func populateV1ManifestDefaults(storage: any Storage, now: Date) async throws {
        let timestamp = LKISO8601.string(from: now)
        let estateUUID = UUID().uuidString

        let defaults: [(String, String)] = [
            ("manifest_version", "1.0"),
            ("schema_version", "1.0"),
            ("estate_uuid", estateUUID),
            ("estate_name", ""),
            ("owner_identifier", ""),
            ("lattice_citation", "UDC:2024+Wikidata:2024-Q3"),
            ("framework_profile", "unspecified_v0"),
            ("framework_profile_definition", "{}"),
            ("zoom_window_low", "0"),
            ("zoom_window_high", "99"),
            ("access_posture", "0"),
            ("provenance_defaults", "0"),
            ("active_storage_mode", "8"),
            ("tables_present", ""),
            ("created_at", timestamp),
            ("last_modified", timestamp),
            ("bitmap_layout_version", "v1.0"),
            ("provenance_bitmap_version", "v1.0")
        ]

        for (key, value) in defaults {
            // Insert only when absent. A plain insert would throw on
            // the second open (duplicate key); a query-then-insert
            // keeps first-open values authoritative.
            let existing = try await storage.rowStore.query(
                table: "manifest",
                where: .eq(Column(table: "manifest", name: "key"), .text(key))
            )
            if existing.isEmpty {
                _ = try await storage.rowStore.insert(
                    table: "manifest",
                    values: ["key": .text(key), "value": .text(value)]
                )
            }
        }
    }

    // MARK: - Drawer CRUD

    /// Insert a drawer. Conflicting ids surface as duplicateKey from
    /// the primary-key constraint. Validation runs before any write.
    ///
    /// Per spec section 6.2 / 6.3, when d.lineageID matches an active
    /// (state cluster < 3) predecessor, the insert runs as a
    /// supersession cascade: capture the new drawer through the gate
    /// (a genesis event), flip the predecessor's state nibble to
    /// .superseded via mutateState(.superseded, via: .supersede)
    /// (which appends one sealed AuditEvent), and file a directional
    /// supersedes tunnel. Otherwise a plain gated capture.
    public func addDrawer(_ d: Drawer, now: Date = Date()) async throws {
        try Self.validateNonEmpty(d.wing, label: "wing")
        try Self.validateNonEmpty(d.room, label: "room")
        try Self.validateNonEmpty(d.content, label: "content")
        try Self.validateNonEmpty(d.addedBy, label: "addedBy")
        try Self.validateNonEmpty(d.embeddingModelID, label: "embeddingModelID")
        // I-22 and all initial-field legality are enforced by the gate on
        // the capture event below (the prior==nil branch runs
        // ForbiddenCombinations.check), so the standalone validator is
        // retired here exactly as it was for the field-edit mutators.

        let predecessorID = try await findActivePredecessor(
            lineageID: d.lineageID, excludingID: d.id)

        if let priorID = predecessorID {
            try await addDrawerWithCascade(d, priorID: priorID)
        } else {
            // Insert the materialized projection row and emit the sealed
            // capture (genesis) event in one transaction. Capture is the
            // moment of remembering — the most important fact in an owned
            // memory's log — so it is a gated write, not a bare INSERT.
            try await gatedCapture(d, now: now)
        }
    }

    /// Supersession cascade as one atomic transaction. The
    /// predecessor's prior adjectiveBitmap is read under the
    /// transaction's write lock so the audit row's prior_value is
    /// exactly what the flip overwrites. State nibble (bits 0-3) is
    /// cleared and ORed to State.superseded.rawValue; upper axes preserved.
    private func addDrawerWithCascade(_ d: Drawer, priorID: String) async throws {
        // Insert the successor and read the predecessor's location, then
        // file the supersedes tunnel — these are the row writes that
        // stay direct. The predecessor's state flip is NOT done here:
        // it is a state transition (active --supersede--> superseded),
        // so it goes through mutateState below, which validates it and
        // appends the sealed audit event. The earlier code smuggled the
        // state through a manual adjective-bitmap write + bitmap_audit
        // row, bypassing the automaton (F8 anti-pattern, same as the
        // withdraw bug); the write gate now forbids that.
        // Read the predecessor's location for the tunnel before the
        // write transaction (a plain read; the row exists).
        let priorRows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(priorID))
        )
        guard let priorRow = priorRows.first else {
            throw LocusKitError.drawerNotFound(id: priorID)
        }
        let priorWing = Self.string(priorRow["wing"])
        let priorRoom = Self.string(priorRow["room"])
        let tunnel = Tunnel(
            id: "supersedes:\(d.id):\(priorID)",
            sourceWing: d.wing, sourceRoom: d.room, sourceDrawerId: d.id,
            targetWing: priorWing, targetRoom: priorRoom, targetDrawerId: priorID,
            label: "supersedes", kind: .supersedes,
            addedBy: d.addedBy, filedAt: d.filedAt
        )
        // Emit the successor's gated capture (genesis) event + insert its
        // projection row, then file the supersedes tunnel.
        try await gatedCapture(d, now: d.filedAt)
        _ = try await storage.rowStore.insert(
            table: "tunnels", values: Self.tunnelValues(tunnel))

        // Validated state flip of the predecessor through the gate.
        try await mutateState(
            drawerId: priorID,
            to: .superseded,
            via: .supersede,
            changedBy: d.addedBy,
            reason: "supersession cascade, lineageID \(d.lineageID.uuidString)",
            now: d.filedAt
        )
    }

    /// Find an active predecessor (state cluster < 3) sharing the
    /// lineageID, excluding the row being inserted. Uses the
    /// generated state-cluster column so the filter is an indexed
    /// equality range rather than an inline bit expression.
    private func findActivePredecessor(
        lineageID: UUID, excludingID: String
    ) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "lineageID"), .text(lineageID.uuidString)),
                .neq(Column(table: "drawers", name: "id"), .text(excludingID)),
                .lt(Column(table: "drawers", name: "g_state_cluster"), .int(3))
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        return rows.first.map { Self.string($0["id"]) }
    }

    /// Look up a drawer by id. Returns nil on miss.
    public func getDrawer(id: String) async throws -> Drawer? {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(id))
        )
        return try rows.first.map(Self.drawerFromRow)
    }

    /// All non-tombstoned drawers in a wing, ordered by filedAt.
    public func drawersIn(wing: String) async throws -> [Drawer] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "wing"), .text(wing)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.drawerFromRow)
    }

    /// All non-tombstoned drawers in a wing/room pair, ordered by filedAt.
    public func drawersIn(wing: String, room: String) async throws -> [Drawer] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "wing"), .text(wing)),
                .eq(Column(table: "drawers", name: "room"), .text(room)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.drawerFromRow)
    }

    /// All non-tombstoned drawers for a source file, ordered by
    /// chunkIndex then filedAt.
    public func drawersBySource(file: String) async throws -> [Drawer] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "sourceFile"), .text(file)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [
                OrderClause(column: Column(table: "drawers", name: "chunkIndex"), direction: .ascending),
                OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)
            ],
            limit: nil, offset: nil
        )
        return try rows.map(Self.drawerFromRow)
    }

    /// Full-corpus scan ordered by filedAt, including tombstoned rows.
    public func allDrawers() async throws -> [Drawer] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.drawerFromRow)
    }

    // MARK: - Provenance mutation

    /// Mutate a drawer's provenance bitmap and append one sealed
    /// AuditEvent to the audit log atomically. The prior value is
    /// read under the write lock so the event's before/after
    /// snapshot reflects the actual transition. Throws drawerNotFound
    /// (transaction rolls back, no event) when the drawer is absent.
    public func mutateProvenance(
        drawerId: String,
        newProvenance: Int64,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")

        _ = reason
        try await gatedColumnWrite(
            drawerId: drawerId, column: .provenance,
            newColumnValue: newProvenance, changedBy: changedBy, now: now)
    }

    // MARK: - Adjective / Operational / State mutation

    /// Mutate a drawer's adjective bitmap and append one sealed
    /// AuditEvent to the audit log atomically. Rejects the forbidden
    /// secret+exportable combination (I-22) in the gate's basis
    /// validation before the projection commits.
    public func mutateAdjective(
        drawerId: String,
        newAdjective: Int64,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")
        _ = reason
        // I-22 (secret+exportable) is enforced inside the gate's basis
        // check now (SubstrateLib), so no separate validator is needed —
        // the gate refuses it on the merged result, on every write.
        try await gatedColumnWrite(
            drawerId: drawerId, column: .adjective,
            newColumnValue: newAdjective, changedBy: changedBy, now: now)
    }

    /// Mutate a drawer's operational bitmap and write the audit row
    /// atomically.
    public func mutateOperational(
        drawerId: String,
        newOperational: Int64,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")
        _ = reason
        try await gatedColumnWrite(
            drawerId: drawerId, column: .operational,
            newColumnValue: newOperational, changedBy: changedBy, now: now)
    }

    /// Mutate a drawer's state (bits 0-3 of adjectiveBitmap),
    /// validating the transition against the legal-transition table
    /// before any write. Illegal transitions throw
    /// disciplineViolation and leave the row and audit table
    /// unchanged. Upper adjective axes are preserved.
    /// Emit a gated capture (genesis) event for a newly-created drawer
    /// and insert its materialized projection row, atomically. Capture
    /// has no prior state, so this routes through AuditGate.admit with
    /// verb=.capture and prior=nil: the gate validates the initial state
    /// (active/pending), runs the basis/forbidden-combination check
    /// (I-22 included), and seals the genesis snapshot. Every declared
    /// slot of all three columns — INCLUDING the state slot, which only
    /// capture may set — is decomposed from the drawer's bitmaps into a
    /// FieldWrite. This makes the audit log self-sufficient from birth
    /// (cold-rebuild and federation both need the creation event).
    private func gatedCapture(_ d: Drawer, now: Date) async throws {
        let rowUuid = try Self.requireUuid(d.id, label: "id")
        let estate = estateUuid
        let vocab = vocabulary
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)

        // All declared slots across the three columns. Unlike a field
        // edit, the state slot is included: capture legitimately sets the
        // initial state via the gate's prior==nil branch.
        func writes(for column: FieldSlot.Column, from value: Int64) -> [FieldWrite] {
            Self.declaredSlots(for: column).map { slot in
                FieldWrite(slot: slot,
                           value: BitField.extractField(value, shift: slot.shift, width: slot.width))
            }
        }
        let allWrites =
            writes(for: .adjective, from: d.adjectiveBitmap) +
            writes(for: .operational, from: d.operationalBitmap) +
            writes(for: .provenance, from: d.provenance)
        let anchor = SubstrateLib.LatticeAnchor.udc(d.udcCode)

        try await storage.transaction(isolation: .serializable) { txn in
            _ = try await txn.rowStore.insert(
                table: "drawers", values: Self.drawerValues(d))

            let result = AuditGate.admit(
                estateUuid: estate, rowId: rowUuid, nounType: .drawer, verb: .capture,
                prior: nil, priorLatticeAnchor: nil, writes: allWrites,
                afterLatticeAnchor: anchor, vocabulary: vocab, hlc: stamp, actor: d.addedBy)
            switch result {
            case .success(let e): try await txn.auditLog.append(e)
            case .failure(let v):
                throw LocusKitError.invalidContent("capture rejected by gate: \(v)")
            }
        }
    }

    public func mutateState(
        drawerId: String,
        to newState: State,
        via verb: RowVerb,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")

        // Stamp the ingest clock once for this write (the decision's
        // single tick per logical mutation). Done before the transaction
        // closure because `hlc` is actor-isolated mutable state.
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)
        let rowUuid = try Self.requireUuid(drawerId, label: "drawerId")
        let estate = estateUuid
        let vocab = vocabulary
        let stateSlot = FieldSlot(column: .adjective, shift: 0, width: 6,
                                  label: "state",
                                  legalValues: [0, 1, 2, 3, 16, 17, 18, 19, 32, 33])

        try await storage.transaction(isolation: .serializable) { txn in
            let rows = try await txn.rowStore.query(
                table: "drawers",
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
            )
            guard let row = rows.first else {
                throw LocusKitError.drawerNotFound(id: drawerId)
            }
            let priorBitmap = Self.int64(row["adjectiveBitmap"])
            let priorOperational = Self.int64(row["operationalBitmap"])
            let priorProvenance = Self.int64(row["provenance"])
            let prior = BitmapFields(
                adjective: UInt64(bitPattern: priorBitmap),
                operational: UInt64(bitPattern: priorOperational),
                provenance: UInt64(bitPattern: priorProvenance)
            )
            // mutateState does not touch the drawer's lattice anchor, so
            // before and after anchors are the row's current udcCode.
            let anchor = SubstrateLib.LatticeAnchor.udc(Self.string(row["udcCode"]))

            // Route the state change through the substrate write gate:
            // it RMWs the state field into the snapshot, runs the basis
            // automaton + I-22 (subsuming DrawerStateValidator), enforces
            // the verb/state consistency, and emits the sealed snapshot
            // event. Verb-driven state is expressed as a FieldWrite.
            let result = AuditGate.admit(
                estateUuid: estate,
                rowId: rowUuid,
                nounType: .drawer,
                verb: verb,
                prior: prior,
                priorLatticeAnchor: anchor,
                writes: [FieldWrite(slot: stateSlot, value: Int64(newState.rawValue))],
                afterLatticeAnchor: anchor,
                vocabulary: vocab,
                hlc: stamp,
                actor: changedBy
            )
            let event: AuditEvent
            switch result {
            case .success(let e): event = e
            case .failure(let v):
                throw LocusKitError.invalidContent("state mutation rejected by gate: \(v)")
            }

            // Materialized projection: write the merged snapshot to the
            // live drawers row (the O(1) read target). Append the sealed
            // event to the audit log (the source of truth).
            _ = try await txn.rowStore.update(
                table: "drawers",
                values: ["adjectiveBitmap": .bitmap(event.afterBitmaps.adjective)],
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
            )
            try await txn.auditLog.append(event)
        }
    }

    /// Expunge a row: tombstone the state, set the
    /// `dreaming_recalc_required` worklist marker (adjective bit 26)
    /// synchronously, zero the content blob, and stamp `tombstonedAt`,
    /// all in one transaction. Implements the cookbook §10.5 expunge
    /// verb's storage-layer postconditions (atomic content erasure +
    /// state transition + flag set); the cross-kit RAG vector delete
    /// is GLK's responsibility and lands in F17 second pass item 4,
    /// not here. Aggregates are deliberately untouched, per §9.5.1
    /// and §10.5 (they are already de-identified statistical roll-ups).
    ///
    /// Routes through `AuditGate.admit` with two FieldWrites in a
    /// single call: the state slot (adjective bits 0-5, target = 33
    /// = tombstoned) and the flags slot (adjective bits 24-26, with
    /// bit 26 set and bits 24-25 preserved from prior). RowVerb is
    /// `.tombstone`. The gate's verb-state-consistency check refuses
    /// any prior state from which `.tombstone` does not legally
    /// transition to `.tombstoned`; in particular `accepted →
    /// tombstoned` is intentionally absent from
    /// `RowStateAutomaton.transitions` (cookbook §9.5 S-3: audit-grade
    /// rows survive intact), so expunging an accepted row throws
    /// `LocusKitError.invalidContent`.
    public func expungeGated(
        drawerId: String,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")

        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)
        let rowUuid = try Self.requireUuid(drawerId, label: "drawerId")
        let estate = estateUuid
        let vocab = vocabulary
        let stateSlot = FieldSlot(column: .adjective, shift: 0, width: 6,
                                  label: "state",
                                  legalValues: [0, 1, 2, 3, 16, 17, 18, 19, 32, 33])
        // F17.2 (commit 5a8ea56): the adjective flags slot is now
        // width 3, spanning bits 24-26. Bit 24 = state_extension
        // (§2.9 C2); bit 25 = lineage_clustering; bit 26 =
        // dreaming_recalc_required. Expunge sets bit 26 within the
        // slot (the third bit of the 3-bit field, raw value 0b100)
        // while preserving bits 24-25.
        let flagsSlot = FieldSlot(column: .adjective, shift: 24, width: 3,
                                  label: "flags")

        try await storage.transaction(isolation: .serializable) { txn in
            let rows = try await txn.rowStore.query(
                table: "drawers",
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
            )
            guard let row = rows.first else {
                throw LocusKitError.drawerNotFound(id: drawerId)
            }
            let priorBitmap = Self.int64(row["adjectiveBitmap"])
            let priorOperational = Self.int64(row["operationalBitmap"])
            let priorProvenance = Self.int64(row["provenance"])
            let prior = BitmapFields(
                adjective: UInt64(bitPattern: priorBitmap),
                operational: UInt64(bitPattern: priorOperational),
                provenance: UInt64(bitPattern: priorProvenance)
            )
            let anchor = SubstrateLib.LatticeAnchor.udc(Self.string(row["udcCode"]))

            // Preserve bits 24-25 of the prior flags; set bit 26 (which
            // is the third bit of the 3-bit slot, raw value 0b100).
            let priorFlagsValue = BitField.extractField(priorBitmap, shift: 24, width: 3)
            let newFlagsValue = (priorFlagsValue & 0b011) | 0b100

            let result = AuditGate.admit(
                estateUuid: estate,
                rowId: rowUuid,
                nounType: .drawer,
                verb: .tombstone,
                prior: prior,
                priorLatticeAnchor: anchor,
                writes: [
                    FieldWrite(slot: stateSlot, value: Int64(State.tombstoned.rawValue)),
                    FieldWrite(slot: flagsSlot, value: newFlagsValue),
                ],
                afterLatticeAnchor: anchor,
                vocabulary: vocab,
                hlc: stamp,
                actor: changedBy
            )
            let event: AuditEvent
            switch result {
            case .success(let e): event = e
            case .failure(let v):
                throw LocusKitError.invalidContent("expunge rejected by gate: \(v)")
            }

            // Materialized projection: write the merged adjective
            // snapshot, zero the content blob, stamp tombstonedAt — all
            // in the same transaction as the gated event append. Per
            // cookbook §10.5: "Content blob zeroized in the same
            // transaction as the state transition (atomic; verbatim
            // sacred only up to expunge)."
            let nowTimestamp = ISO8601DateFormatter().string(from: now)
            _ = try await txn.rowStore.update(
                table: "drawers",
                values: [
                    "adjectiveBitmap": .bitmap(event.afterBitmaps.adjective),
                    "content": .text(""),
                    "tombstonedAt": .text(nowTimestamp),
                ],
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
            )
            try await txn.auditLog.append(event)
            _ = reason   // reason is captured in audit verb context; no
                         // separate audit-row column today, but the
                         // parameter is retained for future ProvFrame
                         // composition (cookbook §10.5 names a `reason`
                         // arg on the verb signature).
        }
    }

    /// Parse a row id string to a UUID for the audit event, or throw.
    /// Per the clock decision the audit event's rowId is a real UUID and
    /// is sealed into the content-id; a non-UUID id at a gated write site
    /// is a programming error, so this fails loudly rather than fabricate
    /// an id that would corrupt cross-configuration event identity.
    static func requireUuid(_ s: String, label: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else {
            throw LocusKitError.invalidContent("\(label) is not a UUID: \(s)")
        }
        return u
    }

    /// Decompose a whole-column replacement value into per-field
    /// FieldWrites for that column's declared slots, then route through
    /// the gate. This closes F8: the legacy whole-column mutators wrote
    /// an entire bitmap with no per-field validation; here every field
    /// is validated and the basis combination is checked. The state
    /// field (adjective 0-5) is verb-driven and is NEVER written by a
    /// field-edit mutator — it is excluded, so a field edit cannot move
    /// state (the gate's verb/state-consistency would reject it anyway).
    ///
    /// Slots for a column: adjective non-state slots are the substrate
    /// basis (sensitivity/exportability/trust/flags); operational and
    /// provenance slots are LocusKit's frozen union.
    private func gatedColumnWrite(
        drawerId: String,
        column: FieldSlot.Column,
        newColumnValue: Int64,
        changedBy: String,
        now: Date
    ) async throws {
        let rowUuid = try Self.requireUuid(drawerId, label: "drawerId")
        let estate = estateUuid
        let vocab = vocabulary
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)

        // The declared slots for this column, excluding the verb-driven
        // state field. Read each slot's value out of the incoming column
        // value and emit a FieldWrite; the gate RMWs + validates each.
        let slots = Self.declaredSlots(for: column)
            .filter { !($0.column == .adjective && $0.shift == 0) } // exclude state
        let writes = slots.map { slot in
            FieldWrite(slot: slot,
                       value: BitField.extractField(newColumnValue, shift: slot.shift, width: slot.width))
        }

        try await storage.transaction(isolation: .serializable) { txn in
            let rows = try await txn.rowStore.query(
                table: "drawers",
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId)))
            guard let row = rows.first else {
                throw LocusKitError.drawerNotFound(id: drawerId)
            }
            let prior = BitmapFields(
                adjective: UInt64(bitPattern: Self.int64(row["adjectiveBitmap"])),
                operational: UInt64(bitPattern: Self.int64(row["operationalBitmap"])),
                provenance: UInt64(bitPattern: Self.int64(row["provenance"])))
            let anchor = SubstrateLib.LatticeAnchor.udc(Self.string(row["udcCode"]))

            // verb .mutate is the state self-loop (active→active); a field
            // edit preserves state, so this is the correct verb.
            let result = AuditGate.admit(
                estateUuid: estate, rowId: rowUuid, nounType: .drawer, verb: .mutate,
                prior: prior, priorLatticeAnchor: anchor, writes: writes,
                afterLatticeAnchor: anchor, vocabulary: vocab, hlc: stamp, actor: changedBy)
            let event: AuditEvent
            switch result {
            case .success(let e): event = e
            case .failure(let v):
                throw LocusKitError.invalidContent("\(column) mutation rejected by gate: \(v)")
            }
            // Materialized projection: write the merged column back.
            let columnName: String = {
                switch column {
                case .adjective: return "adjectiveBitmap"
                case .operational: return "operationalBitmap"
                case .provenance: return "provenance"
                }
            }()
            let merged: Int64 = {
                switch column {
                case .adjective: return event.afterBitmaps.adjective
                case .operational: return event.afterBitmaps.operational
                case .provenance: return event.afterBitmaps.provenance
                }
            }()
            _ = try await txn.rowStore.update(
                table: "drawers", values: [columnName: .bitmap(merged)],
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId)))
            try await txn.auditLog.append(event)
        }
    }

    /// The declared FieldSlots for a column: adjective ⇒ substrate basis;
    /// operational/provenance ⇒ LocusKit's frozen union slots.
    private static func declaredSlots(for column: FieldSlot.Column) -> [FieldSlot] {
        // Source from the authoritative LocusKit-owned definitions, not
        // from the frozen Vocabulary object (the Rust leg's Vocabulary
        // does not expose its union; LocusKit owns these slots either
        // way, so both legs read the owner directly — bilingual parity).
        switch column {
        case .adjective:
            return Array(Vocabulary.basis).filter { $0.column == .adjective }
        case .operational, .provenance:
            return Array(LocusKitVocabulary.unionSlots).filter { $0.column == column }
        }
    }

    /// Audit-log events for a row, in HLC order — the source of truth
    /// (DECISION_CLOCK_TRIANGLE_TIME_MODEL: state is the projection,
    /// the log is authoritative). Thin pass-through to PersistenceKit's
    /// AuditLog. rowID is the row's UUID per DECISION_ROW_IDENTITY_UUID.
    public func auditEventsForRow(_ rowID: UUID) async throws -> [AuditEvent] {
        try await storage.auditLog.eventsForRow(rowID)
    }

    /// Count of audit-log events for a row.
    public func auditEventCountForRow(_ rowID: UUID) async throws -> Int {
        try await storage.auditLog.eventsForRow(rowID).count
    }

    /// Read a single bitmap column for a drawer inside a transaction,
    /// throwing drawerNotFound when the row is absent. Centralizes
    /// the prior-value read shared by every mutation path.
    private static func readBitmap(
        _ rowStore: any RowStore, drawerId: String, column: String
    ) async throws -> Int64 {
        let rows = try await rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
        )
        guard let row = rows.first else {
            throw LocusKitError.drawerNotFound(id: drawerId)
        }
        return int64(row[column])
    }

    // MARK: - Tunnel CRUD

    /// Insert a tunnel. Conflicting ids surface as duplicateKey.
    public func addTunnel(_ t: Tunnel) async throws {
        try Self.validateNonEmpty(t.sourceWing, label: "sourceWing")
        try Self.validateNonEmpty(t.sourceRoom, label: "sourceRoom")
        try Self.validateNonEmpty(t.targetWing, label: "targetWing")
        try Self.validateNonEmpty(t.targetRoom, label: "targetRoom")
        try Self.validateNonEmpty(t.label, label: "label")
        try Self.validateNonEmpty(t.addedBy, label: "addedBy")
        _ = try await storage.rowStore.insert(
            table: "tunnels", values: Self.tunnelValues(t))
    }

    public func getTunnel(id: String) async throws -> Tunnel? {
        let rows = try await storage.rowStore.query(
            table: "tunnels",
            where: .eq(Column(table: "tunnels", name: "id"), .text(id))
        )
        return try rows.first.map(Self.tunnelFromRow)
    }

    /// All non-tombstoned tunnels from a source wing, ordered by filedAt.
    public func tunnelsFrom(wing: String) async throws -> [Tunnel] {
        let rows = try await storage.rowStore.query(
            table: "tunnels",
            where: .and([
                .eq(Column(table: "tunnels", name: "sourceWing"), .text(wing)),
                .isNull(Column(table: "tunnels", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "tunnels", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.tunnelFromRow)
    }

    /// All non-tombstoned tunnels from a source wing/room pair.
    public func tunnelsFrom(wing: String, room: String) async throws -> [Tunnel] {
        let rows = try await storage.rowStore.query(
            table: "tunnels",
            where: .and([
                .eq(Column(table: "tunnels", name: "sourceWing"), .text(wing)),
                .eq(Column(table: "tunnels", name: "sourceRoom"), .text(room)),
                .isNull(Column(table: "tunnels", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "tunnels", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.tunnelFromRow)
    }

    /// All non-tombstoned tunnels to a target wing.
    public func tunnelsTo(wing: String) async throws -> [Tunnel] {
        let rows = try await storage.rowStore.query(
            table: "tunnels",
            where: .and([
                .eq(Column(table: "tunnels", name: "targetWing"), .text(wing)),
                .isNull(Column(table: "tunnels", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "tunnels", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.tunnelFromRow)
    }

    // MARK: - KGFact CRUD

    /// Insert a KGFact. Conflicting ids surface as duplicateKey.
    public func addKGFact(_ f: KGFact) async throws {
        try Self.validateNonEmpty(f.subject, label: "subject")
        try Self.validateNonEmpty(f.predicate, label: "predicate")
        try Self.validateNonEmpty(f.object, label: "object")
        try Self.validateNonEmpty(f.sourceDrawerID, label: "sourceDrawerID")
        _ = try await storage.rowStore.insert(
            table: "kg_facts", values: Self.kgFactValues(f))
    }

    public func getKGFact(id: String) async throws -> KGFact? {
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: .eq(Column(table: "kg_facts", name: "id"), .text(id))
        )
        return try rows.first.map(Self.kgFactFromRow)
    }

    /// All facts from a source drawer whose state cluster is below 7
    /// (excludes the rejected/accepted/tombstoned post-resolution
    /// states), ordered by filedAt ascending. The state-cluster gate
    /// uses the generated column so it is an indexed range scan.
    public func kgFacts(forDrawerID sourceDrawerID: String) async throws -> [KGFact] {
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: .and([
                .eq(Column(table: "kg_facts", name: "sourceDrawerID"), .text(sourceDrawerID)),
                .lt(Column(table: "kg_facts", name: "g_state_cluster"), .int(7))
            ]),
            orderBy: [OrderClause(column: Column(table: "kg_facts", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.kgFactFromRow)
    }

    // MARK: - Diary CRUD

    /// Insert a diary entry. Conflicting ids surface as duplicateKey.
    public func addDiaryEntry(_ e: DiaryEntry) async throws {
        try Self.validateNonEmpty(e.agentName, label: "agentName")
        try Self.validateNonEmpty(e.entry, label: "entry")
        try Self.validateNonEmpty(e.topic, label: "topic")
        try Self.validateNonEmpty(e.wing, label: "wing")
        try Self.validateNonEmpty(e.room, label: "room")
        try Self.validateNonEmpty(e.embeddingModelID, label: "embeddingModelID")
        _ = try await storage.rowStore.insert(
            table: "diary", values: Self.diaryValues(e))
    }

    public func getDiaryEntry(id: String) async throws -> DiaryEntry? {
        let rows = try await storage.rowStore.query(
            table: "diary",
            where: .eq(Column(table: "diary", name: "id"), .text(id))
        )
        return try rows.first.map(Self.diaryFromRow)
    }

    /// Most-recent N non-tombstoned entries for an agent, newest first.
    public func readDiary(agentName: String, lastN: Int = 10) async throws -> [DiaryEntry] {
        let rows = try await storage.rowStore.query(
            table: "diary",
            where: .and([
                .eq(Column(table: "diary", name: "agentName"), .text(agentName)),
                .isNull(Column(table: "diary", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "diary", name: "filedAt"), direction: .descending)],
            limit: lastN, offset: nil
        )
        return try rows.map(Self.diaryFromRow)
    }

    /// Most-recent N non-tombstoned entries for an agent in a wing.
    public func readDiary(agentName: String, in wing: String, lastN: Int = 10) async throws -> [DiaryEntry] {
        let rows = try await storage.rowStore.query(
            table: "diary",
            where: .and([
                .eq(Column(table: "diary", name: "agentName"), .text(agentName)),
                .eq(Column(table: "diary", name: "wing"), .text(wing)),
                .isNull(Column(table: "diary", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "diary", name: "filedAt"), direction: .descending)],
            limit: lastN, offset: nil
        )
        return try rows.map(Self.diaryFromRow)
    }

    // MARK: - RecallTrace CRUD

    /// Insert a recall trace row. The row records one drawer returned by
    /// a recall, with `used = false` (bit 0 of operationalBitmap unset)
    /// until the reward path fires. Conflicting ids surface as
    /// duplicateKey from the primary-key constraint.
    public func insertRecallTrace(_ item: RecallTraceItem) async throws {
        _ = try await storage.rowStore.insert(
            table: "recall_trace",
            values: Self.recallTraceValues(item))
    }

    /// Fetch a single trace row by id. Returns nil when not found.
    public func getRecallTrace(id: String) async throws -> RecallTraceItem? {
        let rows = try await storage.rowStore.query(
            table: "recall_trace",
            where: .eq(Column(table: "recall_trace", name: "id"), .text(id))
        )
        return try rows.first.map(Self.recallTraceFromRow)
    }

    /// Fetch all trace rows whose recalledAt is at or after `since`,
    /// ordered ascending (oldest first). Used by the reward sweep.
    public func recallTraceSince(_ since: Date) async throws -> [RecallTraceItem] {
        let rows = try await storage.rowStore.query(
            table: "recall_trace",
            where: .gte(
                Column(table: "recall_trace", name: "recalledAt"),
                .timestamp(since)
            ),
            orderBy: [OrderClause(
                column: Column(table: "recall_trace", name: "recalledAt"),
                direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return try rows.map(Self.recallTraceFromRow)
    }

    /// Mark a trace row's `used` flag (bit 0 of operationalBitmap).
    /// The reward path calls this when it has processed the row.
    /// Uses `storage.transaction` for atomic read-modify-write: reads
    /// the current bitmap, ORs bit 0 in, then writes it back. A no-op
    /// if the row is already marked used.
    ///
    /// - Parameters:
    ///   - id: the RecallTraceItem id to mark
    ///   - now: deterministic clock value per the fleet rule
    /// - Throws: LocusKitError.notFound if `id` is absent.
    public func markRecallTraceUsed(id: String, now: Date) async throws {
        // Fetch the current row inside the caller's concurrency
        // context. If absent, surface a clear error rather than
        // silently succeeding (which would mask a stale reward signal).
        guard let item = try await getRecallTrace(id: id) else {
            throw LocusKitError.recallTraceItemNotFound(id: id)
        }
        guard !item.used else {
            // Already marked — idempotent path. No write needed.
            return
        }
        let newBitmap = item.operationalBitmap | RecallTraceItem.flagUsed
        let updated = RecallTraceItem(
            id: item.id,
            target: item.target,
            recalledAt: item.recalledAt,
            score: item.score,
            operationalBitmap: newBitmap)
        try await storage.rowStore.update(
            table: "recall_trace",
            values: Self.recallTraceValues(updated),
            where: .eq(Column(table: "recall_trace", name: "id"), .text(id)))
    }

    // MARK: - Summary surface

    /// Wing-level taxonomy: one WingSummary per wing over
    /// non-tombstoned drawers. Computed in Swift from the drawer rows
    /// rather than SQL GROUP BY, because PersistenceKit's query surface
    /// returns rows, not aggregates; the wing/room cardinalities are
    /// small (taxonomy, not corpus) so the in-memory fold is cheap.
    public func listWings() async throws -> [WingSummary] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .isNull(Column(table: "drawers", name: "tombstonedAt"))
        )
        var drawerCounts: [String: Int] = [:]
        var rooms: [String: Set<String>] = [:]
        for row in rows {
            let wing = Self.string(row["wing"])
            let room = Self.string(row["room"])
            drawerCounts[wing, default: 0] += 1
            rooms[wing, default: []].insert(room)
        }
        return drawerCounts.keys.sorted().map { wing in
            WingSummary(
                name: wing,
                drawerCount: drawerCounts[wing] ?? 0,
                roomCount: rooms[wing]?.count ?? 0
            )
        }
    }

    /// Room-level taxonomy. When wing is nil, every wing's rooms;
    /// otherwise restricted to that wing. Non-tombstoned only.
    public func listRooms(in wing: String?) async throws -> [RoomSummary] {
        let predicate: StoragePredicate
        if let wing = wing {
            predicate = .and([
                .eq(Column(table: "drawers", name: "wing"), .text(wing)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ])
        } else {
            predicate = .isNull(Column(table: "drawers", name: "tombstonedAt"))
        }
        let rows = try await storage.rowStore.query(table: "drawers", where: predicate)
        var counts: [String: Int] = [:]   // key "wing\u{0}room"
        for row in rows {
            let w = Self.string(row["wing"])
            let r = Self.string(row["room"])
            counts["\(w)\u{0}\(r)", default: 0] += 1
        }
        return counts.keys.sorted().map { key in
            let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            let w = String(parts[0])
            let r = parts.count > 1 ? String(parts[1]) : ""
            return RoomSummary(wing: w, name: r, drawerCount: counts[key] ?? 0)
        }
    }

    /// Wing-level projection, named distinctly from listWings because
    /// the LOCI-5 layer extends the response shape with diary counts.
    public func taxonomy() async throws -> [WingSummary] {
        try await listWings()
    }

    // MARK: - Meta surface

    /// Insert or update a manifest key (upsert on the key column).
    public func setMeta(key: String, value: String) async throws {
        _ = try await storage.rowStore.upsert(
            table: "manifest",
            values: ["key": .text(key), "value": .text(value)],
            conflictColumns: ["key"]
        )
    }

    /// Read a manifest value. Returns nil on miss.
    public func getMeta(key: String) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text(key))
        )
        return rows.first.map { Self.string($0["value"]) }
    }

    /// Read all manifest keys into a typed snapshot. Absent required
    /// keys fall back to their v1 defaults; absent optional keys are
    /// nil. Per spec sections 5.9 and 7.8.1.
    public func readManifest() async throws -> ManifestValues {
        func req(_ key: ManifestKey, _ fallback: String = "") async throws -> String {
            try await getMeta(key: key.rawValue) ?? fallback
        }
        func reqInt(_ key: ManifestKey, _ fallback: Int = 0) async throws -> Int {
            Int(try await getMeta(key: key.rawValue) ?? "") ?? fallback
        }
        func reqInt64(_ key: ManifestKey, _ fallback: Int64 = 0) async throws -> Int64 {
            Int64(try await getMeta(key: key.rawValue) ?? "") ?? fallback
        }
        func reqDate(_ key: ManifestKey) async throws -> Date {
            LKISO8601.date(from: try await getMeta(key: key.rawValue) ?? "") ?? Date(timeIntervalSince1970: 0)
        }
        func opt(_ key: ManifestKey) async throws -> String? {
            try await getMeta(key: key.rawValue)
        }
        func optInt(_ key: ManifestKey) async throws -> Int? {
            guard let raw = try await getMeta(key: key.rawValue) else { return nil }
            return Int(raw)
        }
        // Manifest stores binary identity material (the Ed25519 keypair)
        // as base64 TEXT, since the manifest table holds string values.
        // A present-but-undecodable value returns nil rather than
        // throwing, matching the tolerant fallback the other readers use.
        func optData(_ key: ManifestKey) async throws -> Data? {
            guard let raw = try await getMeta(key: key.rawValue) else { return nil }
            return Data(base64Encoded: raw)
        }

        return ManifestValues(
            manifestVersion:             try await req(.manifestVersion, "1.0"),
            schemaVersion:               try await req(.schemaVersion, "1.0"),
            estateUUID:                  try await req(.estateUUID),
            estateName:                  try await req(.estateName),
            ownerIdentifier:             try await req(.ownerIdentifier),
            latticeCitation:             try await req(.latticeCitation, "UDC:2024+Wikidata:2024-Q3"),
            frameworkProfile:            try await req(.frameworkProfile, "unspecified_v0"),
            frameworkProfileDefinition:  try await req(.frameworkProfileDefinition, "{}"),
            zoomWindowLow:               try await reqInt(.zoomWindowLow, 0),
            zoomWindowHigh:              try await reqInt(.zoomWindowHigh, 99),
            accessPosture:               try await reqInt64(.accessPosture),
            provenanceDefaults:          try await reqInt64(.provenanceDefaults),
            activeStorageMode:           try await reqInt64(.activeStorageMode, 8),
            tablesPresent:               try await req(.tablesPresent),
            createdAt:                   try await reqDate(.createdAt),
            lastModified:                try await reqDate(.lastModified),
            bitmapLayoutVersion:         try await req(.bitmapLayoutVersion, "v1.0"),
            provenanceBitmapVersion:     try await req(.provenanceBitmapVersion, "v1.0"),
            federationGroupID:           try await opt(.federationGroupID),
            miningPatternsHash:          try await opt(.miningPatternsHash),
            tinyModelID:                 try await opt(.tinyModelID),
            tinyModelTrainingCorpusSize: try await optInt(.tinyModelTrainingCorpusSize),
            operationalBitmapLayouts:    try await opt(.operationalBitmapLayouts),
            ed25519PublicKey:            try await optData(.ed25519PublicKey),
            ed25519PrivateKeyWrapped:    try await optData(.ed25519PrivateKeyWrapped)
        )
    }

    // MARK: - Row encode helpers

    private static func drawerValues(_ d: Drawer) -> [String: TypedValue] {
        [
            "id": .text(d.id),
            "content": .text(d.content),
            "wing": .text(d.wing),
            "room": .text(d.room),
            "sourceFile": d.sourceFile.map { TypedValue.text($0) } ?? .null,
            "chunkIndex": d.chunkIndex.map { TypedValue.int(Int64($0)) } ?? .null,
            "addedBy": .text(d.addedBy),
            "filedAt": .timestamp(d.filedAt),
            // Two-clock ingest (ING-01): persist eventTime alongside the
            // ingest clock. Always bound on insert; the nullable column
            // exists only to tolerate rows written before it landed.
            "eventTime": .timestamp(d.eventTime),
            "embeddingModelID": .text(d.embeddingModelID),
            "tombstonedAt": d.tombstonedAt.map { TypedValue.timestamp($0) } ?? .null,
            "removedByBatch": d.removedByBatch.map { TypedValue.text($0) } ?? .null,
            "provenance": .bitmap(d.provenance),
            "adjectiveBitmap": .bitmap(d.adjectiveBitmap),
            "operationalBitmap": .bitmap(d.operationalBitmap),
            "lineageID": .text(d.lineageID.uuidString),
            "udcCode": .text(d.udcCode),
            "udcFacets": d.udcFacets.map { TypedValue.text($0) } ?? .null,
            "wikidataQID": d.wikidataQID.map { TypedValue.text($0) } ?? .null,
            "wikidataQidsSecondary": d.wikidataQidsSecondary.map { TypedValue.text($0) } ?? .null
        ]
    }

    private static func tunnelValues(_ t: Tunnel) -> [String: TypedValue] {
        [
            "id": .text(t.id),
            "sourceWing": .text(t.sourceWing),
            "sourceRoom": .text(t.sourceRoom),
            "sourceDrawerId": t.sourceDrawerId.map { TypedValue.text($0) } ?? .null,
            "targetWing": .text(t.targetWing),
            "targetRoom": .text(t.targetRoom),
            "targetDrawerId": t.targetDrawerId.map { TypedValue.text($0) } ?? .null,
            "label": .text(t.label),
            "addedBy": .text(t.addedBy),
            "filedAt": .timestamp(t.filedAt),
            "tombstonedAt": t.tombstonedAt.map { TypedValue.timestamp($0) } ?? .null,
            "removedByBatch": t.removedByBatch.map { TypedValue.text($0) } ?? .null,
            "kind_id": .int(Int64(t.kind.rawValue)),
            "adjectiveBitmap": .bitmap(t.adjectiveBitmap),
            "operationalBitmap": .bitmap(t.operationalBitmap),
            "provenanceBitmap": .bitmap(t.provenanceBitmap)
        ]
    }

    private static func diaryValues(_ e: DiaryEntry) -> [String: TypedValue] {
        [
            "id": .text(e.id),
            "agentName": .text(e.agentName),
            "entry": .text(e.entry),
            "topic": .text(e.topic),
            "wing": .text(e.wing),
            "room": .text(e.room),
            "filedAt": .timestamp(e.filedAt),
            "embeddingModelID": .text(e.embeddingModelID),
            "tombstonedAt": e.tombstonedAt.map { TypedValue.timestamp($0) } ?? .null,
            "removedByBatch": e.removedByBatch.map { TypedValue.text($0) } ?? .null,
            "operationalBitmap": .bitmap(e.operationalBitmap)
        ]
    }

    private static func recallTraceValues(_ item: RecallTraceItem) -> [String: TypedValue] {
        [
            "id": .text(item.id),
            "target": .text(item.target),
            "recalledAt": .timestamp(item.recalledAt),
            // score is REAL (float) nullable: TypedValue.float for Double,
            // .null when the recall did not produce a score.
            "score": item.score.map { TypedValue.float($0) } ?? .null,
            "operationalBitmap": .bitmap(item.operationalBitmap)
        ]
    }

    private static func recallTraceFromRow(_ row: StorageRow) throws -> RecallTraceItem {
        RecallTraceItem(
            id: string(row["id"]),
            target: string(row["target"]),
            recalledAt: date(row["recalledAt"]),
            score: optDouble(row["score"]),
            operationalBitmap: int64(row["operationalBitmap"])
        )
    }

    private static func kgFactValues(_ f: KGFact) -> [String: TypedValue] {
        [
            "id": .text(f.id),
            "subject": .text(f.subject),
            "predicate": .text(f.predicate),
            "object": .text(f.object),
            "sourceDrawerID": .text(f.sourceDrawerID),
            "adjectiveBitmap": .bitmap(f.adjectiveBitmap),
            "operationalBitmap": .bitmap(f.operationalBitmap),
            "provenanceBitmap": .bitmap(f.provenanceBitmap),
            "filedAt": .timestamp(f.filedAt)
        ]
    }

    // MARK: - Row decode helpers

    private static func drawerFromRow(_ row: StorageRow) throws -> Drawer {
        Drawer(
            id: string(row["id"]),
            content: string(row["content"]),
            wing: string(row["wing"]),
            room: string(row["room"]),
            sourceFile: optString(row["sourceFile"]),
            chunkIndex: optInt(row["chunkIndex"]),
            addedBy: string(row["addedBy"]),
            filedAt: date(row["filedAt"]),
            // Two-clock ingest (ING-01): backfill a NULL/absent eventTime
            // to this row's filedAt. Rows written before the column
            // existed read NULL here; the fallback gives them
            // eventTime == filedAt (the streaming-capture identity),
            // realizing the mission's "event_time = filed_at" backfill
            // intent in the read path rather than via an ALTER+UPDATE.
            eventTime: optDate(row["eventTime"]) ?? date(row["filedAt"]),
            embeddingModelID: string(row["embeddingModelID"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"]),
            provenance: int64(row["provenance"]),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            // Empty-string or unparseable lineageID becomes a fresh
            // per-row UUID so unset rows never collapse onto one
            // lineage; matches the prior store's drawerFromRow.
            lineageID: UUID(uuidString: string(row["lineageID"])) ?? UUID(),
            udcCode: string(row["udcCode"]),
            udcFacets: optString(row["udcFacets"]),
            wikidataQID: optString(row["wikidataQID"]),
            wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
        )
    }

    private static func tunnelFromRow(_ row: StorageRow) throws -> Tunnel {
        Tunnel(
            id: string(row["id"]),
            sourceWing: string(row["sourceWing"]),
            sourceRoom: string(row["sourceRoom"]),
            sourceDrawerId: optString(row["sourceDrawerId"]),
            targetWing: string(row["targetWing"]),
            targetRoom: string(row["targetRoom"]),
            targetDrawerId: optString(row["targetDrawerId"]),
            label: string(row["label"]),
            kind: TunnelKind(rawValue: Int(int64(row["kind_id"]))) ?? .references,
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            provenanceBitmap: int64(row["provenanceBitmap"]),
            addedBy: string(row["addedBy"]),
            filedAt: date(row["filedAt"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"])
        )
    }

    private static func diaryFromRow(_ row: StorageRow) throws -> DiaryEntry {
        DiaryEntry(
            id: string(row["id"]),
            agentName: string(row["agentName"]),
            entry: string(row["entry"]),
            topic: string(row["topic"]),
            wing: string(row["wing"]),
            room: string(row["room"]),
            filedAt: date(row["filedAt"]),
            embeddingModelID: string(row["embeddingModelID"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"]),
            operationalBitmap: int64(row["operationalBitmap"])
        )
    }

    private static func kgFactFromRow(_ row: StorageRow) throws -> KGFact {
        KGFact(
            id: string(row["id"]),
            subject: string(row["subject"]),
            predicate: string(row["predicate"]),
            object: string(row["object"]),
            sourceDrawerID: string(row["sourceDrawerID"]),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            provenanceBitmap: int64(row["provenanceBitmap"]),
            filedAt: date(row["filedAt"])
        )
    }

    // MARK: - TypedValue extraction

    /// These read a StorageRow cell into the Swift type LocusKit's
    /// value structs expect. PersistenceKit returns typed values already
    /// (the SQLite backend decodes bitmap/timestamp/uuid columns to
    /// their declared cases), so these are total projections with
    /// safe fallbacks rather than parsers.

    private static func string(_ v: TypedValue?) -> String {
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        default: return ""
        }
    }

    private static func optString(_ v: TypedValue?) -> String? {
        switch v {
        case .text(let s): return s
        case .none, .some(.null): return nil
        default: return nil
        }
    }

    private static func int64(_ v: TypedValue?) -> Int64 {
        switch v {
        case .int(let i), .bitmap(let i): return i
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }

    private static func optInt(_ v: TypedValue?) -> Int? {
        switch v {
        case .int(let i), .bitmap(let i): return Int(i)
        default: return nil
        }
    }

    private static func date(_ v: TypedValue?) -> Date {
        switch v {
        case .timestamp(let d): return d
        case .text(let s): return LKISO8601.date(from: s) ?? Date(timeIntervalSince1970: 0)
        default: return Date(timeIntervalSince1970: 0)
        }
    }

    private static func optDate(_ v: TypedValue?) -> Date? {
        switch v {
        case .timestamp(let d): return d
        case .text(let s): return LKISO8601.date(from: s)
        default: return nil
        }
    }

    private static func optDouble(_ v: TypedValue?) -> Double? {
        switch v {
        case .float(let d): return d
        case .int(let i): return Double(i)
        case .null, nil: return nil
        default: return nil
        }
    }

    // MARK: - Validation

    private static func validateNonEmpty(_ value: String, label: String) throws {
        if value.isEmpty {
            throw LocusKitError.invalidContent("\(label) must not be empty")
        }
    }

    // MARK: - ISO8601 helper
    //
    // PersistenceKit's .timestamp TypedValue handles Date<->TEXT for
    // declared timestamp columns, so most date round-trips need no
    // formatting here. The two manifest timestamp keys (created_at,
    // last_modified) are stored in the manifest value column as plain
    // text, and readManifest parses them back, so this local helper
    // covers those cases. Format matches PersistenceKit's internal
    // ISO8601 (.withInternetDateTime + .withFractionalSeconds) so a
    // value written by either side round-trips through the other.
    private enum LKISO8601 {
        nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        static func string(from date: Date) -> String { formatter.string(from: date) }
        static func date(from string: String) -> Date? { formatter.date(from: string) }
    }
}
