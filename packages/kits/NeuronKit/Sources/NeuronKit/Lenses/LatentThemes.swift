import GeniusLocusKit

// Latent themes — soft topic factors (SPEC § 7.2, Lens 2 Topics). Given which
// labels co-occur, NMF factors them into k latent themes; each label gets a
// soft loading vector → mixed-membership reasoning ("60% theme A, 30% theme C"),
// not a hard bucket. Surfaces the GeniusLocusKit matrix-tier MatrixNMF; owns no
// math (I-17). Deterministic for a fixed seed (B-5); total over edge inputs
// (I-18, B-8).

/// One label's soft membership across the latent themes.
public struct ThemeLoading: Sendable, Equatable, Codable {
    public let label: String
    public let loadings: [Double]      // soft membership over k themes
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
    public let reconstructionError: Double  // Frobenius residual of the NMF factorisation
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
    public static func latentThemes(labels: [String],
                                    cooccurrence: [(labelA: String, labelB: String, weight: Double)],
                                    k: Int, seed: UInt64) -> LatentThemes {
        let n = labels.count
        guard n > 0, k > 0 else { return LatentThemes(k: 0, loadings: [], reconstructionError: 0) }

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

        let factorization = MatrixNMF.factorize(
            o: matrix, rows: n, cols: n, k: effectiveK, seed: seed)

        let loadings = labels.enumerated().map { (row, label) -> ThemeLoading in
            let vector = factorization.loadings(forRow: row)
            let dominant = vector.indices.max { vector[$0] < vector[$1] } ?? 0
            return ThemeLoading(label: label, loadings: vector, dominantTheme: dominant)
        }

        return LatentThemes(k: effectiveK, loadings: loadings,
                            reconstructionError: factorization.reconstructionError)
    }
}
