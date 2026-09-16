import Testing
@testable import SubstrateML

@Test func svdCancellationDiscardsPartialFactors() throws {
    let matrix: [[Float]] = [[1, 2], [3, 4], [5, 6]]
    #expect(throws: JacobiSVDCancelled.self) {
        try JacobiSVD.decompose(A: matrix, rank: 2, shouldCancel: { true })
    }
    var checks = 0
    #expect(throws: JacobiSVDCancelled.self) {
        try JacobiSVD.decompose(A: matrix, rank: 2, shouldCancel: {
            checks += 1
            return checks == 3
        })
    }
    #expect(checks == 3)
    let regular = JacobiSVD.decompose(A: matrix, rank: 2)
    let cancellable = try JacobiSVD.decompose(A: matrix, rank: 2, shouldCancel: { false })
    #expect(regular.singularValues == cancellable.singularValues)
    #expect(regular.U == cancellable.U)
    #expect(regular.Vt == cancellable.Vt)
}
