import Foundation

// --ids support: pinned debug subsets. A lane given an IDs file runs exactly
// those units — the instrument that reproduces full-run figures on a small
// fixed subset (pinned via an IDs file). Selection happens after
// corpus load and BEFORE the seeded shuffle, so the same IDs file selects the
// same units regardless of --offset/--limit.

/// Loads a unit-ID file: one ID per line; blank lines and #-comments skipped.
func loadUnitIDs(_ path: String) throws -> Set<String> {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw MCPError(description: "--ids file not readable: \(path)")
    }
    let ids = raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard !ids.isEmpty else {
        throw MCPError(description: "--ids file contains no ids: \(path)")
    }
    return Set(ids)
}

/// Normalises a unit ID that may arrive in stem form (`<evidence>__scene_N_q_M`)
/// to the bare query-id form (`scene_N_q_M`).
///
/// Three cases are handled:
///   - `"ET1__scene_3_q_7"`  → `"scene_3_q_7"` (stem-form stripped)
///   - `"scene_3_q_7"`       → `"scene_3_q_7"` (already bare, returned unchanged)
///   - `"some_other_id"`     → `"some_other_id"` (no `__scene_` marker, returned unchanged)
func normalizeUnitID(_ id: String) -> String {
    if let range = id.range(of: "__scene_") {
        return "scene_" + id[range.upperBound...]
    }
    return id
}

/// Filters a unit list to an explicit ID set. Every requested ID must exist
/// in the loaded corpus — a miss is a hard error, never a silent shrink
/// (a debug subset that silently lost units would report a figure computed
/// over a different set than its pinned reference).
func filterUnits<T>(
    _ units: [T],
    ids: Set<String>?,
    id: (T) -> String,
    lane: String
) throws -> [T] {
    guard let ids else { return units }
    let present = Set(units.map(id))
    let missing = ids.subtracting(present)
    guard missing.isEmpty else {
        let sample = missing.sorted().prefix(5).joined(separator: ", ")
        throw MCPError(description:
            "[\(lane)] --ids: \(missing.count) id(s) not in the loaded corpus "
            + "(first: \(sample)). The ids file does not match this data set.")
    }
    return units.filter { ids.contains(id($0)) }
}
