// FormalConcepts.swift
//
// FormalConcepts — the conscious "what clusters are hidden in my estate"
// recipe (Analytics). Recalls a set of drawers, builds a FormalContext
// where each drawer is one row and its categorical facets are its
// attributes, and surfaces NeuronKit's BoundedConceptMiner.
//
// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//   - Estate read: one `GLK.recall` call.
//   - Context build: one row per recalled drawer; the drawer's discovery
//     spine + filing tiebreakers become `FormalAttribute` triples with
//     namespace "locus", key = axis name, value = the canonical lowercase
//     Swift case name (§ 4.2 vocabulary).
//   - Concept mining: one `BoundedConceptMiner.mine` call — the engine owns
//     all closure/dedup/ordering logic.
// Capability gate: `.formalConceptAnalysis` is verified before any estate
// touch (spec B-5, I-3).
//
// Discovery spine (FORMAL_CONCEPTS_DISCOVERY_SPINE_001): the context is
// built so concepts emerge from about-ness and provenance, not from the
// authored taxonomy. The spine attributes are trust (provenance), the
// lattice anchors udc/qid (about-ness — where in knowledge space), and
// sensitivity (access posture). The filing facets (kind/channel/room) are
// retained as secondary tiebreakers that can refine a concept but no longer
// define it.
//
// Drawer → FormalContext mapping:
//   Each drawer is one row of the FormalContext. Row ordering matches the
//   recall ordering. The drawer's attributes are:
//     FormalAttribute(namespace:"locus", key:"trust",       value:{caseName})
//     FormalAttribute(namespace:"locus", key:"sensitivity", value:{caseName})
//     FormalAttribute(namespace:"locus", key:"kind",        value:{caseName})
//     FormalAttribute(namespace:"locus", key:"channel",     value:{caseName})
//     FormalAttribute(namespace:"locus", key:"room",        value:{roomString})
//     FormalAttribute(namespace:"locus", key:"udc",         value:{udcCode})   // only when non-empty
//     FormalAttribute(namespace:"locus", key:"qid",         value:{wikidataQID}) // only when non-nil/non-empty
//   The `caseName` is the lowercase camelCase Swift case name (canonical
//   substrate vocabulary, § 4.2), identical across both versions.
//
// Anchor-omission (load-bearing): an absent anchor is OMITTED, never emitted
// as an empty attribute. A drawer with `udcCode == ""` contributes no `udc`;
// a drawer with `wikidataQID == nil` contributes no `qid`. Emitting `udc=` /
// `qid=` for unanchored drawers would fuse every unanchored drawer into one
// spurious shared concept — the opposite of discovery.
//
// Output relabeling: FormalConcept.extent is a [FormalContext.RowID] —
// 0-based row indices. The output converts these to the original drawer
// IDs via the recall-order index.
//
// Read-only (B-6): no write verb is issued.

import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

// MARK: - Result types

/// One mining result concept with the drawer IDs substituted for the
/// engine's raw row indices, and the intent as human-readable attribute
/// strings (e.g. "locus.kind=prose").
public struct FormalConceptResult: Sendable, Equatable {
    /// The intent: the attributes every extent row shares.
    /// Each element is a string of the form "{namespace}.{key}={value}".
    public let intent: [String]
    /// The drawer IDs of the concept's extent (the recalled drawers that
    /// carry every attribute in `intent`), in row-index ascending order.
    public let extentDrawerIDs: [String]
    /// Number of drawers in the extent — the FCA support measure.
    public let support: Int

    public init(intent: [String], extentDrawerIDs: [String], support: Int) {
        self.intent = intent
        self.extentDrawerIDs = extentDrawerIDs
        self.support = support
    }
}

// MARK: - Recipe

/// Bounded formal concept analysis over a recalled drawer set.
public struct FormalConcepts: Recipe {

    public struct Input: Sendable {
        /// The estate recall frame.
        public let frame: RecallFrame
        /// Bounding parameters for the miner.
        public let miner: BoundedConceptMiner

        public init(frame: RecallFrame, miner: BoundedConceptMiner) {
            self.frame = frame
            self.miner = miner
        }
    }

    public struct Output: Sendable {
        /// Mined concepts with drawer-ID extents, sorted by support
        /// descending (then intent size ascending, then lexicographic
        /// intent — matching `BoundedConceptMiner`'s output order).
        public let concepts: [FormalConceptResult]
        /// Number of drawers the context was built from.
        public let drawerCount: Int

        public init(concepts: [FormalConceptResult], drawerCount: Int) {
            self.concepts = concepts
            self.drawerCount = drawerCount
        }
    }

    public init() {}

    public let name = "formal_concepts"
    public let version = "1.0.0"
    public let description =
        "Recall a frame, build a formal context whose attributes are each drawer's trust, lattice anchors, sensitivity, and filing facets, and mine bounded formal concepts — emergent provenance and about-ness clusters, not the authored taxonomy."

    /// Requires the `formalConceptAnalysis` NeuronKit surface (spec I-3).
    public let requiredCapabilities: [NeuronKitCapability] = [.formalConceptAnalysis]

    public func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // B-5: verify capabilities before any substrate touch.
        try verifyCapabilities(required: requiredCapabilities)

        // 1. Recall drawers via the GLK recall verb (I-2).
        let drawers = try await kit.recall(estate, input.frame)
        let drawerCount = drawers.count

        guard drawerCount > 0 else {
            return Output(concepts: [], drawerCount: 0)
        }

        // 2. Build FormalContext: one row per drawer, categorical facets as
        //    attributes using the canonical "locus" namespace + axis key +
        //    lowercase camelCase case name (§ 4.2 vocabulary).
        let rows: [[FormalAttribute]] = drawers.map { drawer in
            formalAttributesForDrawer(drawer)
        }
        let context = FormalContext(rows: rows)

        // 3. Mine bounded concepts (engine owns all closure/dedup/ordering).
        let rawConcepts = input.miner.mine(context: context)

        // 4. Relabel: convert FormalContext.RowID (0-based index) back to
        //    drawer IDs; project FormalAttribute triples to "ns.key=value" strings.
        let results: [FormalConceptResult] = rawConcepts.map { concept in
            let intentStrings = concept.intent.map { attr in
                "\(attr.namespace).\(attr.key)=\(attr.value)"
            }
            let extentIDs = concept.extent.map { rowID in
                let idx = Int(rowID)
                return idx < drawers.count ? drawers[idx].id : ""
            }.filter { !$0.isEmpty }
            return FormalConceptResult(
                intent: intentStrings,
                extentDrawerIDs: extentIDs,
                support: concept.support)
        }

        return Output(concepts: results, drawerCount: drawerCount)
    }
}

// MARK: - Attribute helpers

/// Build the `FormalAttribute` set for a single recalled drawer — the
/// discovery spine (trust + lattice + sensitivity) plus the filing facets
/// as tiebreakers.
///
/// Namespace "locus" is the substrate vocabulary namespace. Key is the
/// axis name. Value is the canonical lowercase camelCase Swift case name —
/// identical across both versions (§ 4.2). The lattice anchors (udc/qid)
/// are omitted when absent (see the file header's anchor-omission note).
///
/// Internal (not private) so the anchor-omission and trust-vocabulary
/// behaviour can be unit-tested directly, independent of the estate's
/// capture-time I-5 constraint that forbids an empty `udcCode`.
func formalAttributesForDrawer(_ drawer: Drawer) -> [FormalAttribute] {
    var attributes: [FormalAttribute] = [
        // Spine — provenance: how the substrate qualifies the row's reliability.
        FormalAttribute(namespace: "locus", key: "trust",
                        value: trustValue(drawer.trust)),
        // Spine — access posture.
        FormalAttribute(namespace: "locus", key: "sensitivity",
                        value: sensitivityValue(drawer.adjectiveSensitivity)),
        // Tiebreakers — filing facets (retained, no longer the spine).
        FormalAttribute(namespace: "locus", key: "kind",
                        value: contentKindValue(drawer.contentKind)),
        FormalAttribute(namespace: "locus", key: "channel",
                        value: captureChannelValue(drawer.captureChannel)),
        FormalAttribute(namespace: "locus", key: "room",
                        value: drawer.room),
    ]
    // Spine — about-ness: the lattice anchors locating the drawer in
    // knowledge space. Omit-on-absent is load-bearing: an unanchored drawer
    // contributes NO udc/qid attribute, so unanchored drawers are never
    // fused by a spurious shared empty anchor. The empty string ("") is the
    // no-anchor sentinel for `udcCode`; `nil` is the no-anchor sentinel for
    // `wikidataQID` (an empty qid string is treated as absent too).
    if !drawer.udcCode.isEmpty {
        attributes.append(
            FormalAttribute(namespace: "locus", key: "udc", value: drawer.udcCode))
    }
    if let qid = drawer.wikidataQID, !qid.isEmpty {
        attributes.append(
            FormalAttribute(namespace: "locus", key: "qid", value: qid))
    }
    return attributes
}

private func trustValue(_ trust: Trust) -> String {
    switch trust {
    case .verbatim:  return "verbatim"
    case .observed:  return "observed"
    case .imported:  return "imported"
    case .canonical: return "canonical"
    case .derived:   return "derived"
    case .proposed:  return "proposed"
    case .ambient:   return "ambient"
    }
}

private func contentKindValue(_ kind: ContentKind) -> String {
    switch kind {
    case .prose:           return "prose"
    case .code:            return "code"
    case .transcript:      return "transcript"
    case .list:            return "list"
    case .structuredJSON:  return "structuredJSON"
    case .imageCaption:    return "imageCaption"
    case .fingerprintOnly: return "fingerprintOnly"
    }
}

private func captureChannelValue(_ channel: CaptureChannel) -> String {
    switch channel {
    case .typed:        return "typed"
    case .voiced:       return "voiced"
    case .ocr:          return "ocr"
    case .importedFile: return "importedFile"
    case .sensor:       return "sensor"
    case .actuator:     return "actuator"
    }
}

private func sensitivityValue(_ sensitivity: AdjectiveSensitivity) -> String {
    switch sensitivity {
    case .normal:     return "normal"
    case .elevated:   return "elevated"
    case .restricted: return "restricted"
    case .secret:     return "secret"
    }
}
