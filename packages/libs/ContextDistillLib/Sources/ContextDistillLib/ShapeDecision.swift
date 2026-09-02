import Foundation

/// Content-only structural classification with auditable evidence.
///
/// A direct port of ``record_shape_classifier.ShapeDecision`` (Python frozen dataclass).
/// All fields carry the same semantics and names as in the Python reference so that
/// JSON-encoded output can be compared byte-for-byte against the oracle vectors.
///
/// ``Equatable`` conformance lets tests assert structure directly.
/// ``Sendable`` is required for Swift 6 strict concurrency.
public struct ShapeDecision: Sendable, Equatable {

    /// Primary shape label: one of "dialogue", "timeline", "outline",
    /// "entity_dense", "prose", or "hybrid" when two or more structural
    /// labels are active simultaneously.
    public let primary: String

    /// Ordered label tuple.  When primary is "hybrid", the first element is
    /// "hybrid" and the remainder are the active labels sorted by score
    /// descending then alphabetically.  Otherwise this is the same sorted
    /// active list.
    ///
    /// Mirrors ``labels: tuple[str, ...]`` in the Python dataclass.
    public let labels: [String]

    /// Raw score for each of the five candidate shapes.  Keys are exactly:
    /// "dialogue", "timeline", "outline", "entity_dense", "prose".
    ///
    /// Mirrors ``scores: dict[str, int]`` in the Python dataclass.
    public let scores: [String: Int]

    /// Observable document-topology features used to derive the scores.
    /// Keys and semantics match the ``features`` dict in the Python dataclass.
    public let features: [String: Int]

    /// Difference between the highest and second-highest raw score.
    /// Mirrors ``confidence_margin: int`` in the Python dataclass.
    public let confidenceMargin: Int

    /// Returns true when ``label`` appears in ``labels``.
    /// Mirrors ``ShapeDecision.has(label)`` in Python.
    public func has(_ label: String) -> Bool { labels.contains(label) }

    /// Produces a Foundation-compatible dictionary matching Python's ``as_dict()``.
    ///
    /// The keys are "primary", "labels", "scores", "features", and
    /// "confidence_margin" (snake_case, matching the Python reference).
    /// Values use Swift types that ``JSONSerialization`` encodes identically
    /// to Python's ``json.dumps``.
    public func asDict() -> [String: Any] {
        [
            "primary": primary,
            "labels": labels,
            "scores": scores,
            "features": features,
            "confidence_margin": confidenceMargin,
        ]
    }

    /// Produces a canonical JSON string (sorted keys, no extra whitespace).
    ///
    /// Used by the conformance test suite to compare against oracle vectors.
    public func canonicalJSON() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: asDict(),
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8)!
    }
}
