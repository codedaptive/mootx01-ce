import AdornmentLib
import Foundation
import LocusKit
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - AdornmentPassResult

/// Outcome of one `AdornmentPass.run` invocation, counting (drawer, minter)
/// pairs (GENIUSLOCUSKIT_INTERFACE 2.0.0 § Active-minter adornment orchestration).
///
/// Three counters replace the old (adorned, rejected, skipped) shape:
///   - `adornedPairs`  — pairs for which `putAdornment` succeeded.
///   - `failedPairs`   — pairs for which the generator returned nil or
///                        `putAdornment` threw; the minter is NOT disabled and
///                        the pair will be retried on a subsequent pass.
///   - `skippedPairs`  — pairs skipped because the drawer had empty content
///                        (structural pre-condition failure, not a minting error).
///
/// Mirrors Rust `AdornmentPassResult` (snake_case field names).
public struct AdornmentPassResult: Sendable, Equatable {
    /// Pairs for which a `StoredAdornment` row was successfully written.
    public let adornedPairs: Int
    /// Pairs where minting failed or the generator was unavailable; retried
    /// on the next pass. The minter is never disabled on failure.
    public let failedPairs: Int
    /// Pairs skipped because the drawer's content was empty.
    public let skippedPairs: Int

    public init(adornedPairs: Int, failedPairs: Int, skippedPairs: Int) {
        self.adornedPairs = adornedPairs
        self.failedPairs = failedPairs
        self.skippedPairs = skippedPairs
    }
}

// MARK: - AdornmentPass

/// Dream-time adornment-minting pass (GENIUSLOCUSKIT_SPEC 2.0.0 § 16.1).
///
/// A single pass fetches up to `batchSize` `(live Drawer, active minter)` pairs
/// that do not yet have an `adornments` row. Batch size counts PAIRS, not drawers.
/// For each pair it:
///
/// 1. Resolves the runnable generator from the minter descriptor via `generatorResolver`.
/// 2. Sends the complete drawer content and event date through that generator.
/// 3. Applies the common length/content contract via `AdornmentLib.mintAdornmentMapReduce`.
/// 4. Writes `StoredAdornment(drawerID, minterID, text)` via `Estate.putAdornment`.
///
/// Failure isolation: a failure leaves only THAT pair missing. It neither
/// disables the minter nor blocks other active minters from adorning the same
/// drawer. A repeated pass retries the missing pair.
///
/// The pass NEVER overwrites a different minter's row — the `(drawerID, minterID)`
/// composite key in the `adornments` table enforces this structurally.
///
/// Apple, Candle, port names, and seat counts are NOT branches here. They are
/// registered minter rows plus runtime generator availability. The
/// `generatorResolver` closure encapsulates all seat-specific logic; the pass
/// is seat-agnostic.
///
/// Determinism mandate: `now` is always passed in from the scheduler context.
/// `Date()` is never called inside this type.
///
/// Threading: all async operations run through the estate's serializable
/// storage backend. The signal runs with `.single` concurrency so two
/// concurrent passes on the same estate cannot interleave.
public enum AdornmentPass {

    // MARK: - Constants

    /// Batch ceiling per pass invocation.
    ///
    /// Counts (drawer, minter) PAIRS, not drawers. Two active minters produce
    /// two pairs per drawer. Bounded to 50 per hourly fire so the pass completes
    /// in well under 60 minutes even at slow external seam latency.
    public static let defaultBatchSize = 50

    // MARK: - Entry point

    /// Run one adornment pass against the addressed estate.
    ///
    /// Fetches up to `batchSize` `(drawer, minter)` pairs without an adornment
    /// row, invokes the `generatorResolver` for each pair to obtain the adornment
    /// text, and writes the result via `Estate.putAdornment`.
    ///
    /// - Parameters:
    ///   - estate: the `LocusKit.Estate` to scan and write.
    ///   - batchSize: maximum (drawer, minter) pairs to process per invocation.
    ///     Defaults to `AdornmentPass.defaultBatchSize`.
    ///   - generatorResolver: async closure that resolves the adornment text for
    ///     one `(minter, drawer)` pair. Receives the full minter descriptor and
    ///     the drawer so model choice is data-driven. Returns nil when the
    ///     generator is unavailable, exits non-zero, or produces empty output —
    ///     the pair is counted as `failedPairs` and retried on the next pass.
    ///     The default resolver drives the resident `GoldMiner` (installed
    ///     engine, else the explicit MOOT_MINT_CMD harness engine, else the
    ///     platform default — Apple's on-device model on iOS/macOS) via
    ///     `AdornmentLib.mintAdornmentMapReduce` with the product
    ///     `ADORNMENT_MAX_LENGTH` ceiling.
    ///   - now: deterministic clock from the scheduler context.
    /// - Returns: pass result (adornedPairs / failedPairs / skippedPairs).
    public static func run(
        estate: LocusKit.Estate,
        batchSize: Int = defaultBatchSize,
        /// Fan-out width override. Nil (the default, every production call
        /// site) asks the resident engine for its declared width; tests
        /// pass an explicit width so the pass's concurrency is
        /// environment-independent.
        width widthOverride: Int? = nil,
        /// Claim-length ceiling for the row-batch transport. Nil resolves
        /// to the product constant; the harness ceiling override arrives
        /// from `runAdornmentPass`.
        maxAdornmentLength: Int? = nil,
        /// Row-batch transport engagement. Nil (every production call
        /// site) lets the resident engine decide via
        /// `supportsRowBatching`; tests pass false so pass behavior never
        /// depends on the machine's engine availability.
        rowBatching: Bool? = nil,
        generatorResolver: @escaping @Sendable (
            AdornmentMinterDescriptor, LocusKit.Drawer
        ) async -> String? = { minter, drawer in
            // Default resolver: the resident GoldMiner via AdornmentLib
            // map-reduce. Supplies the full drawer content and event date so
            // relative references are calculable (operator ruling 2026-08-25).
            // The miner's engine is RESIDENT — one-off pairs on the write
            // path and batch pairs on the dream path share one model
            // residency; there is no per-pair load cost.
            await mintAdornmentMapReduce(
                drawerContent: drawer.content,
                eventDate: drawer.eventTime.ISO8601Format(),
                maxLength: ADORNMENT_MAX_LENGTH
            ) { prompt in
                guard let engine = await GoldMiner.shared.engineRef(for: minter.id),
                      let raw = await engine.mint(prompt: prompt) else {
                    return nil
                }
                // Mechanical truncation at the contract length (operator ruling
                // 2026-08-24): engines return raw text; the seam owns the
                // ceiling.
                let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.isEmpty
                    ? nil : String(candidate.prefix(ADORNMENT_MAX_LENGTH))
            }
        },
        now: Date
    ) async throws -> AdornmentPassResult {
        // Fetch up to batchSize (drawer, minter) pairs without an adornment row.
        // Each active minter produces its own debt entry per drawer, so a two-minter
        // estate yields up to 2× pairs per batch.
        let pairs = try await estate.adornmentDebtBatch(
            limit: batchSize, afterDrawerID: nil)

        guard !pairs.isEmpty else {
            log.debug("AdornmentPass: no debt pairs at \(now.ISO8601Format())")
            return AdornmentPassResult(adornedPairs: 0, failedPairs: 0, skippedPairs: 0)
        }

        var adorned = 0
        var failed = 0
        var skipped = 0

        // Fan-out runs in PER-MINTER LANES: each minter's pairs mint
        // through the engine resolved for that minter, in a lane sized to
        // THAT engine's declared width (GoldMinerEngine.maxConcurrentMints;
        // widthOverride pins every lane for tests). Lanes run concurrently,
        // so engines on different silicon overlap — one engine's await is
        // another's runtime. Pairs are fully independent — the
        // (drawerID, minterID) composite key isolates every write and
        // putAdornment serializes through the estate — so lane concurrency
        // changes only wall clock, never the stored result set.

        /// One pair's full journey: guard → generate → write. Returns the
        /// pair's outcome for the counters; all failure isolation is
        /// per-pair, exactly as the serial loop kept it.
        @Sendable func process(
            _ pair: LocusKit.AdornmentDebt
        ) async -> (adorned: Int, failed: Int, skipped: Int) {
            let drawer = pair.drawer
            let minter = pair.minter

            guard !drawer.content.isEmpty else {
                // Content guard: an empty-content drawer cannot produce a meaningful
                // adornment. Skip without leaving the debt queue — the debt predicate
                // structurally excludes empty-content rows, so this guard is defensive.
                log.debug(
                    "AdornmentPass: skipping empty-content drawer \(drawer.id) / minter \(minter.id)")
                return (0, 0, 1)
            }

            // Invoke the generator resolver for this (minter, drawer) pair.
            // Returns nil when the seam is absent, exits non-zero, or yields
            // empty output. A nil result is a per-pair failure — the minter
            // remains active and this pair will be retried on the next pass.
            guard let text = await generatorResolver(minter, drawer) else {
                log.debug(
                    "AdornmentPass: generator returned nil for drawer \(drawer.id) / minter \(minter.id)")
                return (0, 1, 0)
            }

            // Write StoredAdornment(drawerID, minterID, text) via LocusKit.
            // The (drawerID, minterID) composite key enforces that this write
            // never overwrites a different minter's row — structural guarantee.
            do {
                let rows = try await estate.putAdornment(
                    StoredAdornment(
                        drawerID: drawer.id,
                        minterID: minter.id,
                        text: text))
                if rows == 1 {
                    let preview = String(text.prefix(60))
                    log.info(
                        "AdornmentPass: adorned drawer \(drawer.id) minter \(minter.id) '\(preview)...' at \(now.ISO8601Format())"
                    )
                    return (1, 0, 0)
                }
                // Torn write: drawer was expunged between the debt fetch and
                // the putAdornment call. Log and count as failed — not a hard
                // error; the pair vanishes from debt on the next scan.
                log.warning(
                    "AdornmentPass: putAdornment returned \(rows) for drawer \(drawer.id) / minter \(minter.id)"
                )
                return (0, 1, 0)
            } catch {
                // Per-pair failure isolation: a persistence error on one pair
                // leaves only that pair missing, never disables the minter,
                // never blocks other pairs.
                log.error(
                    "AdornmentPass: putAdornment threw for drawer \(drawer.id) / minter \(minter.id): \(error)"
                )
                return (0, 1, 0)
            }
        }

        // ── Row-batch transport (operator design 2026-08-30) ─────────────────
        // Short-content pairs mint in batches of ADORNMENT_BATCH_ROWS
        // through the resident engine's persistent batch session — the
        // task stated once, records fed as row data, answers returned as
        // row data — amortizing the per-request service overhead across
        // the batch. Rows the engine fails (or when no engine speaks the
        // transport — GoldMiner.mintRows nil) fall through to the
        // single-record path below, which keeps the map-reduce chunking
        // and the mechanical-fallback coverage guarantee. Transport only:
        // minter identity and stored-row shape are unchanged.
        let length = maxAdornmentLength ?? ADORNMENT_MAX_LENGTH
        var singles: [LocusKit.AdornmentDebt] = []
        var batchables: [LocusKit.AdornmentDebt] = []
        for pair in pairs {
            if rowBatching ?? true,
               !pair.drawer.content.isEmpty,
               pair.drawer.content.count <= ADORNMENT_BATCH_ROW_CHAR_LIMIT {
                batchables.append(pair)
            } else {
                singles.append(pair)  // empties are counted skipped in process()
            }
        }

        // A frame is ONE minter's rows: the engine that answers a frame is
        // resolved by minter id (multi-model mode routes minters to
        // dedicated engines), so rows for different minters never share a
        // frame. Bucket per minter, then chunk each bucket by the row and
        // character budgets.
        var byMinter: [String: [LocusKit.AdornmentDebt]] = [:]
        for pair in batchables { byMinter[pair.minter.id, default: []].append(pair) }
        var groups: [[LocusKit.AdornmentDebt]] = []
        for (_, minterPairs) in byMinter.sorted(by: { $0.key < $1.key }) {
            var group: [LocusKit.AdornmentDebt] = []
            var groupChars = 0
            for pair in minterPairs {
                if group.count == ADORNMENT_BATCH_ROWS
                    || (groupChars + pair.drawer.content.count > ADORNMENT_BATCH_CHAR_BUDGET
                        && !group.isEmpty) {
                    groups.append(group)
                    group = []
                    groupChars = 0
                }
                group.append(pair)
                groupChars += pair.drawer.content.count
            }
            if !group.isEmpty { groups.append(group) }
        }

        /// Mint one row frame; returns per-frame outcomes plus the pairs
        /// that fall to the single-record path (per-row failures, or a nil
        /// frame when this minter's engine lacks the row transport).
        @Sendable func processGroup(
            _ batch: [LocusKit.AdornmentDebt]
        ) async -> (adorned: Int, failed: Int, fallback: [LocusKit.AdornmentDebt])? {
            let rowPayloads = batch.map {
                buildAdornmentRow(
                    drawerContent: $0.drawer.content,
                    eventDate: $0.drawer.eventTime.ISO8601Format())
            }
            guard let engine = await GoldMiner.shared.engineRef(for: batch[0].minter.id),
                  engine.supportsRowBatching
            else { return nil }
            let claims = await engine.mintRows(rowPayloads, maxLength: length)
            var groupAdorned = 0
            var groupFailed = 0
            var fallback: [LocusKit.AdornmentDebt] = []
            for (pair, claim) in zip(batch, claims) {
                guard let claim, !claim.isEmpty else {
                    fallback.append(pair)  // per-row failure → single path
                    continue
                }
                let text = String(claim.prefix(length))
                do {
                    let written = try await estate.putAdornment(
                        StoredAdornment(
                            drawerID: pair.drawer.id,
                            minterID: pair.minter.id,
                            text: text))
                    if written == 1 { groupAdorned += 1 } else { groupFailed += 1 }
                } catch {
                    log.error(
                        "AdornmentPass: batch putAdornment threw for drawer \(pair.drawer.id) / minter \(pair.minter.id): \(error)"
                    )
                    groupFailed += 1
                }
            }
            return (groupAdorned, groupFailed, fallback)
        }

        // ── Per-minter lanes ────────────────────────────────────────────
        // One concurrent lane per minter: the lane runs its minter's row
        // frames first (a nil frame means that ENGINE does not speak the
        // row transport — only its own pairs fall to the single path; the
        // nil answer is a guard check, not a model call), then its
        // singles, each through a sliding window sized to its engine's
        // width. Lanes overlap freely — with per-minter engines this is
        // what keeps every piece of silicon loaded at once.
        var laneGroups: [String: [[LocusKit.AdornmentDebt]]] = [:]
        for batch in groups { laneGroups[batch[0].minter.id, default: []].append(batch) }
        var laneSingles: [String: [LocusKit.AdornmentDebt]] = [:]
        for pair in singles { laneSingles[pair.minter.id, default: []].append(pair) }
        let laneIDs = Set(laneGroups.keys).union(laneSingles.keys).sorted()

        await withTaskGroup(of: (adorned: Int, failed: Int, skipped: Int).self) { lanes in
            for minterID in laneIDs {
                let myGroups = laneGroups[minterID] ?? []
                let seededSingles = laneSingles[minterID] ?? []
                lanes.addTask {
                    let laneWidth: Int
                    if let widthOverride {
                        laneWidth = widthOverride
                    } else {
                        laneWidth = await GoldMiner.shared.mintWidth(for: minterID)
                    }
                    var laneAdorned = 0
                    var laneFailed = 0
                    var laneSkipped = 0
                    var mySingles = seededSingles

                    await withTaskGroup(
                        of: (batch: [LocusKit.AdornmentDebt],
                             outcome: (adorned: Int, failed: Int,
                                       fallback: [LocusKit.AdornmentDebt])?).self
                    ) { taskGroup in
                        var iterator = myGroups.makeIterator()
                        for _ in 0..<max(1, min(laneWidth, myGroups.count)) {
                            guard let batch = iterator.next() else { break }
                            taskGroup.addTask { (batch, await processGroup(batch)) }
                        }
                        while let (batch, outcome) = await taskGroup.next() {
                            if let outcome {
                                laneAdorned += outcome.adorned
                                laneFailed += outcome.failed
                                mySingles.append(contentsOf: outcome.fallback)
                            } else {
                                mySingles.append(contentsOf: batch)
                            }
                            if let next = iterator.next() {
                                taskGroup.addTask { (next, await processGroup(next)) }
                            }
                        }
                    }

                    await withTaskGroup(
                        of: (adorned: Int, failed: Int, skipped: Int).self
                    ) { taskGroup in
                        var iterator = mySingles.makeIterator()
                        for _ in 0..<max(1, min(laneWidth, mySingles.count)) {
                            guard let pair = iterator.next() else { break }
                            taskGroup.addTask { await process(pair) }
                        }
                        while let outcome = await taskGroup.next() {
                            laneAdorned += outcome.adorned
                            laneFailed += outcome.failed
                            laneSkipped += outcome.skipped
                            if let pair = iterator.next() {
                                taskGroup.addTask { await process(pair) }
                            }
                        }
                    }
                    return (laneAdorned, laneFailed, laneSkipped)
                }
            }
            while let lane = await lanes.next() {
                adorned += lane.adorned
                failed += lane.failed
                skipped += lane.skipped
            }
        }

        log.info(
            "AdornmentPass: pass complete at \(now.ISO8601Format()) adorned=\(adorned) failed=\(failed) skipped=\(skipped)"
        )
        return AdornmentPassResult(
            adornedPairs: adorned, failedPairs: failed, skippedPairs: skipped)
    }
}
