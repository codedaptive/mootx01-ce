// ExpandMemory.swift
//
// Expands a "_distilled" factoid to its source memories by following
// outgoing "_distilled_from" tunnels.
//
// GLK call sequence (3 GLK verb calls, no SQL):
//   1. kit.hydrate([factoidID])        → validate DIST header
//   2. kit.estate(for:) → manifest    → derive estate wing
//      (manifest read via the estate actor — not counted as a verb call)
//   3. kit.recallTunnels(wing)         → filter source==factoidID, label=="_distilled_from"
//   4. kit.hydrate(sourceIDs)          → source content
//
// Layer discipline B-1/B-2: pure sequencing. Read-only (B-6, I-6).
// Note: the spec names step 2 as "kit.readManifest" — no such public GLK
// method exists. The equivalent path is kit.estate(for:).manifest, which
// reads the same manifest row through the public estate actor surface.

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

// MARK: - ExpandError

/// Errors thrown by `ExpandMemory.run()`.
public enum ExpandError: Error, Sendable, Equatable {
    /// The drawer exists but carries no DIST header — it is not a distilled factoid.
    case notADistilledDrawer(id: String)
    /// The factoid drawer ID was absent from the estate (hydrate returned nil).
    case factoidNotFound(id: String)
    /// The factoid exists and is valid but has no outgoing `_distilled_from` tunnels.
    case noSourceTunnels(id: String)
}

// MARK: - ExpandMemory

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
public struct ExpandMemory: Recipe {

    // MARK: Input / Output

    /// UUID of the `_distilled` drawer to expand.
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

    public let name = "expand_memory"
    public let version = "1.0.0"
    public let description =
        "Expand a distilled factoid to its source memories: follows the " +
        "_distilled_from tunnel graph and returns full episodic content " +
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
        let factoidBodyMap = try await kit.hydrate(estate, ids: [input.factoidDrawerID])
        guard let factoidContent = factoidBodyMap[input.factoidDrawerID] else {
            throw ExpandError.factoidNotFound(id: input.factoidDrawerID)
        }
        guard let header = DistilledHeader.parse(factoidContent) else {
            throw ExpandError.notADistilledDrawer(id: input.factoidDrawerID)
        }

        // 2. Resolve the estate's default wing.
        //    ADR-016: the default wing is the fixed constant `LocusKit.defaultWingName`
        //    ("Agentic Memory"). Distilled factoids and their _distilled_from tunnels are
        //    filed in this wing by Consolidate and captureFactoid. kit.estate(for:) is
        //    actor-isolated on GeniusLocusKit (public extension in EstateCoordinator.swift).
        let wing = LocusKit.defaultWingName

        // 3. Recall all tunnels in the estate's wing; filter to the outgoing
        //    _distilled_from edges where this factoid is the source.
        //    Sort oldest → newest so the narrative reads chronologically.
        let allTunnels = try await kit.recallTunnels(estate, wing: wing)
        let sourceTunnels = allTunnels
            .filter { $0.sourceDrawerId == input.factoidDrawerID && $0.label == "_distilled_from" }
            .sorted { $0.filedAt < $1.filedAt }

        guard !sourceTunnels.isEmpty else {
            throw ExpandError.noSourceTunnels(id: input.factoidDrawerID)
        }

        // 4. Hydrate source drawers in one call.
        //    Withdrawn sources are absent from the body map — skip silently.
        //    sourceCount (from the header) records M at distillation time and
        //    remains accurate even when sources.count shrinks due to withdrawals.
        let sourceIDs = sourceTunnels.compactMap(\.targetDrawerId)
        let sourceBodyMap = try await kit.hydrate(estate, ids: sourceIDs)

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
