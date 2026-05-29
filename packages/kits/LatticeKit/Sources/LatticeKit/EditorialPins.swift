// EditorialPins.swift
//
// The editorial pin layer the assembler already accepts but that the
// compute-only build leaves at defaults. Two editorial inputs are
// loaded here from JSON authored by hand and shipped beside the canon:
//
//   parent_pins_v1.json — the pinned-parent map. For a multi-parent
//     Wikidata concept, names which candidate parent wins the collapse.
//     Loaded into `PinnedParents` (CollapseRule tier 1).
//
//   class_pins_v1.json — the pinned-class map. Names the spine class a
//     branch-anchor concept must land in, overriding the coarse
//     `udc_hint` bucketing. Loaded into `[String: Int]` (QID ->
//     classBase) and applied as `SourceConcept.pinnedClassBase`
//     (the assembler's first, highest-priority placement pass).
//
// Why two channels. The `udc_hint` bucketing collapses UDC's class 8
// ("Language. Linguistics. Literature") onto a single MDCC base (800),
// because the leading digit is all the coarse map reads. MDCC's spine
// separates 400 (Language and communication) from 800 (Literature), so
// the hint alone cannot tell a grammar from a novel. The class pin is
// the editorial correction: it moves the reviewed linguistics cohort to
// 400 regardless of the hint. The parent pin is the finer tool, used
// when a concept's correct class should follow a chosen parent's class
// rather than a flat assignment.
//
// Each JSON entry carries a `rationale` string so the canon's editorial
// decisions are self-documenting in the source data. The loader reads
// the behavioral fields and ignores `rationale` — it exists for the
// human auditor and the slow-docs channel, not the assembler.

import Foundation

/// Loader and model for the two editorial pin input files. Pure of
/// side effects beyond reading the files it is handed; callers resolve
/// the paths (the `mdcc-build` executable passes `--pins` /
/// `--class-pins`).
public enum EditorialPins {

    // MARK: - On-disk shapes

    /// A single pinned-parent entry. `child` and `parent` are CC0 source
    /// identities (Wikidata QIDs); `rationale` documents the editorial
    /// choice and is ignored by the loader.
    public struct ParentPin: Sendable, Codable {
        public let child: String
        public let parent: String
        public let rationale: String
    }

    /// A single pinned-class entry. `qid` is the concept's CC0 source
    /// identity; `classBase` is the spine base (000, 100, ... 900) the
    /// editor asserts; `rationale` documents the choice and is ignored
    /// by the loader.
    public struct ClassPin: Sendable, Codable {
        public let qid: String
        public let classBase: Int
        public let rationale: String
    }

    /// The `parent_pins_v1.json` document: a schema marker, an editorial
    /// note, and the pin array.
    public struct ParentPinFile: Sendable, Codable {
        public let schemaVersion: String
        public let note: String
        public let pins: [ParentPin]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case note
            case pins
        }
    }

    /// The `class_pins_v1.json` document: a schema marker, an editorial
    /// note, and the pin array.
    public struct ClassPinFile: Sendable, Codable {
        public let schemaVersion: String
        public let note: String
        public let pins: [ClassPin]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case note
            case pins
        }
    }

    // MARK: - Loaders

    /// Decodes a parent-pin file and builds the `PinnedParents` map the
    /// collapse rule consumes. A duplicate `child` is resolved
    /// last-wins, matching dictionary-literal semantics; authoring is
    /// expected to keep children unique.
    public static func loadParentPins(from url: URL) throws -> PinnedParents {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ParentPinFile.self, from: data)
        var map: [String: String] = [:]
        for pin in file.pins {
            map[pin.child] = pin.parent
        }
        return PinnedParents(map)
    }

    /// Decodes a class-pin file and builds the QID -> spine-base map
    /// applied as `SourceConcept.pinnedClassBase`. A duplicate `qid` is
    /// last-wins. The base is not validated here against the spine; the
    /// assembler emits an `unknownPinnedClass` diagnostic if a base
    /// matches no class, so a typo surfaces in the build report rather
    /// than being silently swallowed.
    public static func loadClassPins(from url: URL) throws -> [String: Int] {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ClassPinFile.self, from: data)
        var map: [String: Int] = [:]
        for pin in file.pins {
            map[pin.qid] = pin.classBase
        }
        return map
    }

    // MARK: - Application

    /// Returns `concepts` with `pinnedClassBase` overridden for every
    /// concept named in `classPins`. A class pin is editorial intent and
    /// outranks the `udc_hint`-derived default, so it replaces whatever
    /// `pinnedClassBase` the concept arrived with. Concepts not named in
    /// `classPins` pass through unchanged. Order is preserved.
    public static func apply(classPins: [String: Int], to concepts: [SourceConcept]) -> [SourceConcept] {
        guard !classPins.isEmpty else { return concepts }
        return concepts.map { concept in
            guard let base = classPins[concept.sourceIdentity] else { return concept }
            return SourceConcept(
                sourceIdentity: concept.sourceIdentity,
                label: concept.label,
                pinnedClassBase: base
            )
        }
    }
}
