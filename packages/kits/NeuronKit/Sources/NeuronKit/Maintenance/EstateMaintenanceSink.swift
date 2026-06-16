// EstateMaintenanceSink.swift
//
// Production adapter that binds `MaintenanceProposalSink` to a live
// GeniusLocusKit estate (NEURONKIT_SPEC § 3.2).
//
// ── Why this lives in NeuronKit, not GeniusLocusKit ──────────────────────
// `MaintenanceProposalSink` is declared here in NeuronKit. A conforming type
// must import NeuronKit. GeniusLocusKit is a dependency of NeuronKit (GLK
// sits below NK in the stack), so GLK cannot import NK without creating a
// circular package dependency. NeuronKit is the only package that can see
// both the protocol and the GLK estate surface, making it the natural home
// for this adapter — the same constraint that placed `EstateDreamingSink`
// here.
//
// ── Write path ────────────────────────────────────────────────────────────
// `propose(_:)` delegates to `GeniusLocusKit.propose(_:_:)`, which maps the
// Brain-layer `ProposalKind` to the substrate's `LocusKit.ProposalKind` via
// `mapBrainKindToSubstrate` and dispatches to `Estate.propose`. The GLK verb
// surface is the only legal write path (B-1).
//
// `recordCycleDiary(_:)` delegates to `GeniusLocusKit.addDiaryEntry(in:_:)`,
// which caches a `DrawerStore` per handle (the GRT-01 lazy-registry pattern)
// and forwards to `DrawerStore.addDiaryEntry`. The `addDiaryEntry` method
// substitutes "no-embedding" when `embeddingModelID` is empty so the
// maintenance daemon's text-only diary entries are not rejected by the
// storage layer's non-empty model-ID constraint.

import Foundation
import GeniusLocusKit

/// Production adapter that binds `MaintenanceProposalSink` to a live estate.
///
/// `EstateMaintenanceSink` bridges the two write operations the maintenance
/// daemon needs (NEURONKIT_SPEC § 3.2 step 6) to live estate verbs:
///
/// - `propose(_:)` → `GeniusLocusKit.propose(_:_:)` (the B-1-compliant verb
///   surface; maps Brain-layer ProposalKind to substrate ProposalKind)
/// - `recordCycleDiary(_:)` → `GeniusLocusKit.addDiaryEntry(in:_:)` (GLK
///   Brain extension that caches a DrawerStore per handle, per GRT-01 pattern)
///
/// Together with `EstateMaintenanceReader`, this adapter lets the maintenance
/// daemon emit real `Proposal` rows and `DiaryEntry` rows through a live estate.
public struct EstateMaintenanceSink: MaintenanceProposalSink {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    /// Construct a sink over the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: the estate to write to.
    ///   - kit: the GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    // MARK: - MaintenanceProposalSink

    /// Emit a remediation proposal (§ 3.2 step 5).
    ///
    /// Delegates to `GeniusLocusKit.propose(_:_:)`, which maps the
    /// Brain-layer `ProposeFrame.kind` to the substrate ProposalKind
    /// via `mapBrainKindToSubstrate` and dispatches to `Estate.propose`.
    /// The return value (the stored `Proposal`) is discarded; the daemon
    /// only needs the write to succeed.
    public func propose(_ frame: ProposeFrame) async throws {
        _ = try await kit.propose(handle, frame)
    }

    /// Record exactly one diary entry summarising the cycle (§ 3.2 step 6).
    ///
    /// Delegates to `GeniusLocusKit.addDiaryEntry(in:_:)`, which resolves
    /// the estate handle to its cached DrawerStore and calls
    /// `DrawerStore.addDiaryEntry`. Empty `embeddingModelID` fields are
    /// substituted with "no-embedding" inside `addDiaryEntry` — maintenance
    /// daemon diary entries carry no embedding.
    public func recordCycleDiary(_ entry: DiaryEntry) async throws {
        try await kit.addDiaryEntry(in: handle, entry)
    }

    /// Update a drawer's provenance bitmap after a QID-pending retry
    /// (Board item 14, NEURONKIT_SPEC § 3.2).
    ///
    /// Delegates to `GeniusLocusKit.updateEnrichmentStatus(in:rowID:…)`,
    /// which calls `Estate.mutateProvenance` and atomically appends an
    /// audit row. The caller (the maintenance daemon's retry batch)
    /// constructs `newProvenance` with the enrichment-status field
    /// (bits 36-41) set to the retry outcome.
    ///
    /// The `changedBy` value is the maintenance daemon's stable agent name,
    /// matching the diary entry agent name for audit traceability.
    public func updateEnrichmentStatus(
        rowID: RowID,
        newProvenance: Int64,
        now: Date
    ) async throws {
        try await kit.updateEnrichmentStatus(
            in: handle,
            rowID: rowID,
            newProvenance: newProvenance,
            // Use the daemon's stable agent name for audit traceability —
            // the same name the cycle diary entries are filed under.
            changedBy: "maintenance-daemon",
            now: now
        )
    }
}
