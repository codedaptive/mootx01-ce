import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateTypes

/// Which facet of the anchor to match on — the three recalls one cue
/// affords.
public enum CueMode: Sendable, Equatable, Codable {
    /// Structurally alike but conceptually different — "feels like this".
    case feelsLike
    /// Same concept, different structure — "about this".
    case aboutThis
    /// Same period, different concept — "from then".
    case fromThen

    /// (matchBlocks, differBlocks) for this cue.
    var blocks: (match: Set<FingerprintBlock>, differ: Set<FingerprintBlock>) {
        switch self {
        case .feelsLike: return ([.structure], [.concept])
        case .aboutThis: return ([.concept], [.structure])
        case .fromThen: return ([.temporal], [.concept])
        }
    }
}

/// One matched memory and its partial-cue score.
public struct CueMatch: Sendable, Equatable, Codable {
    public let id: String
    public let score: Double
    public init(id: String, score: Double) {
        self.id = id
        self.score = score
    }
}

/// The cue pointed at nothing: `anchorID` was not in the recalled set.
/// The Swift face of the fault the Rust version reports through its
/// `Substrate` arm (INTERFACE § 4 — Rust's `SubstrateError` encodes
/// Swift's propagated `throws`).
public struct AnchorNotInRecalledSetError: Error, Equatable {
    public let anchorID: String
    public init(anchorID: String) {
        self.anchorID = anchorID
    }
}

/// PartialCueRecall (FeelsLike / AboutThis / FromThen) — the conscious
/// partial-cue recall recipe (Lens 7, Associative). One anchor memory,
/// three different recalls depending which fingerprint block you query:
/// memories that FEEL structurally like it, that are ABOUT the same
/// concept, or that are FROM the same period. The cue is one drawer;
/// the lens is which facet you match on.
///
/// Layer discipline (SPEC § 5, B-1/B-2): sequencing — recall via GLK,
/// compute each drawer's 4-block fingerprint via LocusKit's
/// `EstateFingerprintFamilies`, and rank by NeuronKit `partialRecall`
/// (SubstrateML PartialStateRecall). The String drawer ids are mapped
/// to the recall primitive's row UUIDs by a per-call table and mapped
/// back on the way out. Read-only (B-6, I-6). Swift version of
/// `run_partial_cue_recall`.
public enum PartialCueRecall {

    /// Recall via `frame`, then rank the recalled memories (excluding
    /// the anchor) by partial-cue similarity to `anchorID` under `mode`,
    /// top `k`. Throws `AnchorNotInRecalledSetError` if `anchorID` is
    /// not in the recalled set. Read-only; a recall failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        frame: LocusKit.RecallFrame,
        anchorID: String,
        mode: CueMode,
        k: Int
    ) async throws -> [CueMatch] {
        let drawers = try await kit.recall(handle, frame)

        // Fingerprint families seeded by the estate uuid so the four
        // blocks are computed consistently for every drawer in this call.
        let estate = try await kit.estate(for: handle)
        let families = EstateFingerprintFamilies(
            estateUUID: await estate.estateUUID.uuidString)

        // Compute fingerprints; pull out the anchor; key the rest by a
        // fresh per-call UUID (the primitive's row key) mapped back to
        // the drawer id on the way out.
        var anchorFingerprint: Fingerprint256?
        var rows: [(rowID: UUID, fingerprint: Fingerprint256)] = []
        var drawerIDByRowID: [UUID: String] = [:]
        for drawer in drawers {
            let fingerprint = families.fingerprint(of: drawer)
            if drawer.id == anchorID {
                anchorFingerprint = fingerprint
                continue   // never rank the anchor against itself
            }
            let rowID = UUID()
            rows.append((rowID, fingerprint))
            drawerIDByRowID[rowID] = drawer.id
        }
        guard let anchorFingerprint else {
            throw AnchorNotInRecalledSetError(anchorID: anchorID)
        }

        let (matchBlocks, differBlocks) = mode.blocks
        let ranked = NeuronKit.partialRecall(
            anchor: anchorFingerprint, rows: rows,
            matchBlocks: matchBlocks, differBlocks: differBlocks, k: k)

        return ranked.map { CueMatch(id: drawerIDByRowID[$0.rowID]!, score: $0.score) }
    }
}
