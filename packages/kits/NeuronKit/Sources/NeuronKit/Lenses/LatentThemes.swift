import GeniusLocusKit

// Latent themes — soft topic factors (SPEC § 7.2, Lens 2 Topics). Given which
// labels co-occur, NMF factors them into k latent themes; each label gets a
// soft loading vector → mixed-membership reasoning ("60% theme A, 30% theme C"),
// not a hard bucket. Surfaces the GeniusLocusKit matrix-tier MatrixNMF; owns no
// math (I-17). Deterministic for a fixed seed (B-5); total over edge inputs
// (I-18, B-8).
//
// Type boundary note: MatrixNMF (GLK) delegates to the canonical substrate
// NMFAlternatingLeastSquares and returns Float32 factors. NeuronKit's public
// ThemeLoading.loadings and LatentThemes.reconstructionError are Double for
// API stability; f32 values are widened to f64 at this boundary. Widening
// preserves the substrate's bit-exact values with no additional rounding.

/// One label's soft membership across the latent themes.
public struct ThemeLoading: Sendable, Equatable, Codable {
    public let label: String
    public let loadings: [Double]      // soft membership over k themes (widened from f32)
    public let dominantTheme: Int      // argmax index into loadings
    public init(label: String, loadings: [Double], dominantTheme: Int) {
        self.label = label
        self.loadings = loadings
        self.dominantTheme = dominantTheme
    }
}

/// The latent-theme factorization of a label co-occurrence.
public struct LatentThemes: Sendable, Equatable, Codable {
    public let k: Int                       // effective theme count (clamped to label count)
    public let loadings: [ThemeLoading]
    public let reconstructionError: Double  // RMS residual of the NMF factorisation (widened from f32)
    public init(k: Int, loadings: [ThemeLoading], reconstructionError: Double) {
        self.k = k
        self.loadings = loadings
        self.reconstructionError = reconstructionError
    }
}

extension NeuronKit {
    /// Factor the symmetric co-occurrence over `labels` into `k` latent themes.
    /// `cooccurrence` is sparse — `(labelA, labelB, weight)` — and treated as
    /// symmetric; pairs whose endpoints are not in `labels` are ignored. `k` is
    /// clamped to the label count. Each label gets a soft loading vector and its
    /// dominant theme (argmax). Deterministic for a fixed `seed`. No labels or
    /// `k <= 0` ⇒ empty factorization (C-16).
    /// Upper bound on distinct labels the dense n×n factorization will accept.
    /// n=4096 ⇒ a 4096² × 8B ≈ 128 MB matrix worst case; beyond this the O(n²)
    /// allocation becomes a local-DoS vector, so an over-cap input degrades to
    /// an empty factorization. Mirrors the Rust `MAX_LATENT_THEME_LABELS`.
    public static let maxLatentThemeLabels = 4096

    public static func latentThemes(labels: [String],
                                    cooccurrence: [(labelA: String, labelB: String, weight: Double)],
                                    k: Int, seed: UInt64) -> LatentThemes {
        let n = labels.count
        // DoS ceiling (see maxLatentThemeLabels): over-cap label counts degrade
        // to an empty factorization, consistent with the n==0 / k==0 C-16 path.
        guard n > 0, k > 0, n <= Self.maxLatentThemeLabels else {
            return LatentThemes(k: 0, loadings: [], reconstructionError: 0)
        }

        let effectiveK = min(k, n)

        // Build the dense symmetric n×n co-occurrence matrix (row-major). The
        // matrix is the primitive's input; the lens only shapes it.
        var indexOf = [String: Int](minimumCapacity: n)
        for (i, label) in labels.enumerated() { indexOf[label] = i }

        var matrix = [Double](repeating: 0, count: n * n)
        for (a, b, weight) in cooccurrence {
            guard let i = indexOf[a], let j = indexOf[b] else { continue }
            matrix[i * n + j] += weight
            if i != j { matrix[j * n + i] += weight }   // symmetric
        }

        // MatrixNMF delegates to the canonical substrate NMFAlternatingLeastSquares
        // (f32, RMS error). Loadings and reconstruction error are Float32; widened
        // to Double here at the NeuronKit public-API boundary.
        let factorization = MatrixNMF.factorize(
            o: matrix, rows: n, cols: n, k: effectiveK, seed: seed)

        let loadings = labels.enumerated().map { (row, label) -> ThemeLoading in
            // Widen Float32 loadings to Double at the NeuronKit boundary.
            let vector = factorization.loadings(forRow: row).map { Double($0) }
            let dominant = vector.indices.max { vector[$0] < vector[$1] } ?? 0
            return ThemeLoading(label: label, loadings: vector, dominantTheme: dominant)
        }

        // Widen Float32 RMS error to Double at the NeuronKit boundary.
        return LatentThemes(k: effectiveK, loadings: loadings,
                            reconstructionError: Double(factorization.reconstructionError))
    }
}
