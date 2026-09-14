import LocusKit

/// Admitted by-ID hydration rows and the sensitivity-only exclusion count.
/// There is deliberately no rejected/loaded-ID channel.
public struct GLKHydrationResult: Sendable {
    public let drawers: [Drawer]
    public let withheldBySensitivity: Int
}

extension GeniusLocusKit {
    /// Hydrate the caller's exact candidate IDs through LocusKit's counted gate.
    public func hydrateWithSensitivityCount(
        _ handle: EstateHandle, ids: [String], frame: RecallFrame,
        hydrationLevel: HydrationLevel
    ) async throws -> GLKHydrationResult {
        let result = try await estate(for: handle).hydrateWithSensitivityCount(
            ids: ids, matchingFrame: frame, hydrationLevel: hydrationLevel)
        return GLKHydrationResult(drawers: result.rows, withheldBySensitivity: result.withheldBySensitivity)
    }
}
