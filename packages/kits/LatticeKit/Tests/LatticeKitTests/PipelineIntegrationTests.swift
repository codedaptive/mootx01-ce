// PipelineIntegrationTests.swift
//
// Integration tests for the MDCC production-canon build pipeline
// (mission MDCC-01). The pipeline turns the CC0 Wikidata concept seed
// plus a fetched subclass/instance edge graph into a real MDCC canon
// through the existing deterministic `Assembler`, then emits the two
// distribution channels and a persisted stable-key registry via
// `CanonWriter`.
//
// These tests never touch the network. The seed is the committed CC0
// resource; the edge graph is an injected `FixtureEdgeSource`. The
// `WikidataEdgeSource` network conformer is exercised only by the
// `mdcc-build` executable against the live Wikidata CC0 endpoint.
//
// The seven contracts pinned here mirror the mission's Part 1 list:
//   1. The CC0 seed loads (2026 concepts, each with qid and label).
//   2. The edge fetch is injectable and offline.
//   3. The pipeline produces a canon spanning four or more spine classes.
//   4. No concept is silently lost: every input is an entry or a
//      diagnostic.
//   5. The pipeline is deterministic: byte-identical canon and
//      fast-codes JSON across two runs.
//   6. The persisted registry round-trips: a second run pinned by the
//      first run's registry produces no code churn.
//   7. Both channels emit: fast-codes JSON parses and is code-sorted;
//      slow-docs markdown names every spine class that has entries.

import Foundation
import Testing
@testable import LatticeKit

@Suite("Pipeline integration")
struct PipelineIntegrationTests {

    // MARK: Fixture

    // A ~30-concept fixture with P279 (subclass-of) edges. Five pinned
    // roots seed distinct spine classes (Generalities, Philosophy,
    // Religion, Natural sciences, History); the remaining concepts are
    // UNPINNED and reach their class only by inheriting a placed
    // parent through the collapse rule — this is what proves real
    // propagation rather than pin-everything bucketing.
    private static func fixtureConcepts() -> [SourceConcept] {
        var c: [SourceConcept] = []
        // Pinned roots — one or two per class.
        c.append(SourceConcept(sourceIdentity: "Qf_gen",    label: "generality root", pinnedClassBase: 0))
        c.append(SourceConcept(sourceIdentity: "Qf_phil",   label: "philosophy",      pinnedClassBase: 100))
        c.append(SourceConcept(sourceIdentity: "Qf_rel",    label: "religion",        pinnedClassBase: 200))
        c.append(SourceConcept(sourceIdentity: "Qf_sci",    label: "science",         pinnedClassBase: 500))
        c.append(SourceConcept(sourceIdentity: "Qf_hist",   label: "history",         pinnedClassBase: 900))
        // Unpinned children of science (inherit base 500 via edges).
        for name in ["math", "physics", "chemistry", "biology", "geology", "astronomy"] {
            c.append(SourceConcept(sourceIdentity: "Qf_sci_\(name)", label: name, pinnedClassBase: nil))
        }
        // Unpinned children of philosophy (inherit base 100).
        for name in ["logic", "ethics", "metaphysics", "epistemology"] {
            c.append(SourceConcept(sourceIdentity: "Qf_phil_\(name)", label: name, pinnedClassBase: nil))
        }
        // Unpinned children of religion (inherit base 200).
        for name in ["theology", "ritual", "mythology"] {
            c.append(SourceConcept(sourceIdentity: "Qf_rel_\(name)", label: name, pinnedClassBase: nil))
        }
        // Unpinned children of history (inherit base 900).
        for name in ["antiquity", "medieval", "modern"] {
            c.append(SourceConcept(sourceIdentity: "Qf_hist_\(name)", label: name, pinnedClassBase: nil))
        }
        // Unpinned grandchildren (two hops from a root) to exercise the
        // fixpoint propagation past a single level.
        c.append(SourceConcept(sourceIdentity: "Qf_sci_quantum",  label: "quantum mechanics", pinnedClassBase: nil))
        c.append(SourceConcept(sourceIdentity: "Qf_sci_organic",  label: "organic chemistry", pinnedClassBase: nil))
        c.append(SourceConcept(sourceIdentity: "Qf_phil_modal",   label: "modal logic",       pinnedClassBase: nil))
        // Unpinned children of the generality root (inherit base 0).
        for name in ["information", "knowledge", "reference"] {
            c.append(SourceConcept(sourceIdentity: "Qf_gen_\(name)", label: name, pinnedClassBase: nil))
        }
        return c
    }

    // P279 edges (child subclass-of parent). Grandchildren point at a
    // child that itself points at a root, so they place only after the
    // child places.
    private static func fixtureEdges() -> [SourceEdge] {
        var e: [SourceEdge] = []
        for name in ["math", "physics", "chemistry", "biology", "geology", "astronomy"] {
            e.append(SourceEdge(child: "Qf_sci_\(name)", parent: "Qf_sci"))
        }
        for name in ["logic", "ethics", "metaphysics", "epistemology"] {
            e.append(SourceEdge(child: "Qf_phil_\(name)", parent: "Qf_phil"))
        }
        for name in ["theology", "ritual", "mythology"] {
            e.append(SourceEdge(child: "Qf_rel_\(name)", parent: "Qf_rel"))
        }
        for name in ["antiquity", "medieval", "modern"] {
            e.append(SourceEdge(child: "Qf_hist_\(name)", parent: "Qf_hist"))
        }
        for name in ["information", "knowledge", "reference"] {
            e.append(SourceEdge(child: "Qf_gen_\(name)", parent: "Qf_gen"))
        }
        // Grandchildren: subclass of a child, not of the root directly.
        e.append(SourceEdge(child: "Qf_sci_quantum", parent: "Qf_sci_physics"))
        e.append(SourceEdge(child: "Qf_sci_organic", parent: "Qf_sci_chemistry"))
        e.append(SourceEdge(child: "Qf_phil_modal",  parent: "Qf_phil_logic"))
        return e
    }

    // Fixed provenance so written artifacts are byte-stable across runs.
    private static let fixtureProvenance = BuildProvenance(
        dataVersion: "fixture-0.1.0",
        licenseNote: "Creative Commons CC0 1.0 Universal (test fixture).",
        accessDate: "2026-05-24",
        edgeSourceKind: "fixture"
    )

    // Drives the same orchestration sequence the `mdcc-build` executable
    // runs: fetch edges for the concept QID set, build the assembler
    // input, assemble. Kept here (not imported from the executable)
    // because the integration test verifies the library primitives
    // compose correctly; the executable wraps the identical sequence.
    private func assembleFixture(
        registry: StableKeyRegistry = StableKeyRegistry(entries: [])
    ) async throws -> AssemblerOutput {
        let concepts = Self.fixtureConcepts()
        let qids = Set(concepts.map(\.sourceIdentity))
        let fetcher = EdgeFetcher(source: FixtureEdgeSource(Self.fixtureEdges()))
        let edges = try await fetcher.fetch(for: qids)
        let input = AssemblerInput(
            concepts: concepts,
            edges: edges,
            pinnedParents: PinnedParents([:]),
            registry: registry,
            canonVersion: "v1"
        )
        return Assembler.assemble(input)
    }

    // MARK: 1 — Seed loads

    @Test("CC0 seed loads with 2026 concepts, each carrying a qid and label")
    func seedLoads() throws {
        let concepts = try WikidataCC0Source.loadSeed()
        #expect(concepts.count == 2026)
        for concept in concepts {
            #expect(!concept.sourceIdentity.isEmpty)
            #expect(!concept.label.isEmpty)
        }
    }

    // MARK: 2 — Edge fetch is injectable and offline

    @Test("fixture edge source returns its child-in-seed edges without the network")
    func edgeFetchInjectable() async throws {
        let concepts = Self.fixtureConcepts()
        let qids = Set(concepts.map(\.sourceIdentity))
        let fetcher = EdgeFetcher(source: FixtureEdgeSource(Self.fixtureEdges()))
        let edges = try await fetcher.fetch(for: qids)
        // Every returned edge has its child inside the seed — that is the
        // one-hop rule's only hard requirement. (Parents may be one-hop
        // routing nodes outside the seed; the one-hop fixture for that
        // path lives in DecimalExtensionAllocationTests.) This fixture's
        // P279 edges are all seed-internal, so every parent is also in
        // the seed and every edge survives.
        for edge in edges {
            #expect(qids.contains(edge.child))
            #expect(qids.contains(edge.parent))
        }
        #expect(edges.count == Self.fixtureEdges().count)
    }

    // MARK: 3 — Multi-class canon

    @Test("pipeline produces a canon spanning four or more spine classes")
    func multiClassCanon() async throws {
        let out = try await assembleFixture()
        let classes = Set(out.canon.entries.map(\.classBase))
        #expect(classes.count >= 4, "canon spanned only \(classes.sorted())")
        // Propagation actually fired: an unpinned science child lands in
        // class 500, inherited from its pinned parent, not Generalities.
        let math = out.canon.entry(forSourceIdentity: "Qf_sci_math")
        #expect(math?.classBase == 500)
        // And a grandchild two hops down also inherits 500.
        let quantum = out.canon.entry(forSourceIdentity: "Qf_sci_quantum")
        #expect(quantum?.classBase == 500)
    }

    // MARK: 4 — Zero silent loss

    @Test("no concept is silently lost — every input is an entry or a diagnostic")
    func zeroSilentLoss() async throws {
        let concepts = Self.fixtureConcepts()
        let out = try await assembleFixture()
        let uniqueInput = Set(concepts.map(\.sourceIdentity))

        // Every input identity is reachable as a canon entry or named in
        // a diagnostic — nothing vanishes.
        let entryIdentities = Set(out.canon.entries.map(\.sourceIdentity))
        let diagnosedIdentities = Set(out.diagnostics.map(\.sourceIdentity))
        for identity in uniqueInput {
            #expect(
                entryIdentities.contains(identity) || diagnosedIdentities.contains(identity),
                "concept \(identity) vanished: no entry, no diagnostic"
            )
        }

        // The count identity: entries placed plus concepts dropped with a
        // drop-class diagnostic equals the unique input count. Only
        // duplicate and classExhausted diagnostics drop a concept
        // (classExhausted now fires only when a class is full to the
        // maximum extension depth, which this fixture never reaches);
        // orphanCycle and unknownPinnedClass concepts are still placed.
        let droppedIdentities = Set(
            out.diagnostics
                .filter { $0.kind == .classExhausted || $0.kind == .duplicateSourceIdentity }
                .map(\.sourceIdentity)
        ).subtracting(entryIdentities)
        #expect(out.canon.entries.count + droppedIdentities.count == uniqueInput.count)
    }

    // MARK: 5 — Determinism

    @Test("two runs over the same fixture produce byte-identical canon and fast-codes JSON")
    func determinism() async throws {
        let a = try await assembleFixture()
        let b = try await assembleFixture()

        let canonA = try CanonWriter.canonData(a.canon)
        let canonB = try CanonWriter.canonData(b.canon)
        #expect(canonA == canonB)

        let codesA = try Channels.encodeFastCodes(Channels.fastCodes(from: a.canon))
        let codesB = try Channels.encodeFastCodes(Channels.fastCodes(from: b.canon))
        #expect(codesA == codesB)
    }

    // MARK: 6 — Registry round-trips

    @Test("persisted registry reloaded as prior produces no code churn")
    func registryRoundTrips() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First run, cold registry. Persist all four artifacts.
        let first = try await assembleFixture()
        try CanonWriter.write(output: first, provenance: Self.fixtureProvenance, to: dir)

        // Reload the persisted registry and feed it back as the prior
        // registry for a second run.
        let registryURL = dir.appendingPathComponent("LatticeRegistryV1.json")
        let reloaded = try CanonWriter.loadRegistry(from: registryURL)
        let second = try await assembleFixture(registry: reloaded)

        // Every code assigned in the first run is pinned in the second —
        // no identity changes its code across reruns.
        for entry in first.canon.entries {
            let again = second.canon.entry(forSourceIdentity: entry.sourceIdentity)
            #expect(again?.code == entry.code, "code churn for \(entry.sourceIdentity)")
        }
    }

    // MARK: 7 — Channels emit

    @Test("fast-codes JSON parses and is code-sorted; slow-docs names every populated class")
    func channelsEmit() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await assembleFixture()
        try CanonWriter.write(output: out, provenance: Self.fixtureProvenance, to: dir)

        // Fast-codes JSON parses and is sorted by code.
        let codesURL = dir.appendingPathComponent("LatticeCodesV1.json")
        let codesData = try Data(contentsOf: codesURL)
        let payload = try JSONDecoder().decode(FastCodesPayload.self, from: codesData)
        let codes = payload.codes.map(\.code)
        #expect(codes == codes.sorted())
        #expect(!codes.isEmpty)

        // Slow-docs markdown names every spine class that has entries.
        let docsURL = dir.appendingPathComponent("LatticeDocsV1.md")
        let docs = try String(contentsOf: docsURL, encoding: .utf8)
        let populatedBases = Set(out.canon.entries.map(\.classBase))
        for cls in NotationSpine.classes where populatedBases.contains(cls.base) {
            #expect(docs.contains(cls.name), "slow-docs omitted populated class \(cls.name)")
        }
    }

    // MARK: Helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdcc-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
