import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Tests for `BitmapEvaluator` per spec § 7.9.
///
/// The evaluator compiles a `RecallFrame.filterChain` into the bitmap
/// operator primitives and applies them across a tiered pipeline:
/// default insertion → bitmap → structured → content → ordering, with
/// optional historical reconstruction at `frame.asOf`.
///
/// Tests use `captureAndConfirm` to file drawers that satisfy the
/// trust/sensitivity/state default-insertion gates unless a test is
/// specifically probing one of those defaults.
@Suite("BitmapEvaluator — filter compilation, evaluation, ordering (spec § 7.9)")
struct EvaluatorTests {

    // MARK: - Fixtures

    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-evaluator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    /// Build a CaptureFrame with the boilerplate set. `room`, `content`,
    /// `lineage`, and `sensitivity` are the per-test variables.
    private func frame(
        content: String = "row",
        room: RoomID = "r1",
        lineage: LineageID? = nil,
        sensitivity: AdjectiveSensitivity = .normal
    ) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            sensitivity: sensitivity,
            kind: .prose,
            lineageID: lineage
        )
    }

    /// Capture a drawer and flip its confirmation to `.userConfirmed`
    /// for tests that explicitly exercise the confirmation axis.
    /// Cookbook §2.5: `.userConfirmed.rawValue = 1` at provenance
    /// confirmation bits 18–23, so `1 << 18 = 0x40000`.
    private func captureAndConfirm(
        _ f: CaptureFrame, into estate: Estate
    ) async throws -> Drawer {
        let d = try await estate.capture(f)
        try await estate._setProvenance(rowID: d.id, newProvenance: 0x40000)
        // Re-read so the returned Drawer reflects the post-mutation
        // provenance value the tests will read back through evaluator.
        return try await estate._peekDrawer(id: d.id) ?? d
    }

    /// Drain a RecallStream into a single `[Drawer]`.
    private func drain(_ stream: RecallStream) async -> [Drawer] {
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        return rows
    }

    // MARK: - Default filter insertion (§ 7.9.5)

    @Test("Default insertion: unconfirmed drawer included by ordinary recall")
    func defaults_includeUnconfirmed() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(room: "r1"))  // provenance stays at 0
        let stream = await estate.recall(
            RecallFrame(filterChain: [.inRoom("r1")])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
    }

    @Test("Default insertion: confirmed drawer included")
    func defaults_includeConfirmed() async throws {
        let estate = try await makeEstate()
        _ = try await captureAndConfirm(frame(room: "r1"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.inRoom("r1")])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
    }

    @Test("Explicit .userConfirmed filter excludes unconfirmed drawer")
    func userConfirmed_excludesUnconfirmed() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(room: "r1"))  // provenance stays at 0
        let stream = await estate.recall(
            RecallFrame(filterChain: [.inRoom("r1"), .userConfirmed])
        )
        let rows = await drain(stream)
        #expect(rows.isEmpty)
    }

    // MARK: - Bitmap-tier filters

    @Test(".currentlyBelieve excludes superseded drawer (state=3)")
    func currentlyBelieve_excludesSuperseded() async throws {
        let estate = try await makeEstate()
        let lineage = UUID()
        let d1 = try await captureAndConfirm(
            frame(content: "v1", lineage: lineage), into: estate
        )
        // Capture v2 with the same lineageID — supersession cascade
        // flips d1 to state=.superseded per § 6.2.
        let f2 = frame(content: "v2", lineage: lineage)
        let d2Raw = try await estate.capture(f2)
        try await estate._setProvenance(rowID: d2Raw.id, newProvenance: 0x40000)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .userConfirmed])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
        #expect(rows.first?.id == d2Raw.id)
        #expect(rows.first?.id != d1.id)
    }

    @Test(".trustworthy excludes drawer with trust=.derived (above threshold)")
    func trustworthy_excludesDerived() async throws {
        let estate = try await makeEstate()
        let d = try await captureAndConfirm(frame(), into: estate)
        // Set trust to .derived (rawValue=4) at bits 18–23: 4 << 18 = 0x100000.
        // OR over the existing adjective bits so state/sensitivity bits
        // stay at their defaults (zero).
        try await estate._setAdjective(rowID: d.id, newAdjective: 0x100000)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .trustworthy, .userConfirmed])
        )
        let rows = await drain(stream)
        #expect(rows.isEmpty)
    }

    @Test(".requiresConfirmation includes drawer with trust=.derived")
    func requiresConfirmation_includesDerived() async throws {
        let estate = try await makeEstate()
        let d = try await captureAndConfirm(frame(), into: estate)
        try await estate._setAdjective(rowID: d.id, newAdjective: 0x100000)
        let stream = await estate.recall(
            RecallFrame(filterChain: [
                .currentlyBelieve, .requiresConfirmation, .userConfirmed
            ])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
    }

    @Test("Tier boundary: elevated included in DEFAULT recall; restricted excluded")
    func tierBoundary_defaultCeiling_elevatedIncluded_restrictedExcluded() async throws {
        // Per ADR-007 Decision 2 / VK-TIER-01: the Normal-tier ceiling is
        // `.elevated`. `restricted` is Private tier and must be absent from
        // default (no-claims) recall.
        let estate = try await makeEstate()
        let dElevated = try await captureAndConfirm(
            frame(content: "elevated-row", sensitivity: .elevated), into: estate
        )
        let dRestricted = try await captureAndConfirm(
            frame(content: "restricted-row", sensitivity: .restricted), into: estate
        )
        // Unconstrained recall — default ceiling is `.elevated`.
        let stream = await estate.recall(RecallFrame(filterChain: []))
        let rows = await drain(stream)
        #expect(rows.contains(where: { $0.id == dElevated.id }),
            "elevated drawer must appear in default (no-claims) recall after tier alignment")
        #expect(!rows.contains(where: { $0.id == dRestricted.id }),
            "restricted drawer must be absent from default recall (Private tier)")
    }

    @Test(".sensitivityAtMost(.elevated) includes elevated drawer")
    func sensitivityAtMost_includesElevated() async throws {
        let estate = try await makeEstate()
        _ = try await captureAndConfirm(
            frame(sensitivity: .elevated), into: estate
        )
        let stream = await estate.recall(
            RecallFrame(filterChain: [.sensitivityAtMost(.elevated),
                                      .currentlyBelieve, .userConfirmed])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
    }

    // MARK: - Secret-exclusion proofs (ADR-007 Decision 2)

    @Test("Secret exclusion: secret drawer absent from unconstrained recall")
    func secretExclusion_unconstrainedRecall() async throws {
        // A `secret`-sensitivity drawer must never appear when the caller
        // supplies no sensitivity filter. The default ceiling (.elevated) is
        // below secret, so no claims are required to enforce this exclusion.
        let estate = try await makeEstate()
        let dSecret = try await captureAndConfirm(
            frame(content: "secret-row", sensitivity: .secret), into: estate
        )
        let dNormal = try await captureAndConfirm(
            frame(content: "normal-row", sensitivity: .normal), into: estate
        )
        let stream = await estate.recall(RecallFrame(filterChain: []))
        let rows = await drain(stream)
        #expect(!rows.contains(where: { $0.id == dSecret.id }),
            "secret drawer must be absent from unconstrained recall")
        #expect(rows.contains(where: { $0.id == dNormal.id }),
            "normal drawer must appear in unconstrained recall")
    }

    @Test("Secret exclusion: secret drawer absent under other-axis filter chains")
    func secretExclusion_otherAxisChains() async throws {
        // A shipped-surface chain that constrains other axes but NOT sensitivity
        // must still exclude secret-sensitivity drawers via the default ceiling.
        // Representative chains: [.unconfirmed], [.contentMatches(...)].
        let estate = try await makeEstate()
        // unconfirmed drawer with secret sensitivity (provenance not yet confirmed)
        let secretCapture = frame(content: "secret-unconfirmed", sensitivity: .secret)
        let dSecret = try await estate.capture(secretCapture)
        // confirmed drawer with normal sensitivity for comparison
        let dNormal = try await captureAndConfirm(
            frame(content: "normal-content", sensitivity: .normal), into: estate
        )
        // Chain that constrains provenance axis (not sensitivity) — default ceiling applies.
        let stream1 = await estate.recall(
            RecallFrame(filterChain: [.unconfirmed])
        )
        let rows1 = await drain(stream1)
        #expect(!rows1.contains(where: { $0.id == dSecret.id }),
            "secret drawer must be excluded even under .unconfirmed chain")

        // Chain that constrains content axis — default sensitivity ceiling applies.
        let stream2 = await estate.recall(
            RecallFrame(filterChain: [.contentMatches("normal-content")])
        )
        let rows2 = await drain(stream2)
        #expect(rows2.contains(where: { $0.id == dNormal.id }),
            "normal drawer must appear under .contentMatches chain")
        // The secret+unconfirmed drawer would not match the content filter anyway,
        // but verify no secret drawer leaks through any content-matching path
        // by adding one with matching content.
        let dSecretMatching = try await estate.capture(
            frame(content: "normal-content", sensitivity: .secret)
        )
        let stream3 = await estate.recall(
            RecallFrame(filterChain: [.contentMatches("normal-content")])
        )
        let rows3 = await drain(stream3)
        #expect(!rows3.contains(where: { $0.id == dSecretMatching.id }),
            "secret drawer must be absent even when content matches, sensitivity axis unconstraining")
    }

    @Test("Secret reachable only by explicit sensitivity constraint")
    func secretReachable_withExplicitSensitivityConstraint() async throws {
        // A secret-sensitivity drawer IS returned when the caller explicitly
        // constrains the sensitivity axis to include secret — both `.sensitivity(.secret)`
        // (exact match) and `.sensitivityAtMost(.secret)` (ceiling at secret).
        let estate = try await makeEstate()
        let dSecret = try await captureAndConfirm(
            frame(content: "secret-row", sensitivity: .secret), into: estate
        )

        // Exact-match form: `.sensitivity(.secret)` — includes only drawers at exactly secret.
        let stream1 = await estate.recall(
            RecallFrame(filterChain: [.sensitivity(.secret),
                                      .currentlyBelieve, .userConfirmed])
        )
        let rows1 = await drain(stream1)
        #expect(rows1.contains(where: { $0.id == dSecret.id }),
            "secret drawer must be present under explicit .sensitivity(.secret) constraint")

        // Ceiling form: `.sensitivityAtMost(.secret)` — includes all tiers up to secret.
        let stream2 = await estate.recall(
            RecallFrame(filterChain: [.sensitivityAtMost(.secret),
                                      .currentlyBelieve, .userConfirmed])
        )
        let rows2 = await drain(stream2)
        #expect(rows2.contains(where: { $0.id == dSecret.id }),
            "secret drawer must be present under explicit .sensitivityAtMost(.secret) constraint")
    }

    // MARK: - Structured-tier filters (§ 7.9.4 step 3)

    @Test(".inRoom returns only matching room")
    func inRoom_filtersByRoom() async throws {
        let estate = try await makeEstate()
        _ = try await captureAndConfirm(frame(content: "a1", room: "room-a"), into: estate)
        _ = try await captureAndConfirm(frame(content: "a2", room: "room-a"), into: estate)
        _ = try await captureAndConfirm(frame(content: "b1", room: "room-b"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.inRoom("room-a")])
        )
        let rows = await drain(stream)
        #expect(rows.count == 2)
        // Room filter correctness is enforced by the filter predicate; Drawer.room
        // was removed per ADR-017, so room cannot be verified on the result struct.
    }

    @Test(".createdAfter returns only drawers filed strictly after the timestamp")
    func createdAfter_filtersByTime() async throws {
        let estate = try await makeEstate()
        let d1 = try await captureAndConfirm(frame(content: "first"), into: estate)
        // Sleep 20ms to guarantee distinct filedAt across machines whose
        // monotonic clock granularity is coarser than the test loop.
        try await Task.sleep(nanoseconds: 20_000_000)
        let mid = Date()
        try await Task.sleep(nanoseconds: 20_000_000)
        let d2 = try await captureAndConfirm(frame(content: "second"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.createdAfter(mid)])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
        #expect(rows.first?.id == d2.id)
        #expect(rows.first?.id != d1.id)
    }

    @Test(".createdBefore returns only drawers filed strictly before the timestamp")
    func createdBefore_filtersByTime() async throws {
        let estate = try await makeEstate()
        let d1 = try await captureAndConfirm(frame(content: "first"), into: estate)
        try await Task.sleep(nanoseconds: 20_000_000)
        let mid = Date()
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await captureAndConfirm(frame(content: "second"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.createdBefore(mid)])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
        #expect(rows.first?.id == d1.id)
    }

    // MARK: - Composition (.all / .not)

    @Test(".all + .not composes — currentlyBelieve AND NOT trustworthy")
    func composition_allWithNot() async throws {
        let estate = try await makeEstate()
        let dTrustworthy = try await captureAndConfirm(
            frame(content: "trustworthy"), into: estate
        )
        let dDerived = try await captureAndConfirm(
            frame(content: "derived"), into: estate
        )
        // Flip the second drawer's trust to .derived (above threshold).
        try await estate._setAdjective(rowID: dDerived.id, newAdjective: 0x100000)
        let stream = await estate.recall(
            RecallFrame(filterChain: [
                .all([.currentlyBelieve, .not(.trustworthy)]),
                .userConfirmed
            ])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
        #expect(rows.first?.id == dDerived.id)
        #expect(rows.first?.id != dTrustworthy.id)
    }

    // MARK: - Content-tier filter (§ 7.9.4 step 4)

    @Test(".contentMatches substring filter")
    func contentMatches_filtersBySubstring() async throws {
        let estate = try await makeEstate()
        _ = try await captureAndConfirm(frame(content: "hello world"), into: estate)
        _ = try await captureAndConfirm(frame(content: "goodbye moon"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.contentMatches("hello")])
        )
        let rows = await drain(stream)
        #expect(rows.count == 1)
        #expect(rows.first?.content == "hello world")
    }

    // MARK: - Historical reconstruction (§ 7.9.6)

    @Test("asOf reconstructs the pre-withdraw bitmap via AuditLogFold over the audit log")
    func asOf_reconstructsWithdrawnState() async throws {
        let estate = try await makeEstate()
        let d = try await captureAndConfirm(frame(content: "ephemeral"), into: estate)
        // The user-confirm mutation's HLC is the asOf to reconstruct
        // the pre-withdraw state: capture is event[0], the confirm is
        // event[1], the withdraw will be event[2]. Folding up to the
        // confirm HLC yields state=active + confirmation=userConfirmed.
        let preWithdraw = try await estate.auditTrail(rowID: d.id)
        guard preWithdraw.count >= 2 else {
            Issue.record("expected at least the capture + confirm events")
            return
        }
        let asOfHLC = preWithdraw.last!.hlc
        try await estate.withdraw(rowID: d.id, reason: "test")

        let historical = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .userConfirmed],
                        asOf: asOfHLC)
        )
        let historicalRows = await drain(historical)
        #expect(historicalRows.count == 1, "drawer should be visible at the capture HLC (state was active)")

        let current = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .userConfirmed])
        )
        let currentRows = await drain(current)
        #expect(currentRows.isEmpty, "drawer should be excluded after withdraw (state=withdrawn)")
    }

    // MARK: - Ordering

    @Test(".byCaptureTimeDesc orders newest first")
    func ordering_desc() async throws {
        let estate = try await makeEstate()
        let d1 = try await captureAndConfirm(frame(content: "a"), into: estate)
        try await Task.sleep(nanoseconds: 20_000_000)
        let d2 = try await captureAndConfirm(frame(content: "b"), into: estate)
        try await Task.sleep(nanoseconds: 20_000_000)
        let d3 = try await captureAndConfirm(frame(content: "c"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .userConfirmed],
                        ordering: .byCaptureTimeDesc)
        )
        let rows = await drain(stream)
        #expect(rows.map(\.id) == [d3.id, d2.id, d1.id])
    }

    @Test(".byCaptureTimeAsc orders oldest first")
    func ordering_asc() async throws {
        let estate = try await makeEstate()
        let d1 = try await captureAndConfirm(frame(content: "a"), into: estate)
        try await Task.sleep(nanoseconds: 20_000_000)
        let d2 = try await captureAndConfirm(frame(content: "b"), into: estate)
        try await Task.sleep(nanoseconds: 20_000_000)
        let d3 = try await captureAndConfirm(frame(content: "c"), into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .userConfirmed],
                        ordering: .byCaptureTimeAsc)
        )
        let rows = await drain(stream)
        #expect(rows.map(\.id) == [d1.id, d2.id, d3.id])
    }

    // MARK: - § 7.9.7 worked example integration test

    @Test("§ 7.9.7 worked example: family/connie room with default trust+state filters")
    func workedExample_familyConnie() async throws {
        let estate = try await makeEstate()
        for i in 0..<5 {
            _ = try await captureAndConfirm(
                frame(content: "fc-\(i)", room: "family/connie"), into: estate
            )
            // tiny stagger so filedAt is strictly increasing
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        for i in 0..<2 {
            _ = try await captureAndConfirm(
                frame(content: "other-\(i)", room: "other-room"), into: estate
            )
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let stream = await estate.recall(
            RecallFrame(filterChain: [
                .inRoom("family/connie"),
                .currentlyBelieve,
                .trustworthy
            ],
                        limit: 50,
                        ordering: .byCaptureTimeDesc)
        )
        let rows = await drain(stream)
        #expect(rows.count == 5)
        // Room filter correctness is enforced by the filter predicate; Drawer.room
        // was removed per ADR-017, so room cannot be verified on the result struct.
        // Descending by filedAt
        let sorted = rows.sorted { $0.filedAt > $1.filedAt }
        #expect(rows.map(\.id) == sorted.map(\.id))
    }
}
