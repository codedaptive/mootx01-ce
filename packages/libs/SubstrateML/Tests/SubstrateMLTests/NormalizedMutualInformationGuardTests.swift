// NormalizedMutualInformationGuardTests.swift
//
// Guards for normalizedMutualInformation on empty and ragged input.
// Empty and ragged inputs return sentinel 0 — matching the contract
// of mutualInformation, which also returns 0 on these inputs.

import Testing
@testable import SubstrateML

@Suite("normalizedMutualInformation guards")
struct NormalizedMutualInformationGuardTests {

    private let tol: Float32 = 1e-5

    // MARK: - Guard cases: empty and ragged return sentinel 0

    @Test("empty joint returns 0 without crashing")
    func emptyJointReturnsSentinel() {
        let result = InformationTheory.normalizedMutualInformation(joint: [])
        #expect(result == 0)
    }

    @Test("ragged joint (unequal row lengths) returns 0 without crashing")
    func raggedJointReturnsSentinel() {
        // First row has 2 elements, second has 1 — ragged.
        let ragged: [[Float32]] = [[0.5, 0.5], [0.3]]
        let result = InformationTheory.normalizedMutualInformation(joint: ragged)
        #expect(result == 0)
    }

    @Test("single-row joint (no Y marginal entropy) returns 0")
    func singleRowReturnsZero() {
        // One row: H(Y) = 0, denominator = 0, sentinel returned.
        let joint: [[Float32]] = [[0.3, 0.7]]
        let result = InformationTheory.normalizedMutualInformation(joint: joint)
        #expect(result == 0)
    }

    // MARK: - Existing behavior preserved for valid inputs

    @Test("perfectly correlated 2×2 joint yields NMI = 1")
    func perfectCorrelationNMIIsOne() {
        let correlated: [[Float32]] = [[0.5, 0.0], [0.0, 0.5]]
        #expect(abs(InformationTheory.normalizedMutualInformation(joint: correlated) - 1.0) < tol)
    }

    @Test("independent 2×2 joint yields NMI = 0")
    func independenceNMIIsZero() {
        let independent: [[Float32]] = [[0.25, 0.25], [0.25, 0.25]]
        #expect(abs(InformationTheory.normalizedMutualInformation(joint: independent)) < tol)
    }
}
