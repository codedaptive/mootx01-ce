import Foundation
import Testing
@testable import AriaMCP
import AriaMCPWire
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SynapseKit
import SubstrateTypes

@Suite("ARIA v2 contradiction reference custody")
struct AriaV2ContradictionsTests {
    private let estateID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    @Test("V2 hunt finds an older contradiction beyond fifty recent probes")
    func huntIncludesOlderEvidence() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "v2-probe-test")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let vectorStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vectorStorage.open(schema: VectorStore.schemaDeclaration)
        let vectors = VectorStore(storage: vectorStorage)
        await kit.registerVectorStore(vectors, for: handle)
        let near = Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
        let far = Fingerprint256(block0: .max, block1: .max, block2: .max, block3: .max)
        var claimIDs = Set<String>()
        for index in 0..<53 {
            let content = index == 0 ? "North warehouse opening time is 08:00."
                : index == 1 ? "North warehouse opening time is 09:00."
                : "Unrelated archive shelf inventory."
            let frame = CaptureFrame(content: content, channel: .typed, room: "Qualification",
                latticeAnchor: LatticeAnchor(udcCode: "004"), addedBy: "test", embeddingModelID: "minilm-v6")
            let drawer = try await kit.capture(handle, frame)
            try await vectors.addVector(itemID: drawer.id, engram: index < 2 ? near : far,
                modelID: "minilm-v6", modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            if index < 2 { claimIDs.insert(drawer.id.lowercased()) }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let legacy = try await kit.tieredContradictionSearch(in: handle, topK: 50, probeLimit: 50, now: now)
        #expect(legacy.tier1.isEmpty && legacy.tier2.isEmpty && legacy.tier3.isEmpty)
        let result = try await AriaV2Contradictions.hunt(
            request: .init(arguments: .object(["limit": .integer(1)])),
            context: .init(estateID: handle.estateUUID, callerBinding: "test", authorizationRevision: "test"),
            kit: kit, handle: handle, references: AriaV2ContradictionReferences(), now: now)
        guard case .result(let hunt) = result else { Issue.record("hunt refused old evidence"); return }
        #expect(hunt.candidates.count == 1)
        let candidate = try #require(hunt.candidates.first)
        #expect(Set([candidate.sourceMemoryID.lowercased(), candidate.targetMemoryID.lowercased()]) == claimIDs)
    }

    @Test("Proposal decoder requires opaque reference and unique selected candidates")
    func strictProposalDecoder() throws {
        let request = try AriaV2Contradictions.ProposeRequest(arguments: .object([
            "analysis_ref": .string("analysis_opaque"),
            "candidate_ids": .array([.string("candidate_one")]),
        ]))
        #expect(request.candidateIDs == ["candidate_one"])

        for arguments in [
            JSONValue.object(["candidate_ids": .array([.string("candidate_one")])]),
            .object(["analysis_ref": .string("analysis"), "candidate_ids": .array([])]),
            .object(["analysis_ref": .string("analysis"), "candidate_ids": .array([.string("x"), .string("x")])]),
            .object(["analysis_ref": .string("analysis"), "candidate_ids": .array([.string("x")]), "extra": .bool(true)]),
        ] {
            do {
                _ = try AriaV2Contradictions.ProposeRequest(arguments: arguments)
                Issue.record("contradiction proposal accepted invalid arguments")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams)
            }
        }
    }

    @Test("Reference selection binds caller estate revision and candidate IDs")
    func boundedSelection() async throws {
        let references = AriaV2ContradictionReferences()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = AriaV2Contradictions.AnalysisContext(
            estateID: estateID, callerBinding: "caller-a", authorizationRevision: "revision-a"
        )
        let retained = await references.retain(context: context, candidates: [candidate("a")], now: now)
        guard case .result(let hunt) = retained else {
            Issue.record("bounded analysis was not retained")
            return
        }
        let request = try AriaV2Contradictions.ProposeRequest(arguments: .object([
            "analysis_ref": .string(hunt.analysisReference),
            "candidate_ids": .array([.string(hunt.candidates[0].candidateID)]),
            "estate_id": .string(estateID.uuidString.lowercased()),
        ]))
        let resolved = await references.resolve(request: request, context: context, now: now)
        guard case .selected(let selection) = resolved else {
            Issue.record("valid selected reference was refused")
            return
        }
        #expect(selection.candidates.count == 1)

        let stale = AriaV2Contradictions.AnalysisContext(
            estateID: estateID, callerBinding: "caller-a", authorizationRevision: "revision-b"
        )
        let staleResolution = await references.resolve(request: request, context: stale, now: now)
        guard case .refusal(let refusal) = staleResolution else {
            Issue.record("stale revision was accepted")
            return
        }
        #expect(refusal.code == "proposal_stale")
    }

    @Test("References expire absolutely and candidates never exceed the hard bound")
    func expiryAndCandidateBounds() async throws {
        let references = AriaV2ContradictionReferences()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = AriaV2Contradictions.AnalysisContext(
            estateID: estateID, callerBinding: "caller-a", authorizationRevision: "revision-a"
        )
        let retained = await references.retain(context: context, candidates: [candidate("a")], now: now)
        guard case .result(let hunt) = retained else {
            Issue.record("bounded analysis was not retained")
            return
        }
        let request = try AriaV2Contradictions.ProposeRequest(arguments: .object([
            "analysis_ref": .string(hunt.analysisReference),
            "candidate_ids": .array([.string(hunt.candidates[0].candidateID)]),
        ]))
        let expired = await references.resolve(
            request: request,
            context: context,
            now: now.addingTimeInterval(AriaV2Contradictions.analysisLifetime)
        )
        guard case .refusal(let refusal) = expired else {
            Issue.record("expired reference was accepted")
            return
        }
        #expect(refusal.code == "proposal_expired")

        let tooMany = Array(repeating: candidate("b"), count: AriaV2Contradictions.maximumCandidates + 1)
        let rejected = await references.retain(context: context, candidates: tooMany, now: now)
        guard case .refusal(let limit) = rejected else {
            Issue.record("oversized analysis was retained")
            return
        }
        #expect(limit.code == "analysis_too_large")
    }

    @Test("Proposal entries retain selected candidate mapping and existing tunnel identity")
    func existingProposalResult() {
        let tunnelID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let tunnel = Tunnel(
            id: tunnelID,
            sourceWing: "Wing", sourceRoom: "Room", sourceDrawerId: "source",
            targetWing: "Wing", targetRoom: "Room", targetDrawerId: "target",
            label: "dcp: rule@1 evidence=evidence", kind: .contradicts,
            addedBy: "test", filedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = AriaV2ContradictionsService.tunnelResult(
            candidateID: "candidate_selected", status: "existing", tunnel: tunnel
        ).objectValue
        #expect(result?["candidate_id"] == .string("candidate_selected"))
        #expect(result?["status"] == .string("existing"))
        #expect(result?["tunnel_id"] == .string(tunnelID.lowercased()))
        #expect(result?["lifecycle"] == .string("active"))
    }

    @Test("Hunt candidates expose bounded paired evidence without changing opaque selection")
    func inspectableCandidate() {
        let sourceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let targetID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let result = AriaV2ContradictionsService.publicCandidate(
            candidate: candidate("inspect", candidateID: "candidate_opaque"),
            sourceID: sourceID,
            sourceExcerpt: String(repeating: "é", count: 513),
            targetID: targetID,
            targetExcerpt: "The launch window is Tuesday."
        ).objectValue

        #expect(result?["candidate_id"] == .string("candidate_opaque"))
        #expect(result?["reason"] == .string("dcp: rule@1"))
        let source = result?["source"]?.objectValue
        #expect(source?["memory_id"] == .string(sourceID))
        if case .string(let excerpt) = source?["excerpt"] {
            #expect(excerpt.unicodeScalars.count == 512)
        } else {
            Issue.record("source excerpt missing")
        }
        #expect(source?["fetch"]?.objectValue?["tool"] == .string("moot_memory_get"))
        #expect(source?["fetch"]?.objectValue?["arguments"]?.objectValue?["memory_id"] == .string(sourceID))
        #expect(result?["target"]?.objectValue?["memory_id"] == .string(targetID))
    }

    @Test("Hunt evidence fails closed for unknown or restricted provenance sensitivity")
    func candidateEvidenceProvenanceGuard() {
        #expect(AriaV2ContradictionsService.candidateEvidenceAllowsProvenance(0))
        #expect(AriaV2ContradictionsService.candidateEvidenceAllowsProvenance(16))
        #expect(!AriaV2ContradictionsService.candidateEvidenceAllowsProvenance(32))
        #expect(!AriaV2ContradictionsService.candidateEvidenceAllowsProvenance(48))
        #expect(!AriaV2ContradictionsService.candidateEvidenceAllowsProvenance(63))
    }

    private func candidate(_ suffix: String, candidateID: String = "") -> AriaV2Contradictions.Candidate {
        let proposal = SelectedConflictProposal(
            sourceDrawerID: "source-\(suffix)", targetDrawerID: "target-\(suffix)",
            pairKey: "pair-\(suffix)", tier: 1, renewalKey: "dcp: rule@1",
            evidenceID: "evidence", sourceDigest: "source", targetDigest: "target",
            evidenceDigest: "evidence", label: "dcp: rule@1 evidence=evidence")
        return .init(candidateID: candidateID, tier: 1, pairKey: "pair-\(suffix)",
                     sourceMemoryID: "source-\(suffix)", targetMemoryID: "target-\(suffix)",
                     ruleOrCue: "rule", evidenceID: "evidence", proposal: proposal)
    }
}
