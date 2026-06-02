// FormalConcepts.swift
//
// FormalConcepts — the conscious "what clusters are hidden in my estate"
// recipe (Analytics). Recalls a set of drawers, builds a FormalContext
// where each drawer is one row and its categorical facets are its
// attributes, and surfaces NeuronKit's BoundedConceptMiner.
//
// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
//   - Estate read: one `GLK.recall` call.
//   - Context build: one row per recalled drawer; the drawer's four
//     categorical facets (kind, channel, sensitivity, room) become
//     `FormalAttribute` triples with namespace "locus", key = axis name,
//     value = the canonical lowercase Swift case name (§ 4.2 vocabulary).
//   - Concept mining: one `BoundedConceptMiner.mine` call — the engine owns
//     all closure/dedup/ordering logic.
// Capability gate: `.formalConceptAnalysis` is verified before any estate
// touch (spec B-5, I-3).
//
// Drawer → FormalContext mapping:
//   Each drawer is one row of the FormalContext. Row ordering matches the
//   recall ordering. The drawer's attributes are:
//     FormalAttribute(namespace:"locus", key:"kind",        value:{caseName})
//     FormalAttribute(namespace:"locus", key:"channel",     value:{caseName})
//     FormalAttribute(namespace:"locus", key:"sensitivity", value:{caseName})
//     FormalAttribute(namespace:"locus", key:"room",        value:{roomString})
//   The `caseName` is the lowercase camelCase Swift case name (canonical
//   substrate vocabulary, § 4.2), identical across both versions.
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
        "Recall a frame, build a formal context where each drawer is a row with its categorical facets as attributes, and mine bounded formal concepts."

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

/// Build the `FormalAttribute` set for a single recalled drawer.
///
/// Namespace "locus" is the substrate vocabulary namespace. Key is the
/// categorical axis name. Value is the canonical lowercase camelCase
/// Swift case name — identical across both versions (§ 4.2).
private func formalAttributesForDrawer(_ drawer: Drawer) -> [FormalAttribute] {
    [
        FormalAttribute(namespace: "locus", key: "kind",
                        value: contentKindValue(drawer.contentKind)),
        FormalAttribute(namespace: "locus", key: "channel",
                        value: captureChannelValue(drawer.captureChannel)),
        FormalAttribute(namespace: "locus", key: "sensitivity",
                        value: sensitivityValue(drawer.adjectiveSensitivity)),
        FormalAttribute(namespace: "locus", key: "room",
                        value: drawer.room),
    ]
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
