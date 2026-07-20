// Recollect.swift
//
// Expands a "_distilled" factoid to its source memories by following
// outgoing "_distilled_from" tunnels. Models the human experience of
// pausing and recalling deep long-term memory from a distilled factoid.
//
// GLK call sequence (2 GLK verb calls, no SQL):
//   1. kit.hydrate([factoidID])        → validate DIST header
//   2. kit.recallTunnels(wing)         → filter source==factoidID, label=="_distilled_from"
//      wing = LocusKit.defaultWingName (the fixed constant; no manifest read)
//   3. kit.hydrate(sourceIDs)          → source content
//
// Layer discipline B-1/B-2: pure sequencing. Read-only (B-6, I-6).

import Foundation
import GeniusLocusKit
import LocusKit
import SubstrateML

// MARK: - ExpandedSource

/// One source memory expanded from a distilled factoid.
public struct ExpandedSource: Sendable, Equatable, Codable {
    /// Source drawer UUID.
    public let id: String
    /// Room the source was filed in.
    public let room: String
    /// Full text content of the source memory.
    public let content: String

    public init(id: String, room: String, content: String) {
        self.id = id
        self.room = room
        self.content = content
    }
}

// MARK: - RecollectError

/// Errors thrown by `Recollect.run()`.
public enum RecollectError: Error, Sendable, Equatable {
    /// The drawer exists but carries no DIST header — it is not a distilled factoid.
    case notADistilledDrawer(id: String)
    /// The factoid drawer ID was absent from the estate (hydrate returned nil).
    case factoidNotFound(id: String)
    /// The factoid exists and is valid but has no outgoing `_distilled_from` tunnels.
    case noSourceTunnels(id: String)
}

// MARK: - Recollect

/// Fan-out from a distilled factoid to its source memories.
///
/// Traverses the outgoing `_distilled_from` tunnel graph from a `_distilled`
/// drawer and returns the full episodic content of the M source memories that
/// produced it. The caller synthesises the sources into a user-facing narrative.
///
/// Three error gates enforce structural invariants before content is returned:
///   - `factoidNotFound` — the ID is not in this estate at all.
///   - `notADistilledDrawer` — the drawer exists but lacks a DIST header.
///   - `noSourceTunnels` — the factoid predates tunnel wiring or was mined
///     on a path that did not emit tunnels; fall back to `lineage_id` + cluster.
///
/// Withdrawn sources are absent from the hydrate result map and are silently
/// skipped, so `Output.sourceCount` (from the DIST header) may exceed
/// `Output.sources.count` after withdrawals.
///
/// Read-only (B-6, I-6). Pure sequencing (B-1 / B-2). No side effects.
public struct Recollect: Recipe {

    // MARK: Input / Output

    /// UUID of the `_distilled` drawer to fan out from.
    public struct Input: Sendable {
        /// The `_distilled` drawer UUID to fan out from.
        public let factoidDrawerID: String

        public init(factoidDrawerID: String) {
            self.factoidDrawerID = factoidDrawerID
        }
    }

    /// Factoid metadata and its source memories, ordered oldest → newest.
    public struct Output: Sendable {
        /// The factoid drawer UUID.
        public let factoidID: String
        /// Factoid prose (DIST header stripped).
        public let prose: String
        /// Confidence score conf(F*) ∈ [0, 1], from DIST header.
        public let confidence: Float32
        /// Source count M from DIST header. May exceed `sources.count` if
        /// some sources were subsequently withdrawn from the estate.
        public let sourceCount: Int
        /// DeltaType raw string when the factoid was promoted from a
        /// non-static sequence (e.g. "CONVERGENT"); nil for STATIC factoids.
        public let deltaType: String?
        /// Source memories ordered oldest → newest (by tunnel filedAt).
        public let sources: [ExpandedSource]
    }

    // MARK: Recipe metadata

    public let name = "recollect"
    public let version = "1.0.0"
    public let description =
        "Recollect: fan-out from a distilled factoid to its source memories. " +
        "Follows the _distilled_from tunnel graph and returns full episodic content " +
        "from the M memories that produced the factoid. Use when the user " +
        "needs the full explanation behind a dense factoid. The AI synthesises " +
        "the sources into a user-facing narrative."
    public let requiredCapabilities: [NeuronKitCapability] = []

    public init() {}

    // MARK: run

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // 1. Hydrate factoid drawer, validate DIST header.
        //
        //    Frame-aware hydration (parity with Rust run_recollect step 1) enforces
        //    the sensitivity ceiling via BitmapEvaluator::insert_defaults →
        //    SensitivityAtMost(Elevated). A restricted or secret factoid is absent
        //    from the admissible result → factoidNotFound — preventing disclosure
        //    of elevated factoid bodies at the MCP boundary. secfix/punt-g2.
        //
        //    Empty filter chain: insert_defaults applies SensitivityAtMost(Elevated)
        //    as the default ceiling; no caller-supplied filter is needed here because
        //    this is a single-id lookup (no confirmation-axis narrowing required).
        //    HydrationLevel.full is required so that drawer.content is populated for
        //    DIST header parsing (Structured level leaves content empty → spurious
        //    notADistilledDrawer). Parity with Rust's HydrationLevel::Full.
        let factoidFrame = RecallFrame(filterChain: [], hydrationLevel: .full, limit: 1)
        let factoidDrawers = try await kit.hydrate(
            estate, ids: [input.factoidDrawerID], matchingFrame: factoidFrame, hydrationLevel: .full)
        guard let factoidContent = factoidDrawers.first(where: { $0.id == input.factoidDrawerID })?.content else {
            throw RecollectError.factoidNotFound(id: input.factoidDrawerID)
        }
        guard let header = DistilledHeader.parse(factoidContent) else {
            throw RecollectError.notADistilledDrawer(id: input.factoidDrawerID)
        }

        // 2. Resolve the estate's default wing.
        //    the default wing is the fixed constant `LocusKit.defaultWingName`
        //    ("Agentic Memory"). Distilled factoids and their _distilled_from tunnels are
        //    filed in this wing by Consolidate and captureFactoid. No kit.estate(for:) call
        //    is made; the constant is read directly.
        let wing = LocusKit.defaultWingName

        // 3. Recall all tunnels in the estate's wing; filter to the outgoing
        //    _distilled_from edges where this factoid is the source.
        //    Sort oldest → newest so the narrative reads chronologically.
        let allTunnels = try await kit.recallTunnels(estate, wing: wing)
        let sourceTunnels = allTunnels
            .filter { $0.sourceDrawerId == input.factoidDrawerID && $0.label == "_distilled_from" }
            .sorted { $0.filedAt < $1.filedAt }

        guard !sourceTunnels.isEmpty else {
            throw RecollectError.noSourceTunnels(id: input.factoidDrawerID)
        }

        // 4. Hydrate source drawers in one frame-aware call. The default recall
        //    frame applies liveness/trust/sensitivity guards and tombstone
        //    exclusion before full source content reaches the MCP boundary.
        //    sourceCount (from the header) records M at distillation time and
        //    remains accurate even when sources.count shrinks due to filtering.
        let sourceIDs = sourceTunnels.compactMap(\.targetDrawerId)
        let frame = RecallFrame(filterChain: [], hydrationLevel: .full, limit: sourceIDs.count)
        let sourceDrawers = try await kit.hydrate(
            estate, ids: sourceIDs, matchingFrame: frame, hydrationLevel: .full)
        let sourceBodyMap = Dictionary(
            uniqueKeysWithValues: sourceDrawers.map { ($0.id, $0.content) })

        let sources: [ExpandedSource] = sourceTunnels.compactMap { tunnel in
            guard let targetID = tunnel.targetDrawerId,
                  let content = sourceBodyMap[targetID] else { return nil }
            return ExpandedSource(id: targetID, room: tunnel.targetRoom, content: content)
        }

        return Output(
            factoidID: input.factoidDrawerID,
            prose: header.prose,
            confidence: header.confidence,
            sourceCount: header.sourceCount,
            deltaType: header.deltaType?.rawValue,
            sources: sources
        )
    }
}
