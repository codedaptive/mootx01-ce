// EstateFormalConcepts.swift
//
// Wires bounded Formal Concept Analysis, cover-delta computation, and
// D-G canonical basis implications to live GeniusLocusKit estates.
//
// Three entry points:
//
//   mineFormalConcepts(estate:miner:)
//     Reads the estate's current audit log via `currentAuditLog(in:)`,
//     converts each entry to `RowAuditEntry`, builds `RowAttributeView`
//     rows, materialises a `FormalContext`, and delegates to the
//     provided `BoundedConceptMiner`. Returns `[FormalConcept]`.
//
//   formalConceptCoverDeltas(estate:miner:)
//     Same pipeline as above; additionally calls
//     `ConceptCoverDeltas.covering(concepts:)` over the mined concepts
//     and returns the cover-delta set.
//
//   conceptImplications(estate:miner:maxImplications:maxPremiseSize:)
//     Same pipeline as mineFormalConcepts; additionally calls
//     `ConceptImplications.conceptImplications(over:context:maxImplications:
//     maxPremiseSize:)` over the materialised context to derive the bounded
//     D-G canonical basis. Every emitted implication is sound.
//
// The cover deltas produced here are a structural lens over the emitted
// concept set — they do not assert that every row carrying lowerIntent
// also carries addedAttributes. See SUBSTRATEML_SPEC_v0.8 for the
// full contract. For sound logical implications, use `conceptImplications`.
//
// Extension pattern: `public extension GeniusLocusKit` places these
// methods in the same module as the actor, giving access to
// `internal func currentAuditLog(in:)` and the internal
// `toRowAuditEntry(_:)` helper shared with EstateAssociationRuleMining.

import Foundation
import OSLog
import SubstrateML
import SubstrateTypes

private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - Public FCA surface

public extension GeniusLocusKit {

    // MARK: Bounded concept mining

    /// Mine bounded formal concepts from the estate's audit log.
    ///
    /// Reads the current audit log via `currentAuditLog(in:)`, converts
    /// each entry to a `RowAuditEntry`, builds `RowAttributeView` rows,
    /// materialises a `FormalContext`, and delegates to `miner`.
    ///
    /// Returns an empty array — not an error — when the audit log
    /// contains no entries (a fresh estate is silent, not broken).
    ///
    /// - Parameters:
    ///   - estate: handle for the target estate.
    ///   - miner: configured `BoundedConceptMiner` (bounds, seed mode).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` when the estate
    ///   is not in the registry; any error from `currentAuditLog`.
    /// - Returns: concepts sorted by support descending, intent size
    ///   ascending, then lexicographic intent — the SubstrateML
    ///   emission order.
    func mineFormalConcepts(
        estate: EstateHandle,
        miner: BoundedConceptMiner
    ) async throws -> [FormalConcept] {
        let rows = try await auditRows(for: estate)
        guard !rows.isEmpty else { return [] }
        let context = FormalContext.from(rowAttributeViews: rows)
        return miner.mine(context: context)
    }

    // MARK: Cover deltas

    /// Derive cover deltas from the estate's audit log using the
    /// provided `BoundedConceptMiner`.
    ///
    /// Mines bounded formal concepts (same pipeline as
    /// `mineFormalConcepts(estate:miner:)`) then applies
    /// `ConceptCoverDeltas.covering(concepts:)` to derive the cover-
    /// delta set over the emitted concept set.
    ///
    /// Cover deltas are a structural lens — they do not assert that
    /// every row carrying `lowerIntent` also carries `addedAttributes`.
    /// See SUBSTRATEML_SPEC_v0.8 for the full contract.
    ///
    /// - Parameters:
    ///   - estate: handle for the target estate.
    ///   - miner: configured `BoundedConceptMiner` (bounds, seed mode).
    /// - Throws: `GeniusLocusKitError.estateNotOpen` when the estate
    ///   is not in the registry; any error from `currentAuditLog`.
    /// - Returns: cover deltas over the mined concept set.
    func formalConceptCoverDeltas(
        estate: EstateHandle,
        miner: BoundedConceptMiner
    ) async throws -> ConceptCoverDeltas {
        let rows = try await auditRows(for: estate)
        guard !rows.isEmpty else { return ConceptCoverDeltas(coverDeltas: []) }
        let context = FormalContext.from(rowAttributeViews: rows)
        let concepts = miner.mine(context: context)
        return ConceptCoverDeltas.covering(concepts: concepts)
    }

    // MARK: Canonical implications (D-G canonical basis)

    /// Derive the bounded Duquenne–Guigues canonical basis from the estate's
    /// audit log.
    ///
    /// Mines the same `FormalContext` used by `mineFormalConcepts` — the
    /// estate's current audit log converted to `RowAttributeView` rows —
    /// and delegates to `ConceptImplications.conceptImplications`. Every
    /// emitted implication is sound: every audit-log row that carries all
    /// attributes in `premise` also carries all attributes in `conclusion`.
    ///
    /// Returns an empty basis — not an error — when the audit log contains
    /// no entries.
    ///
    /// - Parameters:
    ///   - estate: handle for the target estate.
    ///   - miner: configured `BoundedConceptMiner` used to materialise the
    ///     `FormalContext` (its `mine` result is passed to the implication
    ///     engine for context; the engine uses the full `FormalContext`
    ///     for closure operations).
    ///   - maxImplications: hard cap on the number of emitted implications.
    ///     Set to `Int.max` for uncapped enumeration. When the cap triggers,
    ///     `isTruncated == true` in the returned value.
    ///   - maxPremiseSize: maximum premise size to emit. Pseudo-intents with
    ///     `|premise| > maxPremiseSize` are skipped silently; this does not
    ///     set `isTruncated`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` when the estate is not
    ///   in the registry; any error from `currentAuditLog`.
    /// - Returns: bounded D-G canonical basis with `isTruncated` flag.
    func conceptImplications(
        estate: EstateHandle,
        miner: BoundedConceptMiner,
        maxImplications: Int,
        maxPremiseSize: Int
    ) async throws -> ConceptImplications {
        let rows = try await auditRows(for: estate)
        guard !rows.isEmpty else {
            return ConceptImplications(implications: [], isTruncated: false)
        }
        let context = FormalContext.from(rowAttributeViews: rows)
        let concepts = miner.mine(context: context)
        return ConceptImplications.conceptImplications(
            over: concepts,
            context: context,
            maxImplications: maxImplications,
            maxPremiseSize: maxPremiseSize
        )
    }
}

// MARK: - Internal helpers

private extension GeniusLocusKit {

    /// Read the estate's current audit log and convert it to
    /// `RowAttributeView` rows for FCA materialisation.
    ///
    /// Conversion mirrors `EstateAssociationRuleMining.toRowAuditEntry`,
    /// which is `fileprivate` to that file and therefore not callable
    /// here. The mapping is identical: `.bitmap` and `.integer` are
    /// forwarded; `.string`, `.bytes`, and `.null` become `.null`
    /// (no canonical 6-bit Item encoding exists for those types).
    func auditRows(for estate: EstateHandle) async throws -> [RowAttributeView] {
        let auditLog = try await currentAuditLog(in: estate)
        let entries: [RowAuditEntry] = auditLog.orderedEntries.map { entry in
            let rowValue: RowAuditValue
            switch entry.afterValue {
            case .null:
                rowValue = .null
            case .bitmap(let v):
                rowValue = .bitmap(v)
            case .integer(let n):
                rowValue = .integer(n)
            case .string, .bytes:
                // No canonical 6-bit Item encoding for strings or bytes.
                rowValue = .null
            }
            return RowAuditEntry(
                rowID: entry.rowID,
                tier: entry.tier.rawValue,
                fieldPath: entry.fieldPath,
                hlc: entry.hlc,
                value: rowValue
            )
        }
        return RowAttributeView.from(auditEntries: entries)
    }
}
