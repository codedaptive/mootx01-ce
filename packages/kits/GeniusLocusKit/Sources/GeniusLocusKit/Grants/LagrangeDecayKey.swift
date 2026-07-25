import Foundation
import SubstrateKernel

// MARK: - Clean-room provenance (load-bearing legal text — do not edit)
//
// Custody mode 3 is implemented clean-room from the algorithmic
// description in Darwish and Zarras, "Digital Forgetting Using Key
// Decay," ACM SAC 2023, DOI: 10.1145/3555776.3577641, licensed CC BY
// 4.0. No code from the authors' Python prototype is used or
// referenced. The implementation derives from the published algorithmic
// description only. The activating party's
// `experimentalIPClearanceConfirmed: true` assertion is recorded in the
// grant audit record and is their legal responsibility, not the
// substrate's. See federation disclosure controls
// Appendix B.3 and B.8.

/// A 256-bit field element in GF(p), the prime field custody mode 3's
/// Lagrange reconstruction runs over.
///
/// ## Why a prime field, not floating point
/// Threshold reconstruction must be exact: the same K-of-N shares must
/// reconstruct the identical secret on any platform, with no rounding.
/// Lagrange interpolation needs division, which only closes over a
/// field; the integers do not. So the math runs in GF(p).
///
/// ## Why p = 2²⁵⁶ − 189
/// `p = 2^256 - 189` is the largest prime below 2²⁵⁶. It is chosen for
/// two reasons. (1) Field elements are full 256-bit values, so the
/// reconstructed secret carries up to 256 bits of entropy before it is
/// hashed to the scope key — matching ENC-01's AES-256 key width with
/// no entropy bottleneck imposed by the field. (2) It is a
/// pseudo-Mersenne prime: because `2^256 ≡ 189 (mod p)`, reducing a
/// wide product is a cheap fold (multiply the high half by 189 and add
/// it back), avoiding a general division. Arithmetic is built from
/// `multipliedFullWidth` / `addingReportingOverflow` on `UInt64` limbs
/// so it carries no dependency on the `UInt128` stdlib type (which is
/// gated to newer OS versions than this package's deployment floor).
///
/// Stored as four little-endian `UInt64` limbs (`limbs[0]` least
/// significant), always normalized to the range `[0, p)`.
struct DecayFieldElement: Sendable, Equatable {

    /// Four little-endian 64-bit limbs, always `< p`.
    fileprivate let limbs: [UInt64]

    /// p = 2²⁵⁶ − 189, little-endian. limb0 = 0xFFFF…FF43 because
    /// (2²⁵⁶ − 1) − 188 = 2²⁵⁶ − 189 and 0xFF − 0xBC = 0x43.
    fileprivate static let prime: [UInt64] = [
        0xFFFF_FFFF_FFFF_FF43,
        0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF
    ]

    /// The fold constant: 2²⁵⁶ ≡ `reductionConstant` (mod p).
    fileprivate static let reductionConstant: UInt64 = 189

    /// p − 2, the Fermat inverse exponent (aᵖ⁻² = a⁻¹ in GF(p)).
    /// p − 2 = 2²⁵⁶ − 191; limb0 = 0xFF − 0xBE = 0x41.
    fileprivate static let primeMinusTwo: [UInt64] = [
        0xFFFF_FFFF_FFFF_FF41,
        0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF
    ]

    static let zero = DecayFieldElement(normalized: [0, 0, 0, 0])
    static let one = DecayFieldElement(normalized: [1, 0, 0, 0])

    /// Construct from already-normalized limbs (`< p`, exactly 4).
    private init(normalized limbs: [UInt64]) {
        self.limbs = limbs
    }

    /// Reduce arbitrary-width little-endian limbs into `[0, p)`.
    init(reducing wide: [UInt64]) {
        self.limbs = DecayFieldElement.reduce(wide)
    }

    /// Construct from a small unsigned integer.
    init(_ value: UInt64) {
        self.init(reducing: [value, 0, 0, 0])
    }

    /// Interpret 32 big-endian bytes as an integer and reduce mod p.
    /// Used to seed the secret and polynomial coefficients from a hash.
    init(reducingBigEndian data: Data) {
        var limbs = [UInt64](repeating: 0, count: 4)
        // Big-endian bytes: the first byte is most significant. Pack into
        // little-endian limbs (limb 0 holds the least-significant 8 bytes).
        let bytes = [UInt8](data)
        for (offset, byte) in bytes.reversed().enumerated() where offset < 32 {
            let limbIndex = offset / 8
            let shift = UInt64((offset % 8) * 8)
            limbs[limbIndex] |= UInt64(byte) << shift
        }
        self.init(reducing: limbs)
    }

    /// The element as 32 big-endian bytes (fixed width, zero-padded).
    func bigEndianBytes() -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        for limbIndex in 0..<4 {
            let limb = limbs[limbIndex]
            for byteInLimb in 0..<8 {
                let value = UInt8((limb >> UInt64(byteInLimb * 8)) & 0xFF)
                // Most-significant limb/byte goes to the front of `out`.
                let bigEndianIndex = 31 - (limbIndex * 8 + byteInLimb)
                out[bigEndianIndex] = value
            }
        }
        return Data(out)
    }

    // MARK: Field operations

    func adding(_ other: DecayFieldElement) -> DecayFieldElement {
        // Sum is < 2p; carry out of the 256-bit add is folded as 189.
        let (sum, carry) = DecayFieldElement.addLimbs(limbs, other.limbs)
        return DecayFieldElement(reducing: sum + [carry])
    }

    func subtracting(_ other: DecayFieldElement) -> DecayFieldElement {
        // a − b in [0, p): if a ≥ b a plain subtract suffices, otherwise
        // add p first so the result stays non-negative.
        if DecayFieldElement.greaterOrEqual(limbs, other.limbs) {
            let (diff, _) = DecayFieldElement.subLimbs(limbs, other.limbs)
            return DecayFieldElement(normalized: diff)
        }
        let (aPlusP, carry) = DecayFieldElement.addLimbs(limbs, DecayFieldElement.prime)
        let (diff, _) = DecayFieldElement.subLimbs(aPlusP, other.limbs)
        // a + p − b with a < b < p is in (0, p), so the carry limb is 0
        // after the subtraction; reduce defensively in case carry was set.
        return DecayFieldElement(reducing: diff + [carry])
    }

    func negated() -> DecayFieldElement {
        DecayFieldElement.zero.subtracting(self)
    }

    func multiplying(_ other: DecayFieldElement) -> DecayFieldElement {
        DecayFieldElement(reducing: DecayFieldElement.mulFull(limbs, other.limbs))
    }

    /// Multiplicative inverse via Fermat's little theorem: a⁻¹ = aᵖ⁻².
    /// Defined for every nonzero element of GF(p).
    func inverse() -> DecayFieldElement {
        DecayFieldElement.pow(self, DecayFieldElement.primeMinusTwo)
    }

    // MARK: - Limb arithmetic primitives

    /// Add two equal-length little-endian limb arrays; returns the sum and
    /// the carry out of the top limb.
    private static func addLimbs(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
        precondition(a.count == b.count)
        var result = [UInt64](repeating: 0, count: a.count)
        var carry: UInt64 = 0
        for index in 0..<a.count {
            let (s1, o1) = a[index].addingReportingOverflow(b[index])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result[index] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (result, carry)
    }

    /// Subtract `b` from `a` (equal length); returns the difference and the
    /// borrow out of the top limb (1 if `a < b`).
    private static func subLimbs(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
        precondition(a.count == b.count)
        var result = [UInt64](repeating: 0, count: a.count)
        var borrow: UInt64 = 0
        for index in 0..<a.count {
            let (d1, o1) = a[index].subtractingReportingOverflow(b[index])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result[index] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (result, borrow)
    }

    /// `a >= b` for 4-limb little-endian values.
    private static func greaterOrEqual(_ a: [UInt64], _ b: [UInt64]) -> Bool {
        for index in stride(from: a.count - 1, through: 0, by: -1) {
            if a[index] != b[index] { return a[index] > b[index] }
        }
        return true
    }

    /// Multiply a little-endian limb array by a 64-bit scalar; returns the
    /// product with a trailing carry limb appended.
    private static func scalarMul(_ a: [UInt64], _ scalar: UInt64) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: a.count + 1)
        var carry: UInt64 = 0
        for index in 0..<a.count {
            let (hi, lo) = a[index].multipliedFullWidth(by: scalar)
            let (s1, o1) = lo.addingReportingOverflow(carry)
            result[index] = s1
            carry = hi &+ (o1 ? 1 : 0)
        }
        result[a.count] = carry
        return result
    }

    /// Add two little-endian arrays of possibly different lengths; returns
    /// the full sum (length = max + 1 to hold any final carry).
    private static func addVarLength(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let n = Swift.max(a.count, b.count)
        var result = [UInt64](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for index in 0..<n {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            let (s1, o1) = av.addingReportingOverflow(bv)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result[index] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        result[n] = carry
        return result
    }

    /// Schoolbook 4×4-limb multiply producing an 8-limb product. Each
    /// 64×64 partial product is taken at full 128-bit width via
    /// `multipliedFullWidth`, then accumulated with explicit carries.
    private static func mulFull(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            for j in 0..<b.count {
                let (hi, lo) = a[i].multipliedFullWidth(by: b[j])
                // result[i+j] += lo + carry, then propagate hi into carry.
                let (s1, o1) = result[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            result[i + b.count] = result[i + b.count] &+ carry
        }
        return result
    }

    /// Reduce an arbitrary-width little-endian value into `[0, p)` using
    /// the pseudo-Mersenne identity `2²⁵⁶ ≡ 189 (mod p)`: fold every limb
    /// above the low four (which carry a factor of 2²⁵⁶) back into the low
    /// limbs multiplied by 189, repeating until only four limbs remain,
    /// then subtract p while the value is still ≥ p.
    private static func reduce(_ input: [UInt64]) -> [UInt64] {
        var value = input
        if value.count < 4 { value += [UInt64](repeating: 0, count: 4 - value.count) }
        while value.count > 4 {
            let low = Array(value[0..<4])
            let high = Array(value[4...])              // numeric value of the > 2²⁵⁶ part / 2²⁵⁶
            let folded = scalarMul(high, reductionConstant)  // high · 189, placed at limb 0
            value = addVarLength(low, folded)
            // Trim a leading zero limb so the loop makes progress.
            while value.count > 4 && value.last == 0 { value.removeLast() }
        }
        // Exactly four limbs now; value < 2²⁵⁶ < 2p, so at most a couple of
        // conditional subtractions are required.
        var result = Array(value[0..<4])
        while greaterOrEqual(result, prime) {
            let (diff, _) = subLimbs(result, prime)
            result = diff
        }
        return result
    }

    /// Modular exponentiation by square-and-multiply, MSB to LSB over the
    /// 256-bit exponent. Used only for the Fermat inverse.
    private static func pow(_ base: DecayFieldElement, _ exponent: [UInt64]) -> DecayFieldElement {
        var result = DecayFieldElement.one
        for limbIndex in stride(from: exponent.count - 1, through: 0, by: -1) {
            let limb = exponent[limbIndex]
            for bit in stride(from: 63, through: 0, by: -1) {
                result = result.multiplying(result)
                if (limb >> UInt64(bit)) & 1 == 1 {
                    result = result.multiplying(base)
                }
            }
        }
        return result
    }
}

/// One `(xᵢ, yᵢ)` share point on the secret-sharing polynomial.
struct DecaySharePoint: Sendable, Equatable {
    let x: DecayFieldElement
    let y: DecayFieldElement
}

/// Source of the K-of-N `(xᵢ, yᵢ)` shares custody mode 3 reconstructs the
/// scope key from, plus the count still valid at a given instant.
///
/// Appendix B.3 specifies the xi pool as "cryptographically random
/// estate-internal data that evolves at a predictable rate." The
/// substrate has no such live feed wired to the grant surface, so this
/// protocol is the injection seam: a conformance-testable reference
/// provider ships here; a production provider backed by real
/// estate-internal data is out of scope (ENC-03 candidate).
protocol DecayShareProvider: Sendable {
    /// N — the total number of shares the polynomial was split into.
    var totalShares: Int { get }

    /// All N share points. Drift consumes them from the tail: the first
    /// `validShareCount(now:)` points are the ones still recoverable.
    func sharePoints() -> [DecaySharePoint]

    /// How many of the N shares remain valid (uncorrupted) at `now`.
    func validShareCount(now: Date) -> Int
}

/// A deterministic, seeded reference `DecayShareProvider` for conformance
/// testing — NOT the production estate-internal data feed.
///
/// The polynomial's secret (constant term) and coefficients are derived
/// by SHA-256 from the injected `seed`, so a given `(seed, threshold,
/// totalShares)` always yields the identical secret — the property that
/// lets the issue path reconstruct the same scope key on demand. The
/// `seed` at the call site is bound to the estate identity key and the
/// grant id, so a mode-3 key is unique per grant.
///
/// Wiring a real "evolving estate-internal data" pool (Appendix B.3) is
/// explicitly out of scope for ENC-02; this reference provider models
/// drift on a fixed schedule keyed off `now` and the grant's `DriftRate`
/// so the threshold-crossing behavior is testable without a live feed.
///
/// Note: until ENC-03 lands a production share pool, this
/// struct IS the code that runs for mode-3 grants on confirmed IP
/// clearance — `ScopeKeyVault.issue` builds it on the live issue path. It
/// is "reference" in the sense that its shares are seeded deterministically
/// rather than drawn from an evolving estate-internal feed, not in the
/// sense of being test-only.
struct ReferenceDecayShareProvider: DecayShareProvider {

    let totalShares: Int
    /// K — the minimum number of valid shares needed to reconstruct.
    let threshold: Int
    let driftRate: DriftRate
    /// The instant the shares were minted (the grant's `issuedAt`); drift
    /// is measured forward from here.
    let createdAt: Date
    /// The reconstruction target: the polynomial evaluated at x = 0.
    /// Internal so conformance tests can assert the round-trip recovers it.
    let secret: DecayFieldElement

    private let points: [DecaySharePoint]

    /// Build the reference shares for `(threshold, totalShares, driftRate)`
    /// from `seed`. The degree-(K−1) polynomial has the seeded secret as
    /// its constant term; share i (for i in 1…N) is the polynomial
    /// evaluated at xᵢ = i.
    init(threshold: Int, totalShares: Int, driftRate: DriftRate, createdAt: Date, seed: Data) {
        self.threshold = threshold
        self.totalShares = totalShares
        self.driftRate = driftRate
        self.createdAt = createdAt

        // Coefficients c₀…c_{K-1}; c₀ is the secret. Each is a distinct
        // SHA-256 derivation off the seed so the polynomial is fixed by
        // the seed alone (deterministic reconstruction).
        var coefficients: [DecayFieldElement] = []
        for index in 0..<Swift.max(threshold, 1) {
            // Coefficient derivation uses the in-repo SHA-256 (SubstrateKernel.SHA256)
            // rather than CryptoKit. Both implement FIPS 180-4 and produce byte-identical
            // output, so this migration does not change the computed coefficients.
            let material = [UInt8](seed) + [UInt8]("decay-coef-\(index)".utf8)
            let digest = SHA256.hash(material)
            coefficients.append(DecayFieldElement(reducingBigEndian: Data(digest)))
        }
        self.secret = coefficients[0]

        // Evaluate the polynomial at xᵢ = i (i = 1…N) by Horner's method.
        var built: [DecaySharePoint] = []
        for shareIndex in 1...totalShares {
            let x = DecayFieldElement(UInt64(shareIndex))
            var y = coefficients[coefficients.count - 1]
            for coefIndex in stride(from: coefficients.count - 2, through: 0, by: -1) {
                y = y.multiplying(x).adding(coefficients[coefIndex])
            }
            built.append(DecaySharePoint(x: x, y: y))
        }
        self.points = built
    }

    func sharePoints() -> [DecaySharePoint] { points }

    /// Shares lost per day, keyed off the grant's drift rate. These rates
    /// are reference values for conformance, not a tuned production decay
    /// curve (Appendix B.3 calls the real window probabilistic).
    private var sharesLostPerDay: Double {
        switch driftRate {
        case .slow:     return 1
        case .moderate: return 5
        case .fast:     return 25
        }
    }

    func validShareCount(now: Date) -> Int {
        let elapsed = now.timeIntervalSince(createdAt)
        guard elapsed > 0 else { return totalShares }
        let lost = Int((elapsed / 86_400) * sharesLostPerDay)
        return Swift.max(0, totalShares - lost)
    }
}

/// Clean-room Lagrange-over-GF(p) reconstruction of a custody-mode-3
/// scope key. See the clean-room provenance note at the top of this file.
enum LagrangeDecayKey {

    /// Lagrange interpolation evaluated at x = 0 over GF(p): the constant
    /// term of the unique degree-(n−1) polynomial through `points`.
    ///
    /// L(0) = Σᵢ yᵢ · Πⱼ≠ᵢ (−xⱼ) / (xᵢ − xⱼ). Each basis denominator is
    /// inverted in GF(p) (Fermat), so the result is exact with no rounding.
    static func interpolateConstantTerm(points: [DecaySharePoint]) -> DecayFieldElement {
        var accumulator = DecayFieldElement.zero
        for i in 0..<points.count {
            var numerator = DecayFieldElement.one
            var denominator = DecayFieldElement.one
            for j in 0..<points.count where j != i {
                numerator = numerator.multiplying(points[j].x.negated())
                denominator = denominator.multiplying(points[i].x.subtracting(points[j].x))
            }
            let basis = numerator.multiplying(denominator.inverse())
            accumulator = accumulator.adding(points[i].y.multiplying(basis))
        }
        return accumulator
    }

    /// Hash the reconstructed field element (SHA-256) to a 32-byte scope key.
    ///
    /// The field element is never used as key material directly; hashing gives
    /// a uniform 256-bit key that feeds ENC-01's `RowCrypto` (AES-GCM-256)
    /// unchanged. Uses the in-repo SHA-256 (SubstrateKernel.SHA256) so the
    /// output is byte-identical to the Rust port's `lagrange::key_from_secret`.
    static func key(fromSecret secret: DecayFieldElement) -> [UInt8] {
        SHA256.hash([UInt8](secret.bigEndianBytes()))
    }

    /// Reconstruct the scope key from a share provider at `now`.
    ///
    /// If fewer than `threshold` shares remain valid the key has decayed
    /// past recovery: throws `GrantError.keyDecayed` (Appendix B.7 — no
    /// partial recovery is attempted). Otherwise interpolates the secret
    /// from the first `threshold` still-valid shares and hashes it to the
    /// scope key (32 bytes, AES-256 width).
    static func reconstruct(
        threshold: Int,
        provider: DecayShareProvider,
        now: Date
    ) throws -> [UInt8] {
        let valid = provider.validShareCount(now: now)
        guard valid >= threshold else { throw GrantError.keyDecayed }
        // Drift consumes shares from the tail, so the first `valid` points
        // are the recoverable ones; any K of them reconstruct the secret.
        let chosen = Array(provider.sharePoints().prefix(threshold))
        let secret = interpolateConstantTerm(points: chosen)
        return key(fromSecret: secret)
    }
}
