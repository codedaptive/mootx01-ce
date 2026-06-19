import Testing
@testable import SubstrateML
import Foundation

@Suite("TypedDecayWeighting")
struct TypedDecayWeightingTests {

    // MARK: - DistillationFeatureType — lambda values

    @Test("entity decayLambda is 0.1")
    func entityLambda() {
        #expect(DistillationFeatureType.entity.decayLambda == 0.1)
    }

    @Test("relation decayLambda is 0.2")
    func relationLambda() {
        #expect(DistillationFeatureType.relation.decayLambda == 0.2)
    }

    @Test("temporal decayLambda is 0.5")
    func temporalLambda() {
        #expect(DistillationFeatureType.temporal.decayLambda == 0.5)
    }

    @Test("numerical decayLambda is 0.8")
    func numericalLambda() {
        #expect(DistillationFeatureType.numerical.decayLambda == 0.8)
    }

    // MARK: - DistillationFeatureType — raw values

    @Test("raw values match canonical type tags")
    func rawValues() {
        #expect(DistillationFeatureType.entity.rawValue    == "ENT")
        #expect(DistillationFeatureType.relation.rawValue  == "REL")
        #expect(DistillationFeatureType.temporal.rawValue  == "TMP")
        #expect(DistillationFeatureType.numerical.rawValue == "NUM")
    }

    // MARK: - weight()

    @Test("w(0) == 1.0 for all types")
    func weightAtZeroIsOne() {
        for type_ in DistillationFeatureType.allCases {
            #expect(TypedDecayWeighting.weight(featureType: type_, ageInUnits: 0) == 1.0,
                    "Expected weight = 1.0 at age 0 for \(type_.rawValue)")
        }
    }

    @Test("entity weight at age 5 ≈ 0.6065 (exp(-0.1×5))")
    func entityWeightAt5() {
        let w = TypedDecayWeighting.weight(featureType: .entity, ageInUnits: 5.0)
        // exp(-0.5) ≈ 0.60653
        #expect(abs(w - 0.6065) < 0.001)
    }

    @Test("numerical weight at age 5 ≈ 0.0183 (exp(-0.8×5))")
    func numericalWeightAt5() {
        let w = TypedDecayWeighting.weight(featureType: .numerical, ageInUnits: 5.0)
        // exp(-4.0) ≈ 0.01832
        #expect(abs(w - 0.0183) < 0.001)
    }

    @Test("weight decreases monotonically with increasing age")
    func weightMonotone() {
        for type_ in DistillationFeatureType.allCases {
            let w0 = TypedDecayWeighting.weight(featureType: type_, ageInUnits: 0)
            let w1 = TypedDecayWeighting.weight(featureType: type_, ageInUnits: 1)
            let w5 = TypedDecayWeighting.weight(featureType: type_, ageInUnits: 5)
            #expect(w0 > w1, "\(type_.rawValue): w(0) should exceed w(1)")
            #expect(w1 > w5, "\(type_.rawValue): w(1) should exceed w(5)")
        }
    }

    @Test("negative age is clamped to 0, returning 1.0")
    func negativeAgeClamped() {
        let w = TypedDecayWeighting.weight(featureType: .entity, ageInUnits: -5.0)
        #expect(w == 1.0)
    }

    // MARK: - weightedDocFrequency()

    @Test("empty allMemoryTimestamps returns 0")
    func emptyMemoriesReturnsZero() {
        let result = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: [],
            allMemoryTimestamps: [],
            referenceDate: Date()
        )
        #expect(result == 0)
    }

    @Test("uniform timestamps, all present: df_w == 1.0")
    func uniformAllPresentIsOne() {
        let ref = Date()
        // All 5 memories at age 0; all weights = 1.0; numerator = 5, W = 5 → df_w = 1.0
        let timestamps = Array(repeating: ref, count: 5)
        let result = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: timestamps,
            allMemoryTimestamps: timestamps,
            referenceDate: ref
        )
        #expect(abs(result - 1.0) < 1e-5)
    }

    @Test("uniform timestamps, half present: df_w == 0.5")
    func uniformHalfPresentIsHalf() {
        let ref = Date()
        // 6 memories at age 0; 3 present → df_w = 3.0 / 6.0 = 0.5
        let all     = Array(repeating: ref, count: 6)
        let present = Array(repeating: ref, count: 3)
        let result = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: present,
            allMemoryTimestamps: all,
            referenceDate: ref
        )
        #expect(abs(result - 0.5) < 1e-5)
    }

    @Test("no presences returns 0")
    func noPresencesReturnsZero() {
        let ref = Date()
        let all = Array(repeating: ref, count: 4)
        let result = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: [],
            allMemoryTimestamps: all,
            referenceDate: ref
        )
        #expect(result == 0)
    }

    @Test("recent presences outweigh old presences under exponential decay")
    func recentWeighsMore() {
        let ref = Date()
        // Two memories: one 100 days old (weight ≈ 0), one current (weight = 1).
        let old    = ref.addingTimeInterval(-100 * 86_400)
        let recent = ref
        let all    = [old, recent]

        // Feature present only in the recent memory → high df_w
        let dfwRecent = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: [recent],
            allMemoryTimestamps: all,
            referenceDate: ref
        )
        // Feature present only in the old memory → very low df_w
        let dfwOld = TypedDecayWeighting.weightedDocFrequency(
            featureType: .entity,
            presenceTimestamps: [old],
            allMemoryTimestamps: all,
            referenceDate: ref
        )
        #expect(dfwRecent > dfwOld)
        // Recent-only should be very close to 1.0 (old weight ≈ 0)
        #expect(dfwRecent > 0.99)
    }
}
