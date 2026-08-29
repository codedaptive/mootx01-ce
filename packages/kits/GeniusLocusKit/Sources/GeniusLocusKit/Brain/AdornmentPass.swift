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
        generatorResolver: @escaping @Sendable (
            AdornmentMinterDescriptor, LocusKit.Drawer
        ) async -> String? = { minter, drawer in
            // Default resolver: the resident GoldMiner via AdornmentLib
            // map-reduce. Supplies the full drawer content and event date so
            // relative references are calculable (Bob ruling 2026-08-25).
            // The miner's engine is RESIDENT — one-off pairs on the write
            // path and batch pairs on the dream path share one model
            // residency; there is no per-pair load cost.
            await mintAdornmentMapReduce(
                drawerContent: drawer.content,
                eventDate: drawer.eventTime.ISO8601Format(),
                maxLength: ADORNMENT_MAX_LENGTH
            ) { prompt in
                guard let raw = await GoldMiner.shared.mintOne(prompt: prompt) else {
                    return nil
                }
                // Mechanical truncation at the contract length (Bob ruling
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

        for pair in pairs {
            let drawer = pair.drawer
            let minter = pair.minter

            guard !drawer.content.isEmpty else {
                // Content guard: an empty-content drawer cannot produce a meaningful
                // adornment. Skip without leaving the debt queue — the debt predicate
                // structurally excludes empty-content rows, so this guard is defensive.
                log.debug(
                    "AdornmentPass: skipping empty-content drawer \(drawer.id) / minter \(minter.id)")
                skipped += 1
                continue
            }

            // Invoke the generator resolver for this (minter, drawer) pair.
            // Returns nil when the seam is absent, exits non-zero, or yields
            // empty output. A nil result is a per-pair failure — the minter
            // remains active and this pair will be retried on the next pass.
            guard let text = await generatorResolver(minter, drawer) else {
                log.debug(
                    "AdornmentPass: generator returned nil for drawer \(drawer.id) / minter \(minter.id)")
                failed += 1
                continue
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
                    adorned += 1
                    let preview = String(text.prefix(60))
                    log.info(
                        "AdornmentPass: adorned drawer \(drawer.id) minter \(minter.id) '\(preview)...' at \(now.ISO8601Format())"
                    )
                } else {
                    // Torn write: drawer was expunged between the debt fetch and
                    // the putAdornment call. Log and count as failed — not a hard
                    // error; the pair vanishes from debt on the next scan.
                    log.warning(
                        "AdornmentPass: putAdornment returned \(rows) for drawer \(drawer.id) / minter \(minter.id)"
                    )
                    failed += 1
                }
            } catch {
                // Per-pair failure isolation: a persistence error on one pair
                // leaves only that pair missing, never disables the minter,
                // never blocks other pairs.
                log.error(
                    "AdornmentPass: putAdornment threw for drawer \(drawer.id) / minter \(minter.id): \(error)"
                )
                failed += 1
            }
        }

        log.info(
            "AdornmentPass: pass complete at \(now.ISO8601Format()) adorned=\(adorned) failed=\(failed) skipped=\(skipped)"
        )
        return AdornmentPassResult(
            adornedPairs: adorned, failedPairs: failed, skippedPairs: skipped)
    }
}
