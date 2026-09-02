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
///                        (structural pre-condition failure, not a minting error)
///                        or because the pair's minter id is not the identity of
///                        the engine that would serve it (provenance guard).
///
/// Mirrors Rust `AdornmentPassResult` (snake_case field names).
public struct AdornmentPassResult: Sendable, Equatable {
    /// Pairs for which a `StoredAdornment` row was successfully written.
    public let adornedPairs: Int
    /// Pairs where minting failed or the generator was unavailable; retried
    /// on the next pass. The minter is never disabled on failure.
    public let failedPairs: Int
    /// Pairs skipped because the drawer's content was empty, or because the
    /// pair's minter id is not the serving engine's identity (provenance
    /// guard). Skipped pairs stay in debt.
    public let skippedPairs: Int

    public init(adornedPairs: Int, failedPairs: Int, skippedPairs: Int) {
        self.adornedPairs = adornedPairs
        self.failedPairs = failedPairs
        self.skippedPairs = skippedPairs
    }
}

// MARK: - Batch ceiling

/// Hard ceiling on `batchSize` for one `AdornmentPass.run` invocation, in
/// (drawer, minter) pairs. Mirrors Rust `ADORNMENT_PASS_MAX_BATCH_SIZE`.
///
/// One pass runs inside one MCP call and materializes every fetched drawer's
/// content before minting, so the batch bounds both that call's wall-clock
/// and its memory. The ceiling holds for every caller — `AdornmentPass.run`
/// clamps regardless of who requested the batch, so a caller-supplied count
/// can never turn one call into an estate-wide scan. Larger fleets are paged
/// by repeated calls (the benchmark mint driver loops the dark tool to debt
/// exhaustion).
public let ADORNMENT_PASS_MAX_BATCH_SIZE: Int = 5000

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
/// Provenance guard (codex finding 17, GENIUSLOCUSKIT_SPEC 2.7.0 § 16.1):
/// the debt batch carries one pair per ACTIVE minter, and registration never
/// retoggles activation — after an upgrade or a model switch the stale
/// identity stays active beside the selected one, while the shipped build
/// resolves every minter id to ONE resident engine. Minting such a pair and
/// persisting under `pair.minter.id` would stamp the engine's text with a
/// minter it never was. So, before a pair reaches either transport (row
/// frame or single record), the pass asks `engineIdentityResolver` for the
/// minter identity of the engine that would serve the pair's minter id and
/// persists only when the two are equal; every other pair is counted
/// skipped and stays in debt (one warning per distinct skipped minter id
/// per pass). A nil identity — no engine, or the harness `CommandEngine`,
/// whose identity is a command name — disables the guard for that minter:
/// the harness owns the active set exactly, the same rule as the Rust pass
/// with no installed engine (its MOOT_MINT_CMD seam has no identity).
///
/// Concurrency lanes (codex finding 21, GENIUSLOCUSKIT_SPEC 2.8.0 § 16.1):
/// pairs mint in one concurrent lane per RESOLVED ENGINE, each lane a
/// sliding window sized to that engine's `maxConcurrentMints`. The width
/// is a per-engine ceiling and the shipped build resolves every active
/// minter to one resident engine, so lanes are keyed by the identity
/// `laneEngineResolver` returns for a minter, never by the minter id: N
/// minters sharing a width-W engine drive at most W calls into it, and a
/// width-1 command pipe stays serial however many minters it serves.
/// Distinct engines still overlap freely.
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

    /// Default batch size per pass invocation.
    ///
    /// Counts (drawer, minter) PAIRS, not drawers. Two active minters produce
    /// two pairs per drawer. Bounded to 50 per hourly fire so the pass completes
    /// in well under 60 minutes even at slow external seam latency.
    public static let defaultBatchSize = 50

    /// Clamp a requested batch size to `ADORNMENT_PASS_MAX_BATCH_SIZE`.
    ///
    /// Clamps rather than rejects: the mint driver passes large counts and
    /// expects the pass to page, not fail. Same literal behavior as Rust
    /// `clamped_batch_size`.
    public static func clampedBatchSize(_ requested: Int) -> Int {
        min(requested, ADORNMENT_PASS_MAX_BATCH_SIZE)
    }

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
    ///     Defaults to `AdornmentPass.defaultBatchSize`; clamped to
    ///     `ADORNMENT_PASS_MAX_BATCH_SIZE` here, at the entry point, so no
    ///     caller can exceed the ceiling.
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
    ///   - engineIdentityResolver: async closure returning the minter identity
    ///     of the engine that would serve a minter id, for the provenance
    ///     guard; nil = no identity, no guard for that minter. The default
    ///     asks the resident `GoldMiner` (`servingMinterIdentity(for:)`).
    ///     Tests that inject `generatorResolver` inject this too, so the
    ///     guard never depends on the machine's engine availability.
    ///   - laneEngineResolver: async closure returning the identity of the
    ///     engine that would serve a minter id — the key the pass's
    ///     concurrency lanes are grouped by, so every minter sharing one
    ///     engine shares that engine's `maxConcurrentMints` budget. Nil =
    ///     no engine serves the minter: it keeps a lane of its own at
    ///     width 1, and its pairs take the single-record path where the
    ///     generator reports the missing engine. The default asks the
    ///     resident `GoldMiner` (`servingEngineIdentity(for:)`), which,
    ///     unlike `engineIdentityResolver`, reports the harness
    ///     `CommandEngine` too — a command pipe is exactly the width-1 sink
    ///     the lane budget protects. Tests that model several engines with
    ///     one stand-in inject this to pin lane membership.
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
        engineIdentityResolver: @escaping @Sendable (String) async -> String? = { minterID in
            await GoldMiner.shared.servingMinterIdentity(for: minterID)
        },
        laneEngineResolver: @escaping @Sendable (String) async -> String? = { minterID in
            await GoldMiner.shared.servingEngineIdentity(for: minterID)
        },
        now: Date
    ) async throws -> AdornmentPassResult {
        // Fetch up to batchSize (drawer, minter) pairs without an adornment row,
        // never more than ADORNMENT_PASS_MAX_BATCH_SIZE. Each active minter
        // produces its own debt entry per drawer, so a two-minter estate yields
        // up to 2× pairs per batch.
        let pairs = try await estate.adornmentDebtBatch(
            limit: clampedBatchSize(batchSize), afterDrawerID: nil)

        guard !pairs.isEmpty else {
            log.debug("AdornmentPass: no debt pairs at \(now.ISO8601Format())")
            return AdornmentPassResult(adornedPairs: 0, failedPairs: 0, skippedPairs: 0)
        }

        var adorned = 0
        var failed = 0
        var skipped = 0

        // ── Provenance guard ─────────────────────────────────────────────
        // Resolved once per distinct minter id (an actor hop, not a model
        // call). Runs ahead of the transport split below, so both the
        // row-frame path and the single-record path only ever see pairs
        // whose minter id IS the serving engine's identity. A stale active
        // minter keeps its debt untouched — deactivating it is the
        // operator's ruling, never the pass's.
        var identityByMinter: [String: String?] = [:]
        var reportedMismatch: Set<String> = []
        var eligible: [LocusKit.AdornmentDebt] = []
        eligible.reserveCapacity(pairs.count)
        for pair in pairs {
            let minterID = pair.minter.id
            let engineIdentity: String?
            if let cached = identityByMinter[minterID] {
                engineIdentity = cached
            } else {
                engineIdentity = await engineIdentityResolver(minterID)
                identityByMinter[minterID] = engineIdentity
            }
            if let engineIdentity, engineIdentity != minterID {
                skipped += 1
                if reportedMismatch.insert(minterID).inserted {
                    log.warning(
                        "AdornmentPass: skipping active minter \(minterID) — the serving engine is \(engineIdentity); deactivate the stale minter to clear its debt"
                    )
                }
                continue
            }
            eligible.append(pair)
        }

        // Fan-out runs in PER-ENGINE LANES: each pair mints through the
        // engine resolved for its minter, inside the lane of THAT engine,
        // sized to the engine's declared width
        // (GoldMinerEngine.maxConcurrentMints; widthOverride pins every
        // lane for tests). Lanes run concurrently, so engines on different
        // silicon overlap — one engine's await is another's runtime. Pairs
        // are fully independent — the (drawerID, minterID) composite key
        // isolates every write and putAdornment serializes through the
        // estate — so lane concurrency changes only wall clock, never the
        // stored result set.

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
        for pair in eligible {
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
        // character budgets. Every pair here already passed the provenance
        // guard, so the frame's engine carries the frame's minter id.
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

        // ── Per-engine lanes (codex finding 21) ─────────────────────────
        // One concurrent lane per RESOLVED ENGINE, never per minter. An
        // engine's width is a per-engine ceiling, and the shipped build
        // resolves every active minter to the same resident engine, so
        // per-minter lanes would drive N minters × width calls into an
        // engine that promised width (two minters on a serial command
        // pipe ran two subprocess calls at once). A lane holds every
        // minter its engine serves and feeds them in minter-id order: row
        // frames first (a nil frame means that ENGINE does not speak the
        // row transport — those pairs fall to the single path; the nil
        // answer is a guard check, not a model call), then singles, all
        // through ONE sliding window sized to the engine's width. Lanes
        // overlap freely — with multi-model arms every engine sits on its
        // own silicon, and one engine's wait is another's runtime. A
        // minter no engine serves keeps a lane of its own at width 1:
        // there is no engine call to bound.

        /// Lane key: the identity of the engine the lane drives, or the
        /// minter id itself when no engine serves that minter. A product
        /// engine's identity IS a minter id, so the two cases stay
        /// distinct rather than sharing one string namespace.
        enum LaneKey: Hashable, Comparable {
            case engine(String)
            case unserved(minterID: String)

            /// Deterministic lane creation order: engine lanes first,
            /// then unserved minters, each alphabetical.
            static func < (lhs: LaneKey, rhs: LaneKey) -> Bool {
                switch (lhs, rhs) {
                case let (.engine(a), .engine(b)): return a < b
                case let (.unserved(a), .unserved(b)): return a < b
                case (.engine, .unserved): return true
                case (.unserved, .engine): return false
                }
            }
        }

        // Resolve each eligible minter's lane once (an actor hop, not a
        // model call). Minters are visited sorted, so lane membership —
        // and with it the order pairs are fed inside a lane — is
        // deterministic for a given batch.
        let minterIDs = Set(eligible.map(\.minter.id)).sorted()
        var laneByMinter: [String: LaneKey] = [:]
        for minterID in minterIDs {
            if let engineIdentity = await laneEngineResolver(minterID) {
                laneByMinter[minterID] = .engine(engineIdentity)
            } else {
                laneByMinter[minterID] = .unserved(minterID: minterID)
            }
        }
        func lane(for minterID: String) -> LaneKey {
            laneByMinter[minterID] ?? .unserved(minterID: minterID)
        }

        // `groups` is already in minter-id order (built above), so a
        // lane's frames arrive minter-sorted; singles are bucketed per
        // minter and appended in the same sorted order.
        var laneGroups: [LaneKey: [[LocusKit.AdornmentDebt]]] = [:]
        for batch in groups { laneGroups[lane(for: batch[0].minter.id), default: []].append(batch) }
        var singlesByMinter: [String: [LocusKit.AdornmentDebt]] = [:]
        for pair in singles { singlesByMinter[pair.minter.id, default: []].append(pair) }
        var laneSingles: [LaneKey: [LocusKit.AdornmentDebt]] = [:]
        var laneMinters: [LaneKey: [String]] = [:]
        for minterID in minterIDs {
            let key = lane(for: minterID)
            laneMinters[key, default: []].append(minterID)
            laneSingles[key, default: []].append(contentsOf: singlesByMinter[minterID] ?? [])
        }
        let laneKeys = laneMinters.keys.sorted()

        await withTaskGroup(of: (adorned: Int, failed: Int, skipped: Int).self) { lanes in
            for laneKey in laneKeys {
                // Every lane holds at least one minter by construction;
                // the width is asked ONCE per lane through any member,
                // since all of them resolve to this lane's engine.
                guard let representativeMinter = laneMinters[laneKey]?.first else { continue }
                let myGroups = laneGroups[laneKey] ?? []
                let seededSingles = laneSingles[laneKey] ?? []
                lanes.addTask {
                    let laneWidth: Int
                    if let widthOverride {
                        laneWidth = widthOverride
                    } else if case .unserved = laneKey {
                        // No engine to bound; the single path reports the
                        // missing engine per pair and the pair stays in
                        // debt.
                        laneWidth = 1
                    } else {
                        laneWidth = await GoldMiner.shared.mintWidth(for: representativeMinter)
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
