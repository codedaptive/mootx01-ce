import Foundation

/// Adaptive-recall signals only schedule work. The per-estate worker owns
/// audit reads, threshold evaluation, matrix computation and row publication.
public extension GeniusLocusKit {
    func runTemporalCausalityFold(_ handle: EstateHandle, now: Date) async throws {
        _ = try await requestMatrixRefresh(handle, now: now)
    }

    /// The training threshold is evaluated by the worker. Acceptance does not
    /// claim completion; matrixRefreshStatus exposes the eventual outcome.
    func runTrainingTick(_ handle: EstateHandle, now: Date) async throws -> String {
        let disposition = try await requestMatrixTraining(handle, now: now)
        return "training tick \(disposition.rawValue); threshold evaluation and refresh run in the matrix worker"
    }
}
