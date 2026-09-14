// DenseRowSensitivityGateTests.swift
//
// MXE-DM — the S2-row hydration boundary refuses stale-tunnel endpoints
// (Codex finding 9352f983dea081919f83885bdbf77d40).
//
// A tunnel inherits its endpoints' adjective sensitivity ONCE, at capture.
// `CorrectSensitivity` later rewrites only the drawer's adjective bitmap and
// never reclassifies existing tunnels — so a Normal tunnel outlives its
// endpoint's Normal status and keeps pointing at a now-Restricted drawer.
// Every graph-lens arm that hydrates an id off that graph must refuse to
// render its subject, while still emitting the id and its ranking value.
//
// ONE test per behaviour at the HELPER, not one near-duplicate per arm.
// All six lens arms in `LensTools`, the four recall arms in `RecipeTools`,
// and the two tunnel-citation arms in `ToolDispatch` — twelve call sites —
// route through `RecipeTools.s2RowsByID`, so proving the helper gates
// covers every one of them by construction.
//
// The gate here is the empty `filterChain` in `s2RowsByID`, which
// `BitmapEvaluator.insertDefaults` turns into `.sensitivityAtMost(.elevated)`
// on the adjective axis. Twin of the Rust `s2_rows_by_id` tests in
// dispatch_tests.rs (`dm_*`).

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

/// `.serialized`: every case opens a live in-memory estate — same
/// discipline as LensToolsTests and RecipeToolsTests.
@Suite("S2-row sensitivity gate", .serialized)
struct DenseRowSensitivityGateTests {

    /// The canary lives in the SUBJECT, not the content: `ResultComposer.renderS2Row`
    /// renders `subject`, so a canary in the body would prove nothing.
    private static let canary = "dm stale-edge target SUBJECTCANARY"

    // MARK: - Harness

    private func openEstate(
        in kit: GeniusLocusKit, owner: OwnerCredentials
    ) async throws -> EstateHandle {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        return try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
    }

    /// Build the stale-edge state: two Normal drawers linked while BOTH are
    /// Normal (so the tunnel inherits Normal), then the target corrected to
    /// `sensitivity` — which leaves the tunnel's own classification stale.
    private func staleEdge(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        sensitivity: AdjectiveSensitivity
    ) async throws -> (src: String, tgt: String) {
        let estate = try await kit.estate(for: handle)
        let src = try await estate.capture(CaptureFrame(
            content: "dm stale-edge source memory", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "dm-tests",
            embeddingModelID: "test-model-v1",
            subject: "dm stale-edge source subject")).id
        let tgt = try await estate.capture(CaptureFrame(
            content: "dm stale-edge target memory", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "dm-tests",
            embeddingModelID: "test-model-v1",
            subject: Self.canary)).id
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: "study", sourceRoom: "r",
            targetWing: "study", targetRoom: "r",
            label: "relates", addedBy: "dm-tests",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references))
        try await estate.mutate(rowID: tgt, kind: .correctSensitivity(sensitivity))
        return (src, tgt)
    }

    private func text(_ result: JSONValue) throws -> String {
        let obj = try #require(result.objectValue)
        #expect(obj["isError"]?.boolValue == false)
        return try #require(
            obj["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    // MARK: - The helper gate (covers all twelve callers by construction)

    /// A drawer restricted AFTER its tunnels were created is absent from the
    /// helper's map — so every caller's S2-row fallback fires.
    /// Absent rather than substituted: the map is how a caller learns the row
    /// is gated, and substituting a redaction string here would hand every
    /// arm a second, unreviewed disclosure format.
    @Test func helperOmitsStaleRestrictedEndpoint() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dm-h-r"))
        let ids = try await staleEdge(kit, handle, sensitivity: .restricted)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.s2RowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        #expect(rows[ids.tgt] == nil,
                "a restricted endpoint must be absent from the map")
        #expect(rows[ids.src] != nil,
                "its Normal sibling must still hydrate — the gate is not a wall")
        #expect(rows.values.contains { $0.contains("SUBJECTCANARY") } == false,
                "no rendered row may carry the gated subject")
    }

    /// Same for Secret — the ceiling is `> elevated`, not `!= restricted`.
    @Test func helperOmitsStaleSecretEndpoint() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "dm-h-s"))
        let ids = try await staleEdge(kit, handle, sensitivity: .secret)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.s2RowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        #expect(rows[ids.tgt] == nil,
                "a secret endpoint must be absent from the map")
        #expect(rows.values.contains { $0.contains("SUBJECTCANARY") } == false,
                "no rendered row may carry the gated subject")
    }

    /// The gate must not become a wall. Normal and Elevated are both inside
    /// the Normal tier and must hydrate completely, subject included.
    private func expectHydratesWithinCeiling(
        _ sensitivity: AdjectiveSensitivity, owner: String
    ) async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: owner))
        let ids = try await staleEdge(kit, handle, sensitivity: sensitivity)
        let estate = try await kit.estate(for: handle)

        let rows = try await RecipeTools.s2RowsByID(
            ids: [ids.src, ids.tgt], estate: estate)

        let row = try #require(rows[ids.tgt],
                               "\(sensitivity) is within the ceiling and must hydrate")
        #expect(row.contains("SUBJECTCANARY"),
                "\(sensitivity) must render its subject in full")
    }

    @Test func helperHydratesNormalEndpoint() async throws {
        try await expectHydratesWithinCeiling(.normal, owner: "dm-h-ok-n")
    }

    /// Elevated is the ceiling itself, not above it — the boundary case that
    /// catches a gate written as `!= normal`.
    @Test func helperHydratesElevatedEndpoint() async throws {
        try await expectHydratesWithinCeiling(.elevated, owner: "dm-h-ok-e")
    }

    // MARK: - Contradiction lens: WITHHELD-ID-ONLY = a

    /// A contradiction tunnel keeps its endpoint ids even when one endpoint
    /// was later restricted (stale edge). WITHHELD-ID-ONLY = a ruling: an id
    /// is not body-derived content, so it is always emitted for kept tunnels.
    ///
    /// Scenario: source and target both Normal at capture time, so the tunnel
    /// inherits Normal adjective sensitivity. Target is then corrected to
    /// Restricted. The tunnel's bitmap stays Normal and passes the
    /// `adjectiveSensitivity.isBulkExportable` filter; the target endpoint
    /// cannot be read by the caller but its id still appears in the row.
    ///
    /// The canary string embedded in the restricted endpoint's content and
    /// subject must not appear anywhere in the serialized response.
    @Test("contradiction lens emits restricted stale-edge endpoint id")
    func contradictionLensEmitsRestrictedEndpointId() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "prov-b-withheld-ep"))
        let estate = try await kit.estate(for: handle)

        let sourceID = try await estate.capture(CaptureFrame(
            content: "prov-b source content", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "prov-b",
            embeddingModelID: "test-model-v1",
            subject: "prov-b source subject")).id
        // The canary is placed in both content and subject so that any
        // accidental body leak is caught regardless of which field leaks.
        let canary = "PROV_B_STALE_EDGE_CANARY_40ef72a1"
        let targetID = try await estate.capture(CaptureFrame(
            content: "prov-b target content \(canary)", channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "prov-b",
            embeddingModelID: "test-model-v1",
            subject: "\(canary) prov-b target subject")).id
        // Both drawers are Normal at capture time, so the tunnel inherits
        // Normal adjective sensitivity.
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: "study", sourceRoom: "r",
            targetWing: "study", targetRoom: "r",
            label: "contradicts", addedBy: "prov-b",
            sourceDrawerId: sourceID, targetDrawerId: targetID, kind: .contradicts))
        // Stale edge: raise target to Restricted after the tunnel exists.
        // The tunnel's bitmap is not updated by correctSensitivity.
        try await estate.mutate(rowID: targetID, kind: .correctSensitivity(.restricted))

        let authority = AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle)
        let service = AriaV2LensLowerService(
            authority: authority,
            context: .init(estateID: handle.estateUUID, now: Date(timeIntervalSince1970: 1)))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let sc = try #require(response.objectValue?["structuredContent"]?.objectValue)
        let data = try #require(sc["data"]?.objectValue)
        let tunnelRows = try #require(data["contradictsTunnels"]?.arrayValue)
        #expect(tunnelRows.count == 1, "the contradiction tunnel must be present")

        let tunnelRow = try #require(tunnelRows.first?.objectValue)
        // Both endpoint ids are emitted: id is not body-derived content.
        #expect(tunnelRow["sourceDrawerId"]?.stringValue == sourceID,
                "sourceDrawerId must be emitted")
        #expect(tunnelRow["targetDrawerId"]?.stringValue == targetID,
                "the restricted endpoint id must be emitted (WITHHELD-ID-ONLY = a)")

        // The row may carry only id, lifecycle, sourceDrawerId, targetDrawerId.
        let allowed: Set<String> = ["id", "lifecycle", "sourceDrawerId", "targetDrawerId"]
        #expect(Set(tunnelRow.keys).isSubset(of: allowed),
                "tunnel row must carry only the four allowed keys")
        // Pin id and lifecycle presence to match the strength of the Rust twin
        // (project_data calls required_field for both at lens_lower.rs:1756-1760).
        #expect(tunnelRow["id"] != nil, "id must be present in the tunnel row")
        #expect(tunnelRow["lifecycle"]?.stringValue == "active",
                "lifecycle must equal \"active\"")

        // Canary from the restricted endpoint must not bleed into the response.
        let blob = "\(response)"
        #expect(!blob.contains(canary),
                "canary from the restricted endpoint must not appear in the lens output")

        // withheldContradictionCount is 0: the tunnel is Normal; the
        // endpoint's Restriction does not change the tunnel's bitmap.
        let withheld = try #require(data["withheldContradictionCount"]?.integerValue)
        #expect(withheld == 0,
                "the tunnel is Normal; the endpoint restriction does not withhold it")
    }

    /// Trust-synthesis keyInsights omits provenance-restricted rows (KEYINSIGHTS-PROV = a).
    ///
    /// Scenario: two drawers captured. The admissible drawer has normal
    /// provenance sensitivity; its first-line content must appear in
    /// keyInsights. The restricted drawer is captured with
    /// `provenanceSensitivity: .restricted` (bits 30–35 raw 32); its canary
    /// first line must NOT appear in keyInsights. Both drawer ids must be
    /// present in rankedIDs because the id is not body-derived content.
    ///
    /// Take-then-filter is required: maxCount rows are taken in stream order
    /// first, then non-admissible rows are dropped from that slice. This
    /// test proves the wiring from CaptureFrame → LocusKit → CognitionKit
    /// → NeuronKit → trust-synthesis lens output.
    @Test("trust synthesis keyInsights omits provenance-restricted rows")
    func trustSynthesisKeyInsightsOmitsProvenanceRestrictedRows() async throws {
        let kit = GeniusLocusKit()
        let handle = try await openEstate(
            in: kit, owner: OwnerCredentials(ownerIdentifier: "prov-b-keyinsights-prov"))
        let estate = try await kit.estate(for: handle)

        // Admissible drawer: normal provenance sensitivity (default).
        let admissibleFirstLine = "PROV_B_ADMISSIBLE_LINE_for_keyInsights"
        let admissibleID = try await estate.capture(CaptureFrame(
            content: "\(admissibleFirstLine)\nSecond line of admissible content.",
            channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "prov-b",
            embeddingModelID: "test-model-v1",
            subject: "prov-b admissible subject")).id

        // Restricted drawer: provenance sensitivity set to .restricted at capture
        // (bits 30–35, raw 32). This is the provenance axis, not the adjective axis:
        // correctSensitivity acts on adjective bits 6–11 and would cause the row to
        // be absent from the recall set entirely, proving nothing about keyInsights.
        // Provenance-restricted rows ARE recalled (they appear in rankedIDs) but
        // their content MUST NOT contribute to keyInsights.
        let restrictedCanary = "PROV_B_RESTRICTED_CANARY_keyInsights_c3d1a7"
        let restrictedID = try await estate.capture(CaptureFrame(
            content: "\(restrictedCanary)\nSecond line of restricted content.",
            channel: .typed, room: "r",
            latticeAnchor: .udc("004"), addedBy: "prov-b",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .restricted,
            subject: "prov-b restricted subject")).id

        let authority = AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle)
        let service = AriaV2LensLowerService(
            authority: authority,
            context: .init(estateID: handle.estateUUID, now: Date(timeIntervalSince1970: 1)))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensTrustSynthesis.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let sc = try #require(response.objectValue?["structuredContent"]?.objectValue)
        let data = try #require(sc["data"]?.objectValue)
        let context = try #require(data["context"]?.objectValue)
        let keyInsights = try #require(context["keyInsights"]?.arrayValue)

        // The restricted drawer's canary must not appear in keyInsights.
        let insightsStrings = keyInsights.compactMap(\.stringValue)
        #expect(!insightsStrings.contains(where: { $0.contains(restrictedCanary) }),
                "provenance-restricted drawer canary must not appear in keyInsights")

        // The admissible drawer's first line must appear in keyInsights.
        #expect(insightsStrings.contains(where: { $0.contains(admissibleFirstLine) }),
                "admissible drawer first line must appear in keyInsights")

        // Both drawer ids must be present in rankedIDs (id is not body-derived content).
        let rankedRows = try #require(data["rankedIDs"]?.arrayValue)
        let rankedIDStrings = rankedRows.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(rankedIDStrings.contains(where: { $0.caseInsensitiveCompare(admissibleID) == .orderedSame }),
                "admissible drawer id must be present in rankedIDs")
        #expect(rankedIDStrings.contains(where: { $0.caseInsensitiveCompare(restrictedID) == .orderedSame }),
                "restricted drawer id must be present in rankedIDs (id is not body-derived content)")
    }
}
