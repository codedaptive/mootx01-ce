// FrameFaithfulRecallDropTests.swift
//
// Frame-faithful recall drop, GLK level (both ports must agree).
// Resolves DECISION_NEEDED_QUEUEKIT_PIPELINE_RECALL_PARITY (Bob's ruling,
// option 1): corpus-lane candidates honor the recall frame's state filter,
// identical on both ports.
//
// The RecallDirector builds its drawerIndex via the LocusKit frame-aware by-id
// load (Estate.getDrawers(ids:matchingFrame:hydrationLevel:)), so the admissible
// set is exactly the frame-filtered set — identical to the Rust path whose
// drawer_index comes from estate.recall(frame). A BM25/vector candidate the frame
// excludes is DROPPED (not surfaced as a nil-drawer phantom), and the SAME
// candidate surfaces when the frame overrides the state filter. The drop is GATED
// on by-id load success so a valid active drawer not-yet-joined is never dropped.
//
// FORCE-TEST A (WITHDRAWN DROP): capture(impatient) a memory, withdraw it, then
//   a DEFAULT recall (`.currentlyBelieve` implied) does NOT return it — absent,
//   not a nil-drawer phantom. Mirrors Rust dispatch
//   `withdraw_memory_removes_from_unconfirmed_set`.
//
// FORCE-TEST B (FRAME OVERRIDE SURFACES — proves NOT a hardcode): the SAME
//   withdrawn drawer, recalled with a `.usedToBelieve` state filter, IS returned.
//   The drop honors the frame, not a constant. The ARIA dispatch tool cannot
//   express a state-axis override (decodeFilter has no such case), so this proof
//   lives at the GLK level.
//
// Both ports assert the SAME A/B outcomes (peer: rust/tests/frame_faithful_recall_drop_parity.rs).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory

@Suite("Frame-faithful recall drop — withdrawn honors the frame (both ports)", .serialized)
struct FrameFaithfulRecallDropTests {

    /// Provision a GLK estate with Corpus + VectorStore wired (deterministic
    /// model, so the BM25 + dense lanes are live from the first impatient capture).
    private func provision() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-frame-faithful-drop")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "Frame-Faithful Drop Estate",
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

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "frame-faithful",
            latticeAnchor: .udc("000.000"),
            addedBy: "frame-faithful-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// corpusOnly request carrying a caller-supplied state filter. The default
    /// (`.unconfirmed` only) implies `.currentlyBelieve`; passing `.usedToBelieve`
    /// overrides the state axis so Cluster-B (withdrawn) drawers surface.
    private func request(query: String, stateFilter: Filter? = nil) -> GLKRecallRequest {
        var chain: [Filter] = [.unconfirmed]
        if let stateFilter { chain.append(stateFilter) }
        return GLKRecallRequest(
            frame: RecallFrame(
                filterChain: chain,
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed,
            queryText: query
        )
    }

    // MARK: - A. Withdrawn drops under the default frame

    @Test func withdrawnDrawerDroppedUnderDefaultFrame() async throws {
        let (kit, handle) = try await provision()
        defer { Task { try? await kit.close(handle) } }

        // Impatient capture: the drawer's chunk is ingested INLINE into the Corpus
        // (no drain wait), so it is a live BM25/vector candidate immediately. This
        // is the condition that surfaced the latent leak — the corpus is populated.
        let content = "marmalade quasar threnody withdrawn drop probe"
        let drawer = try await kit.capture(handle, captureFrame(content), mode: .impatient)

        // Precondition: before withdrawal, the default recall surfaces it.
        let pre = try await kit.recall(handle, request(query: "marmalade quasar threnody"))
        #expect(pre.hits.contains { $0.drawer?.id == drawer.id && $0.sources.contains(.corpusBM25) },
            "active drawer must be BM25-recallable before withdrawal")

        // Withdraw — transitions state to .withdrawn (Cluster B, adjective bit 18).
        // The corpus chunk PERSISTS (withdraw does not expunge the corpus), so the
        // BM25 lane still returns drawer.id as a candidate.
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "obsolete"))

        // Default frame implies `.currentlyBelieve`, which excludes Cluster B.
        // The candidate loaded (so the drop is gated-on-success) but failed the
        // frame filter → it is DROPPED ENTIRELY, not surfaced as a nil-drawer phantom.
        let post = try await kit.recall(handle, request(query: "marmalade quasar threnody"))
        #expect(!post.hits.contains { $0.id == drawer.id },
            "withdrawn drawer must be DROPPED from default recall (absent, not nil-phantom); got hits: \(post.hits.map(\.id))")
    }

    // MARK: - B. Frame override surfaces the withdrawn drawer (NOT a hardcode)

    @Test func usedToBelieveFrameSurfacesWithdrawnDrawer() async throws {
        let (kit, handle) = try await provision()
        defer { Task { try? await kit.close(handle) } }

        let content = "marmalade quasar threnody frame override probe"
        let drawer = try await kit.capture(handle, captureFrame(content), mode: .impatient)
        try await kit.withdraw(handle, WithdrawFrame(rowID: drawer.id, reason: "obsolete"))

        // Sanity: the default frame drops it (same as test A).
        let def = try await kit.recall(handle, request(query: "marmalade quasar threnody"))
        #expect(!def.hits.contains { $0.id == drawer.id },
            "default frame must drop the withdrawn drawer")

        // Override the state axis to `.usedToBelieve` (Cluster B). The frame-aware
        // load now ADMITS the withdrawn drawer, so it surfaces with a real drawer.
        // This proves the drop honors the FRAME, not a hardcoded constant: a
        // `.isClusterA`-style hardcode would drop it here too.
        let override = try await kit.recall(
            handle, request(query: "marmalade quasar threnody", stateFilter: .usedToBelieve))
        #expect(override.hits.contains { $0.id == drawer.id },
            "a .usedToBelieve frame MUST surface the withdrawn drawer (frame honored, not hardcoded); got hits: \(override.hits.map(\.id))")
        // And the surfaced hit must carry a real (non-nil) drawer in .withdrawn state.
        let hit = override.hits.first { $0.id == drawer.id }
        #expect(hit?.drawer?.state == .withdrawn,
            "the surfaced override hit must carry the real withdrawn drawer, not a nil-drawer phantom")
    }

    // MARK: - C. Burst of 120 active drawers — 100% recallable (join drops nothing)

    /// FORCE-TEST C (the ~10% loss, HARD GATE): an IMPATIENT burst of 120 ACTIVE
    /// drawers is 100% recallable — the frame-faithful recall join drops ZERO
    /// valid active drawers. Impatient (inline) ingest isolates the recall JOIN
    /// from the encode-drain worker (deterministic, no poll-timing), so any miss
    /// here is the join dropping a valid active drawer — exactly the bug fixed.
    /// (The regular+drain path's residual ingest tail is a separate Discovery,
    /// guarded at ≥80% in EncodeDrainNearRealtimeTests.)
    @Test func impatientBurstOf120AllRecallable() async throws {
        let (kit, handle) = try await provision()
        defer { Task { try? await kit.close(handle) } }

        let n = 120
        // Unique, collision-free, high-IDF token per doc: fixed-width alpha so no
        // token is a prefix/stem of another. index 12 → "qzxaacxq" (012 → a,a,c).
        func uniqueToken(_ i: Int) -> String {
            let padded = String(format: "%03d", i)
            let letters = padded.map { ch -> Character in
                Character(UnicodeScalar(UInt8(97 + (Int(String(ch)) ?? 0))))
            }
            return "qzx" + String(letters) + "xq"
        }

        var idByIndex: [Int: String] = [:]
        for i in 0..<n {
            // Impatient: the chunk is ingested INLINE into the Corpus before the
            // call returns — no drain wait, no poll-timing.
            let d = try await kit.capture(handle, captureFrame(uniqueToken(i)), mode: .impatient)
            idByIndex[i] = d.id
        }

        var recalled = 0
        var missing: [Int] = []
        for i in 0..<n {
            let targetID = idByIndex[i]
            let result = try await kit.recall(handle, request(query: uniqueToken(i)))
            if result.hits.contains(where: {
                $0.drawer?.id == targetID && $0.sources.contains(.corpusBM25)
            }) {
                recalled += 1
            } else {
                missing.append(i)
            }
        }
        // HARD GATE: 100%. A valid ACTIVE drawer is never dropped by the join.
        #expect(recalled == n,
            "all \(n) active drawers must be BM25-recallable (got \(recalled)/\(n); missing: \(missing)); any miss = the recall join dropped a valid active drawer")
    }
}
