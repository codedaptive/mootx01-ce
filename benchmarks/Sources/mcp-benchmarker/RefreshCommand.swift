// RefreshCommand.swift — bring an existing artifact fleet up to date without
// rebuilding it.
//
// WHY THIS EXISTS
//
// Artifacts are not all-or-nothing. Three cases, and only one of them needs a
// rebuild:
//
//   schema change        the estates are the wrong shape. Rebuild.
//   calculation change   the estates are the right corpus, computed by older
//                        code — recall weights, fusion, distillation, basis
//                        math. Re-settling them is enough.
//   no change            reuse as-is.
//
// The middle case is the common one and it was previously served by the same
// hammer as the first. That is expensive to the point of changing what work is
// worth doing: measured on this machine, a LongMemEval fleet is 500 artifacts
// and 171 GB, and MemBench is 7,000 artifacts and roughly 322 GB. A rebuild is
// hours of ingest and encode to arrive back at corpora that never changed.
//
// A refresh restores each artifact, runs the same settle sequence the build
// runs (dream, basis retrain, drain), and writes the snapshot back. The corpus
// is untouched; only the derived state is recomputed.
//
// PARALLELISM
//
// Every estate is independent and is served by its own stdio process, so the
// work is embarrassingly parallel — the same shape the artifact build already
// uses per unit. The cap defaults to the machine's core count rather than a
// fixed number, because the bound here is CPU (encode and basis math), not I/O.
//
// WHAT THIS DOES NOT DO
//
// It does not validate that a refresh is the RIGHT answer. If the schema moved,
// the restore path's provenance check hard-fails per artifact and the refresh
// stops — that is the signal to rebuild. Refresh never silently rebuilds a
// missing or mismatched entry, for the same reason `--estate-cache require`
// never does: a fleet with mixed provenance produces a number nobody can
// reproduce.

import Foundation

/// One artifact entry found on disk, ready to refresh.
struct RefreshTarget: Sendable {
    /// The run-key directory name (the fleet this entry belongs to).
    let runKey: String
    /// The unit directory (one estate).
    let entry: URL
    /// Display label for logs.
    var label: String { "\(runKey)/\(entry.lastPathComponent)" }
}

/// Enumerates every artifact entry under a cache directory.
///
/// Layout is `<cacheDir>/<run-key>/<unit-id>/estate`. An entry without an
/// `estate` directory is skipped rather than treated as a target: the cache
/// root also holds the drift-gate receipt and may hold partial writes.
///
/// - Parameter runKeyFilter: when non-nil, only run keys containing this
///   substring are returned (`--lane locomo` picks one fleet out of four).
func discoverRefreshTargets(cacheDir: URL, runKeyFilter: String?) throws -> [RefreshTarget] {
    let fm = FileManager.default
    guard let runKeys = try? fm.contentsOfDirectory(
        at: cacheDir, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }

    var targets: [RefreshTarget] = []
    for runKeyURL in runKeys.sorted(by: { $0.path < $1.path }) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: runKeyURL.path, isDirectory: &isDir), isDir.boolValue
        else { continue }
        let runKey = runKeyURL.lastPathComponent
        if let filter = runKeyFilter, !runKey.contains(filter) { continue }

        let units = (try? fm.contentsOfDirectory(
            at: runKeyURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for unit in units.sorted(by: { $0.path < $1.path }) {
            let estate = unit.appendingPathComponent("estate")
            guard fm.fileExists(atPath: estate.path) else { continue }
            targets.append(RefreshTarget(runKey: runKey, entry: unit))
        }
    }
    return targets
}

/// Runs the settle sequence against one already-ingested estate.
///
/// This is the SAME sequence the artifact build runs before it snapshots
/// (BENCHMARK_PROTOCOL.md §4): dream with full-coverage associations, retrain
/// the basis so novel-term vectors are not dark, then wait for the encode queue
/// to go idle. Both calls take the bulk deadline because whole-corpus work
/// legitimately runs for minutes and a short ceiling aborts real work rather
/// than detecting a fault.
///
/// NOTE: the lanes each inline this same three-step sequence today (ten call
/// sites at the time of writing). This function is the shared definition; the
/// lanes have not yet been converted to it. Until they are, a change to the
/// settle contract must be made here AND in the lanes, which is exactly the
/// duplication that makes a refresh drift from the build it is meant to mirror.
func settleEstateForArtifact(client: MCPClient, label: String) async throws {
    _ = try await client.callTool(
        AriaV2Surface.dream,
        arguments: ["associates": JSONValue.string("all")],
        format: .mootV2,
        deadline: MCPDeadline.bulk)
    _ = try await client.callTool(
        AriaV2Surface.reindex,
        arguments: [:],
        format: .mootV2,
        deadline: MCPDeadline.bulk)
    _ = await waitForEncodeDrain(client: client, label: label)
}

/// Refreshes one artifact in place: restore, settle, snapshot back.
///
/// The restore goes to a scratch directory rather than being settled where it
/// sits. The cache original is never served, matching the build path's rule
/// that a query run can never contaminate a cache entry — here it means a
/// crash mid-settle leaves the existing artifact intact rather than half
/// recomputed.
func refreshOneArtifact(
    target: RefreshTarget,
    mootBinaryPath: String,
    posture: ScratchEstatePosture
) async throws {
    let fm = FileManager.default
    let scratch = URL(fileURLWithPath:
        "/tmp/refresh-bench-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))")
    let estateSource = target.entry.appendingPathComponent("estate")

    try cloneOrCopyItem(at: estateSource, to: scratch)
    // The working copy goes only when the refresh finished. The stored
    // artifact is the durable copy; a failed refresh keeps its estate so the
    // failure can be diagnosed rather than deleted.
    var refreshCompleted = false
    defer {
        if refreshCompleted { try? fm.removeItem(at: scratch) }
        else { keepScratchEstateOnFailure(scratch, lane: "refresh") }
    }

    let endpoint = try lmebEndpointConfig(
        scratchDir: scratch, mootBinaryPath: mootBinaryPath, posture: posture)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    defer { Task { await client.disconnect() } }

    try await settleEstateForArtifact(client: client, label: "refresh \(target.label)")

    // Swap the recomputed estate in only after the settle succeeded. Writing
    // through a sibling and renaming means an interrupted refresh cannot leave
    // the entry without an estate directory.
    let staged = target.entry.appendingPathComponent("estate.refreshed")
    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
    try cloneOrCopyItem(at: scratch, to: staged)
    try fm.removeItem(at: estateSource)
    try fm.moveItem(at: staged, to: estateSource)
    refreshCompleted = true
}
