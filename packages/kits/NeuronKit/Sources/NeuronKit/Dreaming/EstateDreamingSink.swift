// EstateDreamingSink.swift
//
// Production adapter that binds `DreamingProposalSink` to a live
// GeniusLocusKit estate (NEURONKIT_SPEC § 3.1 steps 6–7).
//
// ── Why this lives in NeuronKit, not GeniusLocusKit ──────────────────────
// `DreamingProposalSink` is declared here in NeuronKit. A conforming type
// must import NeuronKit. GeniusLocusKit is a dependency of NeuronKit (GLK
// sits below NK in the stack), so GLK cannot import NK without creating a
// circular package dependency. NeuronKit is the only package that can see
// both the protocol and the GLK estate surface, making it the natural home
// for this adapter — the same constraint that placed `EstateDreamingReader`
// here.
//
// ── Write path ────────────────────────────────────────────────────────────
// `propose(_:)` delegates to `GeniusLocusKit.propose(_:_:)`, which maps the
// Brain-layer `ProposalKind` to the substrate's `LocusKit.ProposalKind` via
// `mapBrainKindToSubstrate` and dispatches to `Estate.propose`. The GLK verb
// surface is the only legal write path (B-1).
//
// `recordCycleDiary(_:)` delegates to `GeniusLocusKit.addDiaryEntry(in:_:)`,
// a new GLK Brain-layer extension method that caches a `DrawerStore` per
// handle (the same lazy-registry pattern GrantStore uses) and forwards to
// `DrawerStore.addDiaryEntry`. The estate's diary store sits inside the same
// LocusKit SQLite database as the estate's drawers; sharing the cached store
// keeps writes serialised through the LocusKit actor without a second file
// handle.

import Foundation
import GeniusLocusKit
import IntellectusLib
import SubstrateTypes

/// Production adapter that binds `DreamingProposalSink` to a live estate.
///
/// `EstateDreamingSink` bridges the two write operations the dreaming
/// daemon needs (NEURONKIT_SPEC § 3.1 steps 6–7) to live estate verbs:
///
/// - `propose(_:)` → `GeniusLocusKit.propose(_:_:)` (the B-1-compliant verb
///   surface; maps Brain-layer ProposalKind to substrate ProposalKind)
/// - `recordCycleDiary(_:)` → `GeniusLocusKit.addDiaryEntry(in:_:)` (new GLK
///   Brain extension that caches a DrawerStore per handle, per GRT-01 pattern)
///
/// Together with `EstateDreamingReader`, this adapter closes BRAIN-PROPOSE:
/// the dreaming daemon can now emit real `Proposal` rows and `DiaryEntry`
/// rows through a live estate handle.
public struct EstateDreamingSink: DreamingProposalSink {

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

    // MARK: - DreamingProposalSink

    /// Emit a proposal for a novel candidate alignment (step 6).
    ///
    /// Delegates to `GeniusLocusKit.propose(_:_:)`, which maps the
    /// Brain-layer `ProposeFrame.kind` to the substrate ProposalKind
    /// via `mapBrainKindToSubstrate` and dispatches to `Estate.propose`.
    /// After a successful write, notifies the topology worker via
    /// `Intellectus.report(.event(kind: .think, ...))`. `Date()` is called
    /// here at the adapter boundary — this is an I/O adapter, not an
    /// algorithm engine; the deterministic-engine rule applies to algorithm
    /// cores. This mirrors `EstateCoordinator.swift` lines 104 and 197,
    /// which also call `Date().timeIntervalSince1970` in `Intellectus.report`.
    public func propose(_ frame: ProposeFrame) async throws {
        let proposal = try await kit.propose(handle, frame)
        Intellectus.report(.event(
            kind: .think,
            nounType: Int(NounType.proposal.rawValue),
            rowID: proposal.id,
            estate: handle.estateUUID.uuidString,
            ts: Date().timeIntervalSince1970
        ))
    }

    /// Record exactly one diary entry summarising the cycle (step 7).
    ///
    /// Delegates to `GeniusLocusKit.addDiaryEntry(in:_:)`, which
    /// resolves the estate handle to its cached DrawerStore and calls
    /// `DrawerStore.addDiaryEntry`.
    public func recordCycleDiary(_ entry: DiaryEntry) async throws {
        try await kit.addDiaryEntry(in: handle, entry)
    }

    /// Delete recall-trace rows whose `recalledAt` is strictly before
    /// `cutoff`. Called after the reward sweep to keep the table bounded.
    /// Delegates to `GeniusLocusKit.pruneRecallTraces(in:olderThan:)`.
    ///
    /// - Parameter cutoff: rows with `recalledAt < cutoff` are deleted.
    /// - Returns: the number of rows deleted.
    @discardableResult
    public func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int {
        try await kit.pruneRecallTraces(in: handle, olderThan: cutoff)
    }

    /// Retire a tunnel by flipping bit 13 of its `operationalBitmap` (T13 / ADR-021 Phase 7).
    ///
    /// Called by OMEGA through the GLK seam (B-1 compliance). Delegates to
    /// `GeniusLocusKit.retireTunnel(in:id:changedBy:now:)`.
    public func retireTunnel(id tunnelId: String, changedBy: String, now: Date) async throws {
        try await kit.retireTunnel(in: handle, id: tunnelId, changedBy: changedBy, now: now)
    }
}
