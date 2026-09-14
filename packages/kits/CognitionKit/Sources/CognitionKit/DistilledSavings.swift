// DistilledSavings.swift
//
// Structured metadata reporting how much context the distilled payload
// saved against the original bodies of the same returned records.
//
// `DistilledSavings` is produced by the ARIA v2 surface for
// `moot_recall_distilled`, from the per-match `tokenCount` and
// `originalTokenCount` the `distilled_recall` recipe carries, summed over
// the rows the surface actually emits (after its row cap and privacy
// projection). It compares the distilled payload cost (tokens sent to the
// caller) against the original body cost (what naive full-body hydration
// would have paid). Estimates are clearly labelled and the estimator is
// named for provenance.
//
// The `skim` field is part of the wire contract now so the schema does
// not change when skim is wired. It is always `nil` today because
// `moot_recall_distilled` does not apply skim.
//
// Codable: synthesised. Key names equal Swift property names (camelCase).
// The `skim` key is absent from encoded output when `skim == nil` because
// synthesised `Codable` uses `encodeIfPresent` for optional properties.
//
// Bitmap rule: `estimated` is a plain `Bool` stored property on a pure
// value type that is never persisted to an estate. The rule covers
// persisted entity types only; this is not one.

import Foundation
import GeniusLocusKit

// MARK: - DistilledSkim

/// Context saved by a skim stage applied on top of distillation.
///
/// Absent (`nil` on the parent field) when skim was not applied.
/// `moot_recall_distilled` does not apply skim today; this struct exists so
/// the wire contract is stable before skim is wired.
public struct DistilledSkim: Sendable, Equatable, Codable {
    /// Tokens the skim stage omitted after distillation. Always non-negative.
    public let omittedTokens: Int64

    public init(omittedTokens: Int64) {
        self.omittedTokens = omittedTokens
    }
}

// MARK: - DistilledSavings

/// Tokens the distilled payload saved against the original bodies of
/// the same returned records.
///
/// ## Arithmetic
///
/// `measure(originalTokens:distilledTokens:skimOmittedTokens:)` computes:
///
///   - `returnedTokens = distilledTokens - (skimOmittedTokens ?? 0)`:
///     tokens actually sent to the caller after skim.
///   - `savedTokens = originalTokens - distilledTokens`: saving from
///     distillation alone; negative when the payload grew.
///   - `savedPercent`: `savedTokens * 100 / originalTokens` rounded
///     half-away-from-zero using integer arithmetic only (no Double,
///     no unguarded narrowing). Zero when `originalTokens == 0`.
///
/// ## Growth is reported as a positive increase
///
/// When `savedTokens < 0` the display says "increase" and uses the
/// absolute value. `savedTokens` itself is signed so the raw number
/// is always recoverable.
///
/// ## Codable
///
/// Keys are camelCase Swift property names (synthesised). The `skim` key
/// is absent from encoded output when `skim == nil`. Callers that decode
/// this struct from JSON may safely omit the `skim` key and get `nil`.
public struct DistilledSavings: Sendable, Equatable, Codable {
    /// One opt-in boundary for text-pair accounting and the caller-facing line.
    /// Pass only authorized, actually returned bodies. `skimmed` is the final
    /// preview, not its fullText/continuation. Disabled calls do no counting.
    public static func text(
        original: String, reduced: String, enabled: Bool,
        skimmed: String? = nil
    ) -> String {
        guard enabled else { return "" }
        let originalCount = GeniusLocusKit.estimatedTokenCount(of: original)
        let reducedCount = GeniusLocusKit.estimatedTokenCount(of: reduced)
        let omitted = skimmed.map {
            reducedCount - GeniusLocusKit.estimatedTokenCount(of: $0)
        }
        // A longer preview is not an omission. Describe the actual final text
        // as a direct reduction/growth instead of inventing negative skim savings.
        if let omitted, omitted < 0, let skimmed {
            return measure(originalTokens: originalCount,
                           distilledTokens: GeniusLocusKit.estimatedTokenCount(of: skimmed),
                           skimOmittedTokens: nil).display
        }
        return measure(originalTokens: originalCount, distilledTokens: reducedCount,
                       skimOmittedTokens: omitted).display
    }

    /// Tokens sent to the caller: `distilledTokens - (skimOmittedTokens ?? 0)`.
    public let returnedTokens: Int64
    /// Sum of `originalTokenCount` over the emitted rows that carry a
    /// distilled body: the cost of naive full-body hydration.
    public let originalTokens: Int64
    /// `originalTokens - distilledTokens`. Negative when the distilled
    /// payload was larger than the original bodies.
    public let savedTokens: Int64
    /// `savedTokens * 100 / originalTokens`, rounded half-away-from-zero.
    /// Negative when the payload grew. Zero when `originalTokens == 0`.
    public let savedPercent: Int64
    /// Always `true`: token counts use `ContextDistillLib.estimateTokens`.
    public let estimated: Bool
    /// Name of the estimator that produced the token counts.
    public let estimator: String
    /// Tokens omitted by skim after distillation. `nil` when skim was
    /// not applied, which is the current `moot_recall_distilled` behaviour.
    /// The field is in the wire contract now so no schema change is needed
    /// when skim is wired.
    public let skim: DistilledSkim?
    /// Human-readable summary of the savings, suitable for logging or
    /// tool-response metadata.
    public let display: String

    /// The estimator used for all token-count estimates in this struct.
    ///
    /// Value is stable across versions; callers may compare against it.
    public static let estimatorName =
        "ContextDistillLib.estimateTokens (TokenCompaction v1)"

    // MARK: - Public memberwise init

    public init(
        returnedTokens: Int64,
        originalTokens: Int64,
        savedTokens: Int64,
        savedPercent: Int64,
        estimated: Bool,
        estimator: String,
        skim: DistilledSkim?,
        display: String
    ) {
        self.returnedTokens = returnedTokens
        self.originalTokens = originalTokens
        self.savedTokens = savedTokens
        self.savedPercent = savedPercent
        self.estimated = estimated
        self.estimator = estimator
        self.skim = skim
        self.display = display
    }

    // MARK: - Factory

    /// Compute savings from raw token sums and build the display string.
    ///
    /// - Parameters:
    ///   - originalTokens: sum of per-match `originalTokenCount` over the
    ///     emitted rows that carry a distilled body.
    ///   - distilledTokens: sum of per-match `tokenCount` (distilled text
    ///     estimate) over the same rows.
    ///   - skimOmittedTokens: tokens removed by skim after distillation.
    ///     Pass `nil` when skim was not applied (the current surface default).
    public static func measure(
        originalTokens: Int64,
        distilledTokens: Int64,
        skimOmittedTokens: Int64?
    ) -> DistilledSavings {
        let omitted = skimOmittedTokens ?? 0
        let returned = distilledTokens - omitted
        let saved = originalTokens - distilledTokens

        // Integer-only rounding: half-away-from-zero of saved*100/original.
        // Swift's Int64 division truncates toward zero, so we add half the
        // denominator before dividing. Positive and negative paths are
        // handled separately so the bias is always away from zero. No Double
        // arithmetic to avoid precision loss or unguarded narrowing.
        let percent: Int64
        if originalTokens == 0 {
            percent = 0
        } else {
            let scaled = saved * 100
            let half = originalTokens / 2
            if saved >= 0 {
                percent = (scaled + half) / originalTokens
            } else {
                percent = -((-scaled + half) / originalTokens)
            }
        }

        let skimStruct = skimOmittedTokens.map { DistilledSkim(omittedTokens: $0) }
        let d = buildDisplay(
            returnedTokens: returned,
            originalTokens: originalTokens,
            savedTokens: saved,
            savedPercent: percent,
            skimStruct: skimStruct)

        return DistilledSavings(
            returnedTokens: returned,
            originalTokens: originalTokens,
            savedTokens: saved,
            savedPercent: percent,
            estimated: true,
            estimator: estimatorName,
            skim: skimStruct,
            display: d)
    }
}

// MARK: - Display helpers

/// Format a non-negative `Int64` with comma separators every three digits.
///
/// Implemented by hand: no NumberFormatter, no locale dependency.
/// The caller is responsible for passing a non-negative value; sign is
/// handled by the callers in `buildDisplay`.
/// Examples: 0 -> "0", 800 -> "800", 1200 -> "1,200", 1234567 -> "1,234,567".
private func formatThousands(_ n: Int64) -> String {
    let digits = Array(String(n))
    var result = ""
    for (i, c) in digits.reversed().enumerated() {
        if i > 0 && i % 3 == 0 { result = "," + result }
        result = String(c) + result
    }
    return result
}

/// Build the display string from the computed savings fields.
///
/// Grammar (exact bytes):
///
///   skim absent, savedTokens >= 0:
///     `🌱 Distilled: ~R tokens returned vs ~O original · ~S saved (P%)`
///
///   skim absent, savedTokens < 0 (payload grew):
///     `🌱 Distilled: ~R tokens returned vs ~O original · ~|S| increase (|P|%)`
///
///   skim present, savedTokens >= 0:
///     `🌱 Distillation saved ~S tokens; skim omitted another ~K tokens.`
///
///   skim present, savedTokens < 0:
///     `🌱 Distillation added ~|S| tokens; skim omitted ~K tokens.`
///
/// `~` marks estimated values (always applied here). `·` is U+00B7 with
/// one space on each side. `🌱` (U+1F331) is followed by one space.
/// The no-skim forms end without a period; the skim forms end with one.
private func buildDisplay(
    returnedTokens: Int64,
    originalTokens: Int64,
    savedTokens: Int64,
    savedPercent: Int64,
    skimStruct: DistilledSkim?
) -> String {
    let p = "~"
    // U+00B7 MIDDLE DOT with one space on each side.
    let dot = " \u{00B7} "
    // U+1F331 SEEDLING followed by one space.
    let leaf = "\u{1F331} "

    if let s = skimStruct {
        // Skim-present forms end with a period.
        let omitted = formatThousands(s.omittedTokens)
        if savedTokens >= 0 {
            let saved = formatThousands(savedTokens)
            return "\(leaf)Distillation saved \(p)\(saved) tokens; skim omitted another \(p)\(omitted) tokens."
        } else {
            let added = formatThousands(-savedTokens)
            return "\(leaf)Distillation added \(p)\(added) tokens; skim omitted \(p)\(omitted) tokens."
        }
    } else {
        // No-skim forms carry no trailing period.
        let ret = formatThousands(returnedTokens)
        let orig = formatThousands(originalTokens)
        let pct = abs(savedPercent)
        if savedTokens >= 0 {
            let saved = formatThousands(savedTokens)
            return "\(leaf)Distilled: \(p)\(ret) tokens returned vs \(p)\(orig) original\(dot)\(p)\(saved) saved (\(pct)%)"
        } else {
            let added = formatThousands(-savedTokens)
            return "\(leaf)Distilled: \(p)\(ret) tokens returned vs \(p)\(orig) original\(dot)\(p)\(added) increase (\(pct)%)"
        }
    }
}
