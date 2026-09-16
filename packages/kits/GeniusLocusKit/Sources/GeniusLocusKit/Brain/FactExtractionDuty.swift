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
    public var chunksProcessed: Int = 0
    public var scannedSources: Int = 0
    public var deferredSources: Int = 0
    public var inapplicableSources: Int = 0
    public var rejectedSources: Int = 0
    public var madeProgress: Bool = false

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
        let recipeID = Self.factWorkflowRecipe(recipeID, spec: extractor.spec)
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

    /// Each invocation pays at most one source-exact chunk per selected memory.
    /// Queue checkpoints make both this compatibility entry and the duty resumable.
    func runFactExtractionBatch(
        _ handle: EstateHandle, limit: Int = 16, now: Date
    ) async throws -> FactExtractionBatchResult {
        guard let work = try await prepareFactExtractionBatch(handle, limit: limit, now: now) else {
            return FactExtractionBatchResult(completedSources: 0, factsFiled: 0,
                candidatesRejected: 0, skippedSources: 0, failedSources: 0)
        }
        return try await work.run()
    }

    static func distilledFactID(
        sourceID: String, recipeID: String, semanticKey: String
    ) -> String {
        var bytes = Array(SHA256.hash(data: Data(
            "distilled-fact-v1|\(sourceID)|\(recipeID)|\(semanticKey)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    static func factSourceDigest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func factSemanticKey(
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

    static func factOperationalBitmap(
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
