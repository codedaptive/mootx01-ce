// ConflictProjectionPass.swift
//
// DCP M2 — the typed lane's projection step: KGFacts → ConflictSignatures
// plus the in-memory coordinate index that buckets signatures by
// (key, dimension) so evaluation is pairwise-within-bucket, never O(N²)
// over the whole fact table. Contract:
// docs/reference/SUBSTRATEML_SPEC.md § 5.27; the value/identity types live in
// SubstrateML/ConflictProjection.swift (M1).
//
// This layer is PURE and deterministic: facts and per-drawer event times
// come in, signatures and diagnostics come out. No estate reads, no
// clock, no I/O — the estate-reading orchestration (drawer hydration,
// evaluator sweep, report lines) is M3's seam. Rust twin:
// rust/src/brain/conflict_projection_pass.rs, golden-gated by
// ConflictProjectionPassTests ↔ conflict projection pass tests.

import Foundation
import LocusKit
import SubstrateML

/// Why a scanned KGFact did not become a ConflictSignature. Counted per
/// pass and surfaced through the report's `coverage: <projected>/<scanned>`
/// and `unknown_or_invalid: N` lines (M0 §7) — never silently dropped.
public struct ConflictProjectionDiagnostics: Sendable, Equatable {
    /// Facts examined this pass.
    public var scanned: Int = 0
    /// Facts that produced a signature.
    public var projected: Int = 0
    /// Facts whose adjective state is not `.active` (withdrawn, rejected,
    /// superseded, tombstoned, pending, contested). Excluded before
    /// evaluation per M0 §1 — only active standing can prove.
    public var inactive: Int = 0
    /// Facts whose predicate resolves to no registered dimension. These
    /// stay in the lexical hunter's domain (UnknownRule never proves);
    /// they are NOT signatures in v0.1.
    public var unregistered: Int = 0
    /// Facts on a registered dimension whose object failed the rule's
    /// normalizer (ambiguous date, out-of-set enum token, malformed
    /// number). The typed lane refuses to guess: these count toward the
    /// report's `unknown_or_invalid` line.
    public var unparsed: Int = 0

    public init() {}
}

/// One pass's output: the projected signatures plus the exclusion counts.
public struct ConflictProjectionResult: Sendable {
    public let signatures: [ConflictSignature]
    public let diagnostics: ConflictProjectionDiagnostics
}

/// KGFact → ConflictSignature projection (M0 §2). Pure functions only.
public enum ConflictProjector {

    /// Canonical scoped key for a fact's subject under a rule:
    /// `<domain>:<canonical subject>` where domain is the ruleID's second
    /// dot-component (`dim.person.employer` → `person`) and the canonical
    /// subject is NFC + trimmed + whitespace-collapsed + lowercased. The
    /// scope policy is exact-equal on this string (M0 §2), so two
    /// spellings of one entity collide only when their canonical forms
    /// match — entity RESOLUTION stays out of scope in v0.1.
    public static func conflictKey(ruleID: String, subject: String) -> String {
        let components = ruleID.split(separator: ".")
        let domain = components.count >= 2 ? String(components[1]) : "unknown"
        return "\(domain):\(ConflictNormalize.enumToken(subject))"
    }

    /// The evidence locator every projected signature carries for
    /// `factID`: `kgfact:<fact id>` — the signature's back-pointer to the
    /// KGFact it was projected from.
    ///
    /// One source of truth on purpose. `ConflictSweepCore.run` joins
    /// signatures back to their facts through this exact string to read
    /// each fact's own adjective sensitivity. If the projection site and
    /// the sweep built the format independently and ever drifted, every
    /// join would miss — and because an unresolvable sensitivity fails
    /// closed, every finding in the estate would silently redact to
    /// `.secret` with no error anywhere. Sharing one function makes that
    /// divergence unrepresentable.
    public static func evidenceLocator(forFactID factID: String) -> String {
        "kgfact:\(factID)"
    }

    /// Project `facts` into signatures under `registry`.
    ///
    /// - Parameters:
    ///   - facts: The scanned KGFacts (any state; filtering happens here
    ///     so the exclusion counts are visible in one place).
    ///   - eventTimeSecondsBySourceDrawer: Source-drawer event times in
    ///     EPOCH SECONDS (M0 §3 temporal bytes are `t:pt:<epoch-secs>`).
    ///     The caller owns the units conversion at the estate seam — the
    ///     Rust drawer clock is epoch-millisecond, so the twin divides
    ///     there, and this parameter name carries the unit to keep the
    ///     KI-003 ms/secs trap out of this layer. A drawer absent from
    ///     the map projects with `.unknown` validity (M0 §5).
    ///   - registry: The rule registry (v0.1 in production; tests may
    ///     pass bespoke registries).
    public static func project(
        facts: [KGFact],
        eventTimeSecondsBySourceDrawer: [String: Int64],
        registry: ConflictRuleRegistry
    ) -> ConflictProjectionResult {
        var diagnostics = ConflictProjectionDiagnostics()
        var signatures: [ConflictSignature] = []
        signatures.reserveCapacity(facts.count)

        for fact in facts {
            diagnostics.scanned += 1
            guard fact.state == .active else {
                diagnostics.inactive += 1
                continue
            }
            let dimension = ConflictNormalize.dimensionKey(fact.predicate)
            guard let rule = registry.rule(forDimension: dimension) else {
                diagnostics.unregistered += 1
                continue
            }
            guard let value = rule.normalize(fact.object) else {
                diagnostics.unparsed += 1
                continue
            }
            let validity: TemporalBasis
            if let seconds = eventTimeSecondsBySourceDrawer[fact.sourceDrawerID] {
                validity = .point(epochSeconds: seconds)
            } else {
                validity = .unknown
            }
            diagnostics.projected += 1
            signatures.append(ConflictSignature(
                key: conflictKey(ruleID: rule.ruleID, subject: fact.subject),
                dimension: rule.dimension,
                value: value,
                sourceDrawerID: fact.sourceDrawerID,
                // Transaction time is the fact's filing instant, floored
                // to whole seconds to match the Rust twin's integer clock.
                transactionTime: Int64(fact.filedAt.timeIntervalSince1970.rounded(.down)),
                validity: validity,
                status: .asserted,
                ruleID: rule.ruleID,
                ruleVersion: rule.version,
                extractorID: nil,
                evidenceLocator: Self.evidenceLocator(forFactID: fact.id)))
        }
        return ConflictProjectionResult(signatures: signatures, diagnostics: diagnostics)
    }
}

/// In-memory coordinate index: signatures bucketed by (key, dimension).
/// Evaluation is pairwise WITHIN a bucket only — two claims on different
/// coordinates are Irrelevant by construction and never meet. Bucket
/// membership is insertion-ordered and the pair walk is deterministic.
public struct ConflictCoordinateIndex: Sendable {

    /// Per-bucket signature cap (M0 §7 `truncated_buckets`). A coordinate
    /// with more claims than this keeps its FIRST `bucketCap` signatures
    /// in insertion order and reports the bucket as truncated (F16) —
    /// bounded work, visible loss, never a silent sample.
    public static let defaultBucketCap = 64

    public let bucketCap: Int
    /// Buckets keyed by `<key>|<dimension>`, insertion-ordered values.
    private(set) var buckets: [String: [ConflictSignature]] = [:]
    /// Bucket keys that hit the cap, in first-truncation order.
    private(set) public var truncatedBucketKeys: [String] = []

    public init(bucketCap: Int = ConflictCoordinateIndex.defaultBucketCap) {
        self.bucketCap = bucketCap
    }

    /// Number of buckets currently truncated (report line: only when > 0).
    public var truncatedBuckets: Int { truncatedBucketKeys.count }

    /// Coordinate bucket key for a signature.
    public static func bucketKey(_ signature: ConflictSignature) -> String {
        "\(signature.key)|\(signature.dimension)"
    }

    /// Insert one signature; drops it (and marks the bucket truncated)
    /// when the bucket is full.
    public mutating func insert(_ signature: ConflictSignature) {
        let key = Self.bucketKey(signature)
        var bucket = buckets[key] ?? []
        guard bucket.count < bucketCap else {
            if !truncatedBucketKeys.contains(key) {
                truncatedBucketKeys.append(key)
            }
            return
        }
        bucket.append(signature)
        buckets[key] = bucket
    }

    /// Insert many, in order.
    public mutating func insert(contentsOf signatures: [ConflictSignature]) {
        for signature in signatures { insert(signature) }
    }

    /// All within-bucket unordered pairs, deterministically ordered:
    /// buckets by sorted bucket key, pairs by (i, j) insertion index.
    /// Self-pairs from the same source drawer are skipped — one drawer
    /// restating its own claim is not a conflict candidate.
    public func pairs() -> [(a: ConflictSignature, b: ConflictSignature)] {
        var result: [(a: ConflictSignature, b: ConflictSignature)] = []
        for key in buckets.keys.sorted() {
            let bucket = buckets[key]!
            guard bucket.count >= 2 else { continue }
            for i in 0..<(bucket.count - 1) {
                for j in (i + 1)..<bucket.count {
                    guard bucket[i].sourceDrawerID != bucket[j].sourceDrawerID
                    else { continue }
                    result.append((a: bucket[i], b: bucket[j]))
                }
            }
        }
        return result
    }
}
