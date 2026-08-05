// KGFactIdentityBackfill.swift
//
// MXE-MI: one-shot, re-runnable backfill that moves pre-MXE-KH
// `kg_facts.sourceDrawerID` values into the identity column each value
// actually belongs in (`addedBy`, `foreignSourceKey`, `foreignRecordID`).
// Before MXE-KH those columns did not exist, so writers parked three
// kinds of non-drawer identity in `sourceDrawerID`: the MCP host
// identity, the foreign palace's stable source key, and (Rust importer
// only) the imported triple's own id. New writes land in the right
// columns; this backfill converges the rows written before the columns
// existed.
//
// Run ONLY by `mootx01 upgrade` — Bob's ruling makes upgrade the sole
// migration vehicle: no detection or prompting lives anywhere else (not
// serve, not install, not the App, not an MCP tool).
//
// Design invariant, inherited from EstateEncryptionMigrator:
//
//   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//
// Met here without the clone → verify → swap shape, because a column
// backfill has no half-written-file hazard: every move is one per-row
// UPDATE that sets the target column and clears `sourceDrawerID`
// together, so each row is always in exactly one of two readable shapes
// (pre-move or post-move) and the palace dedup anchor serves both (its
// legacy fallback reads `sourceDrawerID` when the new columns are
// empty). A crash mid-run is completed by the next run; a second run
// over a migrated estate changes nothing because migrated rows leave
// the scan set (`sourceDrawerID` is empty) and class-A inheritance only
// fires on the all-zero pre-KH bitmap shape.
//
// Classification is deterministic, never heuristic: a value moves only
// when EXACTLY ONE of the four evidence rules matches it. Zero matches
// or multiple matches leave the row in place, counted — a misfiled
// identity is worse than an unmigrated one, because the unmigrated one
// is still findable.

import Foundation
import PersistenceKit

/// Per-class row counts from one backfill run — the audit trail the
/// mission requires. Every scanned row lands in exactly one bucket
/// (`localDrawerIDs`, `hostIdentities`, `foreignPalaceKeys`,
/// `tripleIDs`, or `unclassified`); `inheritanceApplied` is a subset
/// annotation on `localDrawerIDs`, not a bucket.
public struct KGFactIdentityBackfillReport: Sendable, Equatable {
    /// Rows whose `sourceDrawerID` was non-empty (the scan set).
    public var scanned: Int = 0
    /// Class A: the value resolves against this estate's `drawers.id` —
    /// a genuine local anchor, left exactly where it is.
    public var localDrawerIDs: Int = 0
    /// Class-A rows whose all-zero pre-KH bitmaps were backfilled with
    /// the source drawer's `adjectiveBitmap`/`provenance` (MXE-KH's
    /// sensitivity-inheritance rule applied retroactively).
    public var inheritanceApplied: Int = 0
    /// Class D: a known MCP host identity, moved to `addedBy`.
    public var hostIdentities: Int = 0
    /// Class B: a foreign palace stable source key, moved to
    /// `foreignSourceKey`.
    public var foreignPalaceKeys: Int = 0
    /// Class C: an imported triple's own id, moved to `foreignRecordID`.
    public var tripleIDs: Int = 0
    /// Zero rules matched, more than one rule matched, or the target
    /// column was unexpectedly occupied — left in place, counted.
    public var unclassified: Int = 0

    public init() {}
}

/// The backfill. Stateless; all evidence comes from the estate itself
/// plus the injected foreign-key resolver.
public enum KGFactIdentityBackfill {

    /// Every host identity ever compiled into a production
    /// `serverIdentity`/`server_identity`. The set is CLOSED by code
    /// audit, not guessed by string shape:
    ///   - "mootx01"        — Swift `ServeCommand` and every Rust entry
    ///                        point (serve, standalone server, registry
    ///                        default) since PAR-MCP-2.
    ///   - "aria-mcp-server" — Swift standalone server and the
    ///                        `ToolDispatcher` default parameter.
    ///   - "aria-mcp"        — the Rust standalone server's banner
    ///                        before PAR-MCP-2 corrected it to
    ///                        "mootx01"; estates written by that build
    ///                        carry it.
    ///   - "Gateway"         — the App's `MootBridge.attachSQLite`
    ///                        default `serverName`, forwarded verbatim
    ///                        as the host identity for disk estates
    ///                        served through the App gateway.
    /// A value outside this set is never treated as a host identity.
    public static let knownHostIdentities: Set<String> = [
        "mootx01", "aria-mcp-server", "aria-mcp", "Gateway",
    ]

    /// Run the backfill against `storage`.
    ///
    /// Opening the store applies the LocusKit schema ladder first — the
    /// v12 → v13 migration adds the three identity columns to estates
    /// that predate them, which is why this routes through the
    /// substrate open path and never raw SQLite.
    ///
    /// - Parameters:
    ///   - storage: The estate's storage backend, already keyed.
    ///   - resolveForeignKey: Maps a candidate stable source key to the
    ///     lineage id a palace import would have minted for it. The
    ///     caller injects `DrawerMapping.lineageID(forStableSourceKey:)`
    ///     from VaultKit — injected because LocusKit sits below VaultKit
    ///     and must not import it.
    /// - Returns: Per-class counts for the upgrade transcript.
    public static func run(
        storage: any Storage,
        resolveForeignKey: @Sendable (String) -> UUID
    ) async throws -> KGFactIdentityBackfillReport {
        // DrawerStore's init runs `storage.open(schema:)`, which applies
        // the v12 → v13 addColumn migration on a pre-KH estate before
        // any row below is read or written.
        let store = try await DrawerStore(storage: storage)

        // Evidence 1 — the drawers table, ALL lifecycle states. A
        // withdrawn drawer's id is still a genuine local drawer id; no
        // state predicate belongs here. Only the four columns the rules
        // need are used.
        let drawerRows = try await storage.rowStore.query(table: "drawers")
        var drawerBitmaps: [String: (adjective: Int64, provenance: Int64)] = [:]
        var lineageSet: Set<UUID> = []
        for row in drawerRows {
            let id = textValue(row["id"])
            if !id.isEmpty {
                drawerBitmaps[id] = (bitmapValue(row["adjectiveBitmap"]),
                                     bitmapValue(row["provenance"]))
            }
            if let lineage = UUID(uuidString: textValue(row["lineageID"])) {
                lineageSet.insert(lineage)
            }
        }

        // Evidence 2 — every fact, retired included: a retired fact's
        // misfiled identity is still a misfiled identity.
        let facts = try await store.allKGFactsIncludingRetired()

        // Evidence 3 — triple ids. The importer files temporal-validity
        // siblings with `subject = <triple id>` and `predicate =
        // "temporal:…"`; nothing else ever writes a `temporal:` subject.
        // A value appearing there is an imported triple's own id.
        let temporalSubjects = Set(
            facts.lazy
                .filter { $0.predicate.hasPrefix("temporal:") }
                .map(\.subject)
        )

        var report = KGFactIdentityBackfillReport()
        for fact in facts {
            let value = fact.sourceDrawerID
            guard !value.isEmpty else { continue }
            report.scanned += 1

            // Evaluate ALL FOUR rules; act only on exactly one match.
            let isLocalDrawer = drawerBitmaps[value] != nil
            let isHostIdentity = knownHostIdentities.contains(value)
            let isForeignKey = lineageSet.contains(resolveForeignKey(value))
            let isTripleID = temporalSubjects.contains(value)
            let matches = [isLocalDrawer, isHostIdentity, isForeignKey, isTripleID]
                .filter { $0 }.count
            guard matches == 1 else {
                report.unclassified += 1
                continue
            }

            if isLocalDrawer {
                // Class A: correct where it is. Retro-apply MXE-KH's
                // inheritance ONLY to the pre-KH verb-default shape
                // (both bitmaps zero) — nonzero bitmaps carry real
                // state (retired, elevated, …) and are never clobbered.
                report.localDrawerIDs += 1
                let source = drawerBitmaps[value]!
                if fact.adjectiveBitmap == 0, fact.provenanceBitmap == 0,
                   source.adjective != 0 || source.provenance != 0 {
                    _ = try await storage.rowStore.update(
                        table: "kg_facts",
                        values: [
                            "adjectiveBitmap": .bitmap(source.adjective),
                            "provenanceBitmap": .bitmap(source.provenance),
                        ],
                        where: .eq(Column(table: "kg_facts", name: "id"), .text(fact.id)))
                    report.inheritanceApplied += 1
                }
                continue
            }

            // Classes B/C/D move the value. The target must be empty:
            // no writer ever produced a row with both `sourceDrawerID`
            // and an identity column populated, so an occupied target
            // means evidence this rule set does not cover — leave it.
            let targetColumn: String
            if isHostIdentity {
                guard fact.addedBy.isEmpty else { report.unclassified += 1; continue }
                targetColumn = "addedBy"
                report.hostIdentities += 1
            } else if isForeignKey {
                guard fact.foreignSourceKey.isEmpty else { report.unclassified += 1; continue }
                targetColumn = "foreignSourceKey"
                report.foreignPalaceKeys += 1
            } else {
                guard fact.foreignRecordID.isEmpty else { report.unclassified += 1; continue }
                targetColumn = "foreignRecordID"
                report.tripleIDs += 1
            }
            // One UPDATE per row: target set and `sourceDrawerID`
            // cleared together, so the row is never in a half-moved
            // state and a re-run never sees it again.
            _ = try await storage.rowStore.update(
                table: "kg_facts",
                values: [
                    targetColumn: .text(value),
                    "sourceDrawerID": .text(""),
                ],
                where: .eq(Column(table: "kg_facts", name: "id"), .text(fact.id)))
        }
        return report
    }

    // MARK: - Row value coercion

    /// TEXT read-back tolerant of `.text`/`.uuid` (SQLite stores UUIDs
    /// as TEXT; InMemory round-trips the typed value).
    private static func textValue(_ v: TypedValue?) -> String {
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        default: return ""
        }
    }

    /// Bitmap read-back tolerant of `.bitmap`/`.int` (SQLite reads
    /// integers back as `.int`; InMemory preserves `.bitmap`).
    private static func bitmapValue(_ v: TypedValue?) -> Int64 {
        switch v {
        case .bitmap(let i), .int(let i): return i
        default: return 0
        }
    }
}
