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
