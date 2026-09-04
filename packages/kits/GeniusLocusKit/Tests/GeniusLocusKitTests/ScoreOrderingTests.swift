// ScoreOrderingTests.swift
//
// Discriminating tests for the Score-Transparent Ordering contract
// (DECISION_SCORE_TRANSPARENT_ORDERING_2026-08-24, ADR status: ACCEPTED).
//
// Five gate tests covering:
//   1a. Pool-exhaustion branch: limit 5 on a 10-item tie group → ALL 10 returned.
//       Fails against a revert that returns exactly 5 arbitrary members.
//   1b. Non-determinate branch: limit 5 on a 25-item tie group that exceeds the
//       4N window → 0 items returned + "tie.nonDeterminate" degraded stage.
//       Fails against a revert that returns exactly 5 arbitrary members.
//    2. Subject ordering: equal-scored items appear in subject-ascending order.
//       Fails against UUID-insertion ordering.
//    3. Cross-estate determinism: two estates with the same (content, subject)
//       pairs return the same result set in the same order for the same query.
//       Fails against any UUID-influenced ordering (the 12/25 class from the study).
//    4. Payload score: every hit carries a non-zero final score.
//       Fails if the score field is dropped or wired to zero.
//    5. Cross-port fixture: reads Tests/Conformance/score_ordering_fixture.json
//       (shared with Rust score_ordering_parity.rs) and verifies the expected
//       subject order against a live recall run.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory

@Suite("Score-Transparent Ordering — discriminating gates (SCORE-ORDERING)", .serialized)
struct ScoreOrderingTests {

    // MARK: - Infrastructure

    /// Open an estate through GeniusLocusKit backed by in-memory storage with
    /// a deterministic embedding model so both BM25 and dense lanes are live
    /// after an impatient capture.
    private func provision(ownerSuffix: String) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-score-ordering-\(ownerSuffix)")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Score-Ordering Estate \(ownerSuffix)",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    /// Build a CaptureFrame with the given content and optional subject.
    private func frame(content: String, subject: String? = nil) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "score-ordering-tests",
            latticeAnchor: .udc("000"),
            addedBy: "score-ordering-tests",
            embeddingModelID: "test-model-v1",
            subject: subject
        )
    }

    /// Build a unionBest RRF recall request for the given query and limit.
    /// Uses the default filter chain (unconfirmed, sensitivity ≤ elevated) with
    /// full hydration so hit.drawer is populated for subject extraction.
    private func recallRequest(query: String, limit: Int) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .rrf,
            limit: limit,
            fallback: .failClosed,
            queryText: query,
            origin: .internal
        )
    }

    // MARK: - URL helper for cross-port fixture

    /// Resolves Tests/Conformance/score_ordering_fixture.json relative to this
    /// file's location at compile time. The layout is:
    ///   this file → Tests/GeniusLocusKitTests/ScoreOrderingTests.swift
    ///   fixture   → Tests/Conformance/score_ordering_fixture.json
    private func scoreOrderingFixtureURL() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()            // GeniusLocusKitTests/
            .deletingLastPathComponent()            // Tests/
            .appendingPathComponent("Conformance")
            .appendingPathComponent("score_ordering_fixture.json")
    }

    // MARK: - 1a. Pool-exhaustion branch

    /// 10 identical-content drawers, limit 5 → ALL 10 returned.
    ///
    /// With a 10-item estate, frontierK caps at 64 > 10 so the candidate buffer
    /// holds all 10. Phase 1 runs to 2N = 10 and exhausts the pool immediately.
    /// The Phase 2 branch finds unselected.isEmpty → returns the whole pool (all 10).
    /// A revert to "return exactly limit" would return 5 and fail this gate.
    @Test
    func tieResolutionPoolExhaustionReturnsAllTen() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "tie-pool-ten")
        defer { Task { try? await kit.close(handle) } }

        // 10 identical-content items so they all produce equal BM25 + vector scores.
        for i in 1...10 {
            _ = try await kit.capture(
                handle,
                frame(
                    content: "score-ordering-tie pool-ten identical content alpha",
                    subject: String(format: "item-%02d", i)),
                mode: .impatient)
        }

        let result = try await kit.recall(
            handle,
            recallRequest(
                query: "score-ordering-tie pool-ten identical content",
                limit: 5))

        // The pool (10 items) is smaller than 4N (20), so it is fully enumerated.
        // The contract returns the whole pool — no arbitrary truncation.
        #expect(
            result.hits.count == 10,
            "pool-exhaustion branch must return all 10 items, not just limit=5; got \(result.hits.count)")

        // Pool-exhaustion is not a degraded stage — it is a CONTRACT EXPANSION,
        // the honest answer when every candidate is known.
        #expect(
            !result.degradedStages.contains("tie.nonDeterminate"),
            "pool-exhaustion is not non-determinate; degradedStages=\(result.degradedStages)")
    }

    // MARK: - 1b. Non-determinate branch

    /// 25 identical-content drawers, limit 5 → 0 items returned + disclosure.
    ///
    /// With 25 items and frontierK=64, the candidate buffer holds all 25. Phase 1
    /// selects 10 (2N), Phase 2 selects 10 more (to 4N=20), but 5 items remain
    /// in unselected. No score break is found within the 4N window. The contract
    /// returns the determinate prefix (0 items, because all 20 in the window tie)
    /// and appends "tie.nonDeterminate" so the MCP layer can steer the AI toward a
    /// more discriminating query.
    ///
    /// A revert to "return exactly limit" would return 5 items and NOT set the
    /// degraded stage, failing both assertions.
    @Test
    func tieResolutionNonDeterminateReturnsDisclosure() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "tie-nondeterminate")
        defer { Task { try? await kit.close(handle) } }

        // 25 identical-content items → all tied, pool exceeds the 4N window.
        for i in 1...25 {
            _ = try await kit.capture(
                handle,
                frame(
                    content: "score-ordering-tie twenty-five identical content beta",
                    subject: String(format: "item-%02d", i)),
                mode: .impatient)
        }

        let result = try await kit.recall(
            handle,
            recallRequest(
                query: "score-ordering-tie twenty-five identical content",
                limit: 5))

        // Determinate prefix is 0 items: no item in the 4N window has a score
        // below the tie group's score, and the pool has items beyond 4N.
        #expect(
            result.hits.count < 5,
            "non-determinate branch must return fewer than limit=5; got \(result.hits.count)")

        // The non-determinate sentinel surfaces through degradedStages so the MCP
        // layer can emit the steering message without a new struct field.
        #expect(
            result.degradedStages.contains("tie.nonDeterminate"),
            "non-determinate branch must append 'tie.nonDeterminate'; degradedStages=\(result.degradedStages)")
    }

    // MARK: - 2. Subject ordering

    /// Equal-scored items appear in subject-ascending order.
    ///
    /// Three identical-content drawers with subjects "cc-gamma", "aa-alpha",
    /// "bb-beta" are recalled with limit=10. All three get equal final scores.
    /// The presentation comparator sorts by (score DESC, subject ASC), so the
    /// order must be aa-alpha, bb-beta, cc-gamma regardless of capture order or
    /// UUID draw. A revert to UUID or insertion ordering would produce a different
    /// ordering and fail this gate.
    @Test
    func equalScoredItemsReturnInSubjectAscendingOrder() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "subject-order")
        defer { Task { try? await kit.close(handle) } }

        // Capture in reverse subject-alphabetical order to prove insertion order
        // does not influence the result.
        for subject in ["cc-gamma", "aa-alpha", "bb-beta"] {
            _ = try await kit.capture(
                handle,
                frame(
                    content: "score-ordering-subject-order identical content gamma",
                    subject: subject),
                mode: .impatient)
        }

        let result = try await kit.recall(
            handle,
            recallRequest(
                query: "score-ordering-subject-order identical content",
                limit: 10))

        let subjects = result.hits.compactMap { $0.drawer?.subject }

        // The estate is provisioned with a KnowledgeWork profile which seeds wing
        // charter hint drawers. Those score lower than the three identical-content
        // items which directly match the query. Filter to the test-item subjects so
        // the ordering assertion is not perturbed by charter hits.
        let testSubjects = ["aa-alpha", "bb-beta", "cc-gamma"]
        let filteredSubjects = subjects.filter { testSubjects.contains($0) }

        #expect(
            filteredSubjects == testSubjects,
            "equal-scored hits must be ordered by subject ASC; test items in result: \(filteredSubjects), full result: \(subjects)")
    }

    // MARK: - 3. Cross-estate determinism

    /// Two same-recipe estates (different UUID draws) return the same result set
    /// and order for the same query, keyed by (score, subject).
    ///
    /// This is the 12/25 class from the study: before this contract, UUID-influenced
    /// tie-breaking made cross-estate ranking non-reproducible. Subjects are
    /// deterministic keys; if both estates return the same subject order, UUID has
    /// no influence on the output.
    @Test
    func crossEstateDeterminism() async throws {
        let subjects = ["sub-one", "sub-two", "sub-three"]
        let content = "determinism-cross-estate identical phrase content"
        let query = "determinism-cross-estate identical phrase"

        // Estate A
        let (kitA, handleA) = try await provision(ownerSuffix: "determinism-a")
        defer { Task { try? await kitA.close(handleA) } }
        for subject in subjects {
            _ = try await kitA.capture(handleA, frame(content: content, subject: subject), mode: .impatient)
        }
        let resultA = try await kitA.recall(handleA, recallRequest(query: query, limit: 10))
        let subjectsA = resultA.hits.compactMap { $0.drawer?.subject }

        // Estate B — identical recipe, fresh UUID draw.
        let (kitB, handleB) = try await provision(ownerSuffix: "determinism-b")
        defer { Task { try? await kitB.close(handleB) } }
        for subject in subjects {
            _ = try await kitB.capture(handleB, frame(content: content, subject: subject), mode: .impatient)
        }
        let resultB = try await kitB.recall(handleB, recallRequest(query: query, limit: 10))
        let subjectsB = resultB.hits.compactMap { $0.drawer?.subject }

        // Both estates are provisioned with a KnowledgeWork profile which seeds wing
        // charter hint drawers. Filter to the test-item subjects so the cross-estate
        // assertion is not perturbed by charter hits that also appear in both estates.
        let filteredA = subjectsA.filter { subjects.contains($0) }
        let filteredB = subjectsB.filter { subjects.contains($0) }

        #expect(
            filteredA == filteredB,
            "cross-estate results must be identical when (content, subject) recipe is the same; A=\(filteredA), B=\(filteredB)")

        // Both must include all three test subjects.
        #expect(
            !filteredA.isEmpty,
            "estate A must return at least one hit matching the test subjects")
        #expect(
            filteredA.count == subjects.count,
            "estate A must return all \(subjects.count) subjects; got \(filteredA.count) from \(subjectsA)")
    }

    // MARK: - 4. Payload score

    /// Every recall hit carries a non-zero final score.
    ///
    /// The score travels as a suffix on the dense row rendered by AriaMcpKit
    /// (` · %.4f`). This gate verifies the upstream field is populated before
    /// the serialization step, ensuring the score does not silently drop.
    @Test
    func recallHitPayloadCarriesNonZeroScore() async throws {
        let (kit, handle) = try await provision(ownerSuffix: "payload-score")
        defer { Task { try? await kit.close(handle) } }

        _ = try await kit.capture(
            handle,
            frame(content: "score-payload-test canary alpha beta"),
            mode: .impatient)

        let result = try await kit.recall(
            handle,
            recallRequest(query: "score-payload-test canary", limit: 5))

        #expect(!result.hits.isEmpty, "estate must produce at least one hit")
        for hit in result.hits {
            #expect(
                hit.score.final > 0,
                "hit \(hit.id) must carry a non-zero final score; got \(hit.score.final)")
        }
    }

    // MARK: - 5. Cross-port fixture

    /// Reads Tests/Conformance/score_ordering_fixture.json and verifies the
    /// expected subject order against a live recall run.
    ///
    /// The same fixture is read by Rust score_ordering_parity.rs, making this
    /// a golden-pin-twin assertion: one fixture, two ports, same ordering property.
    ///
    /// The fixture pins two items with different relevance to the query; the
    /// higher-relevance item (repeating query terms) must score higher and appear
    /// first. This fails if score ordering is dropped or the score field is zeroed.
    @Test
    func crossPortFixtureSubjectOrderMatches() async throws {
        // --- Load fixture ---
        struct FixtureItem: Decodable {
            let content: String
            let subject: String
        }
        struct Fixture: Decodable {
            let query: String
            let items: [FixtureItem]
            let expected_subject_order: [String]
        }

        let url = scoreOrderingFixtureURL()
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)

        // --- Provision and populate ---
        let (kit, handle) = try await provision(ownerSuffix: "cross-port-fixture")
        defer { Task { try? await kit.close(handle) } }

        for item in fixture.items {
            _ = try await kit.capture(
                handle,
                frame(content: item.content, subject: item.subject),
                mode: .impatient)
        }

        // --- Recall ---
        let result = try await kit.recall(
            handle,
            recallRequest(query: fixture.query, limit: 20))

        let subjects = result.hits.compactMap { $0.drawer?.subject }

        // Verify every expected item is present.
        for expectedSubject in fixture.expected_subject_order {
            #expect(
                subjects.contains(expectedSubject),
                "expected subject '\(expectedSubject)' missing from result; got \(subjects)")
        }

        // Verify the order of expected items matches the fixture.
        // Filter result subjects to only those listed in the fixture, preserving
        // the relative order from the result. This accommodates estates that may
        // return extra items without breaking the ordering assertion.
        let filteredSubjects = subjects.filter { fixture.expected_subject_order.contains($0) }
        #expect(
            filteredSubjects == fixture.expected_subject_order,
            "expected subject order \(fixture.expected_subject_order), got \(filteredSubjects)")
    }
}
