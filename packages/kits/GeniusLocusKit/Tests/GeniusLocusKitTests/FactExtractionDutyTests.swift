import FactExtractionKit
import FactExtractionKitProviders
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import GeniusLocusKit

@Suite("Source-grounded fact extraction duty", .serialized)
struct FactExtractionDutyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func openEstate(
        owner: String
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let credentials = OwnerCredentials(ownerIdentifier: owner)
        _ = try await LocusKit.Estate.create(storage: storage, owner: credentials)
        let handle = try await kit.open(
            storage: storage, owner: credentials,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    private func spec(_ kind: FactExtractorKind = .specializedModel) -> FactExtractorModelSpec {
        FactExtractorModelSpec(
            providerID: "test-provider", modelID: "nuextract-test",
            modelVersion: "q8", schemaVersion: "kgfact-extraction-v1",
            extractorKind: kind, maximumInputCharacters: 16_384,
            maximumFactsPerSource: 8)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, content: String
    ) async throws -> Drawer {
        try await kit.capture(handle, CaptureFrame(
            content: content, channel: .typed, room: "facts",
            latticeAnchor: LatticeAnchor(udcCode: "000"), addedBy: "test",
            embeddingModelID: "test-v1", eventTime: now))
    }

    @Test("files a grounded KGFact with provenance and settles debt")
    func filesGroundedFact() async throws {
        let (kit, handle) = try await openEstate(owner: "fact-grounded")
        let source = "Jack's birthday is June 20th."
        let drawer = try await capture(kit, handle, content: source)
        let model = spec()
        let extractor = ClosureFactExtractor(spec: model) { request in
            #expect(request.sourceText.contains("Jack"))
            #expect(!request.eligibleSourceSpans.isEmpty)
            return FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: model.providerID, modelID: model.modelID,
                modelVersion: model.modelVersion, schemaVersion: model.schemaVersion,
                candidates: [FactCandidate(
                    subject: "Jack", predicate: "birthday", object: "June 20th",
                    evidenceQuote: source, confidence: 0.97,
                    searchAliases: ["Jack birthday", "when is Jack's birthday"])])
        }
        _ = try await kit.activateFactExtractor(
            extractor, recipeID: "nuextract-b1-q8-v1", for: handle)
        let report = try await kit.runFactExtractionBatch(handle, now: now)
        #expect(report == FactExtractionBatchResult(
            completedSources: 1, factsFiled: 1, candidatesRejected: 0,
            skippedSources: 0, failedSources: 0))

        let estate = try await kit.estate(for: handle)
        let fact = try #require(try await estate.allKGFacts().first)
        #expect(UUID(uuidString: fact.id) != nil)
        #expect(fact.sourceDrawerID == drawer.id)
        #expect(fact.evidenceQuote == source)
        #expect(fact.evidenceStart == 0 && fact.evidenceEnd == source.unicodeScalars.count)
        #expect(fact.sourceDigest.count == 64)
        #expect(fact.extractorModelID == model.modelID)
        #expect(fact.searchProjection.contains("when is Jack's birthday"))
        #expect(fact.searchProjectionVersion == FactSearchProjection.version)
        #expect(fact.extractorClass == .specializedModel)
        #expect(fact.confidenceBand == .certain)
        #expect(try await estate.getDrawers(ids: [drawer.id]).first?.areFactsExtracted == true)

        let replay = try await kit.runFactExtractionBatch(handle, now: now)
        #expect(replay.completedSources == 0 && replay.factsFiled == 0)
    }

    @Test("empty model result is settled, wholly ungrounded output stays debt")
    func zeroAndUngroundedOutcomes() async throws {
        let (zeroKit, zeroHandle) = try await openEstate(owner: "fact-zero")
        let zeroDrawer = try await capture(zeroKit, zeroHandle, content: "A friendly hello.")
        let model = spec(.foundationModel)
        let empty = ClosureFactExtractor(spec: model) { request in
            FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: model.providerID, modelID: model.modelID,
                modelVersion: model.modelVersion, schemaVersion: model.schemaVersion,
                candidates: [])
        }
        _ = try await zeroKit.activateFactExtractor(
            empty, recipeID: "apple-system-v1", for: zeroHandle)
        let zero = try await zeroKit.runFactExtractionBatch(zeroHandle, now: now)
        #expect(zero.completedSources == 1 && zero.factsFiled == 0)
        let zeroEstate = try await zeroKit.estate(for: zeroHandle)
        #expect(try await zeroEstate.getDrawers(ids: [zeroDrawer.id]).first?.areFactsExtracted == true)
        #expect(try await zeroEstate.allKGFacts().isEmpty)

        let (badKit, badHandle) = try await openEstate(owner: "fact-bad")
        let badDrawer = try await capture(
            badKit, badHandle, content: "Jack's birthday is June 20th.")
        let bad = ClosureFactExtractor(spec: model) { request in
            FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: model.providerID, modelID: model.modelID,
                modelVersion: model.modelVersion, schemaVersion: model.schemaVersion,
                candidates: [FactCandidate(
                    subject: "Jack", predicate: "birthday", object: "July 4th",
                    evidenceQuote: "Jack's birthday is July 4th.", confidence: 0.99)])
        }
        _ = try await badKit.activateFactExtractor(
            bad, recipeID: "apple-system-v1", for: badHandle)
        let rejected = try await badKit.runFactExtractionBatch(badHandle, now: now)
        #expect(rejected.failedSources == 1 && rejected.candidatesRejected == 1)
        let badEstate = try await badKit.estate(for: badHandle)
        #expect(try await badEstate.getDrawers(ids: [badDrawer.id]).first?.areFactsExtracted == false)
        #expect(try await badEstate.allKGFacts().isEmpty)
    }

    @Test("recipe replacement retires prior machine facts but preserves manual facts")
    func recipeReplacementPreservesManualFacts() async throws {
        let (kit, handle) = try await openEstate(owner: "fact-recipe-replacement")
        let source = "Jack's birthday is June 20th."
        let drawer = try await capture(kit, handle, content: source)
        let firstModel = spec()
        let first = ClosureFactExtractor(spec: firstModel) { request in
            FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: firstModel.providerID, modelID: firstModel.modelID,
                modelVersion: firstModel.modelVersion,
                schemaVersion: firstModel.schemaVersion,
                candidates: [FactCandidate(
                    subject: "Jack", predicate: "birthday", object: "June 20th",
                    evidenceQuote: source, confidence: 0.97)])
        }
        _ = try await kit.activateFactExtractor(
            first, recipeID: "nuextract-b1-q8-v1", for: handle)
        _ = try await kit.runFactExtractionBatch(handle, now: now)
        let estate = try await kit.estate(for: handle)
        let oldMachineID = try #require(try await estate.allKGFacts().first).id

        let manual = try await kit.captureKGFact(
            handle, id: "manual-jack-birthday-note", subject: "Jack",
            predicate: "birthday-note", object: "confirmed by Bob",
            sourceDrawerID: drawer.id, addedBy: "human", now: now)

        let replacementModel = FactExtractorModelSpec(
            providerID: "test-provider", modelID: "nuextract-replacement",
            modelVersion: "q8", schemaVersion: "kgfact-extraction-v2",
            extractorKind: .specializedModel, maximumInputCharacters: 16_384,
            maximumFactsPerSource: 8)
        let replacement = ClosureFactExtractor(spec: replacementModel) { request in
            FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: replacementModel.providerID,
                modelID: replacementModel.modelID,
                modelVersion: replacementModel.modelVersion,
                schemaVersion: replacementModel.schemaVersion,
                candidates: [FactCandidate(
                    subject: "Jack", predicate: "birthday", object: "June 20th",
                    evidenceQuote: source, confidence: 0.97)])
        }
        #expect(try await kit.activateFactExtractor(
            replacement, recipeID: "nuextract-replacement-v2", for: handle) == 1)
        let report = try await kit.runFactExtractionBatch(handle, now: now)
        #expect(report.completedSources == 1 && report.factsFiled == 1)

        let active = try await estate.allKGFacts()
        #expect(active.contains(where: { $0.id == manual.id }))
        #expect(!active.contains(where: { $0.id == oldMachineID }))
        #expect(active.contains(where: {
            $0.extractorModelID == replacementModel.modelID
        }))
        let history = try await estate.allKGFactsIncludingRetired()
        #expect(history.count == 3)
        #expect(history.contains(where: { $0.id == oldMachineID }))
    }

    @Test("source-exact chunking reaches a fact beyond the first model window")
    func extractsTailFactFromOriginalBody() async throws {
        let (kit, handle) = try await openEstate(owner: "fact-original-body")
        let factText = "Jack's birthday is June 20th."
        let source = String(repeating: "Background material. ", count: 40) + factText
        let drawer = try await capture(kit, handle, content: source)
        let model = FactExtractorModelSpec(
            providerID: "test-provider", modelID: "nuextract-test",
            modelVersion: "q8", schemaVersion: "kgfact-extraction-v1",
            extractorKind: .specializedModel, maximumInputCharacters: 700,
            maximumFactsPerSource: 8)
        let extractor = ClosureFactExtractor(spec: model) { request in
            let candidates = request.sourceText.contains(factText) ? [FactCandidate(
                subject: "Jack", predicate: "birthday", object: "June 20th",
                evidenceQuote: factText, confidence: 0.97)] : []
            return FactExtractionResponse(
                sourceDigest: request.sourceDigest,
                providerID: model.providerID, modelID: model.modelID,
                modelVersion: model.modelVersion, schemaVersion: model.schemaVersion,
                candidates: candidates)
        }
        _ = try await kit.activateFactExtractor(
            extractor, recipeID: "nuextract-original-body-v1", for: handle)

        let report = try await kit.runFactExtractionBatch(handle, now: now)
        #expect(report.completedSources == 1)
        #expect(report.factsFiled == 1)
        let fact = try #require(try await kit.estate(for: handle).allKGFacts().first)
        #expect(fact.sourceDrawerID == drawer.id)
        #expect(fact.evidenceQuote == factText)
    }
}
