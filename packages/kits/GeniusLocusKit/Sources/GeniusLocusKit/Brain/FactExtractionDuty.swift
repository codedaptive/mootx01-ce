import CryptoKit
import FactExtractionKit
import Foundation
import LocusKit
import SubstrateKernel

/// Outcome of one bounded source-grounded fact duty invocation.
public struct FactExtractionBatchResult: Sendable, Equatable {
    public let completedSources: Int
    public let factsFiled: Int
    public let candidatesRejected: Int
    public let skippedSources: Int
    public let failedSources: Int

    public init(
        completedSources: Int, factsFiled: Int, candidatesRejected: Int,
        skippedSources: Int, failedSources: Int
    ) {
        self.completedSources = completedSources
        self.factsFiled = factsFiled
        self.candidatesRejected = candidatesRejected
        self.skippedSources = skippedSources
        self.failedSources = failedSources
    }
}

public extension GeniusLocusKit {
    /// The single activation point for a fact-extractor recipe. Re-registering
    /// the unchanged active recipe attaches the runtime without creating new
    /// debt; changing the active recipe clears bit 28 estate-wide.
    @discardableResult
    func activateFactExtractor(
        _ extractor: any FactExtractor,
        recipeID: String,
        for handle: EstateHandle
    ) async throws -> Int {
        guard !recipeID.isEmpty else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "fact extractor recipeID must not be empty")
        }
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        let registry = FactExtractorModelStore(storage: storage)
        let desired = FactExtractorModelRow(recipeID: recipeID, spec: extractor.spec)
        if let active = try await registry.active(), active == FactExtractorModelRow(
            recipeID: desired.recipeID, providerID: desired.providerID,
            modelID: desired.modelID, modelVersion: desired.modelVersion,
            schemaVersion: desired.schemaVersion, extractorKind: desired.extractorKind,
            maximumInputCharacters: desired.maximumInputCharacters,
            maximumFactsPerSource: desired.maximumFactsPerSource, isActive: true
        ) {
            factExtractors[handle] = extractor
            factExtractorRecipeIDs[handle] = recipeID
            return 0
        }
        try await registry.upsert(desired)
        let cleared = try await registry.activate(recipeID: recipeID)
        factExtractors[handle] = extractor
        factExtractorRecipeIDs[handle] = recipeID
        return cleared
    }

    /// Detach the runtime without changing the registry or its debt bits.
    func unregisterFactExtractor(for handle: EstateHandle) {
        factExtractors[handle] = nil
        factExtractorRecipeIDs[handle] = nil
    }

    func registeredFactExtractor(for handle: EstateHandle) -> (any FactExtractor)? {
        factExtractors[handle]
    }

    /// Run a bounded extraction batch. Models see only source-exact chunks of
    /// the original drawer body, and grounding resolves evidence against that
    /// same unchanged body.
    func runFactExtractionBatch(
        _ handle: EstateHandle,
        limit: Int = 16,
        now: Date
    ) async throws -> FactExtractionBatchResult {
        guard limit > 0 else {
            return FactExtractionBatchResult(
                completedSources: 0, factsFiled: 0, candidatesRejected: 0,
                skippedSources: 0, failedSources: 0)
        }
        guard let extractor = factExtractors[handle],
              let recipeID = factExtractorRecipeIDs[handle] else {
            return FactExtractionBatchResult(
                completedSources: 0, factsFiled: 0, candidatesRejected: 0,
                skippedSources: 0, failedSources: 0)
        }
        let estate = try estate(for: handle)
        let pending = try await estate.factExtractionDebtBatch(limit: limit)
        var completed = 0
        var filed = 0
        var rejected = 0
        var skipped = 0
        var failed = 0

        for drawer in pending {
            let source = drawer.content
            guard !source.isEmpty, drawer.tombstonedAt == nil else {
                skipped += 1
                continue
            }
            do {
                let sourceDigest = Self.factSourceDigest(source)
                let chunks = FactSourceChunker.chunks(
                    originalSource: source,
                    maximumCharacters: extractor.spec.maximumInputCharacters)
                var groundedCandidates: [GroundedFactCandidate] = []
                var sourceRejected = 0
                for chunk in chunks {
                    let request = FactExtractionRequest(
                        sourceID: drawer.id,
                        sourceDigest: sourceDigest,
                        sourceText: chunk.text,
                        eligibleSourceSpans: [chunk.span],
                        maximumFacts: extractor.spec.maximumFactsPerSource)
                    let response = try await extractor.extract(request)
                    let grounding = FactGroundingValidator.validate(
                        response: response, request: request, originalSource: source,
                        expectedSpec: extractor.spec)
                    sourceRejected += grounding.rejected.count

                    // A genuinely empty response is a valid zero-fact result.
                    // A non-empty response whose every candidate failed
                    // grounding is provider failure and remains debt.
                    guard response.candidates.isEmpty || !grounding.accepted.isEmpty else {
                        rejected += sourceRejected
                        throw FactExtractionError.malformedResponse(
                            "all non-empty model candidates failed grounding")
                    }
                    groundedCandidates.append(contentsOf: grounding.accepted)
                }
                rejected += sourceRejected
                var seenCandidates = Set<String>()
                groundedCandidates = groundedCandidates.filter { candidate in
                    seenCandidates.insert([
                        candidate.subject, candidate.predicate, candidate.object,
                        candidate.evidenceQuote,
                        String(candidate.evidenceSpan.start), String(candidate.evidenceSpan.end),
                    ].joined(separator: "\u{0}")).inserted
                }
                if groundedCandidates.count > extractor.spec.maximumFactsPerSource {
                    groundedCandidates = Array(
                        groundedCandidates.prefix(extractor.spec.maximumFactsPerSource))
                }
                guard try await estate.getDrawers(ids: [drawer.id]).first?.content == source else {
                    skipped += 1
                    continue
                }

                let history = try await estate.allKGFactsIncludingRetired()
                    .filter { $0.sourceDrawerID == drawer.id }
                let active = try await estate.kgFacts(sourceDrawerIDEq: drawer.id)
                var desiredIDs = Set<String>()
                var newlyFiled: [String] = []

                for candidate in groundedCandidates {
                    let key = Self.factSemanticKey(
                        candidate, digest: sourceDigest, spec: extractor.spec)
                    if let existing = active.first(where: {
                        Self.factSemanticKey($0) == key
                    }) {
                        desiredIDs.insert(existing.id)
                        continue
                    }
                    let baseID = Self.distilledFactID(
                        sourceID: drawer.id, recipeID: recipeID, semanticKey: key)
                    var id = baseID
                    if history.contains(where: { $0.id == id }) {
                        let reactivationOrdinal = history.filter {
                            Self.factSemanticKey($0) == key
                        }.count
                        id = Self.distilledFactID(
                            sourceID: drawer.id, recipeID: recipeID,
                            semanticKey: "\(key)|reactivated|\(reactivationOrdinal)")
                    }
                    let extraction = KGFactExtractionMetadata(
                        evidenceQuote: candidate.evidenceQuote,
                        evidenceStart: candidate.evidenceSpan.start,
                        evidenceEnd: candidate.evidenceSpan.end,
                        evidenceStartUTF8Byte: candidate.evidenceSpan.startUTF8Byte,
                        evidenceEndUTF8Byte: candidate.evidenceSpan.endUTF8Byte,
                        sourceDigest: sourceDigest,
                        extractorProviderID: extractor.spec.providerID,
                        extractorModelID: extractor.spec.modelID,
                        extractorModelVersion: extractor.spec.modelVersion,
                        extractionSchemaVersion: extractor.spec.schemaVersion,
                        searchProjection: candidate.searchProjection,
                        searchProjectionVersion: FactSearchProjection.version,
                        operationalBitmap: Self.factOperationalBitmap(
                            kind: extractor.spec.extractorKind,
                            assertion: candidate.assertionKind,
                            confidence: candidate.confidence))
                    _ = try await captureKGFact(
                        handle, id: id, subject: candidate.subject,
                        predicate: candidate.predicate, object: candidate.object,
                        sourceDrawerID: drawer.id, addedBy: "distilled-fact-duty",
                        extraction: extraction, now: now)
                    desiredIDs.insert(id)
                    newlyFiled.append(id)
                    filed += 1
                }

                // Retire only machine-extracted facts. Manual/imported facts
                // anchored to the same source remain independent assertions.
                for old in active where
                    !old.extractionSchemaVersion.isEmpty && !desiredIDs.contains(old.id) {
                    try await retireKGFact(handle, rowID: old.id, changedBy: "fact-extraction-duty", reason: nil, now: now)
                }

                let settled = try await estate.setFactsExtracted(
                    drawerId: drawer.id, ifContentMatches: source)
                guard settled == 1 else {
                    // The source changed in the last race window. Do not leave
                    // assertions from the stale snapshot active.
                    for id in newlyFiled { try? await retireKGFact(handle, rowID: id, changedBy: "fact-extraction-duty", reason: nil, now: now) }
                    skipped += 1
                    continue
                }
                completed += 1
            } catch {
                // Fail-open for the product path: the debt bit remains clear
                // and the next standing cycle may retry.
                failed += 1
            }
        }
        return FactExtractionBatchResult(
            completedSources: completed, factsFiled: filed,
            candidatesRejected: rejected, skippedSources: skipped,
            failedSources: failed)
    }

    static func distilledFactID(
        sourceID: String, recipeID: String, semanticKey: String
    ) -> String {
        SHA256.hash(data: Data(
            "distilled-fact-v1|\(sourceID)|\(recipeID)|\(semanticKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func factSourceDigest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func factSemanticKey(
        _ candidate: GroundedFactCandidate,
        digest: String,
        spec: FactExtractorModelSpec
    ) -> String {
        [
            digest, spec.providerID, spec.modelID, spec.modelVersion,
            spec.schemaVersion, candidate.subject, candidate.predicate,
            candidate.object, candidate.evidenceQuote,
            String(candidate.evidenceSpan.start), String(candidate.evidenceSpan.end),
        ].joined(separator: "\u{0}")
    }

    private static func factSemanticKey(_ fact: KGFact) -> String {
        [
            fact.sourceDigest, fact.extractorProviderID, fact.extractorModelID,
            fact.extractorModelVersion, fact.extractionSchemaVersion,
            fact.subject, fact.predicate, fact.object, fact.evidenceQuote,
            String(fact.evidenceStart), String(fact.evidenceEnd),
        ].joined(separator: "\u{0}")
    }

    private static func factOperationalBitmap(
        kind: FactExtractorKind,
        assertion: FactAssertionKind,
        confidence: Double
    ) -> Int64 {
        let extractor: KGExtractorClass =
            kind == .foundationModel ? .foundationModel : .specializedModel
        let assertionKind: KGAssertionKind
        switch assertion {
        case .asserted: assertionKind = .asserted
        case .inferred: assertionKind = .inferred
        case .hypothesized: assertionKind = .hypothesized
        }
        let band: KGConfidenceBand
        switch confidence {
        case 0.95...: band = .certain
        case 0.80...: band = .high
        case 0.60...: band = .medium
        default: band = .low
        }
        var bitmap: Int64 = 0
        bitmap = BitField.writeField(
            Int64(extractor.rawValue), into: bitmap, shift: 0, width: 4)
        bitmap = BitField.writeField(
            Int64(assertionKind.rawValue), into: bitmap, shift: 4, width: 3)
        bitmap = BitField.writeField(
            Int64(band.rawValue), into: bitmap, shift: 10, width: 3)
        return bitmap
    }
}

private extension FactExtractorModelRow {
    init(recipeID: String, spec: FactExtractorModelSpec) {
        self.init(
            recipeID: recipeID, providerID: spec.providerID,
            modelID: spec.modelID, modelVersion: spec.modelVersion,
            schemaVersion: spec.schemaVersion, extractorKind: spec.extractorKind.rawValue,
            maximumInputCharacters: spec.maximumInputCharacters,
            maximumFactsPerSource: spec.maximumFactsPerSource)
    }
}
