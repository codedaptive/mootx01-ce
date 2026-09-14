import AriaMCPWire
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed lower lens adapters")
struct AriaV2LensLowerTests {
    private let estateID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test("twenty-three source-backed lens operations use the typed request/result boundary")
    func typedOperations() async throws {
        let service = AriaV2LensLowerService(
            authority: FixtureAuthority(),
            context: .init(estateID: estateID, now: Date(timeIntervalSince1970: 1)))
        for fixture in fixtures {
            let request = try AriaV2RecallLensRequest(
                tool: fixture.tool, arguments: .object(fixture.arguments))
            let response = try await service.execute(request)
            #expect(response.objectValue?["isError"] == .bool(false))
            #expect(response.objectValue?["structuredContent"]?.objectValue?["tool"] == .string(fixture.tool))
            for dataKey in fixture.dataKeys {
                #expect(response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?[dataKey] != nil)
            }
            #expect(response.objectValue?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
        }
    }

    @Test("typed lower refusal remains a structured operational refusal")
    func typedRefusal() async throws {
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensCohesion.rawValue, arguments: .object([:]))
        let response = try await AriaV2LensLowerService(
            authority: RefusingAuthority(),
            context: .init(estateID: estateID, now: Date(timeIntervalSince1970: 1))).execute(request)
        #expect(response.objectValue?["isError"] == .bool(true))
        #expect(response.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("lens_unavailable"))
    }

    private var fixtures: [Fixture] {
        [
            .init(tool: "moot_lens_keystones", arguments: ["wing": .string("work")], dataKeys: ["keystones"]),
            .init(tool: "moot_lens_constellation", arguments: ["wing": .string("work")], dataKeys: ["communities"]),
            .init(tool: "moot_lens_free_association", arguments: [
                "wing": .string("work"),
                "seed_memory_id": .string("22222222-2222-4222-8222-222222222222"),
            ], dataKeys: ["associations"]),
            .init(tool: "moot_lens_bias", arguments: [:], dataKeys: ["biasedFor", "biasedAgainst", "dismissal", "learned"]),
            .init(tool: "moot_lens_cohesion", arguments: [:], dataKeys: ["considered", "outliers"]),
            .init(tool: "moot_lens_contradiction", arguments: [:], dataKeys: ["contradictsTunnels", "conflictingFacts"]),
            .init(tool: "moot_lens_theme_weather", arguments: [:], dataKeys: ["weather"]),
            .init(tool: "moot_lens_latent_themes", arguments: [:], dataKeys: ["k", "loadings"]),
            .init(tool: "moot_lens_drift", arguments: ["splitAt": .string("2026-01-01T00:00:00Z")], dataKeys: ["beforeCount", "afterCount", "drift"]),
            .init(tool: "moot_lens_trust_synthesis", arguments: ["limit": .integer(5)], dataKeys: ["context", "rankedIDs", "highTrustCount"]),
            .init(tool: "moot_lens_partial_cue", arguments: ["anchor_memory_id": .string("22222222-2222-4222-8222-222222222222")], dataKeys: ["results"]),
            .init(tool: "moot_lens_anticipate", arguments: ["targetKind": .string("prose"), "limit": .integer(5)], dataKeys: ["actions"]),
            .init(tool: "moot_lens_node_motion", arguments: ["memory_id": .string("22222222-2222-4222-8222-222222222222")], dataKeys: ["rowID", "volatility", "eventCount", "anchorTrajectory", "reanchored", "anomaly"]),
            .init(tool: "moot_lens_successors", arguments: ["wing": .string("work"), "anchor_memory_id": .string("22222222-2222-4222-8222-222222222222")], dataKeys: ["successors"]),
            .init(tool: "moot_lens_overlap", arguments: ["comparison_estate_id": .string("33333333-3333-4333-8333-333333333333")], dataKeys: ["overlap", "aSufficient", "bSufficient"]),
            .init(tool: "moot_lens_divergence", arguments: ["comparison_estate_id": .string("33333333-3333-4333-8333-333333333333")], dataKeys: ["aCount", "bCount", "divergence"]),
            .init(tool: "moot_lens_associations", arguments: [:], dataKeys: ["rules", "labelOverflow"]),
            .init(tool: "moot_lens_concepts", arguments: [:], dataKeys: ["concepts", "drawerCount", "coverDeltas", "implications", "implicationsTruncated"]),
            .init(tool: "moot_lens_apriori", arguments: [:], dataKeys: ["rules"]),
            .init(tool: "moot_lens_moment", arguments: ["windowStart": .string("2026-01-01T00:00:00Z"), "windowEnd": .string("2026-01-02T00:00:00Z")], dataKeys: ["windowCount", "ranking"]),
            .init(tool: "moot_lens_rhythm", arguments: ["bit": .string("1"), "bucketSeconds": .string("60"), "bucketCount": .string("4"), "endingAt": .string("2026-01-02T00:00:00Z")], dataKeys: ["bucketCount", "periods"]),
            .init(tool: "moot_lens_precedence", arguments: ["windowStart": .string("2026-01-01T00:00:00Z"), "windowEnd": .string("2026-01-02T00:00:00Z"), "targetField": .string("room"), "targetValue": .string("work")], dataKeys: ["entryCount", "antecedents"]),
            .init(tool: "moot_lens_complexity", arguments: ["fieldA": .string("room")], dataKeys: ["result"]),
        ]
    }

    private struct Fixture {
        let tool: String
        let arguments: [String: JSONValue]
        let dataKeys: [String]
    }
}

private struct FixtureAuthority: AriaV2LensLowerAuthority {
    func execute(
        _ request: AriaV2RecallLensRequest,
        context: AriaV2LensLower.Context
    ) async throws -> AriaV2RecallLensOutcome {
        let data: JSONValue = switch request.operation {
        case .lensKeystones:
            .object(["keystones": .array([.object(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "centrality": .double(0.8)])])])
        case .lensConstellation:
            .object(["communities": .array([.array([.string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")])])])
        case .lensFreeAssociation:
            .object(["associations": .array([.object(["drawerID": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "activation": .double(0.5)])])])
        case .lensBias:
            .object(["biasedFor": .array([]), "biasedAgainst": .array([]), "dismissal": .array([]), "learned": .array([])])
        case .lensCohesion:
            .object(["considered": .integer(3), "outliers": .array([])])
        case .lensContradiction:
            .object(["contradictsTunnels": .array([]), "conflictingFacts": .array([])])
        case .lensThemeWeather:
            .object(["weather": .array([.object(["category": .string("work"), "momentum": .double(0.2)])])])
        case .lensLatentThemes:
            .object(["k": .integer(1), "loadings": .array([.object(["label": .string("room:work"), "dominantTheme": .integer(0)])])])
        case .lensDrift:
            .object([
                "beforeCount": .integer(2), "afterCount": .integer(3),
                "drift": .object(["jensenShannon": .double(0.1), "klDivergence": .double(0.2)]),
            ])
        case .lensTrustSynthesis:
            .object([
                "context": .object([
                    "summary": .string("summary"), "patterns": .array([]),
                    "successRate": .double(1), "averageReward": .double(0),
                    "recommendations": .array([]), "keyInsights": .array([]),
                ]),
                "rankedIDs": .array([]), "highTrustCount": .integer(0),
            ])
        case .lensPartialCue:
            .object(["results": .array([])])
        case .lensAnticipate:
            .object(["actions": .array([.object(["action": .integer(1), "successRate": .double(0.5), "count": .integer(2)])])])
        case .lensNodeMotion:
            .object(["rowID": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "volatility": .double(0.2), "eventCount": .integer(2), "anchorTrajectory": .array([.integer(1)]), "reanchored": .bool(false), "anomaly": .string("stable")])
        case .lensSuccessors:
            .object(["successors": .array([.object(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "weight": .integer(2)])])])
        case .lensOverlap:
            .object(["overlap": .double(0.5), "aSufficient": .bool(true), "bSufficient": .bool(true)])
        case .lensDivergence:
            .object(["aCount": .integer(2), "bCount": .integer(3), "divergence": .object(["jensenShannon": .double(0.1), "klDivergence": .double(0.2)])])
        case .lensAssociations:
            .object(["rules": .array([]), "labelOverflow": .bool(false)])
        case .lensConcepts:
            .object(["concepts": .array([]), "drawerCount": .integer(0), "coverDeltas": .array([]), "implications": .array([]), "implicationsTruncated": .bool(false)])
        case .lensApriori:
            .object(["rules": .array([])])
        case .lensMoment:
            .object(["windowCount": .integer(2), "ranking": .array([.object(["hammingDistance": .integer(1)])])])
        case .lensRhythm:
            .object(["bucketCount": .integer(4), "periods": .array([.object(["periodSeconds": .integer(60), "relativeMagnitude": .double(1)])])])
        case .lensPrecedence:
            .object(["entryCount": .integer(2), "antecedents": .array([.object(["source": .object(["fieldPath": .string("room"), "valueRepr": .string("work")]), "lagBucket": .integer(1), "count": .integer(2)])])])
        case .lensComplexity:
            .object(["result": .object(["entropyA": .double(0.5)])])
        default:
            throw AriaV2LensLower.refusal("Unexpected lens fixture operation.")
        }
        return .init(data: data, compactText: "Typed \(request.operation.rawValue).")
    }
}

private struct RefusingAuthority: AriaV2LensLowerAuthority {
    func execute(
        _ request: AriaV2RecallLensRequest,
        context: AriaV2LensLower.Context
    ) async throws -> AriaV2RecallLensOutcome {
        throw AriaV2LensLower.refusal("The lower engine is unavailable.")
    }
}

// MARK: - Partial-cue mode argument — discrimination tests

/// Integration tests that prove the `mode` argument on `moot_lens_partial_cue`
/// routes to the correct engine path. Uses a real in-memory estate with three
/// memories whose structural and conceptual fingerprints are intentionally
/// arranged so the three modes produce distinct orderings.
///
/// Test data design (DrawerFingerprint.swift — four 64-bit blocks):
///   anchor: sensitivity=normal, UDC="004"
///   memA:   sensitivity=normal (identical structure block), UDC="530" (different concept block)
///   memB:   sensitivity=elevated (different structure block), UDC="004" (identical concept block)
///
/// feelsLike (match=structure, differ=concept):
///   memA  score = 1 * differ_concept > 0  (differ_concept > 0 since UDC differs)
///   memB  score = match_struct * 0 = 0    (differ_concept = 0; same UDC → identical concept block)
///
/// aboutThis (match=concept, differ=structure):
///   memB  score = 1 * differ_struct > 0   (differ_struct > 0; sensitivity differs → structure block differs)
///   memA  score = match_concept * 0 = 0   (differ_struct = 0; same sensitivity → identical structure block)
@Suite("moot_lens_partial_cue mode argument — discrimination tests", .serialized)
struct PartialCueModeTests {

    // Open a fresh in-memory estate each time so tests are fully isolated.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "partial-cue-mode-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: false)
        return (kit, handle)
    }

    // Capture one test drawer with the given UDC and sensitivity.
    private func capture(
        kit: GeniusLocusKit, handle: EstateHandle,
        udc: String, sensitivity: AdjectiveSensitivity
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: "partial cue mode test memory \(udc)/\(sensitivity)",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc(udc), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1", sensitivity: sensitivity)
        return try await kit.capture(handle, frame)
    }

    // Helper: extract results[0]["id"] from a service response envelope.
    private func firstResultID(from response: JSONValue) -> JSONValue? {
        response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue?.first?.objectValue?["id"]
    }

    // Helper: extract results[0]["score"] from a service response envelope.
    private func firstResultScore(from response: JSONValue) -> JSONValue? {
        response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue?.first?.objectValue?["score"]
    }

    @Test("feelsLike mode ranks same-struct/diff-concept memory first")
    func feelsLikeRanksStructuralMatchFirst() async throws {
        let (kit, handle) = try await openEstate()
        let anchor = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .normal)
        let memA   = try await capture(kit: kit, handle: handle, udc: "530", sensitivity: .normal)
        _          = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .elevated)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)
        #expect(firstResultID(from: response) == .string(memA.id),
                "feelsLike must rank the same-struct/diff-concept memory first")
    }

    @Test("aboutThis mode ranks same-concept/diff-struct memory first")
    func aboutThisRanksConceptMatchFirst() async throws {
        let (kit, handle) = try await openEstate()
        let anchor = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .normal)
        _          = try await capture(kit: kit, handle: handle, udc: "530", sensitivity: .normal)
        let memB   = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .elevated)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("aboutThis")]))
        let response = try await service.execute(request)
        #expect(firstResultID(from: response) == .string(memB.id),
                "aboutThis must rank the same-concept/diff-struct memory first")
    }

    @Test("fromThen mode produces a different top score than feelsLike for the same memories")
    func fromThenScoreDiffersFromFeelsLike() async throws {
        let (kit, handle) = try await openEstate()
        // Only two memories needed: anchor + memA (diff UDC, same sensitivity).
        // feelsLike score = 1 * differ_concept; fromThen score = match_temporal * differ_concept.
        // Since lineageHashes are fresh UUIDs, match_temporal < 1 with overwhelming probability.
        let anchor = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .normal)
        _          = try await capture(kit: kit, handle: handle, udc: "530", sensitivity: .normal)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))

        let feelsLikeRequest = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let feelsLikeResponse = try await service.execute(feelsLikeRequest)

        let fromThenRequest = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("fromThen")]))
        let fromThenResponse = try await service.execute(fromThenRequest)

        let scoreFL = firstResultScore(from: feelsLikeResponse)
        let scoreFT = firstResultScore(from: fromThenResponse)
        #expect(scoreFL != scoreFT,
                "fromThen scores must differ from feelsLike scores (mode argument is live; different fingerprint blocks used)")
    }

    // MARK: Finding 1 — both storage spellings tried

    /// The anchor id returned by the v2 API is canonical lowercase (canonicalUUID).
    /// On Apple platforms, drawers are stored with uppercase ids (UUID().uuidString).
    /// Passing the lowercase canonical form as anchor_memory_id must still succeed
    /// because the two-spelling lookup tries the native uppercase form first.
    ///
    /// Neuter: revert lensPartialCue to use only `canonicalAnchorID` directly (no
    /// storageIdentitySpellings), and this test fails with AnchorNotInRecalledSetError
    /// because lowercase anchor never equals uppercase drawer.id.
    @Test("anchor lookup succeeds when stored id uses native uppercase and anchor is passed in canonical lowercase")
    func anchorLookupTriesBothUUIDSpellings() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }
        let anchor = try await capture(kit: kit, handle: handle, udc: "004", sensitivity: .normal)
        _           = try await capture(kit: kit, handle: handle, udc: "530", sensitivity: .normal)
        // anchor.id is the native uppercase form (UUID().uuidString on Apple).
        // AriaV2RecallLensRequest.init normalises .uuid arguments via canonicalUUID,
        // so the decoded anchor_memory_id is lowercase regardless of what we pass.
        // The two-spelling loop must try the uppercase spelling to match the stored
        // uppercase drawer.id.
        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id)]))
        let response = try await service.execute(request)
        #expect(firstResultID(from: response) != nil,
                "anchor lookup with uppercase-stored id passed through canonical normalisation must return results")
    }

    // MARK: Finding 4 — banana mode asserted at the shipped envelope path

    /// An unknown mode value must produce a -32602 INVALID_PARAMS protocol error
    /// (a throw from ToolDispatcher.dispatch), not an isError:true result envelope.
    ///
    /// AriaV2RecallLensRequest.init validates the mode enum at decode time so
    /// an unknown value is refused before AriaSurfaceDecoder builds a request and
    /// before dispatchV2 is called.  The thrown JSONRPCError propagates from
    /// dispatch() to the caller — the transport-level error, not a result envelope.
    ///
    /// This matches Rust's behaviour: V2RecallLensRequest::decode validates mode
    /// at parse time and Dispatcher::handle returns an error envelope with code -32602.
    ///
    /// Mutation gate: remove the decode-time validation in AriaV2RecallLensRequest.init
    /// and dispatch() returns a result instead of throwing — the do/catch succeeds on
    /// the wrong branch and Issue.record fires.
    @Test("unknown mode value 'banana' produces -32602 INVALID_PARAMS thrown by dispatch via ToolDispatcher")
    func unknownModeBananaProducesInvalidParamsThrow() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "banana-mode-envelope-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: false)
        defer { Task { try? await kit.close(handle) } }
        let dispatcher = ToolDispatcher(
            kit: kit, handle: handle,
            environment: [BenchClock.envKey: "2026-09-08T00:00:00Z"])
        do {
            _ = try await dispatcher.dispatch(
                name: "moot_lens_partial_cue",
                arguments: .object([
                    "anchor_memory_id": .string("22222222-2222-4222-8222-222222222222"),
                    "mode": .string("banana"),
                ]))
            Issue.record("dispatch must throw for unknown mode value 'banana'; did not throw")
        } catch let error as JSONRPCError {
            // Decode-time validation: the thrown error is a -32602 INVALID_PARAMS
            // protocol fault.  Path convention: Swift uses bare key "mode".
            #expect(error.code == JSONRPCErrorCode.invalidParams,
                    "banana mode must yield -32602 INVALID_PARAMS; got code \(error.code)")
            #expect(error.data?.objectValue?["path"] == .string("mode"),
                    "error data.path must be 'mode'; got \(String(describing: error.data?.objectValue?["path"]))")
            // Parity gate: both ports must expose a machine-readable allowed list.
            // Both ports sort alphabetically, so order is part of the contract.
            let allowedValues = error.data?.objectValue?["allowed"]?.arrayValue?
                .compactMap { $0.stringValue }
            #expect(allowedValues != nil,
                    "error data.allowed must be present; got data: \(String(describing: error.data))")
            #expect(allowedValues == ["aboutThis", "feelsLike", "fromThen"],
                    "error data.allowed must be sorted alphabetically with exactly the three valid modes; got \(String(describing: allowedValues))")
            // Parity gate: both ports must expose a machine-readable correction hint.
            // The hint tells clients which values are valid without parsing the message.
            let correction = error.data?.objectValue?["correction"]?.stringValue
            #expect(correction != nil && !(correction ?? "").isEmpty,
                    "error data.correction must be present and non-empty; got data: \(String(describing: error.data))")
        } catch {
            Issue.record("dispatch must throw JSONRPCError, not \(type(of: error)): \(error)")
        }
    }

    // MARK: bestSpan parity gate

    /// AR_LENS_PARTIAL_CUE_BEST_SPAN_001 (Swift port)
    /// A partial-cue result row for an admissible drawer whose subject and content
    /// are different must carry bestSpan equal to the normalised content body.
    /// Drives the shipped path: AriaV2LensLowerService.execute → AriaV2LensLower
    /// partialCueOutcome → ResultComposer.structuredS1 → structuredRowObject.
    ///
    /// Fixture: anchor UDC "004" Normal; peer UDC "530" Normal, subject ≠ content.
    /// feelsLike: peer has same structure (Normal) and different concept (UDC "530")
    /// so score > 0 and the peer appears in results.
    /// The omit-if-equal branch does not fire because content != subject after
    /// normalisation. bestSpan must equal the normalised content string.
    ///
    /// Port parity: the expectedBestSpan literal must match the Rust twin in
    /// dispatch_tests.rs lens_partial_cue_row_carries_best_span.
    @Test("partial-cue result row carries bestSpan equal to normalised content")
    func partialCueRowCarriesBestSpan() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Anchor: Normal sensitivity, UDC "004". Not returned in its own cue results.
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "partial-cue-span-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1"))

        // Peer: subject and content are DIFFERENT and both non-empty.
        // These literal strings are the wire contract. Both ports assert the same value.
        let expectedBestSpan = "partial cue best span content distinct from subject"
        let peer = try await kit.capture(handle, CaptureFrame(
            content: expectedBestSpan,
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1",
            subject: "partial cue best span subject"))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        // Locate the peer row by id; the anchor is not in results.
        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "peer must appear in partial_cue results")

        let actualBestSpan = try #require(
            peerRow["bestSpan"]?.stringValue,
            "peer row must carry bestSpan — Swift partial_cue must hydrate it")
        #expect(actualBestSpan == expectedBestSpan,
                "bestSpan must equal the normalised content body")
    }

    @Test("partial-cue row carries the cross-port key set and SSC facts")
    func partialCueRowKeysAndSSCFactsMatchPortContract() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        let expectedKeys = ["bestSpan", "eventTime", "id", "room", "score", "sscFacts", "subject"]
        let expectedSSCFacts = "kind: meeting, entity: row parity"
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "partial-cue-row-contract-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1"))
        let peer = try await kit.capture(handle, CaptureFrame(
            content: "partial cue row contract content",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1",
            subject: "partial cue row contract subject"))
        let estate = try await kit.estate(for: handle)
        _ = try await estate.setSSCFacts(expectedSSCFacts, for: peer.id)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue)
        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue)
        #expect(peerRow.keys.sorted() == expectedKeys)
        #expect(peerRow["sscFacts"] == .string(expectedSSCFacts))
    }

    // MARK: Absent-subject and truncation-order parity gates

    /// AR_LENS_PARTIAL_CUE_ABSENT_SUBJECT_001 (Swift port)
    /// A partial-cue result row for a drawer that has no stored subject must
    /// carry no "subject" key at all. Swift's structuredRowObject omits the key
    /// when drawer.subject is nil; Rust's partial-cue arm must do the same.
    ///
    /// Drives the shipped path: AriaV2LensLowerService.execute → AriaV2LensLower
    /// partialCueOutcome → ResultComposer.structuredRowObject.
    ///
    /// Neuter gate: restore the pre-fix Rust path that substitutes NO_SUBJECT_MARKER
    /// and this test remains green in Swift while the Rust twin fails, revealing
    /// the divergence the gate was designed to catch.
    @Test("partial-cue result row omits subject key when drawer has no subject")
    func partialCueRowOmitsSubjectKeyWhenDrawerHasNone() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Anchor: Normal, UDC "004". Not returned in its own cue results.
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "absent-subject-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1"))

        // Peer: no subject set, non-empty content, UDC "530" (same structure as
        // anchor so feelsLike score > 0 and the peer appears in results).
        let peer = try await kit.capture(handle, CaptureFrame(
            content: "absent subject peer content",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1"))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "peer must appear in partial_cue results")

        #expect(peerRow["subject"] == nil,
                "row for drawer without subject must not carry subject key; got row: \(peerRow)")
    }

    /// AR_LENS_PARTIAL_CUE_TRUNCATION_ORDER_001 (Swift port)
    /// bestSpan is produced by normalize-then-truncate at 120 grapheme clusters.
    /// The order and unit are visible when content has collapsible whitespace before
    /// the cut point or a multi-scalar emoji exactly at the boundary.
    ///
    /// Fixture: 50 'A's, five newlines, 100 'B's (155 chars).
    ///   normalize first: "AAAA…AAAA BBBB…BBBB" (151 graphemes)
    ///   then cut:        50 A's + space + 69 B's (120 graphemes)
    ///
    /// Drives the shipped path: AriaV2LensLowerService.execute → AriaV2LensLower
    /// partialCueOutcome → ResultComposer.structuredRowObject.
    ///
    /// Port parity: both expected literals match the Rust twin in dispatch_tests.rs
    /// partial_cue_row_normalises_before_truncating_best_span.
    @Test("partial-cue bestSpan normalises before the 120-grapheme cut")
    func partialCueRowNormalisesBeforeTruncatingBestSpan() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // 50 A's + 5 newlines + 100 B's (155 chars; crosses the 120-char cut).
        let content = String(repeating: "A", count: 50)
            + "\n\n\n\n\n"
            + String(repeating: "B", count: 100)
        // Normalize collapses the newlines, then the cut retains 69 B's.
        let expectedBestSpan = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        // The family emoji is one grapheme cluster despite containing seven scalars.
        let emojiContent = String(repeating: "C", count: 119) + "👨‍👩‍👧‍👦TAIL"
        let expectedEmojiBestSpan = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC👨‍👩‍👧‍👦"

        // Anchor: Normal, UDC "004".
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "truncation-order-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1"))

        // Peer: subject distinct from content so the omit-if-equal branch does
        // not fire and bestSpan reaches the wire.
        let peer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1",
            subject: "truncation order subject"))
        let emojiPeer = try await kit.capture(handle, CaptureFrame(
            content: emojiContent,
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-mode-tests",
            embeddingModelID: "test-model-v1",
            subject: "grapheme boundary subject"))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "peer must appear in partial_cue results")

        let actualBestSpan = try #require(
            peerRow["bestSpan"]?.stringValue,
            "peer row must carry bestSpan")
        #expect(actualBestSpan == expectedBestSpan,
                "bestSpan must normalize before cutting (50 A's + space + 69 B's); got: \(actualBestSpan)")

        let emojiRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == emojiPeer.id })?.objectValue,
            "emoji peer must appear in partial_cue results")
        let actualEmojiBestSpan = try #require(
            emojiRow["bestSpan"]?.stringValue,
            "emoji peer row must carry bestSpan")
        #expect(actualEmojiBestSpan == expectedEmojiBestSpan,
                "bestSpan must retain the complete grapheme at boundary 120; got: \(actualEmojiBestSpan)")
    }

    /// Parity lock: a drawer with provenance sensitivity Restricted and default
    /// adjective sensitivity (Normal) must carry the restricted marker as its
    /// subject and no bestSpan in a partial-cue result row.
    ///
    /// Swift applies AriaV2RecallLensPrivacy.project, which checks bits 30-35 of
    /// drawer.provenance and substitutes ResultComposer.restrictedMarker for the
    /// subject while setting bestSpan to nil (raw=32 arm). Both ports agree on
    /// this exact wire shape; the Rust twin
    /// (dispatch_tests.rs lens_partial_cue_provenance_restricted_row_has_restricted_marker)
    /// asserts the same literal marker string.
    @Test("partial-cue row carries restricted marker as subject and omits bestSpan for provenance-restricted drawer")
    func partialCueProvenanceRestrictedRowHasRestrictedMarker() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Anchor: Normal provenance and adjective, UDC "004".
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "prov-restricted-cue-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-prov-tests",
            embeddingModelID: "test-model-v1"))

        // Peer: provenance=Restricted, adjective=Normal (default).
        // Same UDC as anchor so feelsLike score > 0 and the peer ranks.
        let peer = try await kit.capture(handle, CaptureFrame(
            content: "prov-restricted peer body — must not reach wire",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-prov-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .restricted))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "provenance-restricted peer must appear in partial_cue results")

        // subject must be the restricted marker — literal string so a constant
        // change breaks this test in both ports simultaneously.
        let actualSubject = peerRow["subject"]?.stringValue
        #expect(actualSubject == "[sensitivity: restricted \u{2014} content redacted]",
                "provenance-restricted row subject must be the restricted marker; got: \(String(describing: actualSubject))")
        // Real body content must never appear as bestSpan.
        #expect(peerRow["bestSpan"] == nil,
                "provenance-restricted row must not expose 'bestSpan'; got: \(String(describing: peerRow["bestSpan"]))")
        // id must still be present.
        #expect(peerRow["id"] != nil,
                "provenance-restricted row must carry 'id'")
    }

    /// Parity lock: a drawer with provenance sensitivity Secret and default
    /// adjective sensitivity (Normal) must carry the secret marker as its
    /// subject and no bestSpan in a partial-cue result row.
    ///
    /// Swift applies AriaV2RecallLensPrivacy.project raw=48 arm:
    /// subject = ResultComposer.secretMarker, bestSpan = nil. Both ports
    /// agree on this exact wire shape; the Rust twin
    /// (dispatch_tests.rs lens_partial_cue_provenance_secret_row_has_secret_marker)
    /// asserts the same literal marker string.
    @Test("partial-cue row carries secret marker as subject and omits bestSpan for provenance-secret drawer")
    func partialCueProvenanceSecretRowHasSecretMarker() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Anchor: Normal provenance and adjective, UDC "004".
        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "prov-secret-cue-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-prov-tests",
            embeddingModelID: "test-model-v1"))

        // Peer: provenance=Secret, adjective=Normal (default).
        // Same UDC as anchor so feelsLike score > 0 and the peer ranks.
        let peer = try await kit.capture(handle, CaptureFrame(
            content: "prov-secret peer body — must not reach wire",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-prov-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .secret))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "provenance-secret peer must appear in partial_cue results")

        // subject must be the secret marker — literal string so a constant change
        // breaks this test in both ports simultaneously.
        let actualSubject = peerRow["subject"]?.stringValue
        #expect(actualSubject == "[sensitivity: secret \u{2014} content access requires explicit grant]",
                "provenance-secret row subject must be the secret marker; got: \(String(describing: actualSubject))")
        // Real body content must never appear as bestSpan.
        #expect(peerRow["bestSpan"] == nil,
                "provenance-secret row must not expose 'bestSpan'; got: \(String(describing: peerRow["bestSpan"]))")
        // id must still be present.
        #expect(peerRow["id"] != nil,
                "provenance-secret row must carry 'id'")
    }

    /// Parity lock: normalization removes leading whitespace before applying the
    /// 120-grapheme cut.
    ///
    /// Fixture: 10 spaces + 115 A's (125 chars total).
    ///   normalize first: leading spaces stripped, leaving 115 A's.
    ///   cut: unchanged because 115 is below the limit.
    ///
    /// Port parity: the Rust twin is
    /// dispatch_tests.rs partial_cue_leading_whitespace_normalises_before_grapheme_cut.
    /// Both ports assert the same 115-A literal.
    @Test("partial-cue bestSpan normalises leading whitespace before grapheme cut")
    func partialCueLeadingWhitespaceNormalisesBeforeGraphemeCut() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // 10 leading spaces + 115 A's = 125 chars total.
        let content = String(repeating: " ", count: 10) + String(repeating: "A", count: 115)
        let expectedBestSpan = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        let anchor = try await kit.capture(handle, CaptureFrame(
            content: "trim-asymmetry-anchor",
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("004"), addedBy: "partial-cue-trim-tests",
            embeddingModelID: "test-model-v1"))

        // Subject is distinct from content so the omit-if-equal branch does not
        // fire and bestSpan reaches the wire.
        let peer = try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed, room: "cue-mode-test",
            latticeAnchor: .udc("530"), addedBy: "partial-cue-trim-tests",
            embeddingModelID: "test-model-v1",
            subject: "trim asymmetry subject"))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_partial_cue",
            arguments: .object(["anchor_memory_id": .string(anchor.id), "mode": .string("feelsLike")]))
        let response = try await service.execute(request)

        let results = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["results"]?.arrayValue,
            "results must be an array")

        let peerRow = try #require(
            results.first(where: { $0.objectValue?["id"]?.stringValue == peer.id })?.objectValue,
            "peer must appear in partial_cue results")

        let actualBestSpan = try #require(
            peerRow["bestSpan"]?.stringValue,
            "peer row must carry bestSpan")
        #expect(actualBestSpan == expectedBestSpan,
                "bestSpan must be 115 A's after normalize-before-cut; got: \(actualBestSpan)")
    }

    // MARK: - Provenance gate: keystones and trust-synthesis (B6/B7)

    /// Parity lock: a drawer with provenance sensitivity Restricted and default
    /// adjective sensitivity (Normal) must produce a sparse row in keystones —
    /// id and centrality only, no dense fields.
    ///
    /// The provenance axis (bits 30-35 of drawer.provenance) gates dense fields
    /// independently of the adjective axis (bits 6-11). A provenance-Restricted
    /// drawer with adjective Normal passes the frame ceiling and is present in
    /// drawersByID; AriaV2RecallLensPrivacy.classify must block its body from
    /// the wire. Rust twin: aria_v2_wire_parity_tests.rs
    /// lens_keystones_provenance_restricted_row_has_no_dense_fields.
    @Test("keystones row has no dense fields for provenance-restricted drawer")
    func keystonesProvenanceRestrictedRowHasNoDenseFields() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Hub: provenance=Restricted, adjective=Normal (default).
        // Tunnels are captured while hub is already Restricted on the provenance
        // axis but Normal on the adjective axis, so tunnel sensitivity inherits
        // Normal and the graph includes them — this is the combination that
        // exploited the hole: adjective Normal passes the frame ceiling, provenance
        // Restricted must still block the dense fields.
        let hubContent = "prov-restricted-hub-b6-swift — must not reach wire"
        let hub = try await kit.capture(handle, CaptureFrame(
            content: hubContent,
            channel: .typed, room: "b6p-room",
            latticeAnchor: .udc("004"), addedBy: "prov-keystones-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .restricted,
            wing: "b6p-wing"))

        // Spokes: Normal provenance and adjective. Their IDs anchor the tunnels
        // so hub accumulates out-degree and ranks as the top keystone.
        let s1 = try await kit.capture(handle, CaptureFrame(
            content: "prov-spoke-b6-a",
            channel: .typed, room: "b6p-room",
            latticeAnchor: .udc("004"), addedBy: "prov-keystones-tests",
            embeddingModelID: "test-model-v1",
            wing: "b6p-wing"))
        let s2 = try await kit.capture(handle, CaptureFrame(
            content: "prov-spoke-b6-b",
            channel: .typed, room: "b6p-room",
            latticeAnchor: .udc("004"), addedBy: "prov-keystones-tests",
            embeddingModelID: "test-model-v1",
            wing: "b6p-wing"))

        // Two outbound tunnels from hub make it the highest-centrality node.
        let estate = try await kit.estate(for: handle)
        for spokeID in [s1.id, s2.id] {
            _ = try await estate.capture(TunnelCaptureFrame(
                sourceWing: "b6p-wing", sourceRoom: "b6p-room",
                targetWing: "b6p-wing", targetRoom: "b6p-room",
                label: "relates", addedBy: "prov-keystones-tests",
                sourceDrawerId: hub.id, targetDrawerId: spokeID, kind: .references))
        }

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_keystones",
            arguments: .object(["wing": .string("b6p-wing")]))
        let response = try await service.execute(request)

        let keystones = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["keystones"]?.arrayValue,
            "keystones array must be present")

        let hubRow = try #require(
            keystones.first(where: {
                $0.objectValue?["id"]?.stringValue == hub.id.lowercased()
            })?.objectValue,
            "provenance-restricted hub must appear in keystones; got: \(keystones)")

        // No dense fields: the provenance gate must block the real body from the wire.
        #expect(hubRow["subject"] == nil,
                "provenance-restricted keystone must not expose 'subject'; got: \(String(describing: hubRow["subject"]))")
        #expect(hubRow["bestSpan"] == nil,
                "provenance-restricted keystone must not expose 'bestSpan'; got: \(String(describing: hubRow["bestSpan"]))")
        #expect(hubRow["eventTime"] == nil,
                "provenance-restricted keystone must not expose 'eventTime'; got: \(String(describing: hubRow["eventTime"]))")
        #expect(hubRow["id"] != nil,
                "provenance-restricted keystone must still carry 'id'")
        #expect(hubRow["centrality"] != nil,
                "provenance-restricted keystone must still carry 'centrality'")

        // Fixture content must never appear anywhere in the serialized response.
        let serialized = String(describing: response)
        #expect(!serialized.contains(hubContent),
                "fixture content must not appear in the wire response; serialized prefix: \(serialized.prefix(500))")
    }

    /// Parity lock: a drawer with provenance sensitivity Restricted and default
    /// adjective sensitivity (Normal) must produce a sparse row in trust_synthesis
    /// rankedIDs — id only, no dense fields.
    ///
    /// A provenance-Restricted drawer with adjective Normal passes the frame
    /// ceiling, is present in drawersByID, and must appear in rankedIDs — its
    /// absence would signal a different regression. The gate is
    /// AriaV2RecallLensPrivacy.classify, which blocks dense fields for any
    /// non-admissible verdict. Rust twin: aria_v2_wire_parity_tests.rs
    /// lens_trust_synthesis_provenance_restricted_row_has_no_dense_fields.
    @Test("trust_synthesis rankedIDs row has no dense fields for provenance-restricted drawer")
    func trustSynthesisProvenanceRestrictedRowHasNoDenseFields() async throws {
        let (kit, handle) = try await openEstate()
        defer { Task { try? await kit.close(handle) } }

        // Restricted drawer: passes adjective ceiling, must not expose body.
        let restrictedContent = "prov-restricted-b7-swift — must not reach wire"
        let restricted = try await kit.capture(handle, CaptureFrame(
            content: restrictedContent,
            channel: .typed, room: "b7p-room",
            latticeAnchor: .udc("004"), addedBy: "prov-trust-tests",
            embeddingModelID: "test-model-v1",
            provenanceSensitivity: .restricted))

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: "moot_lens_trust_synthesis",
            arguments: .object([:]))
        let response = try await service.execute(request)

        let ranked = try #require(
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["rankedIDs"]?.arrayValue,
            "rankedIDs array must be present")

        // The restricted drawer must appear — absence means a different regression.
        let row = try #require(
            ranked.first(where: {
                $0.objectValue?["id"]?.stringValue == restricted.id.lowercased()
            })?.objectValue,
            "provenance-restricted drawer must appear in rankedIDs; got: \(ranked)")

        // No dense fields.
        #expect(row["subject"] == nil,
                "provenance-restricted ranked row must not expose 'subject'; got: \(String(describing: row["subject"]))")
        #expect(row["bestSpan"] == nil,
                "provenance-restricted ranked row must not expose 'bestSpan'; got: \(String(describing: row["bestSpan"]))")
        #expect(row["eventTime"] == nil,
                "provenance-restricted ranked row must not expose 'eventTime'; got: \(String(describing: row["eventTime"]))")
        #expect(row["id"] != nil,
                "provenance-restricted ranked row must still carry 'id'")

        // Fixture content must not appear in the rankedIDs array (the field this
        // fix gates). The assertion guards against an implementation that passes
        // the row field-checks by omitting the row entirely rather than
        // redacting it. The context synthesizer separately processes drawer
        // content and is outside this fix's scope; only rankedIDs is checked.
        let rankedIDsSerialized = String(describing:
            response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue?["rankedIDs"] ?? .null)
        #expect(!rankedIDsSerialized.contains(restrictedContent),
                "fixture content must not appear in the rankedIDs field; rankedIDs: \(rankedIDsSerialized.prefix(500))")
    }
}

// MARK: - Contradiction lens deterministic object order

/// `moot_lens_contradiction` must emit objects inside each conflicting group in
/// filedAt-then-object-text order, not storage-insertion order.
///
/// Five facts share (subject, predicate) and ONE identical filedAt. They are
/// stored in non-sorted order ("ähnlich", "zeta", "gamma", "beta", "alpha") so
/// that the assertion goes red without the secondary-key sort. The expected
/// order is UTF-8 byte order: ["alpha", "beta", "gamma", "zeta", "ähnlich"].
/// "ä" begins 0xC3 in UTF-8 so it sorts after all ASCII letters including "z"
/// (0x7A). An all-ASCII fixture cannot detect the Swift/Rust divergence (Swift
/// `<` vs Rust `String::cmp`) because the two orderings agree on ASCII; the
/// non-ASCII object is load-bearing.
///
/// Routes through `AriaV2LensLowerService` with a real estate so the full
/// execution stack is exercised. The response is the camelCase wire envelope.
@Suite("moot_lens_contradiction — deterministic object order", .serialized)
struct ContradictionLensOrderTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "contradiction-order-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: false)
        return (kit, handle)
    }

    @Test("contradiction_objects_sort_by_utf8_byte_order_within_one_filed_instant")
    func contradictionObjectsSortByUtf8ByteOrderWithinOneFiledInstant() async throws {
        let (kit, handle) = try await openEstate()

        // Pin a single filedAt so all five facts share the same instant.
        // The secondary sort by UTF-8 byte order is what the fix under test adds.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Store in non-sorted order so the assertion goes red if the sort is
        // absent. "ähnlich" has UTF-8 lead byte 0xC3, so it sorts AFTER all
        // ASCII objects including "zeta" (lead byte 0x7A).
        for object in ["ähnlich", "zeta", "gamma", "beta", "alpha"] {
            _ = try await kit.captureKGFact(
                handle,
                subject: "sort-test-subject",
                predicate: "sort-test-pred",
                object: object,
                now: fixedDate)
        }

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group must exist; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        #expect(
            objectStrings == ["alpha", "beta", "gamma", "zeta", "ähnlich"],
            "objects within one filed instant must be sorted by UTF-8 byte order; got: \(objectStrings)")
    }

    @Test("contradiction_objects_tie_within_one_persisted_millisecond")
    func contradictionObjectsTieWithinOnePersistedMillisecond() async throws {
        let (kit, handle) = try await openEstate()

        // Two facts whose filedAt values differ by 0.4ms — below one millisecond.
        // Both land in the same millisecond (1700000000000) under floor or
        // round-to-nearest, so the tie-break decides the order in both ports.
        //
        // Filed so that the LATER sub-millisecond time carries the object that
        // sorts FIRST by UTF-8 byte order ("alpha" < "zeta"). Without millisecond
        // normalisation the Date comparison puts "zeta" first (it was filed 0.4ms
        // earlier). With normalisation they tie at the millisecond and byte-order
        // decides: "alpha" before "zeta".
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)         // "zeta"
        let later   = Date(timeIntervalSince1970: 1_700_000_000.0004)    // "alpha"

        _ = try await kit.captureKGFact(
            handle,
            subject: "ms-tie-subject",
            predicate: "ms-tie-pred",
            object: "zeta",
            now: earlier)
        _ = try await kit.captureKGFact(
            handle,
            subject: "ms-tie-subject",
            predicate: "ms-tie-pred",
            object: "alpha",
            now: later)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group must exist; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        #expect(
            objectStrings == ["alpha", "zeta"],
            "facts within one persisted millisecond must sort by UTF-8 byte order; got: \(objectStrings)")
    }

    /// Measures what ISO8601DateFormatter with .withFractionalSeconds emits for
    /// sub-millisecond residues, including the pre-epoch wrap case. The printed
    /// table is the spec for the new sort key. Assertions pin the observed values;
    /// do not change them unless the formatter behaviour changes.
    ///
    /// Twin: none (measurement-only; no Rust equivalent needed).
    @Test("iso8601_formatter_sub_millisecond_measurement")
    func iso8601FormatterSubMillisecondMeasurement() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // The values to measure. Each is designed to sit near a millisecond boundary
        // so truncation vs. rounding produces different results.
        let cases: [(TimeInterval, String)] = [
            ( 0.0004, "+0.0004"),
            ( 0.0006, "+0.0006"),
            ( 0.0015, "+0.0015"),
            (-0.0004, "-0.0004"),
            (-1.0004, "-1.0004"),
            (-1.0006, "-1.0006"),
        ]
        var results: [(label: String, str: String, ms: Int64)] = []
        for (interval, label) in cases {
            let date = Date(timeIntervalSince1970: interval)
            let str = formatter.string(from: date)
            // Parsing back is guaranteed to lose sub-millisecond residue (the
            // formatter caps at 3 decimal places), so the parsed value has an
            // exact integer millisecond component.
            let parsed = formatter.date(from: str)!
            // Use .rounded() not Int64() to avoid truncation-toward-zero on values
            // like 0.002 s, whose IEEE754 representation is slightly below 2.0 ms
            // (0.002 is not exactly representable in binary float). Int64(1.9999...)
            // = 1, which is wrong; .rounded() gives 2.0 and Int64(2.0) = 2.
            let ms = Int64((parsed.timeIntervalSince1970 * 1000).rounded())
            results.append((label: label, str: str, ms: ms))
            print("ISO8601Measurement [\(label)] \"\(str)\" rounded_ms=\(ms)")
        }
        // Assertions on the OBSERVED values, established by running this test and
        // reading the printed table. Each line is: interval → emitted string → ms.
        //
        // Positive residue rounds toward nearest millisecond (ISO8601DateFormatter
        // uses ICU which rounds half-up). Pre-epoch residues may carry into the
        // next second.
        //
        // +0.0004 → "1970-01-01T00:00:00.000Z" → 0 ms
        #expect(results[0].str == "1970-01-01T00:00:00.000Z", "measured: \(results[0].str)")
        #expect(results[0].ms == 0)
        // +0.0006 → "1970-01-01T00:00:00.001Z" → 1 ms
        #expect(results[1].str == "1970-01-01T00:00:00.001Z", "measured: \(results[1].str)")
        #expect(results[1].ms == 1)
        // +0.0015 → "1970-01-01T00:00:00.002Z" → 2 ms
        // 0.0015 is NOT exactly representable in IEEE754 double. The stored
        // binary value is 0.0015000000000000000312..., which is above 1.5 ms,
        // so the formatter had no half-millisecond tie to break — it simply
        // rounded up to 2 ms. The sort key reaches 2 via a different path:
        // 0.0015 * 1000 evaluates to exactly 1.5 in double arithmetic, and
        // Swift's .rounded() resolves that exact half by rounding away from
        // zero to 2. They agree, but not for the same reason.
        // The formatter's behaviour at an EXACT half-millisecond input is NOT
        // measured by this table and remains unknown — for negative instants
        // especially, where Swift's away-from-zero rule and a half-up rule
        // would disagree.
        #expect(results[2].str == "1970-01-01T00:00:00.002Z", "measured: \(results[2].str)")
        #expect(results[2].ms == 2)
        // -0.0004 → pre-epoch: 1969-12-31T23:59:59.9996 → rounds to 0.000 carry → "...00.000Z"
        // The formatter rounds 0.9996 fractional seconds up to 1.000, carrying into
        // the next second (epoch). The round-trip therefore lands at 0 ms, not -1 ms.
        #expect(results[3].str == "1970-01-01T00:00:00.000Z", "measured: \(results[3].str)")
        #expect(results[3].ms == 0)
        // -1.0004 → pre-epoch: 1969-12-31T23:59:58.9996 → rounds to .000 carry → "...59.000Z"
        // Round-trip lands at -1000 ms, NOT at floor(-1000.4) = -1001. This is the
        // canonical divergence between floor and round-nearest for the persisted key.
        #expect(results[4].str == "1969-12-31T23:59:59.000Z", "measured: \(results[4].str)")
        #expect(results[4].ms == -1000)
        // -1.0006 → pre-epoch: 1969-12-31T23:59:58.9994 → rounds to .999 → "...58.999Z"
        #expect(results[5].str == "1969-12-31T23:59:58.999Z", "measured: \(results[5].str)")
        #expect(results[5].ms == -1001)
    }

    /// Discriminating pre-epoch test for the round-nearest vs. truncate-toward-zero distinction.
    ///
    /// Two facts share (subject, predicate), filed at pre-epoch instants that land
    /// in DIFFERENT persisted milliseconds under round-nearest but in the SAME
    /// millisecond under truncate-toward-zero.
    ///
    ///   Date(timeIntervalSince1970: -1.0006) → -1000.6 ms → round-nearest = -1001
    ///   Date(timeIntervalSince1970: -1.0)    → -1000.0 ms → round-nearest = -1000
    ///
    /// Under round-nearest they land in different milliseconds: -1001 < -1000,
    /// so order is by time, earliest first: "zeta" (at -1001) before "alpha"
    /// (at -1000).
    ///
    /// Under truncate-toward-zero both values become -1000 (truncation of -1000.6
    /// toward zero is -1000), so they tie, and the UTF-8 byte-order tie-break fires:
    /// "alpha" < "zeta", yielding ["alpha", "zeta"] — the wrong answer.
    ///
    /// Measurement (from iso8601_formatter_sub_millisecond_measurement):
    ///   Date(-1.0006) formats as "1969-12-31T23:59:58.999Z" -> -1001 ms
    ///   Date(-1.0)    formats as "1969-12-31T23:59:59.000Z" -> -1000 ms
    ///
    /// Twin: dispatch_tests.rs
    /// contradiction_objects_order_by_persisted_millisecond_before_epoch. The Rust
    /// test files the same facts as raw i64 milliseconds (-1001 and -1000), which
    /// are the persisted form of these Swift Dates under round-nearest.
    @Test("contradiction_objects_order_by_persisted_millisecond_before_epoch")
    func contradictionObjectsOrderByPersistedMillisecondBeforeEpoch() async throws {
        let (kit, handle) = try await openEstate()

        // "zeta" is filed EARLIER at -1.0006 s, which the formatter rounds to -1001 ms.
        // "alpha" is filed LATER at -1.0 s, which rounds to -1000 ms.
        // Under truncate-toward-zero both would land at -1000 and "alpha" would win.
        let earlier = Date(timeIntervalSince1970: -1.0006)   // -> -1001 ms (round-nearest)
        let later   = Date(timeIntervalSince1970: -1.0)      // -> -1000 ms

        _ = try await kit.captureKGFact(
            handle,
            subject: "pre-epoch-round-subject",
            predicate: "pre-epoch-round-pred",
            object: "zeta",
            now: earlier)
        _ = try await kit.captureKGFact(
            handle,
            subject: "pre-epoch-round-subject",
            predicate: "pre-epoch-round-pred",
            object: "alpha",
            now: later)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group must exist; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        // Round-nearest: -1001 < -1000, so time order decides — "zeta" first.
        // Truncate-toward-zero: both -1000, tie-break fires — "alpha" first (wrong).
        #expect(
            objectStrings == ["zeta", "alpha"],
            "pre-epoch facts must sort by persisted millisecond (earliest first); got: \(objectStrings)")
    }

    /// Two facts whose STORED ISO8601 text differs by exactly one millisecond.
    /// The sort must put the earlier fact first regardless of the object string.
    ///
    /// Fixture values chosen so the earlier fact carries the alphabetically LATER
    /// object ("zeta") and the later fact carries the alphabetically EARLIER
    /// object ("alpha"). Without time-order dominance the result would be reversed.
    ///
    /// Expected stored texts are derived by running the same format-and-parse
    /// round trip the production sort key normalises to, so the test does not
    /// hard-code reasoning about the formatter.
    ///
    /// Twin: dispatch_tests.rs
    /// contradiction_objects_order_by_time_when_stored_milliseconds_differ.
    @Test("contradiction_objects_order_by_time_when_stored_milliseconds_differ")
    func contradictionObjectsOrderByTimeWhenStoredMillisecondsDiffer() async throws {
        let (kit, handle) = try await openEstate()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Two instants exactly 1 ms apart. Both are integral-millisecond Dates so
        // the format-and-parse round trip changes nothing — no rounding ambiguity.
        let earlier = Date(timeIntervalSince1970: 1_400_000_000.002)   // "zeta" is filed first
        let later   = Date(timeIntervalSince1970: 1_400_000_000.003)   // "alpha" is filed later

        // Derive expected stored texts from the round trip, not from hand reasoning.
        let earlierStr = formatter.string(from: earlier)
        let laterStr   = formatter.string(from: later)
        let earlierMs  = (formatter.date(from: earlierStr)!.timeIntervalSince1970 * 1000).rounded()
        let laterMs    = (formatter.date(from: laterStr)!.timeIntervalSince1970 * 1000).rounded()
        // Premise: stored texts must differ by exactly 1 ms for the test to discriminate.
        #expect(
            laterMs - earlierMs == 1,
            "test premise: stored texts must differ by 1 ms; got \(earlierStr) and \(laterStr)")

        _ = try await kit.captureKGFact(
            handle,
            subject: "time-order-subject",
            predicate: "time-order-pred",
            object: "zeta",
            now: earlier)
        _ = try await kit.captureKGFact(
            handle,
            subject: "time-order-subject",
            predicate: "time-order-pred",
            object: "alpha",
            now: later)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        // Earlier stored ms must come first; "zeta" precedes "alpha" by time.
        #expect(
            objectStrings == ["zeta", "alpha"],
            "time order must dominate when stored texts differ by 1 ms; got: \(objectStrings)")
    }

    /// Two facts whose STORED ISO8601 text is identical. The filedAt values
    /// round to the same millisecond. The UTF-8 byte-order tie-break must decide.
    ///
    /// Fixture: one fact has a sub-ms residue that rounds DOWN to the same stored
    /// text as the exact-millisecond fact. Object "zeta" gets the exact instant;
    /// object "alpha" gets the sub-ms offset. Both store identically. UTF-8 order
    /// puts "alpha" before "zeta".
    ///
    /// Expected stored texts are derived by running the format-and-parse round trip,
    /// not by hand reasoning, so the test pins observable behaviour not assumed
    /// arithmetic.
    ///
    /// Twin: dispatch_tests.rs
    /// contradiction_objects_tie_break_when_stored_texts_identical.
    @Test("contradiction_objects_tie_break_when_stored_texts_identical")
    func contradictionObjectsTieBreakWhenStoredTextsIdentical() async throws {
        let (kit, handle) = try await openEstate()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // "zeta" — exact millisecond, no residue.
        // "alpha" — 0.4 ms sub-residue that rounds DOWN to the same stored text.
        let exact       = Date(timeIntervalSince1970: 1_400_000_000.002)
        let withResidue = Date(timeIntervalSince1970: 1_400_000_000.0024)

        // Derive stored texts and verify they are identical (the test premise).
        let exactStr   = formatter.string(from: exact)
        let residueStr = formatter.string(from: withResidue)
        #expect(
            exactStr == residueStr,
            "test premise: both dates must produce the same stored text; got \(exactStr) vs \(residueStr)")

        _ = try await kit.captureKGFact(
            handle,
            subject: "tie-break-subject",
            predicate: "tie-break-pred",
            object: "zeta",
            now: exact)
        _ = try await kit.captureKGFact(
            handle,
            subject: "tie-break-subject",
            predicate: "tie-break-pred",
            object: "alpha",
            now: withResidue)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        // Both dates round to the same stored ms; UTF-8 byte order decides.
        // "alpha" (0x61...) < "zeta" (0x7A...) in UTF-8.
        #expect(
            objectStrings == ["alpha", "zeta"],
            "UTF-8 tie-break must decide when stored texts are identical; got: \(objectStrings)")
    }

    /// Discriminates .rounded() (round-nearest) from .rounded(.down) (floor) for
    /// the specific pre-epoch pair that the sort key change in this stream touched.
    ///
    /// Two facts share (subject, predicate).
    ///   "zeta"  filed at Date(timeIntervalSince1970: -1.0004)
    ///   "alpha" filed at Date(timeIntervalSince1970: -1.0)
    ///
    /// "zeta" is filed FIRST so insertion order cannot produce the expected result.
    ///
    /// What each sort key expression gives for these two instants:
    ///   floor  -> floor(-1000.4) = -1001 and floor(-1000.0) = -1000
    ///            different keys, time order decides, ["zeta", "alpha"]  (WRONG)
    ///   round  -> round(-1000.4) = -1000 and round(-1000.0) = -1000
    ///            equal keys, UTF-8 tie-break decides, ["alpha", "zeta"] (RIGHT, and what SQLite stores)
    ///
    /// The premise (both dates persist to the same millisecond) is derived at
    /// runtime via ISO8601DateFormatter round-trip and asserted before facts are
    /// filed. If the premise ever stops holding the test fails loudly at that
    /// assertion rather than silently testing something else.
    ///
    /// Twin: dispatch_tests.rs
    /// contradiction_objects_pre_epoch_sub_millisecond_residue_ties_at_the_persisted_millisecond.
    @Test("contradiction_objects_pre_epoch_sub_millisecond_residue_ties_at_the_persisted_millisecond")
    func contradictionObjectsPreEpochSubMillisecondResidueTiesAtThePersistedMillisecond() async throws {
        let (kit, handle) = try await openEstate()

        // Derive the persisted strings for both dates at runtime so that if the
        // formatter's rounding behaviour ever changes the premise check fires,
        // not a silent wrong-thing test.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateZeta  = Date(timeIntervalSince1970: -1.0004)
        let dateAlpha = Date(timeIntervalSince1970: -1.0)
        let strZeta   = formatter.string(from: dateZeta)
        let strAlpha  = formatter.string(from: dateAlpha)
        // Premise: both dates must persist to the same ISO8601 millisecond string.
        // If this ever fails, the test's discriminating premise no longer holds
        // and the expected result below is wrong.
        #expect(
            strZeta == strAlpha,
            "test premise: -1.0004 s and -1.0 s must produce identical persisted strings; got \(strZeta) vs \(strAlpha)")

        // File "zeta" first so insertion order alone cannot produce the expected
        // ["alpha", "zeta"] result.
        _ = try await kit.captureKGFact(
            handle,
            subject: "pre-epoch-residue-tie-subject",
            predicate: "pre-epoch-residue-tie-pred",
            object: "zeta",
            now: dateZeta)
        _ = try await kit.captureKGFact(
            handle,
            subject: "pre-epoch-residue-tie-subject",
            predicate: "pre-epoch-residue-tie-pred",
            object: "alpha",
            now: dateAlpha)

        let service = AriaV2LensLowerService(
            authority: AriaV2GeniusLocusLensLowerAuthority(kit: kit, handle: handle),
            context: .init(estateID: handle.estateUUID, now: Date()))
        let request = try AriaV2RecallLensRequest(
            tool: AriaV2RecallLensOperation.lensContradiction.rawValue,
            arguments: .object([:]))
        let response = try await service.execute(request)

        let data = response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
        let groups = try #require(
            data?["conflictingFacts"]?.arrayValue,
            "conflictingFacts array must be present in the response")
        #expect(groups.count == 1, "exactly one conflicting group must exist; got: \(groups)")

        let objects = try #require(
            groups.first?.objectValue?["objects"]?.arrayValue,
            "objects array must be present in the first conflicting group")
        let objectStrings = objects.compactMap(\.stringValue)
        // Both dates persist to the same millisecond (-1000 ms). The UTF-8
        // tie-break decides: "alpha" (0x61) < "zeta" (0x7A).
        // Under floor (-1001 and -1000, different keys) time order would give
        // ["zeta", "alpha"] — the wrong answer for the persisted data.
        #expect(
            objectStrings == ["alpha", "zeta"],
            "pre-epoch facts tied at the persisted millisecond must sort by UTF-8 byte order; got: \(objectStrings)")
    }
}
