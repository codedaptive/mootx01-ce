// Assembler.swift
//
// The MDCC assembler. Ingests a CC0 source graph (Wikidata
// subclass/instance dump in the production pipeline; a fixture file
// in the test pipeline) and produces an MDCC canon: a mapping from
// source identity to MDCC code, plus the entries for the slow-docs
// channel.
//
// The assembler is deterministic. The same input produces the same
// output across runs, across machines, across processor architectures.
// Two mechanisms enforce that:
//
//   1. The collapse rule (see CollapseRule.swift) is total over the
//      input — every multi-parent or cyclic case has a defined
//      tie-break that does not depend on iteration order or hash
//      randomisation.
//
//   2. The assignment walk (this file) sorts the input on stable keys
//      before iterating, and consults the stable-key registry first
//      so a source identity that already has a pinned code keeps it.
//
// The pipeline:
//
//   load source graph
//     -> apply collapse rule, producing single-parent tree
//     -> walk the tree depth-first, assigning each leaf to a class
//        based on its pinned class (editorial input) or its parent's
//        class (default propagation)
//     -> for each leaf, consult the stable-key registry; if not
//        present, assign the next free code in the leaf's owning
//        class
//     -> emit a Canon containing the updated registry plus the
//        entries that resolve each code to its source identity and
//        human-readable label

import Foundation

/// A single concept entering the assembler. The label is the
/// human-readable English name from the CC0 source (Wikidata label).
/// `pinnedClassBase`, when present, forces the concept into a
/// specific spine class — overriding any inference from the parent
/// graph. Pinned-class assignments are editorial input shipped with
/// each canon.
public struct SourceConcept: Sendable, Hashable, Codable {
    public let sourceIdentity: String
    public let label: String
    public let pinnedClassBase: Int?

    public init(sourceIdentity: String, label: String, pinnedClassBase: Int? = nil) {
        self.sourceIdentity = sourceIdentity
        self.label = label
        self.pinnedClassBase = pinnedClassBase
    }
}

/// The bundle handed to the assembler: the set of source concepts,
/// the edges between them, the pinned parents, and the existing
/// stable-key registry (empty for a v1 cold build, populated for
/// quarterly rebuilds against an existing canon).
public struct AssemblerInput: Sendable {
    public let concepts: [SourceConcept]
    public let edges: [SourceEdge]
    public let pinnedParents: PinnedParents
    public let registry: StableKeyRegistry
    public let canonVersion: String

    public init(
        concepts: [SourceConcept],
        edges: [SourceEdge],
        pinnedParents: PinnedParents,
        registry: StableKeyRegistry,
        canonVersion: String
    ) {
        self.concepts = concepts
        self.edges = edges
        self.pinnedParents = pinnedParents
        self.registry = registry
        self.canonVersion = canonVersion
    }
}

/// A diagnostic produced by the assembler — a graph-shape issue the
/// build chose to skip rather than fail on. Diagnostics are emitted
/// alongside the canon so the slow-docs channel can render a report.
public struct AssemblerDiagnostic: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case orphanCycle              // every parent path closes a cycle
        case classExhausted           // class full to maxExtensionDigits
        case unknownPinnedClass       // pinnedClassBase points at no spine class
        case duplicateSourceIdentity  // two concepts share a source identity
    }

    public let kind: Kind
    public let sourceIdentity: String
    public let detail: String

    public init(kind: Kind, sourceIdentity: String, detail: String) {
        self.kind = kind
        self.sourceIdentity = sourceIdentity
        self.detail = detail
    }
}

/// The assembler output.
public struct AssemblerOutput: Sendable {
    public let canon: LatticeCanon
    public let registry: StableKeyRegistry
    public let diagnostics: [AssemblerDiagnostic]

    public init(canon: LatticeCanon, registry: StableKeyRegistry, diagnostics: [AssemblerDiagnostic]) {
        self.canon = canon
        self.registry = registry
        self.diagnostics = diagnostics
    }
}

/// The MDCC assembler. Pure function from input to output: same input
/// always produces the same output. No I/O happens inside; callers
/// load the source graph (from a Wikidata dump or a test fixture) and
/// hand it in.
public enum Assembler {

    /// Runs the assembler. Determinism is enforced by sorting all
    /// inputs on stable keys at every iteration point.
    public static func assemble(_ input: AssemblerInput) -> AssemblerOutput {
        var diagnostics: [AssemblerDiagnostic] = []

        // 1. Deduplicate by source identity, preserving the first
        //    occurrence in stable-sorted order. Subsequent duplicates
        //    are reported as diagnostics, not silently dropped.
        var byIdentity: [String: SourceConcept] = [:]
        for concept in input.concepts.sorted(by: { $0.sourceIdentity < $1.sourceIdentity }) {
            if byIdentity[concept.sourceIdentity] != nil {
                diagnostics.append(AssemblerDiagnostic(
                    kind: .duplicateSourceIdentity,
                    sourceIdentity: concept.sourceIdentity,
                    detail: "Second occurrence dropped; first wins."
                ))
                continue
            }
            byIdentity[concept.sourceIdentity] = concept
        }

        // 2. Build the candidate-parents map by walking edges in
        //    stable order. Each child accumulates its parents as a
        //    sorted-unique array.
        var candidates: [String: [String]] = [:]
        for edge in input.edges.sorted(by: { ($0.child, $0.parent) < ($1.child, $1.parent) }) {
            var existing = candidates[edge.child] ?? []
            if !existing.contains(edge.parent) {
                existing.append(edge.parent)
            }
            candidates[edge.child] = existing
        }

        // 2b. Routing nodes: edge parents that are not themselves
        //     concepts in the seed. The edge fetch admits them one hop
        //     outside the seed (see EdgeFetcher's one-hop rule). A
        //     routing node is never emitted as a canon entry — the
        //     emission and orphan passes below iterate seed identities
        //     only, so a routing node held in `assignedClass` is invisible
        //     to both. Its sole purpose is to carry its children to a
        //     real spine class: its own class is derived (in the fixpoint
        //     below) from its already-placed children, so an unpinned
        //     child whose only parent is out of seed reaches that class
        //     instead of collapsing to Generalities.
        let conceptIdentities = Set(byIdentity.keys)
        var routingChildren: [String: [String]] = [:]
        for edge in input.edges.sorted(by: { ($0.child, $0.parent) < ($1.child, $1.parent) }) {
            guard !conceptIdentities.contains(edge.parent) else { continue }
            routingChildren[edge.parent, default: []].append(edge.child)
        }
        let routingNodes = routingChildren.keys.sorted()

        // 3. Class assignment. A concept with a pinnedClassBase is
        //    pinned regardless of its parents. Otherwise we walk the
        //    collapsed parent path until we hit a pin or a concept
        //    whose pinnedClassBase exists. Concepts that cannot be
        //    resolved to a class are deferred and then placed in 000
        //    (Generalities) as a fallback — this is documented
        //    behaviour, not an error.
        var assignedClass: [String: LatticeClass] = [:]
        let identities = byIdentity.keys.sorted()

        // First pass: direct pins.
        for identity in identities {
            guard let concept = byIdentity[identity] else { continue }
            if let base = concept.pinnedClassBase {
                if let cls = NotationSpine.owningClass(forBase: base) {
                    assignedClass[identity] = cls
                } else {
                    diagnostics.append(AssemblerDiagnostic(
                        kind: .unknownPinnedClass,
                        sourceIdentity: identity,
                        detail: "pinnedClassBase=\(base) does not match any spine class."
                    ))
                }
            }
        }

        // Second pass: propagate via the collapse rule. We iterate to
        // a fixpoint; each iteration places any concept whose chosen
        // parent has already been placed. The iteration terminates
        // because the number of unplaced concepts strictly decreases
        // or we stop making progress (orphans).
        var progressed = true
        var pass = 0
        while progressed && pass < 32 {
            progressed = false
            pass += 1
            // Rebuild the rule each pass so the tier-2 resolver sees
            // the current class assignments. CollapseRule is a value
            // type and the resolver is captured at construction, so
            // we must reconstruct it whenever assignedClass changes.
            let currentMap = assignedClass
            let collapse = CollapseRule(
                pins: input.pinnedParents,
                resolver: { id in currentMap[id] }
            )
            for identity in identities where assignedClass[identity] == nil {
                let candidatesForChild = candidates[identity] ?? []
                let parent = collapse.selectParent(
                    for: identity,
                    candidates: candidatesForChild,
                    visited: [identity]
                )
                guard let parent else { continue }
                if let parentClass = assignedClass[parent] {
                    assignedClass[identity] = parentClass
                    progressed = true
                }
            }
            // Classify routing nodes from their already-placed children
            // so the next pass can propagate the routing node's class
            // down to its still-unplaced children. Lowest base wins,
            // mirroring the collapse rule's tier-2 general-over-specific
            // preference; the result is deterministic because
            // `routingNodes` is sorted and the min over a base set does
            // not depend on iteration order.
            for routingNode in routingNodes where assignedClass[routingNode] == nil {
                let placedBases = routingChildren[routingNode]!.compactMap { assignedClass[$0]?.base }
                if let minBase = placedBases.min(),
                   let cls = NotationSpine.owningClass(forBase: minBase) {
                    assignedClass[routingNode] = cls
                    progressed = true
                }
            }
        }

        // Third pass: orphan fallback. Any identity still unplaced
        // either has no parents, has only cyclic parents, or has
        // parents that never got placed themselves. They land in
        // class 000 (Generalities) and get an orphanCycle diagnostic.
        let generalities = NotationSpine.classes.first!  // 000 always exists
        for identity in identities where assignedClass[identity] == nil {
            assignedClass[identity] = generalities
            diagnostics.append(AssemblerDiagnostic(
                kind: .orphanCycle,
                sourceIdentity: identity,
                detail: "No reachable parent placed; assigned to Generalities (000)."
            ))
        }

        // 4. Code assignment. Walk identities in stable order. If the
        //    registry already has a code for the identity, reuse it.
        //    Otherwise, allocate the next free slot in the owning
        //    class. The allocator works against a running registry
        //    that includes both prior pins and the assignments made
        //    in this pass — so two new concepts in the same class do
        //    not collide.
        var entries: [StableKeyEntry] = input.registry.entries
        var workingRegistry = input.registry
        var canonEntries: [LatticeEntry] = []

        for identity in identities {
            guard let concept = byIdentity[identity],
                  let cls = assignedClass[identity] else { continue }

            let code: String
            if let pinned = workingRegistry.code(for: identity) {
                code = pinned
            } else if let next = workingRegistry.nextFreeCode(in: cls) {
                code = next
                entries.append(StableKeyEntry(
                    sourceIdentity: identity,
                    code: next,
                    firstAssignedInCanon: input.canonVersion
                ))
                workingRegistry = StableKeyRegistry(entries: entries)
            } else {
                diagnostics.append(AssemblerDiagnostic(
                    kind: .classExhausted,
                    sourceIdentity: identity,
                    detail: "Class \(cls.renderedBase) full to the maximum extension depth."
                ))
                continue
            }

            canonEntries.append(LatticeEntry(
                code: code,
                sourceIdentity: identity,
                label: concept.label,
                classBase: cls.base
            ))
        }

        // Stable sort the canon entries on code for predictable output.
        canonEntries.sort { $0.code < $1.code }

        let canon = LatticeCanon(
            canonVersion: input.canonVersion,
            entries: canonEntries
        )

        return AssemblerOutput(
            canon: canon,
            registry: workingRegistry,
            diagnostics: diagnostics.sorted(by: { ($0.sourceIdentity, $0.kind.rawValue) < ($1.sourceIdentity, $1.kind.rawValue) })
        )
    }
}
