// IndexCompositionPolicyAdapterTests.swift
//
// CDL-03: `LocusDrawerCorpusContentSource` composes the lexical and dense
// texts of a `CorpusContentRecord` under a named `IndexCompositionPolicy`.
// These tests pin, per policy, exactly which bytes each lane receives —
// including the one canonical adornment rendering (ascending minter-ID,
// one adornment per line, "\n"-joined) that both ports must produce
// identically — and that the default policy is byte-identical to the
// pre-CDL-03 dense-over-distillate shape.
//
// Rust twin: rust/src/intake.rs tests (`LocusDrawerContentSource`).

import AdornmentLib
import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

@Suite("LocusDrawerCorpusContentSource — composition policy")
struct IndexCompositionPolicyAdapterTests {

    private static let owner = OwnerCredentials(ownerIdentifier: "cdl-03-adapter-owner")
    private static let addedBy = "cdl-03-adapter-test"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let content = "Alice moved to Lisbon in March. She keeps bees."
    private static let distillate =
        "Alice moved to Lisbon in March. (*[ entity: alice, place: lisbon ]*)"
    // Minter IDs chosen so that lexical (string) order differs from insertion
    // order: "b-minter" is inserted first, "a-minter" second. The adapter must
    // emit a-minter before b-minter regardless of insertion order.
    private static let adornmentB = "Alice relocated to Lisbon (March)."
    private static let adornmentA = "Alice is a beekeeper."

    /// A fresh on-disk estate carrying one drawer with content, a distillate,
    /// and two active adornments from two active minters.
    private static func fixture() async throws -> (estate: LocusKit.Estate, drawerID: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-cdl03-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite3"), busyTimeout: 5.0)))
        let estate = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let drawer = try await estate.capture(CaptureFrame(
            content: content,
            channel: .typed,
            room: "adapter-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: addedBy,
            embeddingModelID: "no-embedding",
            lineageID: UUID()))

        let written = try await estate.setDistilledRepresentation(
            drawerId: drawer.id,
            distilled: distillate,
            pipelineVersion: "cdl-03-test",
            sourceDigest: "cdl-03-digest",
            tokenCount: 12,
            at: now)
        #expect(written == 1)

        for minterID in ["b-minter", "a-minter"] {
            try await estate.registerAdornmentMinter(AdornmentMinterDescriptor(
                id: minterID, name: "CDL-03 \(minterID)", family: "test",
                modelID: "stub", modelVersion: "1", promptDigest: "cafef00d",
                parameters: [:], isActive: true))
        }
        _ = try await estate.putAdornment(StoredAdornment(
            drawerID: drawer.id, minterID: "b-minter", text: adornmentB))
        _ = try await estate.putAdornment(StoredAdornment(
            drawerID: drawer.id, minterID: "a-minter", text: adornmentA))

        return (estate, drawer.id)
    }

    private static func record(
        _ estate: LocusKit.Estate, _ id: String, policy: IndexCompositionPolicy
    ) async throws -> CorpusContentRecord {
        let source = LocusDrawerCorpusContentSource(estate: estate, compositionPolicy: policy)
        return try #require(try await source.record(for: id))
    }

    /// The canonical adornment rendering: base, then each adornment on its
    /// own line in ascending minter-ID order.
    private static func withAdornments(_ base: String) -> String {
        base + "\n" + adornmentA + "\n" + adornmentB
    }

    @Test("default init is .current, and .current is byte-identical to the pre-CDL-03 shape")
    func defaultPolicyMatchesLegacyShape() async throws {
        let (estate, id) = try await Self.fixture()
        let implicit = try #require(
            try await LocusDrawerCorpusContentSource(estate: estate).record(for: id))
        let explicit = try await Self.record(estate, id, policy: .current)
        #expect(implicit == explicit)
        // Pre-CDL-03 contract: BM25 text = verbatim content, dense = distillate,
        // digest keyed on verbatim content, revision 1.
        #expect(explicit.text == Self.content)
        #expect(explicit.denseCompositionText == Self.distillate)
        #expect(explicit.digest == CorpusContentDigest.digest(Self.content))
        #expect(explicit.revision == 1)
        #expect(explicit.id == id)
    }

    @Test("cell B: adornments join the lexical lane only, in ascending minter-ID order")
    func lexicalAdornments() async throws {
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id, policy: .lexicalAdornments)
        #expect(rec.text == Self.withAdornments(Self.content))
        #expect(rec.denseCompositionText == Self.distillate)
    }

    @Test("cell C: adornments join the dense lane only")
    func denseAdornments() async throws {
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id, policy: .denseAdornments)
        #expect(rec.text == Self.content)
        #expect(rec.denseCompositionText == Self.withAdornments(Self.distillate))
    }

    @Test("cell D: adornments join both lanes")
    func bothAdornments() async throws {
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id, policy: .bothAdornments)
        #expect(rec.text == Self.withAdornments(Self.content))
        #expect(rec.denseCompositionText == Self.withAdornments(Self.distillate))
    }

    @Test("cell E: dense lane reads the verbatim content")
    func lexicalBaseline() async throws {
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id, policy: .lexicalBaseline)
        #expect(rec.text == Self.content)
        #expect(rec.denseCompositionText == Self.content)
    }

    @Test("distilled lexical sources read the distillate for BM25")
    func distilledLexical() async throws {
        let (estate, id) = try await Self.fixture()
        let plain = try await Self.record(estate, id, policy: IndexCompositionPolicy(
            lexicalSource: .distilled, denseSource: .distilled))
        #expect(plain.text == Self.distillate)
        #expect(plain.denseCompositionText == Self.distillate)
        let adorned = try await Self.record(estate, id, policy: IndexCompositionPolicy(
            lexicalSource: .distilledPlusAdornments, denseSource: .distilled))
        #expect(adorned.text == Self.withAdornments(Self.distillate))
    }

    @Test("the digest keys on verbatim content under every policy")
    func digestIsPolicyInvariant() async throws {
        let (estate, id) = try await Self.fixture()
        let expected = CorpusContentDigest.digest(Self.content)
        for policy in [IndexCompositionPolicy.current, .lexicalAdornments, .denseAdornments,
                       .bothAdornments, .lexicalBaseline] {
            let rec = try await Self.record(estate, id, policy: policy)
            #expect(rec.digest == expected, "policy \(policy.id)")
        }
    }

    @Test("an inactive minter's adornment is excluded from composition")
    func inactiveMinterExcluded() async throws {
        let (estate, id) = try await Self.fixture()
        _ = try await estate.setAdornmentMinterActive(id: "b-minter", active: false)
        let rec = try await Self.record(estate, id, policy: .bothAdornments)
        #expect(rec.text == Self.content + "\n" + Self.adornmentA)
        #expect(rec.denseCompositionText == Self.distillate + "\n" + Self.adornmentA)
    }

    @Test("undistilled drawer: dense falls back to nil (engine uses verbatim), adornments still attach")
    func undistilledDrawer() async throws {
        let (estate, _) = try await Self.fixture()
        let bare = try await estate.capture(CaptureFrame(
            content: "Bare drawer without a distillate.",
            channel: .typed,
            room: "adapter-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: Self.addedBy,
            embeddingModelID: "no-embedding",
            lineageID: UUID()))
        _ = try await estate.putAdornment(StoredAdornment(
            drawerID: bare.id, minterID: "a-minter", text: "Bare has one adornment."))

        let current = try await Self.record(estate, bare.id, policy: .current)
        #expect(current.denseCompositionText == nil)
        #expect(current.effectiveDenseText == "Bare drawer without a distillate.")

        let dense = try await Self.record(estate, bare.id, policy: .denseAdornments)
        // No distillate: the dense base falls back to verbatim before adornments attach.
        #expect(dense.denseCompositionText
                == "Bare drawer without a distillate.\nBare has one adornment.")
    }
}
