import Foundation

// GauntletRNG.swift — the deterministic seeded PRNG for the adversarial corpus
// generator (Phase 2 of MOOT_RETRIEVAL_GAUNTLET_PLAN.md).
//
// SplitMix64 is the chosen generator (the plan names it explicitly): a tiny,
// well-distributed 64-bit splittable generator with a single 64-bit state. It
// is the reference Java 8 SplittableRandom mixing function, reproduced here so
// the corpus is byte-identical across runs and across machines for a given
// seed. Determinism is the whole point — the seed appears in every output
// filename and report header, and "same seed → byte-identical corpus" is a
// hard test gate. A platform RNG (SystemRandomNumberGenerator) would NOT be
// reproducible and is therefore unusable here.
//
// The constants are the canonical SplitMix64 constants: the 0x9E3779B97F4A7C15
// increment is the 64-bit golden-ratio odd constant (Weyl sequence step), and
// 0xBF58476D1CE4E5B9 / 0x94D049BB133111EB are the published mixing multipliers.
// Do not "tidy" these — they are load-bearing magic numbers, and changing any
// of them changes every corpus this tool has ever emitted.

/// A deterministic SplitMix64 pseudo-random generator. Conforms to
/// `RandomNumberGenerator` so it can drive `shuffled(using:)` and the standard
/// `random(in:using:)` helpers, but every draw is reproducible from the seed.
///
/// Not thread-safe by design: a single generator threads through one
/// generation pass sequentially, which is what guarantees reproducibility.
struct SplitMix64: RandomNumberGenerator {
    /// The 64-bit internal state. Advances by the golden-ratio increment on
    /// every draw (a full-period Weyl sequence), then is mixed to the output.
    private var state: UInt64

    /// The seed this generator was created from, retained so callers can stamp
    /// it into output filenames and report headers without tracking it
    /// separately.
    let seed: UInt64

    /// Creates a generator seeded with `seed`. Two generators with the same
    /// seed produce the identical sequence of draws.
    init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    /// Returns the next 64-bit value and advances the state. The body is the
    /// canonical SplitMix64 `next()`: advance the Weyl state, then apply the
    /// two-stage xor-shift-multiply finalizer.
    mutating func next() -> UInt64 {
        // Advance the Weyl sequence by the golden-ratio odd increment. The
        // wrapping add is the full 2^64 period; overflow is intended.
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        // Two published mixing rounds: xor-shift right 30 then multiply, again
        // with shift 27, then a final shift 31. These give SplitMix64 its
        // avalanche (each input bit affects ~half the output bits).
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Returns an integer uniformly in `0..<bound` (bound > 0). Uses the
    /// rejection-free Lemire-style reduction over the 64-bit draw: a single
    /// multiply-and-shift maps the draw into the range with negligible bias for
    /// the small bounds this generator is asked for (tier counts, index picks).
    /// A truncated-modulo would introduce a tiny bias the conformance tests do
    /// not need; this multiply-high mapping is both fast and bias-minimal.
    mutating func upTo(_ bound: Int) -> Int {
        precondition(bound > 0, "upTo bound must be positive")
        let draw = next()
        // Multiply-high: (draw * bound) >> 64, computed via the 128-bit product.
        let product = draw.multipliedFullWidth(by: UInt64(bound))
        return Int(product.high)
    }
}
