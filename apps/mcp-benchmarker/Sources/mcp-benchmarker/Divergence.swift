import Foundation

// Divergence.swift — the two divergence axes the benchmarker reports.
//
// SET divergence answers "did all expected items land on the target?"
// RANK divergence answers "did recall ORDER change between rankings?"
// Both are normalized so 0.0 means no divergence and 1.0 means maximal,
// so the two axes read on the same scale in the report.

/// SET divergence. Did all expected items land on the target?
/// Symmetric difference over union: 0.0 = identical sets, 1.0 = disjoint.
/// Two empty sets are defined as identical (0.0) — there is nothing that
/// failed to land.
func jaccardDivergence(expected: Set<String>, got: Set<String>) -> Double {
    if expected.isEmpty && got.isEmpty { return 0.0 }
    let intersection = expected.intersection(got).count
    let union = expected.union(got).count
    // Jaccard similarity = |A ∩ B| / |A ∪ B|; divergence is its complement.
    return 1.0 - (Double(intersection) / Double(union))
}

/// RANK divergence. Did recall ORDER change between two rankings?
/// Computed over the intersection of IDs present in both rankings — IDs in
/// only one ranking carry no order information and are dropped.
/// Normalized to 0.0 = identical order, 1.0 = fully reversed, via the
/// normalized Kendall-tau distance: the count of discordant pairs divided
/// by the maximum possible pair count for the shared set.
func rankDivergence(expected: [String], got: [String]) -> Double {
    // Restrict both rankings to the shared-ID intersection.
    let shared = Set(expected).intersection(Set(got))
    let expectedOrder = expected.filter { shared.contains($0) }
    let gotOrder = got.filter { shared.contains($0) }

    let n = expectedOrder.count
    // Fewer than two shared IDs means no pairs exist, so no order can
    // disagree: divergence is 0.
    guard n >= 2 else { return 0.0 }

    // Position of each shared id within `got`, for testing pair order.
    var rankInGot: [String: Int] = [:]
    for (i, id) in gotOrder.enumerated() { rankInGot[id] = i }

    // Count discordant pairs: for every pair (a, b) where a precedes b in
    // `expected`, it is discordant if a follows b in `got`.
    var discordant = 0
    for i in 0..<n {
        for j in (i + 1)..<n {
            guard let ra = rankInGot[expectedOrder[i]],
                  let rb = rankInGot[expectedOrder[j]] else { continue }
            if ra > rb { discordant += 1 }
        }
    }

    let totalPairs = n * (n - 1) / 2
    return Double(discordant) / Double(totalPairs)
}
