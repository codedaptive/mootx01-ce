// PrimitiveRegistry.swift
//
// Registry of primitives the harness knows how to generate
// vectors for and validate. Adding a new primitive means
// registering it here.
//
// Each primitive supplies two closures:
//
//   generate(seed:) -> VectorFile
//     Reads cookbook section, runs the scalar reference on
//     deterministically-generated inputs, returns a VectorFile
//     with cases + CRC populated.
//
//   validate(file:) -> ValidationResult
//     Iterates the file's cases, runs the scalar reference on
//     each input, compares to expected_output. Re-computes CRC.
//     Returns PASS or FAIL with structured diagnostics.

import Foundation

public struct PrimitiveDescriptor: Sendable {
    public let name: String
    public let cookbookSection: String
    public let referenceFile: String
    public let generate: @Sendable (UInt64) throws -> VectorFile
    public let validate: @Sendable (VectorFile) throws -> ValidationResult

    public init(name: String,
                cookbookSection: String,
                referenceFile: String,
                generate: @escaping @Sendable (UInt64) throws -> VectorFile,
                validate: @escaping @Sendable (VectorFile) throws -> ValidationResult) {
        self.name = name
        self.cookbookSection = cookbookSection
        self.referenceFile = referenceFile
        self.generate = generate
        self.validate = validate
    }
}

public struct ValidationResult {
    public var passed: Bool
    public var caseResults: [CaseResult]
    public var crcExpected: UInt32
    public var crcActual: UInt32

    public init(passed: Bool, caseResults: [CaseResult],
                crcExpected: UInt32, crcActual: UInt32) {
        self.passed = passed
        self.caseResults = caseResults
        self.crcExpected = crcExpected
        self.crcActual = crcActual
    }

    public struct CaseResult {
        public let id: String
        public let passed: Bool
        public let diagnostic: String?

        public init(id: String, passed: Bool, diagnostic: String?) {
            self.id = id
            self.passed = passed
            self.diagnostic = diagnostic
        }
    }
}

public enum PrimitiveRegistry {

    /// All primitives the harness knows about. Looked up by name
    /// on the command line.
    public static let all: [PrimitiveDescriptor] = [
        SimHashPrimitive.descriptor,
        AnomalyPrimitive.descriptor,
        HammingPrimitive.descriptor,
        ORReducePrimitive.descriptor,
        BitwisePrimitive.descriptor,
        HLCPrimitive.descriptor,
        FingerprintPrimitive.descriptor,
        LatticePrimitive.descriptor,
        InfoTheoryPrimitive.descriptor,
        BradleyTerryPrimitive.descriptor,
        PartialStateRecallPrimitive.descriptor,
        TemporalCompressionPrimitive.descriptor,
        TierContributionPrimitive.descriptor,
        FFTPrimitive.descriptor,
        HammingNNPrimitive.descriptor,
        PairingHandshakePrimitive.descriptor,
        NMFPrimitive.descriptor,
        AuditLogFoldPrimitive.descriptor,
        MatrixDecayPrimitive.descriptor,
        EigenvalueCentralityPrimitive.descriptor,
        MomentSummaryPrimitive.descriptor,
        FieldPresenceMatrixFPrimitive.descriptor,
        FNVPrimitive.descriptor,
        BitFieldMaskedEqualsPrimitive.descriptor,
        AssociationRuleMiningPrimitive.descriptor,
        FormalConceptAnalysisPrimitive.descriptor,
        SamplingPrimitive.descriptor,
        ShingleSimilarityPrimitive.descriptor,
    ]

    public static func find(_ name: String) -> PrimitiveDescriptor? {
        return all.first { $0.name == name }
    }
}
