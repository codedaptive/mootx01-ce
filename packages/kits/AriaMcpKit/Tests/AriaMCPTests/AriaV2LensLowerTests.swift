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
