// ContextDistiller.swift
// Part 5: full-row assembly for the intent-span candidate.
//
// Ports the intent-span branch of candidate_rows() from distill_plus_converter.py,
// plus the _combine() helper and the DistilledRepresentation output type.
//
// Public entry points:
//   DistilledRepresentation — Codable output value (exact oracle key names)
//   ContextDistiller.distill(_:converter:) — assembles the full output row
//   combine(_:trailer:) — mirrors Python's _combine(core, trailer)
//
// Design rules (from the decision record):
//   - NO regex engine. All pattern matching is hand-written character scanners.
//   - Index unit: unicodeScalars (code points).
//   - Python integer semantics: truncating division (same as Swift for non-negative).
//   - No Date(), no randomness. Pure functions.
//   - Zero external dependencies: Foundation + CryptoKit only.

import Foundation

// MARK: - combine

/// Concatenates core text and a projected trailer with a single space separator.
///
/// Mirrors Python's ``_combine``:
/// ```python
/// def _combine(core: str, trailer: str) -> str:
///     if core and trailer:
///         return f"{core} {trailer}"
///     return core or trailer
/// ```
///
/// Returns `core + " " + trailer` when both are non-empty, otherwise whichever
/// is non-empty (or an empty string when both are empty).
public func combine(_ core: String, trailer: String) -> String {
    if !core.isEmpty && !trailer.isEmpty {
        return "\(core) \(trailer)"
    }
    return core.isEmpty ? trailer : core
}

// MARK: - DistilledRepresentation

/// Full output row produced by the intent-span converter for one estate record.
///
/// Field names use snake_case matching the oracle JSONL keys exactly so that
/// canonical-JSON comparison against oracle rows is field-by-field exact.
///
/// ``@unchecked Sendable`` is safe: all Foundation collection properties
/// (NSArray, NSDictionary, NSString) come from JSONSerialization and are
/// immutable after construction. ``Equatable`` conformance compares via
/// canonical JSON so nested [String: Any] fields are compared correctly.
///
/// Mirrors the intent-span branch of ``candidate_rows()`` in distill_plus_converter.py.
public struct DistilledRepresentation: @unchecked Sendable, Equatable {

    // MARK: Identity fields

    /// Schema version integer. Mirrors ``schema_version: 1``.
    public let schemaVersion: Int

    /// Converter ruleset label. Mirrors ``converter_version``.
    public let converterVersion: String

    /// Ruleset version string for this candidate.
    /// Mirrors ``ruleset_version``: ``INTENT_SPAN_VERSION`` for intent-span.
    public let rulesetVersion: String

    /// Fully-qualified converter identifier.
    /// Mirrors ``converter_id: f"{candidate}@{candidate_ruleset}"``.
    public let converterID: String

    /// SHA-256 hex digest of the original source text encoded as UTF-8.
    /// Mirrors ``source_sha256: source_digest(record.content)``.
    public let sourceSHA256: String

    // MARK: Content fields

    /// Structural shape classification for the source text.
    /// Mirrors ``shape: decision.as_dict()``.
    public let shape: [String: Any]

    /// Offset unit label for selected_source_spans start/end fields.
    /// Always "unicode-code-point". Mirrors ``span_offset_unit``.
    public let spanOffsetUnit: String

    /// Offset unit label for start_utf8_byte/end_utf8_byte fields.
    /// Always "byte". Mirrors ``span_utf8_offset_unit``.
    public let spanUTF8OffsetUnit: String

    /// Per-span metadata for selected atoms in source order.
    /// Each dict has: atom_id, start, end, kind, speaker, dependencies,
    /// hard_required, start_utf8_byte, end_utf8_byte.
    /// Mirrors ``selected_source_spans: _portable_span_offsets(source, spans)``.
    public let selectedSourceSpans: [[String: Any]]

    /// Exact source-atom concatenation (the core text before trailer).
    /// Mirrors ``compact_core``.
    public let compactCore: String

    /// Projected trailer string actually applied (may be empty).
    /// Mirrors ``applied_enrichment_trailer``.
    public let appliedEnrichmentTrailer: String

    /// Combined text for AI consumption: compact_core + " " + applied_enrichment_trailer.
    /// Mirrors ``ai_text: _combine(intent_text, intent_trailer)``.
    public let aiText: String

    /// Same as ai_text for intent-span (both use the combined text).
    /// Mirrors ``mining_body``.
    public let miningBody: String

    // MARK: Metrics

    /// Eight integer metrics for size and compression accounting.
    /// Keys: original_bytes, original_tokens_est, core_bytes, trailer_bytes,
    ///       applied_trailer_bytes, distilled_bytes, distilled_tokens_est,
    ///       compression_ratio_ppm.
    /// Mirrors ``metrics`` dict in candidate_rows().
    public let metrics: [String: Any]

    // MARK: Selection details

    /// Full selection metadata dict including trailer_projection.
    /// Mirrors ``selection_details: details`` from intent_span().
    public let selectionDetails: [String: Any]

    // MARK: - asDict

    /// Produces the [String: Any] dictionary representation with exact oracle key names.
    ///
    /// The returned dictionary can be passed to JSONSerialization for canonical-JSON
    /// comparison against oracle rows. All keys match the oracle JSONL schema exactly.
    public func asDict() -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "converter_version": converterVersion,
            "ruleset_version": rulesetVersion,
            "converter_id": converterID,
            "source_sha256": sourceSHA256,
            "shape": shape,
            "span_offset_unit": spanOffsetUnit,
            "span_utf8_offset_unit": spanUTF8OffsetUnit,
            "selected_source_spans": selectedSourceSpans,
            "compact_core": compactCore,
            "applied_enrichment_trailer": appliedEnrichmentTrailer,
            "ai_text": aiText,
            "mining_body": miningBody,
            "metrics": metrics,
            "selection_details": selectionDetails,
        ]
    }

    // MARK: - Equatable

    /// Compares by canonical JSON to handle [String: Any] fields correctly.
    public static func == (lhs: DistilledRepresentation, rhs: DistilledRepresentation) -> Bool {
        let lData = try? JSONSerialization.data(
            withJSONObject: lhs.asDict(), options: [.sortedKeys])
        let rData = try? JSONSerialization.data(
            withJSONObject: rhs.asDict(), options: [.sortedKeys])
        return lData == rData
    }
}

// MARK: - DistilledRepresentation + Encodable

extension DistilledRepresentation: Encodable {
    /// Encoding key names match the oracle JSONL schema exactly (snake_case).
    public enum CodingKeys: String, CodingKey {
        case schemaVersion          = "schema_version"
        case converterVersion       = "converter_version"
        case rulesetVersion         = "ruleset_version"
        case converterID            = "converter_id"
        case sourceSHA256           = "source_sha256"
        case shape
        case spanOffsetUnit         = "span_offset_unit"
        case spanUTF8OffsetUnit     = "span_utf8_offset_unit"
        case selectedSourceSpans    = "selected_source_spans"
        case compactCore            = "compact_core"
        case appliedEnrichmentTrailer = "applied_enrichment_trailer"
        case aiText                 = "ai_text"
        case miningBody             = "mining_body"
        case metrics
        case selectionDetails       = "selection_details"
    }

    /// Encodes the representation.
    ///
    /// Primitive fields use the standard Codable path. The [String: Any] fields
    /// (shape, selectedSourceSpans, metrics, selectionDetails) are first
    /// serialised via JSONSerialization, then decoded into the JSONAny recursive
    /// enum, then re-encoded through Swift's Codable system. This two-step
    /// round-trip is the standard Foundation-only approach for encoding
    /// [String: Any] through JSONEncoder without external dependencies.
    ///
    /// Note: the approach preserves all numeric precision that Foundation's
    /// JSONSerialization uses (NSNumber maps to Int when the value fits, to
    /// Double otherwise). Both encoder paths (JSONEncoder and JSONSerialization
    /// directly) produce numerically identical output because NSNumber encodes
    /// in the same way in both contexts.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion,            forKey: .schemaVersion)
        try c.encode(converterVersion,         forKey: .converterVersion)
        try c.encode(rulesetVersion,           forKey: .rulesetVersion)
        try c.encode(converterID,              forKey: .converterID)
        try c.encode(sourceSHA256,             forKey: .sourceSHA256)
        try c.encode(spanOffsetUnit,           forKey: .spanOffsetUnit)
        try c.encode(spanUTF8OffsetUnit,       forKey: .spanUTF8OffsetUnit)
        try c.encode(compactCore,              forKey: .compactCore)
        try c.encode(appliedEnrichmentTrailer, forKey: .appliedEnrichmentTrailer)
        try c.encode(aiText,                   forKey: .aiText)
        try c.encode(miningBody,               forKey: .miningBody)

        // Encode [String: Any] fields via the JSONAny intermediary.
        let shapeData      = try JSONSerialization.data(withJSONObject: shape,              options: [.sortedKeys])
        let spansData      = try JSONSerialization.data(withJSONObject: selectedSourceSpans, options: [.sortedKeys])
        let metricsData    = try JSONSerialization.data(withJSONObject: metrics,             options: [.sortedKeys])
        let detailsData    = try JSONSerialization.data(withJSONObject: selectionDetails,    options: [.sortedKeys])

        let jsonDecoder = JSONDecoder()
        let shapeAny      = try jsonDecoder.decode(JSONAny.self, from: shapeData)
        let spansAny      = try jsonDecoder.decode([JSONAny].self, from: spansData)
        let metricsAny    = try jsonDecoder.decode(JSONAny.self, from: metricsData)
        let detailsAny    = try jsonDecoder.decode(JSONAny.self, from: detailsData)

        try c.encode(shapeAny,   forKey: .shape)
        try c.encode(spansAny,   forKey: .selectedSourceSpans)
        try c.encode(metricsAny, forKey: .metrics)
        try c.encode(detailsAny, forKey: .selectionDetails)
    }
}

// MARK: - JSONAny: recursive JSON value for Codable round-trip

/// Recursive JSON value type used to carry Foundation's [String: Any] through
/// Swift's Codable system. Foundation's JSONSerialization emits NSNumber, NSString,
/// NSArray, and NSDictionary; JSONAny captures all four cases plus null.
///
/// This is a local utility, not a public API. It exists solely to support
/// DistilledRepresentation.encode(to:) without external dependencies.
enum JSONAny: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONAny])
    case object([String: JSONAny])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONAny].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONAny].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "JSONAny: unrecognised JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - ContextDistiller

/// Assembles the full intent-span output row for one estate record.
///
/// Mirrors the intent-span branch of ``candidate_rows()`` in distill_plus_converter.py.
/// All computation is deterministic and pure: no Date(), no randomness, no I/O.
///
/// ``Sendable`` because the struct has no mutable state.
public struct ContextDistiller: Sendable {

    /// Creates a new distiller. No configuration is required; all parameters
    /// are passed per-call to `distill(_:converter:)`.
    public init() {}

    /// Distils one estate record into the full intent-span representation.
    ///
    /// - Parameters:
    ///   - input: Source text and raw enrichment trailer (split before this call).
    ///   - converter: The converter variant to apply. Pass
    ///     ``ContextDistillConverter/completeFormV6`` for complete compaction,
    ///     or ``ContextDistillConverter/intentSpanV23Attributed`` for
    ///     the v23.2 attributed peer-dialogue converter.
    /// - Returns: A ``DistilledRepresentation`` whose fields match the oracle
    ///   JSONL schema for the chosen converter.
    ///
    /// Mirrors Python:
    /// ```python
    /// intent_text, intent_spans, intent_details, intent_trailer = intent_span(
    ///     record.content, trailer)
    /// combined = _combine(intent_text, intent_trailer)
    /// ```
    /// `boundedSelection` is for recall after its source-byte admission check.
    /// It preserves the complete source core if selector budgets are exhausted.
    /// Offline callers retain the frozen recipe by leaving this false.
    public func distill(
        _ input: DistillationInput,
        converter: ContextDistillConverter,
        boundedSelection: Bool = false
    ) -> DistilledRepresentation {
        let source = input.original
        let trailer = input.enrichmentTrailer
        if converter == .completeFormV6 {
            return completeRepresentation(input, converter: converter)
        }

        // --- Shape classification ---
        // Mirrors Python: decision = classify_record(record.content)
        let shape = ContextShape.classify(source)

        // --- Intent-span selection ---
        // Mirrors Python: intent_text, intent_spans, intent_details, intent_trailer
        //                 = intent_span(record.content, trailer)
        let useAttributedPeerDialogue = converter == .intentSpanV23Attributed
        let spanResult = intentSpan(
            source,
            trailer: trailer,
            peerDialogue: useAttributedPeerDialogue,
            bounded: boundedSelection
        )
        var intentText    = spanResult.core
        let intentSpans   = spanResult.selectedSpans
        var intentDetails = spanResult.selectionDetails
        let intentTrailer = spanResult.projectedTrailer

        if useAttributedPeerDialogue {
            if intentDetails["mode"] as? String == "peer-dialogue" {
                intentText = renderPeerAttributedProse(intentText)
                intentDetails["rendering"] = "inline-attributed-prose"
            } else {
                intentDetails["rendering"] = "source-exact"
            }
        }

        // --- _combine ---
        // Mirrors Python: combined = _combine(intent_text, intent_trailer)
        let combined = combine(intentText, trailer: intentTrailer)

        // --- metrics ---
        // Mirrors Python: metrics dict inside candidate_rows().
        // trailer_bytes is the raw input trailer size (before projection).
        // applied_trailer_bytes is the projected trailer size.
        let originalBytes       = source.utf8.count
        let coreBytes           = intentText.utf8.count
        let trailerBytes        = trailer.utf8.count
        let appliedTrailerBytes = intentTrailer.utf8.count
        let distilledBytes      = combined.utf8.count
        // compression_ratio_ppm: combined_bytes * 1_000_000 // original_bytes (Python //).
        // Python guard: if original_bytes else 0.
        let compressionRatioPPM = originalBytes > 0
            ? distilledBytes * 1_000_000 / originalBytes
            : 0

        let metrics: [String: Any] = [
            "original_bytes":        originalBytes,
            "original_tokens_est":   estimateTokens(source),
            "core_bytes":            coreBytes,
            "trailer_bytes":         trailerBytes,
            "applied_trailer_bytes": appliedTrailerBytes,
            "distilled_bytes":       distilledBytes,
            "distilled_tokens_est":  estimateTokens(combined),
            "compression_ratio_ppm": compressionRatioPPM,
        ]

        // --- source_sha256 ---
        // Mirrors Python: digest = source_digest(record.content)
        let digest = sourceDigest(source)

        // --- converter identity fields ---
        // Mirrors Python:
        //   candidate_ruleset = INTENT_SPAN_VERSION  (for intent-span)
        //   converter_id = f"{candidate}@{candidate_ruleset}"
        // ContextDistillConverter.id = "intent-span@intent-span-v22-authority-closure"
        // rulesetVersion is the part after "@".
        let parts = converter.id.split(separator: "@", maxSplits: 1)
        let candidateRuleset = parts.count == 2 ? String(parts[1]) : converter.id

        return DistilledRepresentation(
            schemaVersion:             converter.schemaVersion,
            converterVersion:          converter.converterVersion,
            rulesetVersion:            candidateRuleset,
            converterID:               converter.id,
            sourceSHA256:              digest,
            shape:                     shape.asDict(),
            spanOffsetUnit:            "unicode-code-point",
            spanUTF8OffsetUnit:        "byte",
            selectedSourceSpans:       intentSpans,
            compactCore:               intentText,
            appliedEnrichmentTrailer:  intentTrailer,
            aiText:                    combined,
            miningBody:                combined,
            metrics:                   metrics,
            selectionDetails:          intentDetails
        )
    }

    /// Complete-form compaction never selects away source passages. Reserved
    /// representation collisions fail unchanged rather than losing a record.
    private func completeRepresentation(
        _ input: DistillationInput, converter: ContextDistillConverter
    ) -> DistilledRepresentation {
        let source = input.original
        let reduced = try? CompleteContentReducer.distill(source)
        let core = reduced?.text ?? source
        let trailer = input.enrichmentTrailer
        let combined = combine(core, trailer: trailer)
        let bytes = source.utf8.count
        return DistilledRepresentation(
            schemaVersion: converter.schemaVersion,
            converterVersion: converter.converterVersion,
            rulesetVersion: "complete-form-visible-v6",
            converterID: converter.id, sourceSHA256: sourceDigest(source),
            shape: ContextShape.classify(source).asDict(),
            spanOffsetUnit: "unicode-code-point", spanUTF8OffsetUnit: "byte",
            selectedSourceSpans: source.isEmpty ? [] : [[
                "start": 0, "end": source.unicodeScalars.count,
                "start_utf8_byte": 0, "end_utf8_byte": bytes,
                "kind": "complete-source"
            ]],
            compactCore: core, appliedEnrichmentTrailer: trailer,
            aiText: combined, miningBody: combined,
            metrics: ["original_bytes": bytes, "original_tokens_est": estimateTokens(source),
                      "core_bytes": core.utf8.count, "trailer_bytes": trailer.utf8.count,
                      "applied_trailer_bytes": trailer.utf8.count,
                      "distilled_bytes": combined.utf8.count,
                      "distilled_tokens_est": estimateTokens(combined),
                      "compression_ratio_ppm": bytes == 0 ? 0 : combined.utf8.count * 1_000_000 / bytes],
            selectionDetails: ["mode": "complete-form", "complete": true,
                               "rendering": "complete-form-visible-v6",
                               "count_unit": "tokens_estimate", "model_assistance": false,
                               "fallback_unchanged": reduced == nil])
    }
}
