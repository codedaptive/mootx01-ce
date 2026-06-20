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
import OSLog
import IntellectusLib
import SubstrateKernel
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
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

private let drawerStoreLog = Logger(subsystem: "com.mootx01.kit", category: "LocusKit")

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
        // Resolve the estate identity once, distinguishing two cases that
        // must NOT be conflated (P1-7):
        //   • ABSENT manifest value (fresh estate, key never written) →
        //     the legitimate fresh-estate path. populate guarantees the
        //     key is present on a normal open, so `.absent` here means a
        //     genuinely empty/unseeded manifest, not corruption.
        //   • PRESENT-but-malformed UUID (non-parseable text — wrong
        //     length, bad characters, truncation) → data corruption. We
        //     throw `corruptStoredValue` rather than fabricating a random
        //     UUID / node 0, which would silently mask the corruption.
        // A single read+classify keeps the estate uuid and the HLC maker
        // node id derived from the SAME manifest value, so they can never
        // disagree (mirrors the Rust port's `classify_estate_uuid`).
        let identity = try await Self.classifyEstateUuid(storage: storage)
        switch identity {
        case .present(let uuid, _):
            self.estateUuid = uuid
        case .absent:
            // Fresh estate: no persisted identity to honour. Mint one for
            // this store's stamping. A corrupt value never reaches here.
            self.estateUuid = UUID()
        }
        if let injected = hlc {
            self.hlc = injected
        } else {
            // Top mode: make our own. Node id is derived from the SAME
            // classified value: a valid persisted uuid yields a stable
            // per-estate maker; an absent value yields node 0 (fresh).
            // A corrupt value already threw above, so it never reaches here.
            self.hlc = HLCGenerator(nodeID: Self.makerNodeID(for: identity))
        }
    }

    /// The classification of the manifest's `estate_uuid` value at open.
    /// `.present` carries a successfully-parsed UUID; `.absent` means the
    /// key was never written (fresh estate). A present-but-malformed value
    /// is NOT a case here — it surfaces as a thrown `corruptStoredValue`
    /// from `classifyEstateUuid`, because conflating corruption with a
    /// fresh estate would mask data loss (P1-7).
    /// `.present` carries both the parsed UUID (for stamping) and the
    /// raw stored text (for hashing the maker node id). The maker id is
    /// hashed from the raw stored text — identical bytes to what Rust
    /// hashes — so the two ports derive byte-identical node ids.
    private enum EstateUuidState {
        case present(uuid: UUID, rawText: String)
        case absent
    }

    /// Read the manifest `estate_uuid` value and classify it as a fresh
    /// estate (`.absent`), a valid persisted identity (`.present`), or
    /// data corruption (throws). The three outcomes are mutually
    /// exclusive and exhaustive:
    ///   • row missing / value missing / non-text → `.absent` (fresh).
    ///   • value present and parses as a UUID → `.present(uuid)`.
    ///   • value present but does NOT parse → throws
    ///     `corruptStoredValue(table: "manifest", column: "estate_uuid",
    ///     storedText:)`, fail-loud, never a fabricated default.
    /// Parity: Rust `DrawerStoreCore::classify_estate_uuid`.
    private static func classifyEstateUuid(
        storage: any Storage
    ) async throws -> EstateUuidState {
        let rows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text("estate_uuid")))
        // Absent: no row, no value, or a non-text value. A fresh, never-
        // written estate. Legitimate — derive/assign as a new estate.
        guard let v = rows.first?["value"], case let .text(s) = v else {
            return .absent
        }
        // Present: the value exists, so it MUST parse. A non-parseable
        // value is corruption — fail loud rather than mint a random UUID.
        guard let uuid = UUID(uuidString: s) else {
            throw LocusKitError.corruptStoredValue(
                table: "manifest", column: "estate_uuid", storedText: s)
        }
        return .present(uuid: uuid, rawText: s)
    }

    /// Derive a stable maker node id from an already-classified estate
    /// uuid. A present value hashes to a non-negative Int32 (low 31 bits
    /// of FNV-1a 32-bit) so the id is estate-specific; an absent value
    /// (fresh estate) yields node 0. Corrupt values never reach here —
    /// `classifyEstateUuid` throws before this is called.
    private static func makerNodeID(for state: EstateUuidState) -> Int32 {
        switch state {
        case .absent:
            // Fresh estate: no persisted identity to key the node id on.
            return 0
        case .present(_, let rawText):
            // FNV-1a 32-bit (SubstrateLib), masked to non-negative Int32.
            // Hash the RAW stored text (not the re-serialised UUID) so the
            // node id is byte-identical to the Rust port, which hashes the
            // same stored string.
            let h = FNV.hash32(rawText)
            return Int32(bitPattern: h & 0x7FFF_FFFF)
        }
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
    ///
    /// Telemetry: emits `locuskit.drawer.capture_latency_ms` and
    /// `locuskit.drawer.capture_count` via IntellectusLib when monitoring
    /// is enabled. Off by default; the emit call short-circuits after
    /// a single Atomic<Bool> load when disabled.
    ///
    /// ## Access: internal — not public (§11.5 Option B add-coverage guarantee)
    ///
    /// This method is `internal` rather than `public` so it is not the obvious
    /// add path for callers outside LocusKit. The only sanctioned add path in
    /// the verb layer is `Estate.addDrawerCovered`, which bundles
    /// `store.addDrawer` + `containerFP.orIn` so coverage is structurally
    /// guaranteed. Direct callers inside the package (e.g. backfill tests,
    /// DrawerStore unit tests) access it via `@testable import LocusKit`; all
    /// other callers must go through the Estate verb surface.
    ///
    /// The clear-side (withdraw / bit-off) is intentionally a no-op everywhere —
    /// stale set bits are a harmless over-approximation (see
    /// ContainerFingerprintStore header). Tightening is done by
    /// `containerFP.rebuildAll` at estate open.
    internal func addDrawer(_ d: Drawer, now: Date = Date()) async throws {
        // Capture start instant before any work. One epoch-seconds read
        // per call; the elapsed is computed inside emitDrawerCapture only
        // when monitoring is enabled, so this clock read is the only
        // unconditional overhead added.
        let startTs = Date().timeIntervalSince1970

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

        // Emit drawer-capture telemetry at the operation boundary.
        // The `startTs` clock is read unconditionally above; the emit
        // itself (autoclosure + arithmetic) is skipped when monitoring is
        // off. Estate tag uses the estate UUID: stable, estate-specific.
        let nowTs = Date().timeIntervalSince1970
        let estateTag = estateUuid.uuidString
        emitDrawerCapture(start: startTs, now: nowTs, estateTag: estateTag)
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

    /// Find a living successor sharing `lineageID`, excluding `excludingID`.
    ///
    /// A "living successor" is any row in the same content lineage that
    /// currently occupies a Cluster-A state — active, pending, contested,
    /// or accepted (raw state < 16, the Cluster-B boundary per cookbook
    /// §2.3). This is the lineage head: the row that superseded the
    /// excluded predecessor (or a later link in the chain).
    ///
    /// The revive guard (`Estate.mutate` with `.revive`) consults this to
    /// decide whether reviving a superseded row would create two active
    /// rows claiming the same lineage position — a domain contradiction
    /// (cookbook §6.2). Note the predicate is `< 16`, wider than
    /// `findActivePredecessor`'s `< 3`: a living successor includes the
    /// audit-grade `accepted` state, which the supersession-cascade
    /// predecessor lookup intentionally excludes.
    ///
    /// - Returns: the id of one living successor if any exists, else nil.
    public func livingSuccessorInLineage(
        lineageID: UUID, excludingID: String
    ) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "lineageID"), .text(lineageID.uuidString)),
                .neq(Column(table: "drawers", name: "id"), .text(excludingID)),
                // Living = RowState Cluster A; boundary from the automaton.
                .lt(Column(table: "drawers", name: "g_state_cluster"),
                    .int(Int64(RowState.activeClusterUpperBoundRaw)))
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

    /// Batch by-id load. Returns the drawers whose ids appear in `ids`,
    /// in unspecified order, omitting any id with no matching row. This is
    /// the O(candidates) hydration path for recall: it loads only the
    /// requested frontier rows via a single `WHERE id IN (...)` query rather
    /// than scanning the whole estate. Row decoding mirrors `getDrawer(id:)`
    /// exactly, so a drawer fetched here is byte-for-byte the one fetched
    /// singly. Like `getDrawer`, it does NOT filter tombstoned rows; callers
    /// that need a liveness guard apply it on the returned drawers.
    ///
    /// SQLite caps a single statement at SQLITE_MAX_VARIABLE_NUMBER bound
    /// parameters (999 on the conservative pre-3.32 default). The id set is
    /// chunked below that ceiling so an arbitrarily large frontier still
    /// resolves in a bounded number of queries. An empty `ids` returns `[]`
    /// without touching storage.
    public func getDrawers(ids: [String]) async throws -> [Drawer] {
        // The bare signature is the full-hydration path (today's behavior:
        // reads every column, content blob included). All existing callers
        // resolve here unchanged.
        try await getDrawers(ids: ids, hydrationLevel: .full)
    }

    /// Every `drawers` column EXCEPT `content` — the no-blob structured
    /// projection. A `.structured`/`.bitmapOnly` load selects exactly these
    /// columns, so the content blob is never read out of storage. The set is
    /// the column list `drawerValues(_:)` writes minus `"content"`; a column
    /// added to the schema must be added here too or it reads as absent at
    /// `.structured`. `drawerFromRow` decodes an absent `content` to "" via
    /// `string(_:)`, so a structured drawer carries an empty body by design.
    private static let structuredDrawerColumns: [String] = [
        "id", "wing", "room", "sourceFile", "chunkIndex", "addedBy",
        "filedAt", "eventTime", "embeddingModelID", "tombstonedAt",
        "removedByBatch", "provenance", "adjectiveBitmap", "operationalBitmap",
        "lineageID", "udcCode", "udcFacets", "wikidataQID",
        "wikidataQidsSecondary"
    ]

    /// Batch by-id load at a chosen hydration level — the dense-first candidate
    /// pool path. At `.structured`/`.bitmapOnly` the query PROJECTS away the
    /// `content` column, so the blob is never read from storage; the returned
    /// drawers carry `content == ""` and every structured/bitmap/lattice column
    /// intact (the dense signal the higher lanes select on). At `.full` it reads
    /// every column, identical to `getDrawers(ids:)`. Chunking, de-duplication,
    /// and the no-tombstone-filter contract match `getDrawers(ids:)` exactly.
    public func getDrawers(ids: [String], hydrationLevel: HydrationLevel) async throws -> [Drawer] {
        if ids.isEmpty { return [] }
        // No-blob projection for the structured/bitmap tiers; full read for
        // `.full`. The projection omits `content`, which is the entire point of
        // the dense-first pool load.
        let columns: [String]?
        switch hydrationLevel {
        case .structured, .bitmapOnly:
            columns = Self.structuredDrawerColumns
        case .full:
            columns = nil
        }
        // De-duplicate to avoid emitting the same row twice when an id
        // repeats in the input. Order within a chunk is not meaningful to
        // callers (recall re-indexes by id), so a Set is sufficient.
        let unique = Array(Set(ids))
        // Stay strictly below the 999-variable SQLite ceiling. 900 leaves
        // headroom for any wrapping predicate a future caller might add.
        let chunkSize = 900
        var result: [Drawer] = []
        result.reserveCapacity(unique.count)
        var index = 0
        while index < unique.count {
            let end = min(index + chunkSize, unique.count)
            let chunk = unique[index..<end]
            let values = chunk.map { TypedValue.text($0) }
            let rows = try await storage.rowStore.query(
                table: "drawers",
                where: .in(Column(table: "drawers", name: "id"), values),
                orderBy: [], limit: nil, offset: nil, columns: columns
            )
            result.append(contentsOf: try rows.map(Self.drawerFromRow))
            index = end
        }
        return result
    }

    /// All non-tombstoned drawers in a wing, ordered by filedAt.
    ///
    /// Telemetry: emits `locuskit.drawer.query_latency_ms` and
    /// `locuskit.drawer.query_result_count` (tag: query="wing") when
    /// monitoring is enabled.
    public func drawersIn(wing: String) async throws -> [Drawer] {
        let startTs = Date().timeIntervalSince1970
        // Use querySkipCorrupt so rows with corrupt timestamp columns (e.g.
        // a poison filedAt from a bad Vault import or millisecond-vs-seconds
        // confusion) are skipped rather than bricking the entire wing scan.
        let (rows, _) = try await storage.rowStore.querySkipCorrupt(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "wing"), .text(wing)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil, columns: nil
        )
        // decodeDrawerRowsSkipCorrupt handles any remaining drawerFromRow failures
        // (e.g. corrupt lineageID UUID) that survived the storage-level skip.
        let result = try Self.decodeDrawerRowsSkipCorrupt(rows, scan: "drawersIn(wing:)")
        // Emit query metrics at the operation boundary.
        // query="wing" labels this as a per-wing query path for per-path
        // latency dashboards. Off-path: single Atomic<Bool> load.
        emitDrawerQuery(
            start: startTs, now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "wing"
        )
        return result
    }

    /// All non-tombstoned drawers in a wing/room pair, ordered by filedAt.
    ///
    /// Telemetry: emits `locuskit.drawer.query_latency_ms` and
    /// `locuskit.drawer.query_result_count` (tag: query="wing_room") when
    /// monitoring is enabled.
    public func drawersIn(wing: String, room: String) async throws -> [Drawer] {
        let startTs = Date().timeIntervalSince1970
        let (rows, _) = try await storage.rowStore.querySkipCorrupt(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "wing"), .text(wing)),
                .eq(Column(table: "drawers", name: "room"), .text(room)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil, columns: nil
        )
        let result = try Self.decodeDrawerRowsSkipCorrupt(rows, scan: "drawersIn(wing:room:)")
        // query="wing_room" labels this as the per-wing/room path.
        emitDrawerQuery(
            start: startTs, now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "wing_room"
        )
        return result
    }

    /// All non-tombstoned drawers for a source file, ordered by
    /// chunkIndex then filedAt.
    public func drawersBySource(file: String) async throws -> [Drawer] {
        let (rows, _) = try await storage.rowStore.querySkipCorrupt(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "sourceFile"), .text(file)),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [
                OrderClause(column: Column(table: "drawers", name: "chunkIndex"), direction: .ascending),
                OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)
            ],
            limit: nil, offset: nil, columns: nil
        )
        return try Self.decodeDrawerRowsSkipCorrupt(rows, scan: "drawersBySource(file:)")
    }

    /// Full-corpus scan ordered by filedAt, including tombstoned rows.
    ///
    /// Telemetry: emits `locuskit.drawer.query_latency_ms` and
    /// `locuskit.drawer.query_result_count` (tag: query="all") when
    /// monitoring is enabled.
    public func allDrawers() async throws -> [Drawer] {
        try await allDrawers(hydrationLevel: .full, limit: nil)
    }

    /// Bounded, optionally no-blob corpus scan ordered by filedAt ascending.
    ///
    /// This is the performance-critical path for the recall locus lane:
    ///
    ///   - `hydrationLevel` controls whether the `content` blob is fetched.
    ///     At `.structured` or `.bitmapOnly` the query projects away the
    ///     `content` column (identical to the `getDrawers(ids:hydrationLevel:)`
    ///     structured projection) — the blob is never read from storage.
    ///     At `.full` all columns are selected, identical to `allDrawers()`.
    ///
    ///   - `limit` caps how many rows SQLite materialises. When non-nil the
    ///     query applies `LIMIT limit` at the storage tier, so the database
    ///     stops scanning after it has produced that many rows. This is the
    ///     candidate-cap mechanism: recall only needs the first N rows in
    ///     filedAt order; fetching the whole estate and discarding the tail
    ///     is O(N_estate), this is O(min(N_estate, limit)).
    ///
    /// Telemetry: emits `locuskit.drawer.query_latency_ms` and
    /// `locuskit.drawer.query_result_count` (tag: query="all") when
    /// monitoring is enabled.
    public func allDrawers(hydrationLevel: HydrationLevel, limit: Int?) async throws -> [Drawer] {
        let startTs = Date().timeIntervalSince1970
        // No-blob projection for the structured/bitmap tiers; full read for `.full`.
        // Mirrors the same column set used by `getDrawers(ids:hydrationLevel:)`.
        let columns: [String]?
        switch hydrationLevel {
        case .structured, .bitmapOnly:
            columns = Self.structuredDrawerColumns
        case .full:
            columns = nil
        }
        // Use querySkipCorrupt so rows with corrupt timestamp columns (e.g.
        // a poison filedAt like "+58432-..." from a Vault import where a
        // millisecond epoch was stored where seconds were expected) are skipped
        // at the storage cursor level and do not abort the entire corpus scan.
        let (rows, _) = try await storage.rowStore.querySkipCorrupt(
            table: "drawers",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "drawers", name: "filedAt"), direction: .ascending)],
            limit: limit.map { $0 }, offset: nil, columns: columns
        )
        let result = try Self.decodeDrawerRowsSkipCorrupt(rows, scan: "allDrawers(hydrationLevel:limit:)")
        // query="all" labels this as the full-corpus path.
        // This is the most expensive drawer read and the one most worth
        // monitoring for latency regression in large estates.
        emitDrawerQuery(
            start: startTs, now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "all"
        )
        return result
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

        try await gatedColumnWrite(
            drawerId: drawerId, column: .provenance,
            newColumnValue: newProvenance, changedBy: changedBy, reason: reason, now: now)
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
        // I-22 (secret+exportable) is enforced inside the gate's basis
        // check now (SubstrateLib), so no separate validator is needed —
        // the gate refuses it on the merged result, on every write.
        try await gatedColumnWrite(
            drawerId: drawerId, column: .adjective,
            newColumnValue: newAdjective, changedBy: changedBy, reason: reason, now: now)
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
        try await gatedColumnWrite(
            drawerId: drawerId, column: .operational,
            newColumnValue: newOperational, changedBy: changedBy, reason: reason, now: now)
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
        let anchor = SubstrateTypes.LatticeAnchor.udc(d.udcCode)

        let nowTs = now.timeIntervalSince1970
        let estateTag = estate.uuidString
        try await storage.transaction(isolation: .serializable) { txn in
            _ = try await txn.rowStore.insert(
                table: "drawers", values: Self.drawerValues(d))

            let result = AuditGate.admit(
                estateUuid: estate, rowId: rowUuid, nounType: .drawer, verb: .capture,
                prior: nil, priorLatticeAnchor: nil, writes: allWrites,
                afterLatticeAnchor: anchor, vocabulary: vocab, hlc: stamp, actor: d.addedBy)
            switch result {
            case .success(let e):
                try await txn.auditLog.append(e)
                emitGateAdmit(now: nowTs, estateTag: estateTag)
            case .failure(let v):
                emitGateReject(now: nowTs, estateTag: estateTag, reason: "\(v)")
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
        // ──────────────────────────────────────────────────────────────
        // Quis custodiet ipsos custodes? Who watches the watchmen's
        // bitmaps? The SwiftSyntax Guardian does — tools/guardian.
        //
        // The stateSlot legalValues below duplicate the State enum raws
        // from LocusKit/Adjectives.swift. DrawerStore cannot use State
        // directly because FieldSlot takes Set<Int64>, not Set<State>.
        // Touch one side and the Guardian warns at your desk, before it
        // ships. Test backstop: GuardianPairParityTests.
        //
        // @guardian-pair: drawerstore-mutate-state DrawerStore.mutateState.stateSlot.legalValues <-> State.allCases (raw set equality)
        // ──────────────────────────────────────────────────────────────
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
            let anchor = SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))

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
            let gateEvent: AuditEvent
            switch result {
            case .success(let e): gateEvent = e
            case .failure(let v):
                throw LocusKitError.invalidContent("state mutation rejected by gate: \(v)")
            }
            // Thread the caller-supplied reason into the event before persisting.
            let event = gateEvent.withReason(reason)

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
    /// is GLK's orchestration responsibility — see §B-2a.
    /// Aggregates are deliberately untouched, per §9.5.1 and §10.5
    /// (they are already de-identified statistical roll-ups).
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
    ///
    /// When `sealAudit` is `true` (default), the audit event is
    /// appended atomically inside the same transaction as the row
    /// mutation — this is the behaviour for direct callers that own
    /// the full expunge. When `sealAudit` is `false`, the audit event
    /// is NOT appended (the caller must call `sealExpungeAudit(_:now:)`
    /// after completing its own orchestration steps). The gate-produced
    /// event is returned in both cases so the caller has it ready for
    /// the deferred seal. Returns nil only when `sealAudit` is true
    /// (the event was sealed inside the transaction and no further
    /// action is required from the caller).
    @discardableResult
    public func expungeGated(
        drawerId: String,
        changedBy: String,
        reason: String? = nil,
        now: Date = Date(),
        sealAudit: Bool = true
    ) async throws -> AuditEvent? {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")

        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)
        let rowUuid = try Self.requireUuid(drawerId, label: "drawerId")
        let estate = estateUuid
        let vocab = vocabulary
        // ──────────────────────────────────────────────────────────────
        // Quis custodiet ipsos custodes? Who watches the watchmen's
        // bitmaps? The SwiftSyntax Guardian does — tools/guardian.
        //
        // Same stateSlot legalValues as mutateState — duplicates the
        // State enum raws. Test backstop: GuardianPairParityTests.
        //
        // @guardian-pair: drawerstore-expunge-state DrawerStore.expungeGated.stateSlot.legalValues <-> State.allCases (raw set equality)
        // ──────────────────────────────────────────────────────────────
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

        // When sealAudit is false the gate-produced event is returned to
        // the caller (GLK VerbSurface) so it can be sealed after its own
        // orchestration steps. The transaction returns the event in both
        // cases; we thread it back via the generic-return overload so the
        // mutable-capture concurrency constraint is satisfied.
        let capturedEvent: AuditEvent = try await storage.transaction(isolation: .serializable) { txn in
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
            let anchor = SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))

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
            let gateEvent: AuditEvent
            switch result {
            case .success(let e): gateEvent = e
            case .failure(let v):
                throw LocusKitError.invalidContent("expunge rejected by gate: \(v)")
            }
            // Thread the caller-supplied reason into the event so it is
            // persisted in the audit table's `reason` column.
            let event = gateEvent.withReason(reason)

            // Materialized projection: write the merged adjective
            // snapshot, zero the content blob, stamp tombstonedAt — all
            // in the same transaction as the gated event append. Per
            // cookbook §10.5: "Content blob zeroized in the same
            // transaction as the state transition (atomic; verbatim
            // sacred only up to expunge)."
            //
            // TypedValue.timestamp is the canonical door for all
            // timestamp column writes (PersistenceKit serialises it as
            // ISO-8601 with fractional seconds, matching every other
            // date column in the schema and the read-back path in
            // drawerValues(_:) at line 2489). Using a bare
            // ISO8601DateFormatter() here would be a bespoke side-door
            // and a one-door violation.
            _ = try await txn.rowStore.update(
                table: "drawers",
                values: [
                    "adjectiveBitmap": .bitmap(event.afterBitmaps.adjective),
                    "content": .text(""),
                    "tombstonedAt": .timestamp(now),
                ],
                where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
            )
            if sealAudit {
                // Default path: seal atomically in the same transaction
                // as the row mutation. Direct callers (not via GLK) use
                // this path and get the same atomic guarantee as before.
                try await txn.auditLog.append(event)
            }
            return event
        }

        // When sealAudit is true the event was appended inside the
        // transaction; return nil so callers know no deferred action is
        // needed. When sealAudit is false, return the captured event so
        // the caller can pass it to sealExpungeAudit(_:).
        return sealAudit ? nil : capturedEvent
    }

    /// Seal a previously prepared expunge audit event.
    ///
    /// Called by GLK's `VerbSurface.expunge` after the cross-kit vector
    /// delete step succeeds, when `expungeGated(sealAudit:false)` was
    /// used to split the storage mutation from the audit seal.
    ///
    /// Appends `event` directly to the audit log outside any transaction
    /// — the storage half of the expunge already committed. The event
    /// carries verb `"tombstone"` and the gate-computed afterBitmaps from
    /// the original mutation, so rebuild via `feedAuditLog` produces the
    /// same unified log entry as the fully-atomic (sealAudit:true) path.
    ///
    /// Deterministic: the caller threads the same `now` the verb received;
    /// never calls Date() here.
    public func sealExpungeAudit(_ event: AuditEvent) async throws {
        try await storage.auditLog.append(event)
    }

    /// Seal a cross-kit-orphan audit event for a partially-completed expunge.
    ///
    /// Called by GLK's `VerbSurface.expunge` when the storage half (step 1)
    /// succeeded but the cross-kit vector delete (step 2) failed. The row is
    /// already tombstoned and its content is zeroed; this method writes an
    /// honest audit record that the fact-of-expunge at the storage layer is
    /// preserved (spec I-6) while making the partial outcome detectable.
    ///
    /// The audit event uses verb `"expungeOrphan"` — distinct from the success
    /// verb `"tombstone"`, but both bridge to `UnifiedAuditVerb.expunge` in the
    /// GLK unified log (AuditBridge). A consumer that needs to distinguish
    /// a clean expunge from an orphan case must read the substrate audit trail
    /// directly (verb string is `"expungeOrphan"`) rather than the unified log.
    ///
    /// Unlike `sealExpungeAudit(_:)`, the bitmaps in the orphan event match
    /// the post-tombstone state (same as the success event) — the storage
    /// mutation DID occur. The only difference is the verb string, which
    /// signals to audit consumers that the cross-kit delete did not complete.
    ///
    /// Deterministic: the caller threads the same `now` the verb received;
    /// never calls Date() here.
    ///
    /// Parity note (eventID): the Rust port computes `eventID` via
    /// `audit_gate::content_id` (deterministic SHA-256 over the event fields).
    /// This Swift initializer uses `AuditEvent(eventID: UUID())` (random UUID,
    /// the default for the `AuditEvent` initializer). The IDs will diverge if
    /// orphan audit events are ever federated cross-port. Until cross-port audit
    /// federation lands, this divergence is acceptable — both ports write the
    /// event to their own substrate, and the unified log does not expose `eventID`.
    /// When federation is implemented, reconcile this to use the same SHA-256
    /// deterministic content-ID derivation as the Rust port.
    public func sealExpungeOrphanAudit(
        drawerId: String,
        successEvent: AuditEvent,
        changedBy: String,
        now: Date
    ) async throws {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: nowMillis)
        // Construct the orphan event from the success event's fields,
        // replacing only the verb and the HLC (new stamp so the orphan
        // event sorts after the success-event's HLC would have).
        let orphanEvent = AuditEvent(
            estateUuid: successEvent.estateUuid,
            rowId: successEvent.rowId,
            hlc: stamp,
            verb: "expungeOrphan",
            beforeBitmaps: successEvent.beforeBitmaps,
            afterBitmaps: successEvent.afterBitmaps,
            beforeLatticeAnchor: successEvent.beforeLatticeAnchor,
            afterLatticeAnchor: successEvent.afterLatticeAnchor,
            actor: changedBy
        )
        try await storage.auditLog.append(orphanEvent)
    }

    // MARK: - Expunge integrity sweep helpers

    /// Query for tombstoned drawers that have no sealed "tombstone" or
    /// "expungeOrphan" audit event.
    ///
    /// Returns the set of rows that fell into the crash-window: step 1 of the
    /// §B-2a expunge (LocusKit storage tombstone+scrub) ran, but the process
    /// crashed before step 3 (audit seal) and the orphan-seal recovery path
    /// also did not complete. These rows are tombstoned and content-zeroed, but
    /// the audit trail is silent about the expunge.
    ///
    /// The GLK `runExpungeIntegritySweep` maintenance function calls this to
    /// enumerate the orphan set, then re-attempts the cross-kit delete and seals
    /// a synthetic "expungeOrphan" audit for each row via
    /// `sealExpungeOrphanForSweep`.
    ///
    /// Deterministic: does not call Date(); all timestamps come from existing
    /// stored data.
    ///
    /// - Throws: `LocusKitError` when the underlying storage query fails.
    ///   The caller treats this as fatal (the orphan set is unknown; sweep
    ///   cannot proceed).
    public func tombstonedRowsWithoutExpungeAudit() async throws -> [Drawer] {
        // Query every tombstoned row (tombstonedAt IS NOT NULL), regardless of
        // hydration level — the sweep needs the drawer's bitmaps and lattice
        // anchor to construct the synthetic audit event.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .isNotNull(Column(table: "drawers", name: "tombstonedAt")),
            orderBy: [OrderClause(column: Column(table: "drawers", name: "tombstonedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        let tombstoned = try rows.map(Self.drawerFromRow)

        // Filter to only those with no tombstone or expungeOrphan audit event.
        var orphans: [Drawer] = []
        for drawer in tombstoned {
            guard let uuid = UUID(uuidString: drawer.id) else { continue }
            let events = try await storage.auditLog.eventsForRow(uuid)
            let hasExpungeAudit = events.contains(where: {
                $0.verb == "tombstone" || $0.verb == "expungeOrphan"
            })
            if !hasExpungeAudit {
                orphans.append(drawer)
            }
        }
        return orphans
    }

    /// The set of lineage IDs whose rows have been permanently erased (cluster C:
    /// `tombstonedAt IS NOT NULL`). Reads the `lineageID` column directly from
    /// storage rows without a full `drawerFromRow` decode — the `tombstonedAt`
    /// column is used only as a filter predicate at the storage tier, never parsed
    /// here. `IS NOT NULL` is the correct existence predicate for the timestamp
    /// column: it lets the SQLite index handle the live/tombstoned split without
    /// decoding the timestamp value, and it is unambiguous regardless of whether
    /// the column carries `.timestamp(Date)` (the canonical write from
    /// `expungeGated`) or `.null` (live row).
    ///
    /// The query predicate `tombstonedAt IS NOT NULL` is evaluated by the storage
    /// backend on the raw `TypedValue` (`.isNotNull` → `!value.isNull`), which
    /// correctly identifies `.timestamp(_)` as non-null.
    ///
    /// Used by `Estate.tombstonedLineageIDs()` → `GLK.tombstonedLineageIDs` →
    /// `VaultBridge.existingTombstonedLineageIDs` to block vault re-import from
    /// resurrecting erased notes (FINDING-1b cluster C fix).
    public func tombstonedLineageIDs() async throws -> Set<UUID> {
        // Project only the lineageID column — the content blob and most
        // metadata fields are not needed for this lookup.
        let (rows, _) = try await storage.rowStore.querySkipCorrupt(
            table: "drawers",
            where: .isNotNull(Column(table: "drawers", name: "tombstonedAt")),
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: ["lineageID"]
        )
        // Extract lineageID from each raw row. Rows where lineageID is absent,
        // null, or not a valid UUID are silently skipped — a corrupt lineageID
        // on a tombstoned row does not prevent other tombstoned lineages from
        // being detected. The critical invariant is that every well-formed
        // tombstoned row contributes its lineageID to the block-set.
        var result = Set<UUID>()
        for row in rows {
            guard case .text(let raw) = row["lineageID"], !raw.isEmpty,
                  let uuid = UUID(uuidString: raw) else { continue }
            result.insert(uuid)
        }
        return result
    }

    /// Seal a synthetic "expungeOrphan" audit event for a crash-window row.
    ///
    /// Called by the GLK integrity sweep after re-attempting the cross-kit
    /// delete. Unlike `sealExpungeOrphanAudit`, this path constructs the audit
    /// event from the current drawer state rather than from the original gate
    /// event (which was lost in the crash). The result is honest: the bitmaps
    /// reflect the post-tombstone state, and the "expungeOrphan" verb signals
    /// that the row was cleaned up by the sweep, not the live expunge path.
    ///
    /// The sweep cannot reconstruct the exact HLC that the original expunge
    /// used, so the event gets a fresh HLC stamp (sorted after all prior events
    /// for this row, per the monotonic HLC guarantee).
    ///
    /// Deterministic: the caller threads `now`; never calls Date() here.
    ///
    /// - Parameters:
    ///   - drawerId: the stable row id.
    ///   - changedBy: identity string for the actor (estate owner or "estate").
    ///   - now: the sweep's wall-clock snapshot in millis since UNIX epoch.
    ///
    /// - Throws: `LocusKitError.drawerNotFound` when the row is absent.
    ///   `LocusKitError` variants for storage or audit-log write failures.
    public func sealExpungeOrphanForSweep(
        drawerId: String,
        changedBy: String,
        now: Int64
    ) async throws {
        try Self.validateNonEmpty(drawerId, label: "drawerId")
        try Self.validateNonEmpty(changedBy, label: "changedBy")

        // Read the current row to obtain bitmaps and lattice anchor.
        // The row is tombstoned (content zeroed), so these reflect the
        // post-tombstone state — correct for the "after" snapshot.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
        )
        guard let row = rows.first else {
            throw LocusKitError.drawerNotFound(id: drawerId)
        }
        let rowUuid = try Self.requireUuid(drawerId, label: "drawerId")
        let estate = estateUuid

        let adjBitmap = Self.int64(row["adjectiveBitmap"])
        let opBitmap  = Self.int64(row["operationalBitmap"])
        let provBitmap = Self.int64(row["provenance"])
        let latticeAnchor = SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))

        let stamp = hlc.send(now: now)

        // Construct the synthetic orphan event from current drawer state.
        // `beforeBitmaps: nil` — the pre-tombstone snapshot is unavailable
        // (crash window; no original gate event). This is distinct from the
        // live expunge path where `beforeBitmaps` comes from the gate event.
        // Consumers that need to distinguish sweep-sealed from live-sealed
        // events can check for `beforeBitmaps == nil`.
        let orphanEvent = AuditEvent(
            estateUuid: estate,
            rowId: rowUuid,
            hlc: stamp,
            verb: "expungeOrphan",
            beforeBitmaps: nil,
            afterBitmaps: (adjective: adjBitmap, operational: opBitmap, provenance: provBitmap),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: latticeAnchor,
            actor: changedBy
        )
        try await storage.auditLog.append(orphanEvent)
    }

    /// Reanchor a drawer: update the row's placement columns (`room` and/or
    /// lattice anchor columns), emitting one sealed audit event for the move.
    ///
    /// Routes through `AuditGate.admit` with `verb: .mutate` (the active→active
    /// self-loop) because no `RowVerb.reanchor` case exists. The anchor delta
    /// is expressed via `priorLatticeAnchor` ≠ `afterLatticeAnchor`. The three
    /// bitmaps are read and passed as-is (unchanged by a reanchor). All column
    /// writes and the audit event append occur in the same transaction.
    ///
    /// Throws:
    ///   - `LocusKitError.drawerNotFound(id:)` when the row is absent.
    ///   - `LocusKitError.invalidContent(...)` when the gate rejects the write.
    public func reanchorGated(
        drawerId: String,
        toRoom: String? = nil,
        toWing: String? = nil,
        toLattice: LatticeAnchor? = nil,
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
            let priorAnchor = SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))
            let afterAnchor: SubstrateTypes.LatticeAnchor
            if let newLattice = toLattice {
                afterAnchor = SubstrateTypes.LatticeAnchor.udc(newLattice.udcCode)
            } else {
                afterAnchor = priorAnchor
            }

            // Reanchor is a placement move, not a bitmap field edit. No
            // FieldWrites are needed — the gate records the anchor delta via
            // priorLatticeAnchor/afterLatticeAnchor and validates the verb
            // (mutate = active→active self-loop). Pass an empty writes array.
            let result = AuditGate.admit(
                estateUuid: estate,
                rowId: rowUuid,
                nounType: .drawer,
                verb: .mutate,
                prior: prior,
                priorLatticeAnchor: priorAnchor,
                writes: [],
                afterLatticeAnchor: afterAnchor,
                vocabulary: vocab,
                hlc: stamp,
                actor: changedBy
            )
            let gateEvent: AuditEvent
            switch result {
            case .success(let e): gateEvent = e
            case .failure(let v):
                throw LocusKitError.invalidContent("reanchor rejected by gate: \(v)")
            }
            // Thread the caller-supplied reason into the event before persisting.
            let event = gateEvent.withReason(reason)

            // Build the column update dictionary. Always update at least
            // the columns named in the event (bitmaps are unchanged, so the
            // write is idempotent there) plus any placement columns that changed.
            var updateValues: [String: TypedValue] = [:]
            if let newLattice = toLattice {
                updateValues["udcCode"] = .text(newLattice.udcCode)
                updateValues["udcFacets"] = newLattice.udcFacets.map { .text($0) } ?? .null
                updateValues["wikidataQID"] = newLattice.wikidataQID.map { .text($0) } ?? .null
                updateValues["wikidataQidsSecondary"] = newLattice.wikidataQidsSecondary.map { .text($0) } ?? .null
            }
            if let newRoom = toRoom {
                updateValues["room"] = .text(newRoom)
            }
            // Cross-wing moves: update the wing column when toWing is supplied.
            // Wings emerge from SELECT DISTINCT wing on the drawers table (no wings
            // table), so writing a new wing name here is sufficient to move the drawer
            // into the target wing.
            if let newWing = toWing {
                updateValues["wing"] = .text(newWing)
            }

            if !updateValues.isEmpty {
                _ = try await txn.rowStore.update(
                    table: "drawers",
                    values: updateValues,
                    where: .eq(Column(table: "drawers", name: "id"), .text(drawerId))
                )
            }
            try await txn.auditLog.append(event)
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
        reason: String? = nil,
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
            let anchor = SubstrateTypes.LatticeAnchor.udc(Self.string(row["udcCode"]))

            // verb .mutate is the state self-loop (active→active); a field
            // edit preserves state, so this is the correct verb.
            let result = AuditGate.admit(
                estateUuid: estate, rowId: rowUuid, nounType: .drawer, verb: .mutate,
                prior: prior, priorLatticeAnchor: anchor, writes: writes,
                afterLatticeAnchor: anchor, vocabulary: vocab, hlc: stamp, actor: changedBy)
            let gateEvent: AuditEvent
            switch result {
            case .success(let e): gateEvent = e
            case .failure(let v):
                throw LocusKitError.invalidContent("\(column) mutation rejected by gate: \(v)")
            }
            // Thread the caller-supplied reason into the event before persisting.
            let event = gateEvent.withReason(reason)
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
    ///
    /// Telemetry: emits `locuskit.tunnel.add_count` when monitoring is
    /// enabled. Off by default; the emit call short-circuits after a
    /// single Atomic<Bool> load when disabled.
    public func addTunnel(_ t: Tunnel) async throws {
        try Self.validateNonEmpty(t.sourceWing, label: "sourceWing")
        try Self.validateNonEmpty(t.sourceRoom, label: "sourceRoom")
        try Self.validateNonEmpty(t.targetWing, label: "targetWing")
        try Self.validateNonEmpty(t.targetRoom, label: "targetRoom")
        try Self.validateNonEmpty(t.label, label: "label")
        try Self.validateNonEmpty(t.addedBy, label: "addedBy")
        _ = try await storage.rowStore.insert(
            table: "tunnels", values: Self.tunnelValues(t))
        // Emit tunnel-add metric at the operation boundary.
        // Tunnel count tracks link density growth in the estate graph.
        emitTunnelAdd(
            now: Date().timeIntervalSince1970,
            estateTag: estateUuid.uuidString
        )
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

    /// All non-tombstoned tunnels across all wings, ordered by filedAt.
    /// Used by the dreaming daemon to suppress duplicate proposals: a
    /// candidate endpoint pair that already has a Tunnel is dropped.
    /// Unlike `tunnelsFrom(wing:)` this is estate-wide — the daemon
    /// considers the full association graph, not a single wing.
    public func allTunnels() async throws -> [Tunnel] {
        let rows = try await storage.rowStore.query(
            table: "tunnels",
            where: .isNull(Column(table: "tunnels", name: "tombstonedAt")),
            orderBy: [OrderClause(
                column: Column(table: "tunnels", name: "filedAt"),
                direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return try rows.map(Self.tunnelFromRow)
    }

    // MARK: - KGFact CRUD

    /// Insert a KGFact. Conflicting ids surface as duplicateKey.
    ///
    /// `sourceDrawerID` may be `""` as an "unanchored fact" sentinel — used by
    /// the MCP surface when the caller asserts a freestanding triple not
    /// extracted from a specific drawer. Non-empty values are validated as usual.
    ///
    /// Telemetry: emits `locuskit.kgfact.add_count` when monitoring is
    /// enabled. Off by default; the emit call short-circuits after a
    /// single Atomic<Bool> load when disabled.
    public func addKGFact(_ f: KGFact) async throws {
        try Self.validateNonEmpty(f.subject, label: "subject")
        try Self.validateNonEmpty(f.predicate, label: "predicate")
        try Self.validateNonEmpty(f.object, label: "object")
        // sourceDrawerID = "" is the "not anchored to a specific drawer" sentinel;
        // non-empty values are admitted as-is (same leniency as the other fields'
        // validateNonEmpty checks, which accept non-empty strings without
        // additional whitespace trimming).
        _ = try await storage.rowStore.insert(
            table: "kg_facts", values: Self.kgFactValues(f))
        // Emit KGFact-add metric at the operation boundary.
        // Tracks knowledge-graph growth rate per estate.
        emitKGFactAdd(
            now: Date().timeIntervalSince1970,
            estateTag: estateUuid.uuidString
        )
    }

    /// Transition a KGFact's state to withdrawn.
    ///
    /// Sets bits 0–5 of `adjectiveBitmap` to `State.withdrawn.rawValue` (18).
    /// That raw lands in RowState Cluster B (at/above the active upper bound
    /// `RowState.activeClusterUpperBoundRaw`, 16), so the fact is excluded
    /// from `allKGFacts` active recall. The row is not deleted — retirement
    /// is a state transition that preserves the audit trail.
    ///
    /// - Throws: `LocusKitError.invalidContent` if no fact with `id` exists.
    public func withdrawKGFact(id: String) async throws {
        guard let fact = try await getKGFact(id: id) else {
            throw LocusKitError.invalidContent("kgFact not found: \(id)")
        }
        // Preserve all bits above the 6-bit state field (g_state_cluster mask = 0x3F).
        let newBitmap = (fact.adjectiveBitmap & ~Int64(0x3F)) | Int64(State.withdrawn.rawValue)
        _ = try await storage.rowStore.update(
            table: "kg_facts",
            values: ["adjectiveBitmap": .bitmap(newBitmap)],
            where: .eq(Column(table: "kg_facts", name: "id"), .text(id)))
    }

    public func getKGFact(id: String) async throws -> KGFact? {
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: .eq(Column(table: "kg_facts", name: "id"), .text(id))
        )
        return try rows.first.map(Self.kgFactFromRow)
    }

    /// All facts from a source drawer in the RowState Cluster-A (active)
    /// set — `g_state_cluster < RowState.activeClusterUpperBoundRaw` (the
    /// cluster-B floor, 16) — ordered by filedAt ascending. The
    /// generated column stores the raw 6-bit RowState, so the predicate
    /// keeps active/pending/contested/accepted and drops the retired
    /// B/C states; it uses the generated column so it is an indexed range
    /// scan. The boundary is sourced from the RowState automaton, not a
    /// bare literal.
    ///
    /// Telemetry: emits `locuskit.kgfact.query_result_count`
    /// (tag: query="drawer") when monitoring is enabled.
    public func kgFacts(forDrawerID sourceDrawerID: String) async throws -> [KGFact] {
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: .and([
                .eq(Column(table: "kg_facts", name: "sourceDrawerID"), .text(sourceDrawerID)),
                .lt(Column(table: "kg_facts", name: "g_state_cluster"),
                    .int(Int64(RowState.activeClusterUpperBoundRaw)))
            ]),
            orderBy: [OrderClause(column: Column(table: "kg_facts", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        let result = try rows.map(Self.kgFactFromRow)
        // query="drawer" labels the per-drawer KGFact query path.
        emitKGFactQuery(
            now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "drawer"
        )
        return result
    }

    // MARK: - Proposal CRUD

    /// Insert a Proposal. The lattice anchor is required per cookbook
    /// §2.7 (I-16): an empty `udcCode` is rejected with
    /// `LocusKitError.invalidContent` before the insert, mirroring the
    /// capture-path guard in `EstateVerbs.swift`. `targetRowID` is NOT
    /// validated non-empty — a brand-new-object proposal (target object
    /// type `.noneBrandNew`) legitimately has no existing target row.
    /// Conflicting ids surface as duplicateKey.
    public func addProposal(_ p: Proposal) async throws {
        try Self.validateNonEmpty(p.latticeAnchor.udcCode, label: "latticeAnchor.udcCode")
        _ = try await storage.rowStore.insert(
            table: "proposals", values: Self.proposalValues(p))
    }

    /// Fetch a Proposal by id. Returns nil for an absent id — a routine
    /// query miss, not an error, mirroring `getKGFact` / `getDrawer`.
    public func getProposal(id: String) async throws -> Proposal? {
        let rows = try await storage.rowStore.query(
            table: "proposals",
            where: .eq(Column(table: "proposals", name: "id"), .text(id))
        )
        return try rows.first.map(Self.proposalFromRow)
    }

    /// All proposals targeting a given row, ordered by `filedAt`
    /// ascending. Resolves through the `idx_proposals_target` index on
    /// `targetRowID`. Mirrors `kgFacts(forDrawerID:)`.
    public func proposals(forTargetRowID targetRowID: String) async throws -> [Proposal] {
        let rows = try await storage.rowStore.query(
            table: "proposals",
            where: .eq(Column(table: "proposals", name: "targetRowID"), .text(targetRowID)),
            orderBy: [OrderClause(column: Column(table: "proposals", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.proposalFromRow)
    }

    // MARK: - Association CRUD

    /// Insert an association. The edge endpoints and `addedBy` are required
    /// (mirroring `addTunnel`), and the lattice anchor is required per
    /// cookbook §2.7 (I-16): an empty `udcCode` is rejected with
    /// `LocusKitError.invalidContent` before the insert, mirroring
    /// `addProposal`. Conflicting ids surface as duplicateKey.
    public func addAssociation(_ a: Association) async throws {
        try Self.validateNonEmpty(a.sourceWing, label: "sourceWing")
        try Self.validateNonEmpty(a.sourceRoom, label: "sourceRoom")
        try Self.validateNonEmpty(a.targetWing, label: "targetWing")
        try Self.validateNonEmpty(a.targetRoom, label: "targetRoom")
        try Self.validateNonEmpty(a.label, label: "label")
        try Self.validateNonEmpty(a.addedBy, label: "addedBy")
        try Self.validateNonEmpty(a.latticeAnchor.udcCode, label: "latticeAnchor.udcCode")
        _ = try await storage.rowStore.insert(
            table: "associations", values: Self.associationValues(a))
    }

    /// Fetch an association by id. Returns nil for an absent id — a routine
    /// query miss, not an error, mirroring `getTunnel` / `getProposal`.
    public func getAssociation(id: String) async throws -> Association? {
        let rows = try await storage.rowStore.query(
            table: "associations",
            where: .eq(Column(table: "associations", name: "id"), .text(id))
        )
        return try rows.first.map(Self.associationFromRow)
    }

    /// All non-tombstoned associations from a source wing/room pair, ordered
    /// by `filedAt` ascending. Resolves through `idx_associations_source`.
    /// Mirrors `tunnelsFrom(wing:room:)`.
    public func associationsFrom(wing: String, room: String) async throws -> [Association] {
        let rows = try await storage.rowStore.query(
            table: "associations",
            where: .and([
                .eq(Column(table: "associations", name: "sourceWing"), .text(wing)),
                .eq(Column(table: "associations", name: "sourceRoom"), .text(room)),
                .isNull(Column(table: "associations", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "associations", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.associationFromRow)
    }

    /// All non-tombstoned associations to a target wing/room pair, ordered
    /// by `filedAt` ascending. Resolves through `idx_associations_target`.
    /// Mirrors `tunnelsTo(wing:)`.
    public func associationsTo(wing: String, room: String) async throws -> [Association] {
        let rows = try await storage.rowStore.query(
            table: "associations",
            where: .and([
                .eq(Column(table: "associations", name: "targetWing"), .text(wing)),
                .eq(Column(table: "associations", name: "targetRoom"), .text(room)),
                .isNull(Column(table: "associations", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "associations", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.associationFromRow)
    }

    // MARK: - LearnedReference CRUD

    /// Insert a learned reference. `handle` and `addedBy` are required, and
    /// the lattice anchor is required per cookbook §2.7 (I-16): an empty
    /// `udcCode` is rejected with `LocusKitError.invalidContent` before the
    /// insert, mirroring `addAssociation`. Conflicting ids surface as
    /// duplicateKey. (`sourceCatalogID` is intentionally not validated
    /// non-empty — a reference may be learned without a catalog entry.)
    public func addLearnedReference(_ r: LearnedReference) async throws {
        try Self.validateNonEmpty(r.handle, label: "handle")
        try Self.validateNonEmpty(r.addedBy, label: "addedBy")
        try Self.validateNonEmpty(r.latticeAnchor.udcCode, label: "latticeAnchor.udcCode")
        _ = try await storage.rowStore.insert(
            table: "learned_references", values: Self.learnedReferenceValues(r))
    }

    /// Fetch a learned reference by id. Returns nil for an absent id — a
    /// routine query miss, not an error, mirroring `getAssociation`.
    public func getLearnedReference(id: String) async throws -> LearnedReference? {
        let rows = try await storage.rowStore.query(
            table: "learned_references",
            where: .eq(Column(table: "learned_references", name: "id"), .text(id))
        )
        return try rows.first.map(Self.learnedReferenceFromRow)
    }

    /// All non-tombstoned references learned from a source catalog entry,
    /// ordered by `filedAt` ascending. Resolves through
    /// `idx_learned_references_source`. Mirrors `associationsFrom`; the
    /// refresh-sweep query path for a source's references.
    public func learnedReferences(forSourceCatalogID sourceCatalogID: String) async throws -> [LearnedReference] {
        let rows = try await storage.rowStore.query(
            table: "learned_references",
            where: .and([
                .eq(Column(table: "learned_references", name: "sourceCatalogID"), .text(sourceCatalogID)),
                .isNull(Column(table: "learned_references", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(column: Column(table: "learned_references", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.learnedReferenceFromRow)
    }

    // MARK: - Source catalog CRUD

    /// Insert a source catalog entry. `handle` and `addedBy` are required,
    /// and the lattice anchor is required per cookbook §2.7 (I-16): an empty
    /// `udcCode` is rejected with `LocusKitError.invalidContent` before the
    /// insert, mirroring `addLearnedReference`. The genuine anchor recorded
    /// here is what the `learn` verb copies onto each `LearnedReference`, so
    /// an empty anchor here would propagate a fabricated identity — hence the
    /// hard rejection. Conflicting ids surface as duplicateKey.
    public func addSourceCatalogEntry(_ e: SourceCatalogEntry) async throws {
        try Self.validateNonEmpty(e.handle, label: "handle")
        try Self.validateNonEmpty(e.addedBy, label: "addedBy")
        try Self.validateNonEmpty(e.latticeAnchor.udcCode, label: "latticeAnchor.udcCode")
        _ = try await storage.rowStore.insert(
            table: "source_catalog", values: Self.sourceCatalogValues(e))
    }

    /// Fetch a source catalog entry by id. Returns nil for an absent id — a
    /// routine query miss, not an error, mirroring `getLearnedReference`.
    public func getSourceCatalogEntry(id: String) async throws -> SourceCatalogEntry? {
        let rows = try await storage.rowStore.query(
            table: "source_catalog",
            where: .eq(Column(table: "source_catalog", name: "id"), .text(id))
        )
        return try rows.first.map(Self.sourceCatalogFromRow)
    }

    /// Fetch the source catalog entry whose `handle` matches, if any.
    /// Resolves through `idx_source_catalog_handle`. The learn verb's
    /// source-resolution probe: "do we already catalog this source?".
    /// Returns the first match (handles are not unique-constrained; the
    /// learn verb catalogs at most one entry per handle), or nil.
    public func sourceCatalogEntry(forHandle handle: String) async throws -> SourceCatalogEntry? {
        let rows = try await storage.rowStore.query(
            table: "source_catalog",
            where: .eq(Column(table: "source_catalog", name: "handle"), .text(handle)),
            orderBy: [OrderClause(column: Column(table: "source_catalog", name: "firstSeen"), direction: .ascending)],
            limit: 1, offset: nil
        )
        return try rows.first.map(Self.sourceCatalogFromRow)
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

    // MARK: - Unfiltered full-corpus reads (recall surface)

    /// All proposals estate-wide, ordered by `filedAt` ascending.
    ///
    /// The MCP recall surface calls this to list every proposal without
    /// a target-row filter. Peer of the Rust `DrawerStore::all_proposals`.
    public func allProposals() async throws -> [Proposal] {
        let rows = try await storage.rowStore.query(
            table: "proposals",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "proposals", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.proposalFromRow)
    }

    /// All non-tombstoned associations estate-wide, ordered by `filedAt`
    /// ascending.
    ///
    /// The MCP recall surface calls this when no source wing/room filter is
    /// needed. Peer of the Rust `DrawerStore::all_associations`.
    public func allAssociations() async throws -> [Association] {
        let rows = try await storage.rowStore.query(
            table: "associations",
            where: .isNull(Column(table: "associations", name: "tombstonedAt")),
            orderBy: [OrderClause(column: Column(table: "associations", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.associationFromRow)
    }

    /// All non-tombstoned learned references estate-wide, ordered by `filedAt`
    /// ascending.
    ///
    /// The MCP recall surface calls this when no source catalog filter is
    /// needed. Peer of the Rust `DrawerStore::all_learned_references`.
    public func allLearnedReferences() async throws -> [LearnedReference] {
        let rows = try await storage.rowStore.query(
            table: "learned_references",
            where: .isNull(Column(table: "learned_references", name: "tombstonedAt")),
            orderBy: [OrderClause(column: Column(table: "learned_references", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        return try rows.map(Self.learnedReferenceFromRow)
    }

    /// All kg-facts estate-wide in the RowState Cluster-A (active) set —
    /// `g_state_cluster < RowState.activeClusterUpperBoundRaw` (the
    /// cluster-B floor, 16) — ordered by `filedAt` ascending. Keeps
    /// active/pending/contested/accepted; drops the retired B/C states.
    ///
    /// Mirrors `kgFacts(forDrawerID:)` but without the source-drawer
    /// predicate. Peer of the Rust `DrawerStore::all_kg_facts`.
    ///
    /// Telemetry: emits `locuskit.kgfact.query_result_count`
    /// (tag: query="all") when monitoring is enabled.
    public func allKGFacts() async throws -> [KGFact] {
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: .lt(Column(table: "kg_facts", name: "g_state_cluster"),
                       .int(Int64(RowState.activeClusterUpperBoundRaw))),
            orderBy: [OrderClause(column: Column(table: "kg_facts", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        let result = try rows.map(Self.kgFactFromRow)
        // query="all" labels the estate-wide KGFact query path.
        emitKGFactQuery(
            now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "all"
        )
        return result
    }

    /// All kg-facts estate-wide regardless of state — active AND retired
    /// (withdrawn, expired, decayed, superseded, rejected, tombstoned).
    ///
    /// This is the timeline read path: it returns the full lifecycle history
    /// of every fact ever filed, ordered by `filedAt` ascending so callers
    /// can trace how structured knowledge evolved over time.  Each returned
    /// `KGFact` carries its `adjectiveBitmap` intact; callers derive the
    /// lifecycle state via `(adjectiveBitmap & 0x3F)`, the raw RowState —
    /// values below `RowState.activeClusterUpperBoundRaw` (16) are
    /// Cluster-A active, values at or above it are retired (see
    /// `Adjectives.State`).
    ///
    /// Use `allKGFacts()` when you only need the currently-active set.
    /// Use this method only when you need the full history, e.g. to power
    /// `moot_fact_timeline`.
    ///
    /// Peer of the Rust `DrawerStore::all_kg_facts_including_retired`.
    ///
    /// Telemetry: emits `locuskit.kgfact.query_result_count`
    /// (tag: query="timeline") when monitoring is enabled.
    public func allKGFactsIncludingRetired() async throws -> [KGFact] {
        // No state-cluster predicate — return every row, all lifecycle states.
        let rows = try await storage.rowStore.query(
            table: "kg_facts",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "kg_facts", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
        )
        let result = try rows.map(Self.kgFactFromRow)
        // query="timeline" distinguishes this estate-wide all-history path
        // from the active-only "all" path in emitted telemetry.
        emitKGFactQuery(
            now: Date().timeIntervalSince1970,
            resultCount: result.count,
            estateTag: estateUuid.uuidString,
            queryLabel: "timeline"
        )
        return result
    }

    /// All non-tombstoned diary entries estate-wide, ordered by `filedAt`
    /// ascending.
    ///
    /// The MCP recall surface calls this when no agent-name filter is needed.
    /// Peer of the Rust `DrawerStore::all_diary_entries`.
    public func allDiaryEntries() async throws -> [DiaryEntry] {
        let rows = try await storage.rowStore.query(
            table: "diary",
            where: .isNull(Column(table: "diary", name: "tombstonedAt")),
            orderBy: [OrderClause(column: Column(table: "diary", name: "filedAt"), direction: .ascending)],
            limit: nil, offset: nil
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

    /// Batch-insert a set of recall trace rows in a single transaction.
    ///
    /// This is the performance-correct path for recall tracing: tracing every
    /// drawer in the filtered set with one INSERT per drawer is O(N) in the
    /// estate size and the dominant cost at scale (~135ms for 1,040 inserts on
    /// a 1,040-drawer estate). A batched insert amortises the transaction
    /// overhead across all rows, reducing the commit count from N to 1.
    ///
    /// Callers must supply only the bounded candidate set that was actually
    /// returned to the caller (the drained frontierK rows), not the full
    /// filtered set. The reward sweep only needs rows the caller received.
    ///
    /// Empty `items` is a no-op (no transaction opened, no storage touched).
    /// Conflicting ids in the batch surface as duplicateKey from the primary-key
    /// constraint; the transaction rolls back the entire batch on the first
    /// conflict, consistent with the single-insert contract.
    public func insertRecallTraces(_ items: [RecallTraceItem]) async throws {
        guard !items.isEmpty else { return }
        try await storage.transaction(isolation: .serializable) { txn in
            for item in items {
                _ = try await txn.rowStore.insert(
                    table: "recall_trace",
                    values: Self.recallTraceValues(item))
            }
        }
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

    /// Trace rows whose `recalledAt` falls in `[since, now]` (inclusive),
    /// ordered ascending (oldest first). This is the two-sided reward window
    /// the dreaming daemon uses: `since` is `now - tickInterval`; `now` is the
    /// deterministic clock the caller supplies. Rows outside the upper bound
    /// are excluded so future rows are never pulled into a past cycle.
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] {
        let rows = try await storage.rowStore.query(
            table: "recall_trace",
            where: .and([
                .gte(
                    Column(table: "recall_trace", name: "recalledAt"),
                    .timestamp(since)
                ),
                .lte(
                    Column(table: "recall_trace", name: "recalledAt"),
                    .timestamp(now)
                ),
            ]),
            orderBy: [OrderClause(
                column: Column(table: "recall_trace", name: "recalledAt"),
                direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return try rows.map(Self.recallTraceFromRow)
    }

    /// Delete recall-trace rows whose `recalledAt` is strictly before
    /// `cutoff`. Returns the number of rows deleted.
    ///
    /// Called by the dreaming daemon's reward sweep after it has processed
    /// the window so stale rows do not accumulate indefinitely. The cutoff
    /// is expressed as a `Date`; the comparison uses the TEXT ISO8601
    /// convention used by neighbouring trace queries (`.lt` on a lexicographic
    /// ISO8601 string is equivalent to a numeric less-than on the timestamps,
    /// provided all values are in UTC — which the fleet date-storage rule
    /// guarantees).
    ///
    /// - Parameter cutoff: rows with `recalledAt < cutoff` are deleted.
    /// - Returns: the number of rows deleted.
    public func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int {
        try await storage.rowStore.delete(
            table: "recall_trace",
            where: .lt(
                Column(table: "recall_trace", name: "recalledAt"),
                .timestamp(cutoff)
            )
        )
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

    /// Bulk-mark trace rows for a drawer target within a time window.
    ///
    /// Sets bit 0 (`flagUsed`) on every `recall_trace` row where
    /// `target == target` AND `recalledAt ∈ [since, now]` AND bit 0 is
    /// currently unset. This is the production reward-wiring path: ARIA
    /// decides "drawer D was used" and calls this once; the substrate
    /// flips whatever live trace rows exist for that drawer. Idempotent —
    /// rows already marked are skipped by the `bit0 = 0` predicate.
    ///
    /// The reward sweep keys by `target` (not trace-row id), so a single
    /// bulk UPDATE per target drawer is the correct granularity. The
    /// existing `markRecallTraceUsed(id:now:)` remains as the tested
    /// per-row primitive; this method is the ARIA path.
    ///
    /// - Parameters:
    ///   - target: the drawer id whose live trace rows to mark.
    ///   - since: lower bound (inclusive) of the time window.
    ///   - now:   upper bound (inclusive) of the time window; the
    ///            deterministic clock value the caller supplies.
    /// - Returns: number of rows whose bit was flipped (0 when all already
    ///            marked or no matching rows exist).
    public func markRecallTracesUsed(target: String, since: Date, now: Date) async throws -> Int {
        // Fetch matching trace rows in-memory and mark each one that is
        // not yet marked. PersistenceKit's row-store exposes a predicate
        // query + update surface, not arbitrary SQL; the fetch-then-update
        // pattern is consistent with markRecallTraceUsed(id:now:) and keeps
        // the query layer the single abstraction consumers of PersistenceKit
        // use. The window is bounded [since, now] so this is O(trace window)
        // not O(estate), and the trace table is bounded by retention pruning.
        let rows = try await storage.rowStore.query(
            table: "recall_trace",
            where: .and([
                .eq(Column(table: "recall_trace", name: "target"), .text(target)),
                .gte(
                    Column(table: "recall_trace", name: "recalledAt"),
                    .timestamp(since)
                ),
                .lte(
                    Column(table: "recall_trace", name: "recalledAt"),
                    .timestamp(now)
                ),
            ])
        )
        let items = try rows.map(Self.recallTraceFromRow)
        var touched = 0
        for item in items where !item.used {
            let updated = RecallTraceItem(
                id: item.id,
                target: item.target,
                recalledAt: item.recalledAt,
                score: item.score,
                operationalBitmap: item.operationalBitmap | RecallTraceItem.flagUsed
            )
            try await storage.rowStore.update(
                table: "recall_trace",
                values: Self.recallTraceValues(updated),
                where: .eq(Column(table: "recall_trace", name: "id"), .text(item.id))
            )
            touched += 1
        }
        return touched
    }

    /// Count all rows in the recall_trace table.
    ///
    /// Used by estate-status reporting so trace-table growth is observable
    /// without requiring the caller to load every row. Returns the total
    /// row count across all targets and windows; includes both used and
    /// unused rows (the distinction is visible in the dreaming reward report,
    /// not here). An empty table returns 0.
    public func countRecallTraces() async throws -> Int {
        // Pass `where: nil` to query all rows — the RowStore protocol
        // defaults `where` to nil when no predicate is supplied, which
        // matches a SELECT * with no WHERE clause.
        let rows = try await storage.rowStore.query(
            table: "recall_trace",
            where: nil
        )
        return rows.count
    }

    /// Count all rows in the `drawers` table using a SQL `COUNT(*)` query.
    ///
    /// Unlike `allDrawers(hydrationLevel:limit:)` this bypasses all row-decode
    /// logic, so corrupt rows (e.g. a poison timestamp) are still counted.
    /// This is intentional: the count is used as a "is the estate genuinely
    /// empty or is recall returning zero due to corruption?" sentinel in the
    /// vault-export fail-loud path. A non-zero count when recall returns 0
    /// means at least some rows are corrupt — the export should fail loud
    /// rather than report a successful 0-note export. Mirrors Rust
    /// `DrawerStore::count_drawer_rows`.
    public func countDrawerRows() async throws -> Int {
        try await storage.rowStore.count(table: "drawers", where: nil)
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
            let raw = try await getMeta(key: key.rawValue) ?? ""
            // Empty string means the manifest key is absent — return epoch-0
            // (the legitimate absent-value sentinel for manifest dates).
            // A non-empty string that fails to parse is unambiguous corruption:
            // throw instead of fabricating an epoch-0 date that would
            // misrepresent createdAt / lastModified timestamps.
            if raw.isEmpty { return Date(timeIntervalSince1970: 0) }
            guard let parsed = LKISO8601.date(from: raw) else {
                throw LocusKitError.corruptStoredValue(
                    table: "manifest",
                    column: key.rawValue,
                    storedText: raw
                )
            }
            return parsed
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

    private static func associationValues(_ a: Association) -> [String: TypedValue] {
        [
            "id": .text(a.id),
            "sourceWing": .text(a.sourceWing),
            "sourceRoom": .text(a.sourceRoom),
            "sourceDrawerId": a.sourceDrawerId.map { TypedValue.text($0) } ?? .null,
            "targetWing": .text(a.targetWing),
            "targetRoom": .text(a.targetRoom),
            "targetDrawerId": a.targetDrawerId.map { TypedValue.text($0) } ?? .null,
            "label": .text(a.label),
            "addedBy": .text(a.addedBy),
            "filedAt": .timestamp(a.filedAt),
            "tombstonedAt": a.tombstonedAt.map { TypedValue.timestamp($0) } ?? .null,
            "removedByBatch": a.removedByBatch.map { TypedValue.text($0) } ?? .null,
            "udcCode": .text(a.latticeAnchor.udcCode),
            "udcFacets": a.latticeAnchor.udcFacets.map { TypedValue.text($0) } ?? .null,
            "wikidataQID": a.latticeAnchor.wikidataQID.map { TypedValue.text($0) } ?? .null,
            "wikidataQidsSecondary": a.latticeAnchor.wikidataQidsSecondary.map { TypedValue.text($0) } ?? .null,
            "adjectiveBitmap": .bitmap(a.adjectiveBitmap),
            "operationalBitmap": .bitmap(a.operationalBitmap),
            "provenanceBitmap": .bitmap(a.provenanceBitmap)
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
            "operationalBitmap": .bitmap(e.operationalBitmap),
            // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
            // REAL nullable: bind the f64 value or NULL.
            "reward": e.reward.map { TypedValue.float($0) } ?? .null,
            "rewardProvenance": e.rewardProvenance.map { TypedValue.text($0) } ?? .null
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
            recalledAt: try date(table: "recall_traces", column: "recalledAt", row["recalledAt"]),
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

    private static func proposalValues(_ p: Proposal) -> [String: TypedValue] {
        [
            "id": .text(p.id),
            "targetRowID": .text(p.targetRowID),
            "justification": p.justification.map { TypedValue.text($0) } ?? .null,
            "candidateState": .bitmap(p.candidateState),
            "adjectiveBitmap": .bitmap(p.adjectiveBitmap),
            "operationalBitmap": .bitmap(p.operationalBitmap),
            "provenanceBitmap": .bitmap(p.provenanceBitmap),
            "udcCode": .text(p.latticeAnchor.udcCode),
            "udcFacets": p.latticeAnchor.udcFacets.map { TypedValue.text($0) } ?? .null,
            "wikidataQID": p.latticeAnchor.wikidataQID.map { TypedValue.text($0) } ?? .null,
            "wikidataQidsSecondary": p.latticeAnchor.wikidataQidsSecondary.map { TypedValue.text($0) } ?? .null,
            "filedAt": .timestamp(p.filedAt)
        ]
    }

    private static func learnedReferenceValues(_ r: LearnedReference) -> [String: TypedValue] {
        [
            "id": .text(r.id),
            "sourceCatalogID": .text(r.sourceCatalogID),
            "handle": .text(r.handle),
            "addedBy": .text(r.addedBy),
            "filedAt": .timestamp(r.filedAt),
            "tombstonedAt": r.tombstonedAt.map { TypedValue.timestamp($0) } ?? .null,
            "removedByBatch": r.removedByBatch.map { TypedValue.text($0) } ?? .null,
            "udcCode": .text(r.latticeAnchor.udcCode),
            "udcFacets": r.latticeAnchor.udcFacets.map { TypedValue.text($0) } ?? .null,
            "wikidataQID": r.latticeAnchor.wikidataQID.map { TypedValue.text($0) } ?? .null,
            "wikidataQidsSecondary": r.latticeAnchor.wikidataQidsSecondary.map { TypedValue.text($0) } ?? .null,
            "adjectiveBitmap": .bitmap(r.adjectiveBitmap),
            "operationalBitmap": .bitmap(r.operationalBitmap),
            "provenanceBitmap": .bitmap(r.provenanceBitmap)
        ]
    }

    private static func sourceCatalogValues(_ e: SourceCatalogEntry) -> [String: TypedValue] {
        [
            "id": .text(e.id),
            "kind": .int(Int64(e.kind.rawValue)),
            "handle": .text(e.handle),
            "addedBy": .text(e.addedBy),
            "firstSeen": .timestamp(e.firstSeen),
            "udcCode": .text(e.latticeAnchor.udcCode),
            "udcFacets": e.latticeAnchor.udcFacets.map { TypedValue.text($0) } ?? .null,
            "wikidataQID": e.latticeAnchor.wikidataQID.map { TypedValue.text($0) } ?? .null,
            "wikidataQidsSecondary": e.latticeAnchor.wikidataQidsSecondary.map { TypedValue.text($0) } ?? .null
        ]
    }

    // MARK: - Row decode helpers

    private static func drawerFromRow(_ row: StorageRow) throws -> Drawer {
        // lineageID — empty-string is the intentional "unset" sentinel and
        // becomes a fresh per-row UUID so unset rows never collapse onto one
        // lineage. A non-empty string that is not a valid UUID is unambiguous
        // corruption: throwing surfaces it rather than manufacturing a
        // lineage that never existed (which would mislead federation routing
        // and Bradley-Terry reward matching). Parity with PersistenceKit
        // commit 0ff08d93 (corruptStoredValue for UUID/timestamp parse failure).
        let rawLineage = string(row["lineageID"])
        let lineageID: UUID
        if rawLineage.isEmpty {
            lineageID = UUID()
        } else if let parsed = UUID(uuidString: rawLineage) {
            lineageID = parsed
        } else {
            throw LocusKitError.corruptStoredValue(
                table: "drawers",
                column: "lineageID",
                storedText: rawLineage
            )
        }
        let filedAt = try date(table: "drawers", column: "filedAt", row["filedAt"])
        return Drawer(
            id: string(row["id"]),
            content: string(row["content"]),
            wing: string(row["wing"]),
            room: string(row["room"]),
            sourceFile: optString(row["sourceFile"]),
            chunkIndex: optInt(row["chunkIndex"]),
            addedBy: string(row["addedBy"]),
            filedAt: filedAt,
            // Two-clock ingest (ING-01): backfill a NULL/absent eventTime
            // to this row's filedAt. Rows written before the column
            // existed read NULL here; the fallback gives them
            // eventTime == filedAt (the streaming-capture identity),
            // realising the "event_time = filed_at" backfill intent in
            // the read path rather than via an ALTER+UPDATE.
            eventTime: optDate(row["eventTime"]) ?? filedAt,
            embeddingModelID: string(row["embeddingModelID"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"]),
            provenance: int64(row["provenance"]),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            lineageID: lineageID,
            udcCode: string(row["udcCode"]),
            udcFacets: optString(row["udcFacets"]),
            wikidataQID: optString(row["wikidataQID"]),
            wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
        )
    }

    /// Decode a slice of `StorageRow` values into `Drawer` values, skipping
    /// rows that fail with `LocusKitError.corruptStoredValue`.
    ///
    /// ## Scan-level resilience (data-integrity fix 2026-06-18)
    ///
    /// The per-value strict decode in `drawerFromRow` and in PersistenceKit's
    /// SQLite backend (fail-loud, no silent identity lie) is preserved for POINT
    /// LOOKUPS. For CORPUS SCANS (`allDrawers`, `drawersIn(wing:)`, etc.) one
    /// corrupt row must NOT brick the entire estate. This helper implements the
    /// skip-and-log policy:
    ///
    ///   - `.corruptStoredValue` from `drawerFromRow` (e.g. a non-parseable
    ///     `lineageID` UUID) → log a warning via OSLog, skip the row, continue.
    ///   - Any other error (storage backend failure, SQL engine error) →
    ///     re-throw immediately. These indicate a systemic failure, not a data
    ///     problem, and the caller must surface them.
    ///
    /// Timestamp corruption (a `+58432-…` value in `filedAt`) is caught one
    /// level earlier by PersistenceKit's `readColumn` which returns a
    /// `.corruptStoredValue` `StorageError`; that error propagates through
    /// `query()` and surfaces as a throw before this function is called. When
    /// the upstream `query()` call itself throws `.corruptStoredValue`, the
    /// corpus-scan callers catch it and return an empty result plus a log. This
    /// function handles only decode failures that `drawerFromRow` surfaces after
    /// a clean `query()`.
    private static func decodeDrawerRowsSkipCorrupt(
        _ rows: [StorageRow],
        scan: String
    ) throws -> [Drawer] {
        var out = [Drawer]()
        out.reserveCapacity(rows.count)
        for row in rows {
            do {
                out.append(try drawerFromRow(row))
            } catch LocusKitError.corruptStoredValue(let table, let column, let storedText) {
                drawerStoreLog.warning(
                    "[\(scan, privacy: .public)] Skipping corrupt drawer row (table='\(table, privacy: .public)' column='\(column, privacy: .public)' storedText='\(storedText, privacy: .public)'). The row will not appear in corpus scans until repaired."
                )
                // Continue — skip this row, collect the rest.
            } catch {
                throw error // systemic failure — re-throw
            }
        }
        return out
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
            filedAt: try date(table: "tunnels", column: "filedAt", row["filedAt"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"])
        )
    }

    private static func associationFromRow(_ row: StorageRow) throws -> Association {
        Association(
            id: string(row["id"]),
            sourceWing: string(row["sourceWing"]),
            sourceRoom: string(row["sourceRoom"]),
            sourceDrawerId: optString(row["sourceDrawerId"]),
            targetWing: string(row["targetWing"]),
            targetRoom: string(row["targetRoom"]),
            targetDrawerId: optString(row["targetDrawerId"]),
            label: string(row["label"]),
            latticeAnchor: LatticeAnchor(
                udcCode: string(row["udcCode"]),
                udcFacets: optString(row["udcFacets"]),
                wikidataQID: optString(row["wikidataQID"]),
                wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
            ),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            provenanceBitmap: int64(row["provenanceBitmap"]),
            addedBy: string(row["addedBy"]),
            filedAt: try date(table: "associations", column: "filedAt", row["filedAt"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"])
        )
    }

    private static func learnedReferenceFromRow(_ row: StorageRow) throws -> LearnedReference {
        LearnedReference(
            id: string(row["id"]),
            sourceCatalogID: string(row["sourceCatalogID"]),
            handle: string(row["handle"]),
            latticeAnchor: LatticeAnchor(
                udcCode: string(row["udcCode"]),
                udcFacets: optString(row["udcFacets"]),
                wikidataQID: optString(row["wikidataQID"]),
                wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
            ),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            provenanceBitmap: int64(row["provenanceBitmap"]),
            addedBy: string(row["addedBy"]),
            filedAt: try date(table: "learned_references", column: "filedAt", row["filedAt"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"])
        )
    }

    private static func sourceCatalogFromRow(_ row: StorageRow) throws -> SourceCatalogEntry {
        SourceCatalogEntry(
            id: string(row["id"]),
            kind: SourceKind.fromRaw(Int(int64(row["kind"]))),
            handle: string(row["handle"]),
            latticeAnchor: LatticeAnchor(
                udcCode: string(row["udcCode"]),
                udcFacets: optString(row["udcFacets"]),
                wikidataQID: optString(row["wikidataQID"]),
                wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
            ),
            firstSeen: try date(table: "source_catalog", column: "firstSeen", row["firstSeen"]),
            addedBy: string(row["addedBy"])
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
            filedAt: try date(table: "diary", column: "filedAt", row["filedAt"]),
            embeddingModelID: string(row["embeddingModelID"]),
            tombstonedAt: optDate(row["tombstonedAt"]),
            removedByBatch: optString(row["removedByBatch"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            // Explicit reward channel (NEURONKIT_SPEC § 3.1 step 1a).
            // SQLite returns .float (Double) or .null; optDouble handles both.
            reward: optDouble(row["reward"]),
            rewardProvenance: optString(row["rewardProvenance"])
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
            filedAt: try date(table: "kg_facts", column: "filedAt", row["filedAt"])
        )
    }

    private static func proposalFromRow(_ row: StorageRow) throws -> Proposal {
        Proposal(
            id: string(row["id"]),
            targetRowID: string(row["targetRowID"]),
            justification: optString(row["justification"]),
            candidateState: int64(row["candidateState"]),
            latticeAnchor: LatticeAnchor(
                udcCode: string(row["udcCode"]),
                udcFacets: optString(row["udcFacets"]),
                wikidataQID: optString(row["wikidataQID"]),
                wikidataQidsSecondary: optString(row["wikidataQidsSecondary"])
            ),
            adjectiveBitmap: int64(row["adjectiveBitmap"]),
            operationalBitmap: int64(row["operationalBitmap"]),
            provenanceBitmap: int64(row["provenanceBitmap"]),
            filedAt: try date(table: "proposals", column: "filedAt", row["filedAt"])
        )
    }

    // MARK: - TypedValue extraction

    /// These read a StorageRow cell into the Swift type LocusKit's
    /// value structs expect. PersistenceKit returns typed values already
    /// (the SQLite backend decodes bitmap/timestamp/uuid columns to
    /// their declared cases), so these are total projections with
    /// safe fallbacks rather than parsers.
    ///
    /// INTENTIONAL CONTRACT: the empty-string sentinel for udcCode and
    /// the .text/.int type-tolerant decode of VALID values remain as
    /// non-throwing total projections. Only `date(table:column:value:)`
    /// and the lineageID path in `drawerFromRow` throw — and only when
    /// a non-empty stored TEXT string cannot be parsed to its declared
    /// type, which is unambiguous corruption rather than an absent value.

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

    /// Decode a required (non-nullable) date column from a `StorageRow` cell.
    ///
    /// - `.timestamp`: already decoded by PersistenceKit — returned directly.
    /// - `.text("")` or absent: column is NULL or an empty-string sentinel —
    ///   returns `Date(timeIntervalSince1970: 0)`. This is the legitimate
    ///   absent-value path, not corruption.
    /// - `.text(s)` where `s` is a non-empty, non-parseable ISO 8601 string:
    ///   the stored value is corrupt. Throws
    ///   `LocusKitError.corruptStoredValue` so the caller surfaces the
    ///   problem rather than silently fabricating an epoch-0 date that
    ///   could misrepresent tombstone state or ordering.
    private static func date(table: String, column: String, _ v: TypedValue?) throws -> Date {
        switch v {
        case .timestamp(let d): return d
        case .text(let s):
            if s.isEmpty { return Date(timeIntervalSince1970: 0) }
            guard let parsed = LKISO8601.date(from: s) else {
                throw LocusKitError.corruptStoredValue(
                    table: table,
                    column: column,
                    storedText: s
                )
            }
            return parsed
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

    // MARK: - Temporal reads

    /// Returns the `Fingerprint256` of every non-tombstoned drawer whose
    /// effective capture time falls in `window`, in ascending row-id order.
    ///
    /// Effective capture time: `eventTime` when present; `filedAt` otherwise
    /// (ING-01 two-clock backfill — rows written before the eventTime column
    /// existed get `eventTime = filedAt` on the read path). Feeds the
    /// MomentSummary OR-fold (substrate math §15.1 predicate π₁).
    ///
    /// - Parameter window: closed `[lower, upper]` Date range; both bounds
    ///   are inclusive.
    /// - Returns: fingerprints in ascending SQLite row-id order.
    public func fingerprintsCaptured(in window: ClosedRange<Date>) async throws -> [Fingerprint256] {
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                Self.captureTimeInRangePredicate(lower: window.lowerBound, upper: window.upperBound),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [OrderClause(
                column: Column(table: "drawers", name: "id"),
                direction: .ascending
            )],
            limit: nil,
            offset: nil
        )
        // Construct on-demand — one FNV hash, cheap and correct.
        let families = EstateFingerprintFamilies(estateUUID: estateUuid.uuidString)
        return try rows.map { row in
            let drawer = try Self.drawerFromRow(row)
            return families.fingerprint(of: drawer)
        }
    }

    /// Returns one Bool per time bucket (oldest first): whether any
    /// non-tombstoned drawer captured in that bucket has the given
    /// fingerprint bit set.
    ///
    /// Feeds the FFT rhythm spectrum (substrate math §15.5).
    ///
    /// **Bucket layout** (oldest first, `i` ∈ `[0, bucketCount)`):
    /// ```
    /// lowerᵢ = endingAt − (bucketCount − i) × bucketSeconds
    /// upperᵢ = endingAt − (bucketCount − i − 1) × bucketSeconds
    /// ```
    /// Interval: `[lowerᵢ, upperᵢ)` — lower inclusive, upper exclusive — so
    /// a capture exactly on a shared boundary belongs to the later
    /// (higher-timestamp) bucket. The final bucket is `[lower, endingAt]`
    /// (inclusive upper).
    ///
    /// Bit layout: block0 covers bits 0–63, block1 covers 64–127,
    /// block2 covers 128–191, block3 covers 192–255.
    ///
    /// - Parameters:
    ///   - bit: fingerprint bit index in `[0, 255]`.
    ///   - bucketSeconds: width of each bucket in seconds; must be ≥ 1.
    ///   - bucketCount: number of buckets; returns `[]` when 0.
    ///   - endingAt: upper bound of the newest bucket (caller-supplied
    ///     deterministic clock — never call `Date()` inside the kit).
    /// - Throws: `LocusKitError.invalidContent` when `bit ∉ [0, 255]` or
    ///   `bucketSeconds < 1`.
    public func fingerprintBitSeries(
        bit: Int,
        bucketSeconds: Int,
        bucketCount: Int,
        endingAt: Date
    ) async throws -> [Bool] {
        guard bit >= 0 && bit <= 255 else {
            throw LocusKitError.invalidContent(
                "fingerprintBitSeries: bit \(bit) out of range [0, 255]"
            )
        }
        guard bucketSeconds >= 1 else {
            throw LocusKitError.invalidContent(
                "fingerprintBitSeries: bucketSeconds \(bucketSeconds) must be ≥ 1"
            )
        }
        guard bucketCount > 0 else { return [] }

        let windowStart = endingAt.addingTimeInterval(
            Double(-bucketCount) * Double(bucketSeconds)
        )
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .and([
                Self.captureTimeInRangePredicate(lower: windowStart, upper: endingAt),
                .isNull(Column(table: "drawers", name: "tombstonedAt"))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        let families = EstateFingerprintFamilies(estateUUID: estateUuid.uuidString)
        // Pre-compute (effectiveCaptureTime, fingerprint) for all drawers in the window.
        // drawer.eventTime already carries the ING-01 filedAt backfill from drawerFromRow.
        let captures: [(time: Date, fp: Fingerprint256)] = try rows.map { row in
            let drawer = try Self.drawerFromRow(row)
            return (time: drawer.eventTime, fp: families.fingerprint(of: drawer))
        }

        return (0..<bucketCount).map { i in
            let bucketLower = endingAt.addingTimeInterval(
                Double(-(bucketCount - i)) * Double(bucketSeconds)
            )
            let isLastBucket = (i == bucketCount - 1)
            // Check whether any capture falls in this bucket AND has the target bit set.
            return captures.contains { entry in
                let inBucket: Bool
                if isLastBucket {
                    // Final bucket: [lower, endingAt] inclusive upper.
                    inBucket = entry.time >= bucketLower && entry.time <= endingAt
                } else {
                    // [lower, upper): exclusive upper so edge belongs to the later bucket.
                    let bucketUpper = endingAt.addingTimeInterval(
                        Double(-(bucketCount - i - 1)) * Double(bucketSeconds)
                    )
                    inBucket = entry.time >= bucketLower && entry.time < bucketUpper
                }
                return inBucket && Self.isBitSet(entry.fp, bit: bit)
            }
        }
    }

    /// Returns true when the given bit (0-based) is set in `fp`.
    /// Callers must pre-validate that bit ∈ [0, 255].
    /// Layout: block0 = bits 0–63, block1 = 64–127, block2 = 128–191, block3 = 192–255.
    private static func isBitSet(_ fp: Fingerprint256, bit: Int) -> Bool {
        switch bit {
        case 0..<64:    return (fp.block0 >> UInt64(bit)) & 1 != 0
        case 64..<128:  return (fp.block1 >> UInt64(bit - 64)) & 1 != 0
        case 128..<192: return (fp.block2 >> UInt64(bit - 128)) & 1 != 0
        default:        return (fp.block3 >> UInt64(bit - 192)) & 1 != 0
        }
    }

    /// Builds a predicate matching drawers whose effective capture time falls
    /// in [lower, upper] (both inclusive). The OR branch handles rows with a
    /// NULL eventTime column by falling back to filedAt (ING-01 two-clock
    /// backfill: rows written before eventTime existed have eventTime = filedAt).
    private static func captureTimeInRangePredicate(lower: Date, upper: Date) -> StoragePredicate {
        let etCol = Column(table: "drawers", name: "eventTime")
        let faCol = Column(table: "drawers", name: "filedAt")
        return .or([
            .and([
                .isNotNull(etCol),
                .gte(etCol, .timestamp(lower)),
                .lte(etCol, .timestamp(upper))
            ]),
            .and([
                .isNull(etCol),
                .gte(faCol, .timestamp(lower)),
                .lte(faCol, .timestamp(upper))
            ])
        ])
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
