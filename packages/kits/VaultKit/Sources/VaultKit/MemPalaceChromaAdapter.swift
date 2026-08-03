import Foundation
import SQLite3

// MemPalaceChromaAdapter — the direct MemPalace → MOOTx01 importer
// (read side of the MemPalace migration lane).
//
// MemPalace persists THREE stores under one palace root (`~/.mempalace`):
//
//   1. `palace/chroma.sqlite3` — a standard ChromaDB SQLite file. Two
//      collections: `mempalace_drawers` (drawer chunks, including
//      `type=diary_entry` rows) and `mempalace_closets` (closet
//      summaries). Per-row metadata lives in `embedding_metadata`
//      (key / string_value / int_value / float_value / bool_value,
//      joined to `embeddings` by rowid); the full text rides the
//      metadata key `chroma:document`.
//   2. `tunnels.json` — explicit cross-wing links, an atomic-replace
//      JSON list (MemPalace `palace_graph.py`).
//   3. `knowledge_graph.sqlite3` — KG facts: tables `entities` and
//      `triples` (MemPalace `knowledge_graph.py`).
//
// This adapter reads all three READ-ONLY (`SQLITE_OPEN_READONLY`; the
// palace is never written) and maps every field of every store into
// `NoteIR` — the full-fidelity contract: nothing is dropped; anything
// without a native `NoteIR` home rides `frontmatter` verbatim.
//
// ## Field → NoteIR mapping (the complete contract, shared with the
// ## Rust port `rust/src/mem_palace_chroma_adapter.rs`)
//
// ### Store 1 — chroma.sqlite3 (one NoteIR per embedding row)
//
// | MemPalace field            | NoteIR home                                            |
// |----------------------------|--------------------------------------------------------|
// | embedding_id               | `stableSourceKey` (raw, un-namespaced)                 |
// | chroma:document            | `body` (single `"markdown"` block)                     |
// | wing                       | `frontmatter["wing"]` + `pathComponents[0]`            |
// | hall                       | `frontmatter["hall"]` + `pathComponents` (when present)|
// | room                       | `frontmatter["room"]` + `pathComponents` last          |
// | wing/hall/room joined "/"  | `originalPath`                                         |
// | filed_at                   | `frontmatter["filed_at"]` verbatim + `originDate`      |
// |                            | (normalized, see `canonicalISO8601(fromMemPalace:)`)   |
// | date (diary rows)          | `frontmatter["date"]` verbatim (+ `originDate`         |
// |                            | fallback when `filed_at` is absent/unparseable)        |
// | source_file                | `frontmatter["source_file"]` + `source` (`SourceRef`,  |
// |                            | empty `contentHash` — MemPalace records no hash)       |
// | source_mtime (REAL)        | `frontmatter["source_mtime"]` (SQLite text form)       |
// | chunk_index (INT)          | `frontmatter["chunk_index"]`                           |
// | added_by                   | `frontmatter["added_by"]`                              |
// | agent (diary rows)         | `frontmatter["agent"]`                                 |
// | topic (diary rows)         | `frontmatter["topic"]`                                 |
// | type (diary rows)          | `frontmatter["type"]`; drives `kind`                   |
// | drawer_count (closets)     | `frontmatter["drawer_count"]`                          |
// | normalize_version (INT)    | `frontmatter["normalize_version"]`                     |
// | entities ("A;B;C")         | `frontmatter["entities"]` verbatim + one `FactIR`      |
// |                            | per entity: (entity, "mentioned_in", embedding_id)     |
// | any other metadata key     | `frontmatter[key]` verbatim (future-proof: unknown     |
// |                            | keys ride through, never dropped)                      |
// | collection membership      | `kind`: `"closet_summary"` for the closets             |
// |                            | collection; `"diary_entry"` when `type=diary_entry`;   |
// |                            | `"drawer"` otherwise                                   |
//
// ### Store 2 — tunnels.json (one NoteIR per tunnel)
//
// | MemPalace field | NoteIR home                                               |
// |-----------------|-----------------------------------------------------------|
// | id              | `stableSourceKey` (raw)                                   |
// | label           | `body` (single block) + `links[0].raw`                    |
// | target.wing/room| `links[0].target` = `"<wing>/<room>"` +                   |
// |                 | `frontmatter["target_wing"]` / `["target_room"]`          |
// | source.wing/room| `pathComponents` = `[wing, room]` (drawer placement) +    |
// |                 | `frontmatter["source_wing"]` / `["source_room"]`          |
// | created_at      | `frontmatter["created_at"]` verbatim + `originDate`       |
// | (kind)          | `"tunnel"`                                                |
//
// An empty/absent label falls back to `"<src> -> <tgt>"` for `body` and
// `links[0].raw` so invariant I-5 (non-empty content) and the tunnel
// label both hold.
//
// ### Store 3 — knowledge_graph.sqlite3
//
// `entities` (one NoteIR per row, kind `"kg_entity"`, placed under
// `knowledge_graph/entities`):
//
// | column      | NoteIR home                                        |
// |-------------|-----------------------------------------------------|
// | id          | `stableSourceKey` (raw)                             |
// | name        | `body` (falls back to `id` when empty, I-5) +       |
// |             | `frontmatter["name"]`                               |
// | type        | `frontmatter["type"]`                               |
// | properties  | `frontmatter["properties"]` (the JSON text verbatim)|
// | created_at  | `frontmatter["created_at"]` verbatim + `originDate` |
//
// `triples` (one NoteIR per row, kind `"kg_triple"`, placed under
// `knowledge_graph/triples`):
//
// | column           | NoteIR home                                          |
// |------------------|-------------------------------------------------------|
// | id               | `stableSourceKey` (raw)                               |
// | subject          | `facts[0].subject` (+ rendered into `body`)           |
// | predicate        | `facts[0].predicate` (+ `body`)                       |
// | object           | `facts[0].object` (+ `body`)                          |
// | valid_from       | `facts[0].validFrom` (verbatim — MemPalace stores     |
// |                  | date-only strings; pass-through, not re-formatted)    |
// | valid_to         | `facts[0].validTo` (verbatim)                         |
// | confidence       | `facts[0].confidence`                                 |
// | source_closet    | `frontmatter["source_closet"]`                        |
// | source_file      | `frontmatter["source_file"]` + `source` (`SourceRef`) |
// | source_drawer_id | `frontmatter["source_drawer_id"]`                     |
// | adapter_name     | `frontmatter["adapter_name"]`                         |
// | extracted_at     | `frontmatter["extracted_at"]` verbatim + `originDate` |
//
// ## Numeric metadata stringification
//
// `int_value` / `float_value` / `bool_value` are converted to text BY
// SQLITE ITSELF (`CAST(... AS TEXT)` in the query), not by Swift/Rust
// float formatting. Both ports therefore produce byte-identical
// frontmatter for REAL values like `source_mtime` — SQLite's
// shortest-round-trip float rendering is one shared implementation,
// where Swift's `String(Double)` and Rust's `Display` could disagree
// on edge cases (e.g. integral floats: "1.0" vs "1").
//
// ## Trust posture: the palace root is UNTRUSTED input
//
// A palace root is a directory handed to the importer from outside the
// estate. "The user chose it" covers a palace they were given, not only
// one they built — so its size and shape are an attacker-influenced
// input, not a fact this code may assume. Every read below is therefore
// bounded by `MemPalaceImportLimits` and accounted against one
// `MemPalaceImportBudget` for the whole import: a maximum `tunnels.json`
// size checked BEFORE the file is opened, a maximum row count, a maximum
// total of materialized bytes, and a SQLite progress guard that abandons
// a query which burns virtual-machine steps without returning rows.
//
// The palace is opened read-only and never written, so this adapter
// cannot mutate it and does not write outside the estate. Availability
// was the exposure these bounds close: before them the importer would
// read an oversized `tunnels.json`, every SQLite row, and every `NoteIR`
// into memory with no ceiling of any kind.
//
// One residual is worth knowing rather than assuming away: the queries
// below run against an attacker-authored schema, so a palace that
// defines `embeddings` / `collections` / `entities` / `triples` as VIEWS
// executes its own SQL inside this connection. Read-only blocks writes
// and no filesystem-reach function is enabled, which leaves SQLite's own
// parser surface plus availability — and the step budget bounds the
// availability half. `PRAGMA trusted_schema=OFF` would close the rest;
// it is deliberately NOT set here because it changes how SQLite treats a
// foreign file and a real palace has never needed it. Do not upgrade
// this comment to "no confidentiality or integrity risk" without it. Every limit below fails with an error naming the limit AND
// the observed value, because an import that dies on an unexplained cap
// is worse than one that is slow.
//
// ## Why direct SQLite here (and not PersistenceKit)
//
// PersistenceKit's public surface is a `RowStore` over schemas the kit
// itself declares and migrates — it cannot open a foreign, third-party
// SQLite file (ChromaDB's schema) read-only. Reading an external tool's
// file format is codec territory and belongs to the adapter (the same
// boundary that lets `ExchangeAdapter` parse a foreign JSON file), so
// this adapter speaks the system SQLite C API directly — exactly as
// PersistenceKitSQLite itself does — with `SQLITE_OPEN_READONLY` so the
// palace can never be mutated.
/// The ceilings one MemPalace import may not cross.
///
/// Every value is a named constant with a documented default, and every
/// default is sized against a REAL palace (`~/.mempalace`, measured
/// 2026-08-03) rather than invented: 50,381 embeddings across 506,204
/// `embedding_metadata` rows, 40,700,592 bytes of metadata values,
/// ~8,850,000 SQLite virtual-machine steps for the whole palace, and a
/// 3,149-byte `tunnels.json`. Each constant below states its headroom
/// over that measurement. Defaults that reject a real palace would be a
/// broken feature rather than a control, so the headroom is deliberate.
///
/// The Rust port's `MemPalaceImportLimits` carries the identical values;
/// divergent caps would mean an import that succeeds in one port and
/// fails in the other.
public struct MemPalaceImportLimits: Sendable, Equatable {

    /// Maximum size of `tunnels.json`, checked BEFORE the file is read.
    ///
    /// Default 64 MiB against a measured 3,149 bytes — a 21,311x factor
    /// that looks extreme only because MemPalace writes one record per
    /// explicit cross-wing link, so the file is tiny in every real
    /// palace. 64 MiB still admits roughly 130,000 tunnel records at
    /// ~500 bytes each. The cap exists to reject a multi-gigabyte file
    /// before it is opened, not to be tight.
    public var maxTunnelsJSONBytes: Int

    /// Maximum SQLite rows read across the WHOLE import (both chroma
    /// collections plus both knowledge-graph tables), not per query.
    ///
    /// Default 20,000,000 against a measured 506,204 rows for the whole
    /// palace — a 39.5x factor. A palace would need roughly 2,000,000
    /// embeddings to reach it.
    public var maxImportRows: Int

    /// Maximum bytes of SQLite column text materialized across the whole
    /// import.
    ///
    /// Default 1 GiB against a measured 40,700,592 bytes — a 26.4x
    /// factor. This is the cap that actually bounds memory: the row
    /// count alone does not, because one row may carry an arbitrarily
    /// large text or blob value.
    public var maxMaterializedBytes: Int

    /// Maximum SQLite virtual-machine steps before a query is abandoned.
    ///
    /// Default 1,000,000,000 against a measured ~8,850,000 for the whole
    /// palace — a 113x factor, roughly 30-60 seconds of work at the
    /// measured throughput. This catches what the row and byte caps
    /// cannot: a corrupt or hostile database whose query plan degenerates
    /// (a missing index turning the metadata join into a nested loop) and
    /// burns instructions WITHOUT returning rows, so neither the row
    /// counter nor the byte counter ever advances.
    public var maxSQLiteVMSteps: Int

    /// SQLite virtual-machine steps between progress-handler callbacks.
    ///
    /// Default 1,000,000, which at the full step budget fires the handler
    /// about a thousand times — frequent enough to abandon a pathological
    /// query promptly, rare enough that the callback itself costs
    /// nothing measurable.
    public var sqliteProgressGrain: Int32

    /// Construct a limit set. The defaults are the measured-and-justified
    /// values documented on each property.
    public init(
        maxTunnelsJSONBytes: Int = 67_108_864,
        maxImportRows: Int = 20_000_000,
        maxMaterializedBytes: Int = 1_073_741_824,
        maxSQLiteVMSteps: Int = 1_000_000_000,
        sqliteProgressGrain: Int32 = 1_000_000
    ) {
        self.maxTunnelsJSONBytes = maxTunnelsJSONBytes
        self.maxImportRows = maxImportRows
        self.maxMaterializedBytes = maxMaterializedBytes
        self.maxSQLiteVMSteps = maxSQLiteVMSteps
        self.sqliteProgressGrain = sqliteProgressGrain
    }

    /// The shipping defaults.
    public static let `default` = MemPalaceImportLimits()
}

/// The running totals for one import, charged as rows and bytes arrive.
///
/// A reference type on purpose: ONE budget is threaded through every read
/// of a single palace — both chroma collections, `tunnels.json`, and both
/// knowledge-graph tables — so `maxImportRows` and `maxMaterializedBytes`
/// are real totals for the import rather than a per-query allowance that
/// would silently multiply by the number of stores.
public final class MemPalaceImportBudget {

    /// The ceilings this budget enforces.
    public let limits: MemPalaceImportLimits

    /// Rows charged so far, across every store.
    public private(set) var rowsRead = 0

    /// Column-text bytes charged so far, across every store.
    public private(set) var bytesMaterialized = 0

    /// Progress-handler callbacks observed so far. Multiplied by the
    /// grain this is the virtual-machine step count; it is a class
    /// property rather than a local so the C progress callback (which
    /// receives only an opaque pointer) can reach it.
    fileprivate var progressTicks = 0

    /// Set when the progress handler interrupted a query, so the caller
    /// can report the step limit by name instead of SQLite's generic
    /// "interrupted" diagnostic.
    fileprivate var interruptedByStepLimit = false

    /// Start a fresh budget. Defaults to the shipping limits.
    public init(limits: MemPalaceImportLimits = .default) {
        self.limits = limits
    }

    /// Charge one row and its column bytes, or throw naming the limit
    /// that was crossed and the value observed when it was crossed.
    func chargeRow(byteCount: Int) throws {
        rowsRead += 1
        if rowsRead > limits.maxImportRows {
            throw VaultKitError.adapterError(
                "MemPalace import limit exceeded: read \(rowsRead) SQLite rows, over the "
                + "maxImportRows limit of \(limits.maxImportRows). The palace is larger than "
                + "this importer will materialize; raise MemPalaceImportLimits.maxImportRows "
                + "to import it.")
        }
        bytesMaterialized += byteCount
        if bytesMaterialized > limits.maxMaterializedBytes {
            throw VaultKitError.adapterError(
                "MemPalace import limit exceeded: materialized \(bytesMaterialized) bytes of "
                + "SQLite column text, over the maxMaterializedBytes limit of "
                + "\(limits.maxMaterializedBytes). Raise "
                + "MemPalaceImportLimits.maxMaterializedBytes to import this palace.")
        }
    }

    /// Charge a whole file read against `maxTunnelsJSONBytes`. Called
    /// with the size from the filesystem BEFORE the file is opened, so an
    /// oversized file is never read into memory at all.
    func chargeTunnelsFile(byteCount: Int, path: String) throws {
        if byteCount > limits.maxTunnelsJSONBytes {
            throw VaultKitError.adapterError(
                "MemPalace import limit exceeded: tunnels.json at \(path) is \(byteCount) "
                + "bytes, over the maxTunnelsJSONBytes limit of "
                + "\(limits.maxTunnelsJSONBytes). The file was not read. Raise "
                + "MemPalaceImportLimits.maxTunnelsJSONBytes to import this palace.")
        }
        bytesMaterialized += byteCount
        if bytesMaterialized > limits.maxMaterializedBytes {
            throw VaultKitError.adapterError(
                "MemPalace import limit exceeded: materialized \(bytesMaterialized) bytes "
                + "after reading tunnels.json at \(path), over the maxMaterializedBytes "
                + "limit of \(limits.maxMaterializedBytes).")
        }
    }

    /// The error for a query the progress handler interrupted, naming the
    /// step limit rather than surfacing SQLite's generic diagnostic.
    func stepLimitError() -> VaultKitError {
        VaultKitError.adapterError(
            "MemPalace import limit exceeded: a SQLite query ran past the maxSQLiteVMSteps "
            + "limit of \(limits.maxSQLiteVMSteps) virtual-machine steps and was "
            + "interrupted. The palace's database is degenerate or hostile — a query plan "
            + "that burns steps without returning rows. Raise "
            + "MemPalaceImportLimits.maxSQLiteVMSteps only if the palace is known good.")
    }
}

/// The C progress callback. SQLite hands back only the opaque context
/// pointer, so the budget rides through it unretained — the connection
/// that installs this handler outlives every query it runs, and clears
/// the handler before closing.
private func memPalaceProgressHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let budget = Unmanaged<MemPalaceImportBudget>.fromOpaque(context).takeUnretainedValue()
    budget.progressTicks += 1
    // Non-zero aborts the running statement with SQLITE_INTERRUPT.
    if budget.progressTicks * Int(budget.limits.sqliteProgressGrain)
        > budget.limits.maxSQLiteVMSteps {
        budget.interruptedByStepLimit = true
        return 1
    }
    return 0
}

public struct MemPalaceChromaAdapter: VaultAdapter {

    /// Name of the ChromaDB collection holding drawer chunks.
    public var drawersCollection: String

    /// Name of the ChromaDB collection holding closet summaries.
    public var closetsCollection: String

    /// The ceilings this adapter enforces on an untrusted palace root.
    /// Configurable so a caller with a known-good oversized palace can
    /// raise them deliberately, and so the limits are testable without
    /// building a twenty-million-row fixture.
    public var limits: MemPalaceImportLimits

    public init(
        drawersCollection: String = "mempalace_drawers",
        closetsCollection: String = "mempalace_closets",
        limits: MemPalaceImportLimits = .default
    ) {
        self.drawersCollection = drawersCollection
        self.closetsCollection = closetsCollection
        self.limits = limits
    }

    // MARK: - Palace layout (relative to the palace root)

    /// `chroma.sqlite3` location under the palace root. Required.
    static let chromaRelativePath = "palace/chroma.sqlite3"

    /// `tunnels.json` location under the palace root. Optional — a palace
    /// with no explicit tunnels has no file (MemPalace `_load_tunnels`
    /// treats absence as the empty list; so does this adapter).
    static let tunnelsRelativePath = "tunnels.json"

    /// `knowledge_graph.sqlite3` location under the palace root. Optional —
    /// a palace whose KG was never populated has no file.
    static let knowledgeGraphRelativePath = "knowledge_graph.sqlite3"

    // MARK: - VaultAdapter

    /// Read one whole palace into canonical notes.
    ///
    /// - Parameter vaultURL: the PALACE ROOT directory (e.g. `~/.mempalace`),
    ///   containing `palace/chroma.sqlite3` (required), `tunnels.json`
    ///   (optional), and `knowledge_graph.sqlite3` (optional).
    /// - Returns: one `NoteIR` per chroma row, tunnel, KG entity, and KG
    ///   triple — sorted by `stableSourceKey` UTF-8 bytes (the
    ///   `VaultAdapter` deterministic-order contract; byte order matches
    ///   Rust's `str` ordering so both ports emit the same sequence).
    public func toIR(vaultURL: URL) throws -> [NoteIR] {
        let chromaURL = vaultURL.appendingPathComponent(Self.chromaRelativePath)
        guard FileManager.default.fileExists(atPath: chromaURL.path) else {
            throw VaultKitError.adapterError(
                "MemPalace chroma store not found at \(chromaURL.path)")
        }

        // ONE budget for the whole palace: the row and byte ceilings are
        // totals for this import, not a fresh allowance per store.
        let budget = MemPalaceImportBudget(limits: limits)

        var notes = try chromaNotes(dbPath: chromaURL.path, budget: budget)
        notes += try Self.tunnelNotes(
            jsonURL: vaultURL.appendingPathComponent(Self.tunnelsRelativePath),
            budget: budget)
        notes += try Self.knowledgeGraphNotes(
            dbPath: vaultURL.appendingPathComponent(Self.knowledgeGraphRelativePath).path,
            budget: budget)

        // Deterministic order by stableSourceKey UTF-8 bytes — NOT Swift's
        // localized/canonical String `<` — so the sequence is identical to
        // the Rust port's `sort_by` over `&str` (which is byte order).
        notes.sort {
            $0.stableSourceKey.utf8.lexicographicallyPrecedes($1.stableSourceKey.utf8)
        }
        return notes
    }

    /// MemPalace is an external SOURCE store: this adapter is import-only.
    /// Writing notes back into a live ChromaDB file would bypass MemPalace's
    /// own write path (embeddings, dedup, sweeper) and corrupt the palace,
    /// so the write direction is rejected loudly rather than half-done.
    public func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws {
        throw VaultKitError.adapterError(
            "MemPalaceChromaAdapter is read-only: MemPalace is an external source; writes go through MemPalace itself")
    }

    // MARK: - Store 1: chroma.sqlite3

    /// Read both collections from the ChromaDB file into notes.
    private func chromaNotes(dbPath: String, budget: MemPalaceImportBudget) throws -> [NoteIR] {
        let db = try SQLiteReadOnly(path: dbPath, budget: budget)
        var notes: [NoteIR] = []
        for (collection, isCloset) in [(drawersCollection, false), (closetsCollection, true)] {
            // A palace may legitimately lack a collection (e.g. closets
            // never built); absence yields zero notes from it, not an error.
            guard let segmentID = try Self.metadataSegmentID(db: db, collection: collection)
            else { continue }
            for (embeddingID, metadata) in try Self.metadataRows(db: db, segmentID: segmentID) {
                notes.append(Self.chromaNote(
                    id: embeddingID, metadata: metadata, isCloset: isCloset))
            }
        }
        return notes
    }

    /// The METADATA segment id for a collection name, or nil when the
    /// collection does not exist in this file. ChromaDB stores per-row
    /// metadata under the collection's metadata segment, so this id is the
    /// join key for everything we read.
    static func metadataSegmentID(db: SQLiteReadOnly, collection: String) throws -> String? {
        let rows = try db.query(
            """
            SELECT s.id FROM segments s
            JOIN collections c ON s.collection = c.id
            WHERE c.name = ?1 AND s.scope = 'METADATA'
            LIMIT 1
            """,
            bindings: [collection]
        )
        return rows.first?.first ?? nil
    }

    /// All metadata rows of one segment, grouped per embedding:
    /// `[(embeddingID, [key: textValue])]` in embedding-rowid order.
    ///
    /// The value is COALESCEd across the four typed columns with the
    /// numeric ones CAST to text by SQLite itself — see the adapter header
    /// for why that (and not host-language float formatting) is the
    /// cross-port determinism anchor.
    ///
    /// Rows are consumed through `forEachRow` and grouped as they arrive,
    /// so this scan — the largest the adapter runs (447,955 rows /
    /// 34,157,687 value-bytes on the measured real palace) — is
    /// materialized ONCE. Reading it into an intermediate `[[String?]]`
    /// first and regrouping afterwards would hold two full copies at
    /// peak. The Rust port's cursor has always worked this way; this is
    /// the Swift side matching it.
    static func metadataRows(
        db: SQLiteReadOnly, segmentID: String
    ) throws -> [(id: String, metadata: [String: String])] {
        var out: [(id: String, metadata: [String: String])] = []
        var currentID: String?
        var currentMeta: [String: String] = [:]
        try db.forEachRow(
            """
            SELECT e.embedding_id, m.key,
                   COALESCE(m.string_value,
                            CAST(m.int_value AS TEXT),
                            CAST(m.float_value AS TEXT),
                            CAST(m.bool_value AS TEXT))
            FROM embeddings e
            JOIN embedding_metadata m ON m.id = e.id
            WHERE e.segment_id = ?1
            ORDER BY e.id, m.key
            """,
            bindings: [segmentID]
        ) { row in
            guard let id = row[0], let key = row[1] else { return }
            if id != currentID {
                if let finished = currentID { out.append((finished, currentMeta)) }
                currentID = id
                currentMeta = [:]
            }
            // A row whose four value columns are all NULL has no value to
            // carry; the key is skipped (ChromaDB never writes such rows).
            if let value = row[2] { currentMeta[key] = value }
        }
        if let finished = currentID { out.append((finished, currentMeta)) }
        return out
    }

    /// Pure mapping of one chroma row → `NoteIR`. See the adapter header
    /// for the complete field table.
    static func chromaNote(id: String, metadata: [String: String], isCloset: Bool) -> NoteIR {
        // Frontmatter: every metadata key VERBATIM (no prefix), except the
        // document text, whose home is the body.
        var frontmatter = metadata
        let document = frontmatter.removeValue(forKey: "chroma:document") ?? ""

        // Placement: wing / hall / room in palace order. `hall` is present
        // on most drawer rows and absent on closets; only present, non-empty
        // components ride.
        let pathComponents = ["wing", "hall", "room"].compactMap { key -> String? in
            guard let v = metadata[key], !v.isEmpty else { return nil }
            return v
        }

        // kind: collection membership first (a closet summary is a closet
        // summary even if it ever grew a `type` key), then the diary
        // discriminator, then the plain-drawer default.
        let kind: String
        if isCloset {
            kind = "closet_summary"
        } else if metadata["type"] == "diary_entry" {
            kind = "diary_entry"
        } else {
            kind = "drawer"
        }

        // Origin date: `filed_at` (full timestamp, every row) wins; the
        // diary `date` key (date-only) is the fallback. The verbatim
        // strings stay in frontmatter either way — normalization here is
        // additive, never destructive.
        let originDate = (metadata["filed_at"].flatMap(Self.canonicalISO8601(fromMemPalace:))
            ?? metadata["date"].flatMap(Self.canonicalISO8601(fromMemPalace:)))
            .map(OccurredAt.init(iso8601:))

        // entities: semicolon-separated entity names (MemPalace miner
        // format "A;B;C") → one mention fact per entity. The object is
        // this row's stable key so the mention is anchored to its note.
        let facts: [FactIR] = (metadata["entities"] ?? "")
            .split(separator: ";")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { FactIR(subject: $0, predicate: "mentioned_in", object: id) }

        // source_file → SourceRef. MemPalace records no content hash, so
        // contentHash is empty (the SourceRef contract allows an
        // adapter-defined format; "no hash recorded" is the honest value).
        let source = metadata["source_file"].map {
            SourceRef(path: $0, contentHash: "")
        }

        return NoteIR(
            stableSourceKey: id,
            body: [Block(kind: "markdown", text: document)],
            frontmatter: frontmatter,
            links: [],
            tags: [],
            originalPath: pathComponents.joined(separator: "/"),
            originDate: originDate,
            source: source,
            mootID: nil,
            facts: facts,
            pathComponents: pathComponents,
            scope: [:],
            kind: kind
        )
    }

    // MARK: - Store 2: tunnels.json

    /// Size of a file on disk, or 0 when the attribute cannot be read.
    ///
    /// A file whose size is unreadable is charged as 0 rather than
    /// rejected: the read that follows will fail on its own terms with a
    /// filesystem error, and inventing a limit breach for a stat failure
    /// would report the wrong cause.
    static func fileByteCount(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// One tunnel record as MemPalace `palace_graph.py` writes it.
    struct TunnelRecord: Decodable {
        struct Endpoint: Decodable {
            let wing: String
            let room: String
        }
        let id: String
        let source: Endpoint
        let target: Endpoint
        let label: String?
        let created_at: String?
    }

    /// Read `tunnels.json` into one note per tunnel. A missing file is the
    /// empty list (MemPalace semantics); a present-but-malformed file
    /// throws — silently dropping links would violate full fidelity.
    /// The size is taken from the filesystem and charged to the budget
    /// BEFORE the file is opened, so an oversized `tunnels.json` is
    /// rejected without ever being read into memory.
    static func tunnelNotes(jsonURL: URL, budget: MemPalaceImportBudget) throws -> [NoteIR] {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return [] }
        try budget.chargeTunnelsFile(
            byteCount: Self.fileByteCount(at: jsonURL), path: jsonURL.path)
        let data = try Data(contentsOf: jsonURL)
        let records: [TunnelRecord]
        do {
            records = try JSONDecoder().decode([TunnelRecord].self, from: data)
        } catch {
            throw VaultKitError.adapterError(
                "tunnels.json is malformed at \(jsonURL.path): \(error)")
        }
        return records.map(Self.tunnelNote(from:))
    }

    /// Pure mapping of one tunnel record → `NoteIR`. See the adapter
    /// header for the field table.
    static func tunnelNote(from record: TunnelRecord) -> NoteIR {
        let targetRef = "\(record.target.wing)/\(record.target.room)"
        let sourceRef = "\(record.source.wing)/\(record.source.room)"
        let label = record.label ?? ""
        // I-5: body must be non-empty; an unlabeled tunnel renders its
        // endpoints. The same fallback rides the wikilink's `raw` so the
        // substrate tunnel label is never empty either.
        let text = label.isEmpty ? "\(sourceRef) -> \(targetRef)" : label

        var frontmatter = [
            "source_wing": record.source.wing,
            "source_room": record.source.room,
            "target_wing": record.target.wing,
            "target_room": record.target.room,
        ]
        if let createdAt = record.created_at { frontmatter["created_at"] = createdAt }

        return NoteIR(
            stableSourceKey: record.id,
            body: [Block(kind: "markdown", text: text)],
            frontmatter: frontmatter,
            links: [WikiLink(target: targetRef, alias: nil, raw: text)],
            tags: [],
            originalPath: sourceRef,
            originDate: record.created_at
                .flatMap(Self.canonicalISO8601(fromMemPalace:))
                .map(OccurredAt.init(iso8601:)),
            source: nil,
            mootID: nil,
            facts: [],
            pathComponents: [record.source.wing, record.source.room],
            scope: [:],
            kind: "tunnel"
        )
    }

    // MARK: - Store 3: knowledge_graph.sqlite3

    /// Read the KG file into one note per entity and one per triple. A
    /// missing file is an empty KG (a palace whose KG was never built).
    /// The file's size on disk is NOT charged: only the column text this
    /// adapter actually materializes is, row by row, inside `query`. A
    /// large SQLite file whose rows are never read costs no memory.
    static func knowledgeGraphNotes(
        dbPath: String, budget: MemPalaceImportBudget
    ) throws -> [NoteIR] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        let db = try SQLiteReadOnly(path: dbPath, budget: budget)
        var notes: [NoteIR] = []

        for row in try db.query(
            "SELECT id, name, type, properties, created_at FROM entities ORDER BY id"
        ) {
            guard let id = row[0] else { continue }
            notes.append(Self.kgEntityNote(
                id: id, name: row[1] ?? "", type: row[2],
                properties: row[3], createdAt: row[4]))
        }

        for row in try db.query(
            """
            SELECT id, subject, predicate, object, valid_from, valid_to,
                   CAST(confidence AS TEXT), source_closet, source_file,
                   source_drawer_id, adapter_name, extracted_at
            FROM triples ORDER BY id
            """
        ) {
            guard let id = row[0] else { continue }
            notes.append(Self.kgTripleNote(
                id: id, subject: row[1] ?? "", predicate: row[2] ?? "",
                object: row[3] ?? "", validFrom: row[4], validTo: row[5],
                confidenceText: row[6], sourceCloset: row[7], sourceFile: row[8],
                sourceDrawerID: row[9], adapterName: row[10], extractedAt: row[11]))
        }
        return notes
    }

    /// Pure mapping of one KG `entities` row → `NoteIR`.
    static func kgEntityNote(
        id: String, name: String, type: String?,
        properties: String?, createdAt: String?
    ) -> NoteIR {
        var frontmatter: [String: String] = ["name": name]
        if let type { frontmatter["type"] = type }
        if let properties { frontmatter["properties"] = properties }
        if let createdAt { frontmatter["created_at"] = createdAt }

        return NoteIR(
            stableSourceKey: id,
            // I-5: `name` is NOT NULL in the schema but "" is storable;
            // the id (a primary key, always non-empty) is the fallback.
            body: [Block(kind: "markdown", text: name.isEmpty ? id : name)],
            frontmatter: frontmatter,
            links: [],
            tags: [],
            originalPath: "knowledge_graph/entities",
            originDate: createdAt
                .flatMap(Self.canonicalISO8601(fromMemPalace:))
                .map(OccurredAt.init(iso8601:)),
            source: nil,
            mootID: nil,
            facts: [],
            pathComponents: ["knowledge_graph", "entities"],
            scope: [:],
            kind: "kg_entity"
        )
    }

    /// Pure mapping of one KG `triples` row → `NoteIR`.
    ///
    /// `confidenceText` is SQLite's text rendering of the REAL column
    /// (see the stringification note in the header); it is parsed back to
    /// a Double for `FactIR.confidence`, whose wire type is numeric.
    static func kgTripleNote(
        id: String, subject: String, predicate: String, object: String,
        validFrom: String?, validTo: String?, confidenceText: String?,
        sourceCloset: String?, sourceFile: String?, sourceDrawerID: String?,
        adapterName: String?, extractedAt: String?
    ) -> NoteIR {
        var frontmatter: [String: String] = [:]
        if let sourceCloset { frontmatter["source_closet"] = sourceCloset }
        if let sourceFile { frontmatter["source_file"] = sourceFile }
        if let sourceDrawerID { frontmatter["source_drawer_id"] = sourceDrawerID }
        if let adapterName { frontmatter["adapter_name"] = adapterName }
        if let extractedAt { frontmatter["extracted_at"] = extractedAt }

        // validFrom/validTo ride VERBATIM (MemPalace stores date-only
        // strings like "2026-04-27"); re-formatting a partial date would
        // invent precision the source never asserted.
        let fact = FactIR(
            subject: subject,
            predicate: predicate,
            object: object,
            validFrom: validFrom,
            validTo: validTo,
            confidence: confidenceText.flatMap(Double.init)
        )

        return NoteIR(
            stableSourceKey: id,
            // The triple rendered as prose — the drawer content a recall
            // can match on. The structured truth is `facts[0]`.
            body: [Block(kind: "markdown", text: "\(subject) \(predicate) \(object)")],
            frontmatter: frontmatter,
            links: [],
            tags: [],
            originalPath: "knowledge_graph/triples",
            originDate: extractedAt
                .flatMap(Self.canonicalISO8601(fromMemPalace:))
                .map(OccurredAt.init(iso8601:)),
            source: sourceFile.map { SourceRef(path: $0, contentHash: "") },
            mootID: nil,
            facts: [fact],
            pathComponents: ["knowledge_graph", "triples"],
            scope: [:],
            kind: "kg_triple"
        )
    }

    // MARK: - Timestamp normalization

    /// Normalize a MemPalace timestamp to LocusKit's canonical ISO8601
    /// form (`YYYY-MM-DDTHH:MM:SS.fffZ`), or nil when the string is not a
    /// recognizable UTC instant (the verbatim value stays in frontmatter
    /// regardless, so nil loses nothing).
    ///
    /// MemPalace writes four shapes, all UTC:
    ///   - `"2026-05-08T04:27:12.542283"` — naive microseconds (`filed_at`)
    ///   - `"2026-05-29T08:38:47.205501+00:00"` — explicit UTC offset
    ///     (tunnel `created_at`)
    ///   - `"2026-04-28 02:48:07"` — SQLite `CURRENT_TIMESTAMP` (KG rows)
    ///   - `"2026-05-08"` — date-only (diary `date`)
    ///
    /// This is a PURE STRING transform (truncate/pad the fraction to
    /// milliseconds, naive == UTC, `T00:00:00.000Z` for date-only) — no
    /// date library — so the Swift and Rust ports are trivially
    /// byte-identical. A non-UTC offset returns nil rather than doing
    /// timezone arithmetic two runtimes might disagree on.
    static func canonicalISO8601(fromMemPalace raw: String) -> String? {
        var chars = Array(raw.utf8).map { Character(UnicodeScalar($0)) }

        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

        // Date-only: "YYYY-MM-DD".
        if chars.count == 10 {
            guard chars[4] == "-", chars[7] == "-",
                  [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ isDigit(chars[$0]) })
            else { return nil }
            return String(chars) + "T00:00:00.000Z"
        }

        guard chars.count >= 19 else { return nil }

        // SQLite CURRENT_TIMESTAMP separator: " " → "T".
        if chars[10] == " " { chars[10] = "T" }

        // Strip a UTC suffix; reject any other offset (no tz arithmetic).
        if chars.last == "Z" {
            chars.removeLast()
        } else if chars.count >= 25, String(chars.suffix(6)) == "+00:00" {
            chars.removeLast(6)
        } else if chars.count > 19, chars[19...].contains(where: { $0 == "+" }) {
            return nil
        } else if chars.count > 19, chars[19...].contains(where: { $0 == "-" }) {
            return nil
        }

        // Validate the 19-char date-time prefix.
        guard chars.count >= 19,
              chars[4] == "-", chars[7] == "-", chars[10] == "T",
              chars[13] == ":", chars[16] == ":",
              [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
                  .allSatisfy({ isDigit(chars[$0]) })
        else { return nil }

        // Fraction: absent → ".000"; present → digits truncated/padded to
        // milliseconds (canonical `.withFractionalSeconds` is 3 digits).
        var fraction = "000"
        if chars.count > 19 {
            guard chars[19] == "." else { return nil }
            let digits = chars.dropFirst(20)
            guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
            fraction = String((Array(digits) + ["0", "0", "0"]).prefix(3))
        }
        return String(chars.prefix(19)) + "." + fraction + "Z"
    }
}

// MARK: - Minimal read-only SQLite access

/// A minimal read-only SQLite connection for foreign (non-PersistenceKit)
/// files, opened with `SQLITE_OPEN_READONLY` — the palace is never
/// written, structurally. All values are read as text (the adapter's
/// queries CAST numerics in SQL; see the stringification note above).
///
/// Internal to VaultKit: this is adapter plumbing, not a storage API —
/// estate persistence stays with PersistenceKit.
///
/// Every connection carries the import's `MemPalaceImportBudget` and
/// installs a SQLite progress handler from it, so a query against an
/// untrusted palace is abandoned rather than run to completion.
final class SQLiteReadOnly {

    private var handle: OpaquePointer?

    /// The running totals every read on this connection is charged to.
    let budget: MemPalaceImportBudget

    /// Open `path` read-only, bounded by `budget`. Throws
    /// `VaultKitError.adapterError` with the SQLite diagnostic when the
    /// file cannot be opened as a database.
    ///
    /// `budget` defaults to a fresh one at the shipping limits so a
    /// connection is never accidentally unbounded; callers importing a
    /// whole palace pass a shared budget instead, making the row and byte
    /// ceilings totals for the import.
    init(path: String, budget: MemPalaceImportBudget = MemPalaceImportBudget()) throws {
        self.budget = budget
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw VaultKitError.adapterError("cannot open \(path) read-only: \(message)")
        }
        handle = db
        // The budget is passed unretained: this connection holds a strong
        // reference for its whole life and clears the handler in `deinit`
        // before closing, so the pointer can never outlive the object.
        sqlite3_progress_handler(
            db,
            budget.limits.sqliteProgressGrain,
            memPalaceProgressHandler,
            Unmanaged.passUnretained(budget).toOpaque())
    }

    deinit {
        if let handle {
            // Clear before close so no callback can fire against a
            // context pointer whose owner is going away.
            sqlite3_progress_handler(handle, 0, nil, nil)
            sqlite3_close_v2(handle)
        }
    }

    /// Run one SELECT with optional text bindings, materializing every
    /// row; each column comes back as optional text (`NULL` → nil).
    ///
    /// Bounded by the connection's budget exactly as `forEachRow` is —
    /// this is a thin accumulator over it. Prefer `forEachRow` when the
    /// caller can consume rows as they arrive; use this when it genuinely
    /// needs the whole result at once.
    func query(_ sql: String, bindings: [String] = []) throws -> [[String?]] {
        var rows: [[String?]] = []
        try forEachRow(sql, bindings: bindings) { rows.append($0) }
        return rows
    }

    /// Run one SELECT and hand each row to `body` as it is stepped, never
    /// holding more than the current row.
    ///
    /// Every row is charged to the budget — one row against
    /// `maxImportRows`, its column bytes against `maxMaterializedBytes` —
    /// so a scan over an untrusted palace stops at the ceiling instead of
    /// consuming memory without limit. A query the progress handler
    /// interrupts is reported as the step limit by name rather than as
    /// SQLite's generic "interrupted" diagnostic.
    func forEachRow(
        _ sql: String, bindings: [String] = [], _ body: ([String?]) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            // The progress handler runs during prepare as well as step —
            // SQLite may interrupt while it is still planning the query, and
            // a degenerate plan is exactly the case the step budget exists
            // to catch. Name the limit here too, or the guard reports itself
            // as a bare "interrupted".
            if budget.interruptedByStepLimit { throw budget.stepLimitError() }
            throw VaultKitError.adapterError(
                "prepare failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: SQLite copies the bound text immediately, so the
        // Swift string's lifetime ends safely at the call boundary.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) == SQLITE_OK
            else {
                if budget.interruptedByStepLimit { throw budget.stepLimitError() }
                throw VaultKitError.adapterError(
                    "bind failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
        }

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                // The progress handler aborts a runaway statement with
                // SQLITE_INTERRUPT; name the limit that did it rather
                // than leaving the caller with "interrupted".
                if budget.interruptedByStepLimit { throw budget.stepLimitError() }
                throw VaultKitError.adapterError(
                    "step failed: \(String(cString: sqlite3_errmsg(handle)))")
            }
            let columnCount = sqlite3_column_count(stmt)
            var row: [String?] = []
            row.reserveCapacity(Int(columnCount))
            var rowBytes = 0
            for column in 0..<columnCount {
                if let text = sqlite3_column_text(stmt, column) {
                    // sqlite3_column_bytes is the byte length of the value
                    // just read as text — the honest memory cost of this
                    // column, and cheaper than measuring the Swift String.
                    rowBytes += Int(sqlite3_column_bytes(stmt, column))
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            try budget.chargeRow(byteCount: rowBytes)
            try body(row)
        }
    }
}
