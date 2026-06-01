// MDCCBuildMain.swift
//
// The `mdcc-build` executable: the reproducible production-canon build.
// It runs the pipeline end to end — load the CC0 concept seed, fetch
// the subclass/instance edge graph, assemble the canon through the
// existing deterministic `Assembler`, and write the four artifacts via
// `CanonWriter`. It prints a build report and exits non-zero if any
// concept is silently lost (placed in neither the canon nor a
// diagnostic), so a regression in the machinery fails the build rather
// than shipping a lossy canon.
//
// Network is used only for the live edge fetch (`WikidataEdgeSource`),
// and only when `--fixture` is absent. With `--fixture <path>` the
// build runs fully offline against a committed edge file — the mode CI
// and air-gapped builds use. Because every seed concept carries a
// pinned class derived from its UDC hint, a build with no edges still
// produces a real multi-class canon from the pins alone; edges only
// add inheritance for unpinned concepts.
//
// Usage:
//   mdcc-build [--seed <path>] [--fixture <edges.json>]
//              [--registry <prior.json>] [--out <dir>]
//              [--data-version <s>] [--access-date <YYYY-MM-DD>]
//
//   --seed         CC0 concept seed JSON. Defaults to EideticLib's
//                  committed WikidataSubset.json, resolved relative to
//                  the LatticeLib source tree.
//   --fixture      Offline edge graph: a JSON array of {child,parent}.
//                  When supplied, no network call is made.
//   --registry     Prior persisted registry to pin existing codes
//                  across the rerun. Omit for a cold build.
//   --prior-canon  Prior canon JSON to reconstruct the stable-key
//                  registry from when no persisted registry file exists.
//                  Concepts reclassified by --class-pins are excluded so
//                  they re-home with a fresh code in their new class; all
//                  other codes are preserved. Mutually exclusive with
//                  --registry in practice (the canon is the fallback).
//   --pins         Editorial pinned-parent map (parent_pins_v1.json),
//                  loaded into PinnedParents (CollapseRule tier 1).
//   --class-pins   Editorial pinned-class map (class_pins_v1.json),
//                  loaded into SourceConcept.pinnedClassBase overrides.
//   --out          Output directory for the four artifacts. Defaults to
//                  the current directory.
//   --data-version Provenance data_version string. Defaults to the
//                  seed's own data_version.
//   --access-date  Provenance access date (YYYY-MM-DD). Defaults to the
//                  current date at the CLI boundary.

import Foundation
import LatticeLib

/// Parsed command-line options.
struct BuildOptions {
    var seedPath: String?
    var fixturePath: String?
    var registryPath: String?
    var priorCanonPath: String?
    var pinsPath: String?
    var classPinsPath: String?
    var outDirectory: String = FileManager.default.currentDirectoryPath
    var dataVersionOverride: String?
    var accessDate: String?

    /// Parses options from the argument list (excluding the program
    /// name). Unrecognised flags are reported and abort the build.
    static func parse(_ args: [String]) -> BuildOptions {
        var opts = BuildOptions()
        var i = 0
        func nextValue(_ flag: String) -> String {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("mdcc-build: \(flag) requires a value\n".utf8))
                exit(2)
            }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--seed": opts.seedPath = nextValue("--seed")
            case "--fixture": opts.fixturePath = nextValue("--fixture")
            case "--registry": opts.registryPath = nextValue("--registry")
            case "--prior-canon": opts.priorCanonPath = nextValue("--prior-canon")
            case "--pins": opts.pinsPath = nextValue("--pins")
            case "--class-pins": opts.classPinsPath = nextValue("--class-pins")
            case "--out": opts.outDirectory = nextValue("--out")
            case "--data-version": opts.dataVersionOverride = nextValue("--data-version")
            case "--access-date": opts.accessDate = nextValue("--access-date")
            default:
                FileHandle.standardError.write(Data("mdcc-build: unknown argument '\(args[i])'\n".utf8))
                exit(2)
            }
            i += 1
        }
        return opts
    }
}

/// A build report: the headline counts the run produced.
struct BuildReport {
    let edgeSourceKind: String          // "wikidata-endpoint" or "fixture"
    let edgesFetched: Int               // edges returned by the source
    let routingNodeCount: Int           // one-hop parents pulled in from outside the seed
    let conceptsIn: Int
    let codesAssigned: Int
    let diagnosticsByKind: [String: Int]
    let classDistribution: [Int: Int]   // classBase -> entry count
    let silentlyLost: Int               // must be zero

    /// Renders the report for stdout.
    func rendered() -> String {
        var out = ""
        out += "MDCC build report\n"
        out += "  edge source:      \(edgeSourceKind)\n"
        out += "  edges fetched:    \(edgesFetched)\n"
        out += "  routing nodes:    \(routingNodeCount)\n"
        out += "  concepts in:      \(conceptsIn)\n"
        out += "  codes assigned:   \(codesAssigned)\n"
        out += "  silently lost:    \(silentlyLost)\n"
        out += "  diagnostics:\n"
        for kind in diagnosticsByKind.keys.sorted() {
            out += "    \(kind): \(diagnosticsByKind[kind]!)\n"
        }
        out += "  class distribution:\n"
        for base in classDistribution.keys.sorted() {
            let name = NotationSpine.owningClass(forBase: base)?.name ?? "?"
            out += "    \(String(format: "%03d", base)) \(name): \(classDistribution[base]!)\n"
        }
        return out
    }
}

/// The pipeline orchestration shared by the executable. Kept as a
/// static seam so the sequence — fetch edges, build input, assemble —
/// is named in one place; the integration test drives the identical
/// sequence against a `FixtureEdgeSource` using the library primitives.
enum BuildPipeline {

    /// Runs the assemble step: fetch edges for the concept QID set, then
    /// assemble. Pure of file I/O — the caller loads the seed and writes
    /// the artifacts. `pinnedParents` is the editorial parent-pin map
    /// (CollapseRule tier 1); pass `PinnedParents([:])` when no parent
    /// pins are supplied. Class pins are applied by the caller to the
    /// `concepts` before this point (as `SourceConcept.pinnedClassBase`).
    static func assemble(
        concepts: [SourceConcept],
        edgeSource: EdgeSource,
        pinnedParents: PinnedParents,
        priorRegistry: StableKeyRegistry,
        canonVersion: String
    ) async throws -> (output: AssemblerOutput, edgesFetched: Int, routingNodeCount: Int) {
        let qids = Set(concepts.map(\.sourceIdentity))
        let edges = try await EdgeFetcher(source: edgeSource).fetch(for: qids)
        // Routing nodes are the one-hop edge parents that are not
        // themselves seed concepts — the connection the one-hop rule
        // restores. Counted here for the build report; they never become
        // canon entries.
        let routingNodes = Set(edges.map(\.parent)).subtracting(qids)
        let input = AssemblerInput(
            concepts: concepts,
            edges: edges,
            pinnedParents: pinnedParents,
            registry: priorRegistry,
            canonVersion: canonVersion
        )
        return (Assembler.assemble(input), edges.count, routingNodes.count)
    }

    /// Reconstructs a stable-key registry from a prior canon JSON so a
    /// rerun preserves every code the prior canon assigned. A concept named in
    /// `classPins` whose pinned class differs from the class the prior
    /// canon recorded is EXCLUDED from the registry: it must re-home with
    /// a fresh code in its new class rather than carry its old code,
    /// which would leave the entry's code resolving to the wrong class.
    /// Concepts whose pin matches their existing class (or that are
    /// unpinned) keep their code, so unchanged concepts never churn.
    /// This is the warm-rebuild discipline MDCC-04 established, extended
    /// to the first canon that reclassifies concepts.
    static func priorRegistry(
        fromCanonAt url: URL,
        classPins: [String: Int]
    ) throws -> StableKeyRegistry {
        let data = try Data(contentsOf: url)
        let canon = try JSONDecoder().decode(LatticeCanon.self, from: data)
        var entries: [StableKeyEntry] = []
        for entry in canon.entries {
            if let pinned = classPins[entry.sourceIdentity], pinned != entry.classBase {
                continue
            }
            entries.append(StableKeyEntry(
                sourceIdentity: entry.sourceIdentity,
                code: entry.code,
                firstAssignedInCanon: canon.canonVersion
            ))
        }
        return StableKeyRegistry(entries: entries)
    }

    /// Computes the build report and the silent-loss count from a run.
    /// Silent loss = an input concept placed in neither the canon nor a
    /// diagnostic. Duplicate and classExhausted concepts are accounted
    /// for as drops; everything else must appear as a canon entry.
    static func report(
        conceptCount uniqueInput: Int,
        output: AssemblerOutput,
        edgeSourceKind: String,
        edgesFetched: Int,
        routingNodeCount: Int
    ) -> BuildReport {
        let entryIdentities = Set(output.canon.entries.map(\.sourceIdentity))
        let diagnosedIdentities = Set(output.diagnostics.map(\.sourceIdentity))

        var byKind: [String: Int] = [:]
        for d in output.diagnostics {
            byKind[d.kind.rawValue, default: 0] += 1
        }
        var dist: [Int: Int] = [:]
        for e in output.canon.entries {
            dist[e.classBase, default: 0] += 1
        }
        // Accounted-for identities = placed as an entry, or named in any
        // diagnostic. Anything in neither is a silent loss.
        let accounted = entryIdentities.union(diagnosedIdentities)
        let silentlyLost = max(0, uniqueInput - accounted.count)

        return BuildReport(
            edgeSourceKind: edgeSourceKind,
            edgesFetched: edgesFetched,
            routingNodeCount: routingNodeCount,
            conceptsIn: uniqueInput,
            codesAssigned: output.canon.entries.count,
            diagnosticsByKind: byKind,
            classDistribution: dist,
            silentlyLost: silentlyLost
        )
    }
}

@main
struct MDCCBuild {
    static func main() async {
        let opts = BuildOptions.parse(Array(CommandLine.arguments.dropFirst()))

        do {
            // 1. Load the CC0 concept seed.
            let seedPath = opts.seedPath ?? WikidataCC0Source.defaultSeedPath()
            let seed = try WikidataCC0Source.loadSeedFile(at: seedPath)
            let seedConcepts = WikidataCC0Source.concepts(from: seed)

            // 1b. Editorial pins. Class pins override each named concept's
            //     udc_hint-derived pinnedClassBase; parent pins feed the
            //     collapse rule's tier-1 selection. Both are optional;
            //     absent flags leave the compute-only defaults in place.
            var pinnedParents = PinnedParents([:])
            if let pinsPath = opts.pinsPath {
                pinnedParents = try EditorialPins.loadParentPins(from: URL(fileURLWithPath: pinsPath))
            }
            var classPins: [String: Int] = [:]
            if let classPinsPath = opts.classPinsPath {
                classPins = try EditorialPins.loadClassPins(from: URL(fileURLWithPath: classPinsPath))
            }
            let concepts = EditorialPins.apply(classPins: classPins, to: seedConcepts)
            let uniqueInput = Set(concepts.map(\.sourceIdentity)).count

            // 2. Choose the edge source: offline fixture or live endpoint.
            let edgeSource: EdgeSource
            let edgeSourceKind: String
            if let fixturePath = opts.fixturePath {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
                let edges = try JSONDecoder().decode([SourceEdge].self, from: data)
                edgeSource = FixtureEdgeSource(edges)
                edgeSourceKind = "fixture"
            } else {
                edgeSource = WikidataEdgeSource()
                edgeSourceKind = "wikidata-endpoint"
            }

            // 3. Prior registry. A persisted registry file wins; otherwise
            //    a prior canon is reconstructed into one (excluding the
            //    concepts the class pins reclassify, so they re-home); a
            //    cold build supplies neither.
            let priorRegistry: StableKeyRegistry
            if let registryPath = opts.registryPath {
                priorRegistry = try CanonWriter.loadRegistry(from: URL(fileURLWithPath: registryPath))
            } else if let priorCanonPath = opts.priorCanonPath {
                priorRegistry = try BuildPipeline.priorRegistry(
                    fromCanonAt: URL(fileURLWithPath: priorCanonPath),
                    classPins: classPins
                )
            } else {
                priorRegistry = StableKeyRegistry(entries: [])
            }

            // 4. Assemble.
            let (output, edgesFetched, routingNodeCount) = try await BuildPipeline.assemble(
                concepts: concepts,
                edgeSource: edgeSource,
                pinnedParents: pinnedParents,
                priorRegistry: priorRegistry,
                canonVersion: LatticeLib.canonVersion
            )

            // 5. Write the four artifacts with provenance.
            let provenance = BuildProvenance(
                dataVersion: opts.dataVersionOverride ?? seed.dataVersion,
                licenseNote: seed.licenseNote,
                accessDate: opts.accessDate ?? Self.todayISO8601(),
                edgeSourceKind: edgeSourceKind
            )
            try CanonWriter.write(
                output: output,
                provenance: provenance,
                to: URL(fileURLWithPath: opts.outDirectory, isDirectory: true)
            )

            // 6. Report, and fail the build on any silent loss.
            let report = BuildPipeline.report(
                conceptCount: uniqueInput,
                output: output,
                edgeSourceKind: edgeSourceKind,
                edgesFetched: edgesFetched,
                routingNodeCount: routingNodeCount
            )
            FileHandle.standardOutput.write(Data(report.rendered().utf8))
            if report.silentlyLost > 0 {
                FileHandle.standardError.write(Data(
                    "mdcc-build: \(report.silentlyLost) concept(s) silently lost — failing build\n".utf8
                ))
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("mdcc-build: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The current calendar date as YYYY-MM-DD, read once at the CLI
    /// boundary. The pipeline and writer never read the clock; the date
    /// is supplied to them as provenance so they stay deterministic.
    private static func todayISO8601() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}
