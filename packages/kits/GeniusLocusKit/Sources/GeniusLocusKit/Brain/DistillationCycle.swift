// DistillationCycle.swift
//
// Per-item distillation for GeniusLocusKit.
//
// Implements the intra-item distillation model: each stored item is reduced
// from its own sentences (the item's "memories" in the M×|V| matrix).
// Features recurring across most of the item's own passages form its
// structural core and become the factoid.
//
// NeuronKit is NOT a GeniusLocusKit dependency, so the distillation
// function is injected as a closure (DistillationInput → DistillationOutput).
// Both DistillationInput and DistillationOutput are defined in SubstrateML,
// which IS a GeniusLocusKit dependency. Callers at the app layer bridge
// NeuronKit.distillCluster or a test stub.

import EideticLib
import EngramLib
import Foundation
import LocusKit
import OSLog
import PersistenceKit
import SubstrateML
import VectorKit

// MARK: - Per-item distillation (intra-item reduction)

public extension GeniusLocusKit {


    /// Distill a SINGLE item into a factoid from its OWN chunks — the
    /// sub-quadratic *intra-item* reduction. The item's content is chunked and
    /// the chunks become the M rows of the M×|V| incidence matrix, so features
    /// that recur ACROSS the item's own passages form its structural core. This
    /// is the corrected distillation model: a single document distills on its
    /// own, with no sibling memories and no cross-memory cluster.
    ///
    /// Sentence segmentation is the per-item unit, and ≥3 is REQUIRED: with
    /// M < 3 every feature has df = 1.0, so every pairwise PMI = 0, the coherence
    /// graph fragments, and no honest factoid can form. A too-short item (fewer
    /// than 3 sentences) is simply not distilled.
    ///
    /// `distillFn` is injected — GLK does not depend on NeuronKit; the closure
    /// pattern matches the per-item distillation used throughout CognitionKit.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - drawerID: the source item's drawer id.
    ///   - content: the item's text content (sentence-segmented here).
    ///   - distillFn: injected distillation function (DistillationInput → Output).
    ///   - now: deterministic clock, stamped into the factoid.
    /// - Returns: the factoid drawer id when a factoid was produced; nil when the
    ///   item was too short to form a usable matrix, or the pipeline held/failed
    ///   it below the confidence gate.
    func distillItem(
        handle: EstateHandle,
        drawerID: String,
        content: String,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date
    ) async throws -> String? {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let vectorStore = vectorStores[handle] else { return nil }
        let estate = try estate(for: handle)

        // Segment the item's own content into sentences — the per-item reduction
        // units (the item's "memories" in the M×|V| matrix). Sentences are the
        // natural fine-grained statement unit: a feature recurring across most
        // sentences is central to the item. This is the SAME segmenter the corpus
        // Chunker uses, so the units are consistent with the dense index.
        let sentences = EideticLib.sentences(content).map(String.init)
        // M < 3 degenerates the matrix (df = 1.0 everywhere → PMI = 0 → no
        // coherence). Short items carry no intra-item recurrence to reduce.
        guard sentences.count >= 3 else { return nil }

        let input = DistillationInput(
            memoryContents: sentences,
            memoryTimestamps: nil,
            clusterID: drawerID,
            sourceIDs: [drawerID]
        )
        let output = distillFn(input)
        // Produce whenever the pipeline computed a real dominant component F*
        // (non-zero feature fingerprint). For intra-item distillation the factoid
        // is always emitted from the item's recurring core — confidence rides
        // along as metadata (the `uncertain` flag / injection depth), it does not
        // gate production. The early-failure paths (no features, empty F*) return
        // a zero fingerprint and are correctly skipped.
        guard output.featureFingerprint != .zero else { return nil }

        // Provenance: the single source item. captureFactoid writes the factoid
        // into "_distilled", stores its featureFingerprint in the
        // distillation-features-v1 lane, and links factoid → source.
        let memberDrawers = try await fetchDrawerRows(ids: [drawerID], storage: storage)
        guard !memberDrawers.isEmpty else { return nil }
        return try await captureFactoid(
            output: output,
            clusterID: drawerID,
            estate: estate,
            memberDrawers: memberDrawers,
            vectorStore: vectorStore,
            now: now
        )
    }

    /// Per-item distillation sweep — distill every active, not-yet-distilled item
    /// long enough to chunk into a usable matrix. Turns each stored item into its
    /// factoid using the intra-item reduction model.
    ///
    /// Idempotent: a factoid is captured in "_distilled" with `lineageID` equal
    /// to its source item's id, so items that already produced a factoid are
    /// skipped on re-run.
    ///
    /// - Parameters:
    ///   - handle: the estate. Must be open.
    ///   - distillFn: injected distillation function (DistillationInput → Output).
    ///   - now: deterministic clock.
    ///   - limit: optional cap on items distilled this sweep (nil = all eligible).
    /// - Returns: count of factoids produced this sweep.
    func distillItemsSweep(
        handle: EstateHandle,
        distillFn: @escaping @Sendable (DistillationInput) -> DistillationOutput,
        now: Date,
        limit: Int? = nil
    ) async throws -> Int {
        let estate = try estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        // Items already distilled: a "_distilled" factoid's lineageID is its
        // source item's UUID. Skip any source whose id is already in this set.
        let distilledSources: Set<UUID> = Set(
            allDrawers.filter { $0.room == "_distilled" }.map { $0.lineageID }
        )
        let candidates = allDrawers.filter { drawer in
            guard drawer.tombstonedAt == nil,
                  !drawer.content.isEmpty,
                  drawer.room != "_distilled" else { return false }
            if let uuid = UUID(uuidString: drawer.id), distilledSources.contains(uuid) {
                return false
            }
            return true
        }
        var produced = 0
        for drawer in candidates {
            if let cap = limit, produced >= cap { break }
            if try await distillItem(
                handle: handle, drawerID: drawer.id, content: drawer.content,
                distillFn: distillFn, now: now) != nil {
                produced += 1
            }
        }
        return produced
    }
}

// MARK: - Private helpers

private extension GeniusLocusKit {

    // MARK: - Drawer query helpers

    /// Minimal projection of a drawers row used by the sweep.
    struct DrawerRow: Sendable {
        let id: String
        let content: String
        let wing: String
        let room: String
        let filedAt: Date?
    }

    /// Fetch content, wing, room, and filedAt for the given drawer UUIDs.
    func fetchDrawerRows(ids: [String], storage: any Storage) async throws -> [DrawerRow] {
        guard !ids.isEmpty else { return [] }
        let values = ids.map { TypedValue.text($0) }
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .in(Column(table: "drawers", name: "id"), values),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { row in
            guard
                let id = stringValue(row["id"]),
                let content = stringValue(row["content"]),
                let wing = stringValue(row["wing"]),
                let room = stringValue(row["room"])
            else { return nil }
            return DrawerRow(
                id: id,
                content: content,
                wing: wing,
                room: room,
                filedAt: dateValue(row["filedAt"])
            )
        }
    }

    // MARK: - Factoid capture

    /// Capture the distilled factoid drawer, store its structural fingerprint
    /// in VectorKit's distillation lane, and write M _distilled_from tunnels.
    ///
    /// The factoid is an ordinary drawer in room "_distilled" with
    /// addedBy = "distillation-daemon" per DISTILLATION_DESIGN.md §0.
    /// The lineageID is set to the cluster UUID so recipes can trace a
    /// factoid back to its source cluster.
    ///
    /// Returns the factoid's UUID string.
    func captureFactoid(
        output: DistillationOutput,
        clusterID: String,
        estate: LocusKit.Estate,
        memberDrawers: [DrawerRow],
        vectorStore: VectorStore,
        now: Date
    ) async throws -> String {
        // Derive the estate's wing name from the manifest owner identifier.
        // Mirrors LocusKit.EstateVerbs.defaultWing() (private there).
        let manifest = try await estate.manifest
        let wing = manifest.ownerIdentifier.isEmpty
            ? "wing_default"
            : "wing_\(manifest.ownerIdentifier)"

        let lineageID = UUID(uuidString: clusterID) ?? UUID()

        // Capture the factoid as an ordinary drawer in "_distilled".
        // embeddingModelID = "distillation-features-v1": this is the lane
        // under which VectorKit will store the structural fingerprint below.
        // channel = .actuator: daemon-generated content (cookbook §2.4).
        // sourceType = .derived: inferred from existing content (Provenance §F13).
        // latticeAnchor "001": UDC Knowledge class — appropriate for synthesized
        // knowledge drawers per spec I-5 (udcCode must not be empty).
        let captureFrame = CaptureFrame(
            content: output.drawerContent,
            channel: .actuator,
            room: "_distilled",
            latticeAnchor: LatticeAnchor.udc("001"),
            addedBy: "distillation-daemon",
            embeddingModelID: "distillation-features-v1",
            sourceType: .derived,
            lineageID: lineageID
        )

        let factoid = try await estate.capture(captureFrame)
        let factoidID = factoid.id

        // Store the structural fingerprint in the distillation-features-v1 lane.
        // This is the second VectorKit lane, independent of the prose embedding
        // lane. It enables no-inference Hamming NN via findNearestDistilled.
        try await vectorStore.addVector(
            itemID: factoidID,
            engram: output.featureFingerprint,
            modelID: "distillation-features-v1",
            modelVersion: "1",
            filedAt: now
        )

        // Write M _distilled_from tunnels: factoid → each source drawer.
        // Direction: source = factoid (the synthesis), target = raw memory.
        // originClass = .derived: tunnel relationship inferred by the substrate.
        for sourceDrawer in memberDrawers {
            let tunnelFrame = TunnelCaptureFrame(
                sourceWing: wing,
                sourceRoom: "_distilled",
                targetWing: sourceDrawer.wing,
                targetRoom: sourceDrawer.room,
                label: "_distilled_from",
                addedBy: "distillation-daemon",
                sourceDrawerId: factoidID,
                targetDrawerId: sourceDrawer.id,
                kind: .references,
                originClass: .derived
            )
            _ = try await estate.capture(tunnelFrame)
        }

        return factoidID
    }

    // MARK: - TypedValue extraction helpers

    func stringValue(_ v: TypedValue?) -> String? {
        // Tolerate both forms a string-bearing column can take after a round
        // trip through storage. A column declared `.uuid` is written as `.text`
        // but the SQLite backend's schema-hinted read converts it back to `.uuid`
        // — so a `.text`-only guard silently returns nil on SQLite estates.
        // The InMemory backend returns `.text`. Accept both forms.
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        default: return nil
        }
    }

    func int64Value(_ v: TypedValue?) -> Int64? {
        guard case .int(let i) = v else { return nil }
        return i
    }

    func jsonData(_ v: TypedValue?) -> Data? {
        switch v {
        case .json(let d): return d
        case .blob(let d): return d
        default: return nil
        }
    }

    func dateValue(_ v: TypedValue?) -> Date? {
        guard case .timestamp(let d) = v else { return nil }
        return d
    }
}
