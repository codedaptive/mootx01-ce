// NeuronKit.swift
//
// Module documentation and the public surface roll-up. The
// reasoning and autonomic functions land here as separate files;
// this file enumerates what NeuronKit ships and points readers at
// the specifications.
//
// First reasoning surface: the lattice-anchor inference path.
// NeuronKit imports EideticLib, calls its deterministic
// lookup(_:) function, and wraps the result in a substrate-shaped
// LatticeAnchorInference record that carries the provenance bit
// transition. The linguistic pipeline itself (tokenize, normalize,
// stem, resolve against the MDCC canon) is EideticLib's job;
// NeuronKit's job is the substrate-layer bookkeeping.

import Foundation
import EideticLib

/// NeuronKit module marker. Carries the module version and the
/// build configuration metadata callers may need for provenance
/// recording.
public enum NeuronKit {
    /// The NeuronKit module version. Pinned with the substrate
    /// schema version and incremented when reasoning or autonomic
    /// functions change in ways that affect output.
    public static let version: String = "0.1.0"

    /// The linguistic pipeline build configuration. Either
    /// `deterministicReference` (the always-available default,
    /// federation-compatible) or `appleNLAccel` (Swift-only Apple
    /// NaturalLanguage path, federation-disabled). Determined at
    /// compile time per MISSION_AE_02_APPLE_NL_ACCEL.md.
    public static var linguisticPipelineMode: LinguisticPipelineMode {
        #if APPLE_NLP_ACCEL
        return .appleNLAccel
        #else
        return .deterministicReference
        #endif
    }

    /// Looks up the lattice anchor for the given drawer content
    /// and packages it as a substrate-shaped
    /// `LatticeAnchorInference` carrying the provenance bit
    /// transition the substrate should apply. Composes
    /// EideticLib's deterministic lookup.
    public static func inferLatticeAnchor(
        _ content: String
    ) -> LatticeAnchorInference {
        let anchor = EideticLib.lookup(content)
        let status: EnrichmentStatus = {
            if anchor.code.isEmpty {
                return .none
            } else if anchor.wikidataQID == nil {
                return .qidPending
            } else {
                return .qidCompleted
            }
        }()
        return LatticeAnchorInference(
            code: anchor.code,
            wikidataQID: anchor.wikidataQID,
            confidence: anchor.confidence,
            enrichmentStatusBits: status.rawValue,
            pipelineMode: linguisticPipelineMode
        )
    }
}

// MARK: - Autonomic surface: dreaming daemon (§ 3.1)

public extension NeuronKit {

    /// Construct a dreaming daemon over the supplied substrate seams
    /// (NEURONKIT_SPEC § 3.1). This is the facade entry point: the
    /// daemon's own `registerDreamingPolicy(...)` and
    /// `triggerDreamingCycle(now:)` methods are the spec's registration
    /// and on-demand-trigger API.
    ///
    /// The daemon talks to the substrate only through these seams (B-1):
    /// `reader` for the reads it mines, `sink` for its two writes
    /// (proposal + cycle diary), `policyStore` for the manifest-resident
    /// policy, and `rewardSource` for the reward signal. The production
    /// adapter that binds the seams to live estate verbs lands with the
    /// GLK Brain layer; until then the GLK `propose` verb throws and no
    /// estate verb exposes the reads, so the seams cannot be wired to GLK
    /// here.
    ///
    /// - Parameters:
    ///   - reader: substrate read seam.
    ///   - sink: proposal + diary write seam.
    ///   - policyStore: manifest-resident policy persistence seam.
    ///   - rewardSource: reward-signal seam. Defaults to the v1
    ///     single-source `RecallTraceRewardSource` (`RecallTraceItem.used`).
    ///   - triggerMode: trigger seam. Defaults to `.timer` (no
    ///     SolverBandit dependency).
    /// - Returns: a configured `DreamingDaemon`.
    static func dreamingDaemon(
        reader: DreamingSubstrateReader,
        sink: DreamingProposalSink,
        policyStore: DreamingPolicyStore,
        rewardSource: RewardSource = RecallTraceRewardSource(),
        triggerMode: DreamingTriggerMode = .default
    ) -> DreamingDaemon {
        DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: rewardSource,
            policyStore: policyStore,
            triggerMode: triggerMode
        )
    }
}

// MARK: - Reasoning surface: branch ops + migration benchmark (§ 4.3, § 4.7)

// The COW branch operations and the migration recall-fidelity benchmark
// roll up into the public `NeuronKit` enum through net-new extension
// files rather than inline here, to keep this roll-up file declaration-
// free:
//
// - `BranchOps.swift` — `deriveBranch` / `promoteBranch` / `mergeDrawers`,
//   thin forwards over the GeniusLocusKit actor's COW branch verbs
//   (§ 4.3). NeuronKit stores no branch state (B-1); GLK is the
//   mechanical layer.
// - `BenchmarkAlgorithm.swift` — `benchmark(branch:against:queries:now:)`
//   and `BenchmarkReport`, the recall-fidelity scoring (§ 4.7) whose
//   `notFoundInBranch` is the zero-tolerance migration-loss signal
//   (C-13). The benchmark is read-only — it drives only
//   `BranchHandle.recall(_:)` and issues no estate write verb.
//   `ExternalCorpus` / `ExternalEntry` (the MemPalace-export reference
//   set the benchmark scores against) is defined in GeniusLocusKit and
//   imported here via the established GLK dependency.

/// The compile-time mode of the linguistic pipeline. Recorded in
/// the estate manifest so callers can audit and federate
/// accordingly.
public enum LinguisticPipelineMode: String, Sendable, Codable {
    /// Deterministic in-tree pipeline. Cross-language conformance
    /// guaranteed against the Rust version. Federation-compatible.
    case deterministicReference = "deterministic-reference"

    /// Apple NaturalLanguage acceleration path. Swift-only.
    /// Federation-disabled. Faster on Apple hardware for some
    /// operations.
    case appleNLAccel = "apple-nl-accel"
}
