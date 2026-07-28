import Foundation

// TransferEngine.swift — moves a corpus from source to target, recording a
// manifest and timing each capture, then verifying every entry round-trips.
//
// Flow:
//   1. PAGINATE the source `list` verb (limit + offset) to exhaustion, so the
//      whole corpus is enumerated, not just the first default page. A
//      `maxEntries` cap stops early when sampling a large corpus (MemPalace is
//      ~39k drawers) — and the cap is reported, never a silent truncation.
//   2. For each listed item, fetch its FULL content by id via the source
//      `fetch` verb when one is configured (MemPalace `list_drawers` returns a
//      TRUNCATED `content_preview`; `get_drawer` returns the full content). A
//      faithful transfer writes full content, not previews.
//   3. Write to the target via the target `write` verb, timing each capture; a
//      transient failure is retried, a permanent one recorded as `.failed`.
//   4. VERIFY the round-trip: query the target for the just-written content and
//      confirm the assigned id comes back. Any entry that does not round-trip
//      is recorded so the operator sees exactly what failed to land.
//
// TARGET WRITE + ID CORRELATION: the target's write tool may mint its own id
// and ignore the caller's (MOOTx01 `moot_file_memory` assigns a UUID and
// requires `{ content, location }`). So the engine builds write arguments from
// the TARGET verbMap (content key + constant args) and, when the target returns
// an assigned id, records THAT id in the manifest. Round-trip verification and
// recall then check the target's own id — the only id the target knows.

/// One entry that failed its post-write round-trip check, retained for the
/// transfer report so a non-round-tripping drawer is never silent.
struct RoundTripFailure: Sendable, Equatable {
    /// The manifest id (the target's assigned id, or the source id fallback).
    let id: String
    /// Why it failed: it was never written, or it was written but did not come
    /// back when the target was queried for its content.
    enum Reason: String, Sendable { case writeFailed, notRecalled }
    let reason: Reason
}

/// The outcome of a transfer run: the manifest, the timing, and any entries
/// that did not round-trip.
struct TransferResult: Sendable {
    let manifest: Manifest
    let timing: TimingCollection
    let roundTripFailures: [RoundTripFailure]
    /// Number of items the source enumerated (before the maxEntries cap and
    /// content-empty skips) — reported so a capped sample is explicit.
    let sourceEnumerated: Int
    /// True when the run stopped at the maxEntries cap rather than corpus end.
    let cappedBySample: Bool
}

/// Drives a source → target transfer and produces the ground-truth manifest.
struct TransferEngine {
    let source: MCPClient
    let target: MCPClient
    let sourceVerbs: EndpointConfig.VerbMap
    let targetVerbs: EndpointConfig.VerbMap
    /// Retries per entry on a transient write failure before the entry is
    /// recorded as permanently failed.
    let maxRetries: Int
    /// Cap on entries to transfer. nil = whole corpus. Used to sample a large
    /// source (MemPalace ~39k) without a silent truncation — the cap is
    /// reported in the result.
    let maxEntries: Int?
    /// When true, query the target after each write to confirm the entry
    /// round-trips (data-integrity check). On by default for `transfer`.
    let verifyRoundTrip: Bool
    /// Clock injected at the CLI boundary so timestamps are not read from a
    /// hidden global. Deterministic-by-injection, matching the MOOTx01 "pass
    /// now as a parameter" discipline even though this is a CLI tool.
    let now: @Sendable () -> Date

    init(source: MCPClient,
         target: MCPClient,
         sourceVerbs: EndpointConfig.VerbMap,
         targetVerbs: EndpointConfig.VerbMap,
         maxRetries: Int = 2,
         maxEntries: Int? = nil,
         verifyRoundTrip: Bool = true,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.target = target
        self.sourceVerbs = sourceVerbs
        self.targetVerbs = targetVerbs
        self.maxRetries = maxRetries
        self.maxEntries = maxEntries
        self.verifyRoundTrip = verifyRoundTrip
        self.now = now
    }

    /// Runs the transfer. Paginates + full-content-fetches the source, writes to
    /// the target, and (when enabled) verifies each entry round-trips.
    func run() async throws -> TransferResult {
        guard let listVerb = sourceVerbs.list else {
            throw MCPError(description: "source verbMap has no `list` verb; cannot enumerate corpus")
        }

        var manifest = Manifest()
        var timing = TimingCollection()
        var roundTripFailures: [RoundTripFailure] = []

        // 1. Enumerate the source by paginating list(limit, offset).
        let (items, capped) = try await enumerateSource(listVerb: listVerb)

        var positional = 0
        for item in items {
            positional += 1
            // 2. Fetch full content by id when a fetch verb is configured and
            // the item has an id; else fall back to the (possibly preview)
            // content the list returned.
            let content = try await fullContent(for: item)
            guard let content, !content.isEmpty else { continue }
            let sourceID = item.id ?? "source-\(positional)"

            // 3. Write to the target, capturing the assigned id + latency.
            let (outcome, assignedID, elapsed) = await writeWithRetry(content: content)
            timing.record(elapsed, into: .capture)
            manifest.recordCaptureLatency(elapsed)
            let manifestID = assignedID ?? sourceID
            manifest.record(ManifestEntry(
                id: manifestID,
                content: content,
                transferredAt: Self.iso8601(now()),
                outcome: outcome
            ))

            // 4. Round-trip verify.
            if outcome == .failed {
                roundTripFailures.append(RoundTripFailure(id: manifestID, reason: .writeFailed))
            } else if verifyRoundTrip {
                let recalled = await roundTrips(content: content, expectedID: manifestID)
                if !recalled {
                    roundTripFailures.append(RoundTripFailure(id: manifestID, reason: .notRecalled))
                }
            }
        }

        return TransferResult(manifest: manifest,
                              timing: timing,
                              roundTripFailures: roundTripFailures,
                              sourceEnumerated: items.count,
                              cappedBySample: capped)
    }

    /// Paginates the source `list` verb to exhaustion (or the maxEntries cap),
    /// returning the enumerated items and whether the run was capped. A page
    /// shorter than the page size (or empty) marks corpus end.
    private func enumerateSource(listVerb: String) async throws -> (items: [MCPResultItem], capped: Bool) {
        let pageSize = max(sourceVerbs.listPageSize, 1)
        var offset = 0
        var collected: [MCPResultItem] = []
        while true {
            // limit/offset passed as JSON numbers; the encoder emits whole
            // integers (e.g. 100, not 100.0) which the servers accept.
            let page = try await source.callTool(
                listVerb,
                arguments: [
                    sourceVerbs.listLimitArg: .number(Double(pageSize)),
                    sourceVerbs.listOffsetArg: .number(Double(offset)),
                ],
                format: sourceVerbs.resultFormat)
            if page.items.isEmpty { break }
            collected.append(contentsOf: page.items)

            if let cap = maxEntries, collected.count >= cap {
                return (Array(collected.prefix(cap)), true)
            }
            // A short page means we reached the end of the corpus.
            if page.items.count < pageSize { break }
            offset += pageSize
        }
        return (collected, false)
    }

    /// Returns the full content for an item: when the source has a `fetch` verb
    /// and the item has an id, fetch the full record by id (the list preview is
    /// truncated). Otherwise use the content the list returned.
    private func fullContent(for item: MCPResultItem) async throws -> String? {
        guard let fetchVerb = sourceVerbs.fetch, let id = item.id else {
            return item.content
        }
        // The fetch result is a single full record whose content lives under a
        // DIFFERENT key than the list preview (MemPalace: list → `content_preview`,
        // get_drawer → `content`). Parse it with a format keyed on the full
        // content key. The list's id key still applies to the single record.
        let fetchFormat: ResultFormat
        switch sourceVerbs.resultFormat {
        case let .jsonObjects(idKey, _):
            fetchFormat = .jsonObjects(idKey: idKey, contentKey: sourceVerbs.fetchContentKey)
        case .mootText:
            // A mootText server exposes no separate fetch; keep the format.
            fetchFormat = sourceVerbs.resultFormat
        }
        let result = try await source.callTool(
            fetchVerb,
            arguments: [sourceVerbs.fetchIDArg: .string(id)],
            format: fetchFormat)
        // Take the single record's content; fall back to the list preview if
        // the fetch returned nothing.
        return result.items.first?.content ?? item.content
    }

    /// Queries the target for the just-written content and confirms the
    /// expected id appears in the results — the round-trip integrity check.
    private func roundTrips(content: String, expectedID: String) async -> Bool {
        do {
            let result = try await target.callTool(
                targetVerbs.query,
                arguments: [targetVerbs.queryArg: .string(content)],
                format: targetVerbs.resultFormat)
            return result.orderedIDs.contains(expectedID)
        } catch {
            return false
        }
    }

    /// Writes one entry to the target, retrying transient failures up to
    /// `maxRetries` times. Returns the final outcome, the target-assigned id
    /// (when the target mints one), and the total elapsed seconds across
    /// attempts (what the operator actually waited).
    private func writeWithRetry(content: String) async -> (TransferOutcome, String?, Double) {
        let start = DispatchTime.now()
        var attempt = 0
        while true {
            do {
                // Build write arguments from the TARGET verbMap: the content
                // under the target's content key, plus any required constant
                // args (MOOTx01 needs `location`; MemPalace needs `wing`+`room`).
                // The caller's id is never sent — the target either ignores it
                // (MOOTx01) or assigns its own.
                var arguments: [String: JSONValue] = [
                    targetVerbs.contentArg: .string(content),
                ]
                for (key, value) in targetVerbs.constantArgs {
                    arguments[key] = .string(value)
                }
                let result = try await target.callTool(targetVerbs.write,
                                                       arguments: arguments,
                                                       format: targetVerbs.resultFormat)
                return (.transferred, result.writeAssignedID, elapsedSeconds(since: start))
            } catch {
                attempt += 1
                if attempt > maxRetries {
                    // Permanent failure: no id was assigned (nothing landed).
                    return (.failed, nil, elapsedSeconds(since: start))
                }
                // Brief backoff before retrying a transient write error.
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            }
        }
    }

    /// Monotonic elapsed seconds since a start mark — uses DispatchTime, not
    /// the wall clock, so a clock adjustment cannot corrupt a latency sample.
    private func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Formats a date as an ISO8601 TEXT timestamp.
    static func iso8601(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}
